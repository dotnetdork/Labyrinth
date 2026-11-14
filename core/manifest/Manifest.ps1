#Requires -Version 5.1
# core/manifest/Manifest.ps1: the run manifest (docs/Conventions.md section 7).
# Dot-sourced through core/Lab.ps1.
#
# The manifest of a run is $env:LAB_STATE_DIR\runs\<run>\manifest.jsonl: one
# JSON object per line, all values strings, with the fields
#   ts run host module seq action target backup prev note
# Every change is recorded BEFORE it is made, so a run cut off at any point
# can still be rolled back: undoing a recorded change that never happened
# is harmless. Rollback replays a module's entries newest first.
#
# Never record a secret. `prev` holds a previous value only when that value
# is not secret; anything secret is restored from a backup file instead.

function Get-LabManifestPath {
    param([string] $RunId = $env:LAB_RUN_ID)
    return Join-Path (Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $RunId) 'manifest.jsonl'
}

function Get-LabManifestNextSeq {
    $f = Get-LabManifestPath
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return 1 }
    return @([IO.File]::ReadAllLines($f)).Count + 1
}

# Add-LabManifestEntry -Action ACTION [-Target T] [-Backup B] [-Prev P] [-Note N]:
# append an entry for $env:LAB_MODULE_ID. Refused in plan mode.
function Add-LabManifestEntry {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [AllowEmptyString()] [string] $Target = '',
        [AllowEmptyString()] [string] $Backup = '',
        [AllowEmptyString()] [string] $Prev = '',
        [AllowEmptyString()] [string] $Note = ''
    )
    if ($env:LAB_DRY_RUN -ne '0') { throw "manifest: refused in plan mode ($Action $Target)" }
    if ($Action -cnotmatch '^[a-z0-9_]+$') { throw "manifest: bad action name: $Action" }
    # Control characters are kept: ConvertTo-LabJsonString escapes them, and
    # refusing them would let an attacker's file name stop a quarantine.
    $fields = [ordered]@{
        ts = Get-LabUtcNow; run = "$env:LAB_RUN_ID"; host = Get-LabHostName; module = "$env:LAB_MODULE_ID"
        seq = [string](Get-LabManifestNextSeq); action = $Action; target = $Target; backup = $Backup; prev = $Prev; note = $Note
    }
    $line = '{' + (($fields.Keys | ForEach-Object { '"{0}":{1}' -f $_, (ConvertTo-LabJsonString $fields[$_]) }) -join ',') + '}'
    Add-LabTextLine -Path (Get-LabManifestPath) -Line $line
}

# Get-LabManifestEntry [-RunId RUN]: the run's entries, oldest first.
function Get-LabManifestEntry {
    param([string] $RunId = $env:LAB_RUN_ID)
    $f = Get-LabManifestPath $RunId
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return }
    foreach ($line in [IO.File]::ReadAllLines($f)) {
        if ($line.Trim() -ne '') { $line | ConvertFrom-Json }
    }
}

# The native calls behind Open-LabFileNoFollow. CreateFileW with
# FILE_FLAG_OPEN_REPARSE_POINT opens a symbolic link or junction itself
# rather than what it points to, and GetFileInformationByHandle then tells
# what was opened, through the same handle, so the check and the use can
# never be two looks at the path.
$script:LabFileSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LabFile {
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
        public uint Attributes;
        public uint CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
        public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);

    const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, ShareRead = 0x1;
    const uint CreateNew = 1, OpenExisting = 3, OpenReparsePoint = 0x00200000;
    const uint AttrDirectory = 0x10, AttrReparsePoint = 0x400;

    // Open PATH without following a link at its last name. An existing
    // file opens only if it is a plain file (not a link, junction or
    // folder); otherwise this throws InvalidDataException, having read and
    // written nothing. With create, PATH must not exist yet, not even as a
    // link, and is made new.
    public static FileStream Open(string path, bool write, bool create) {
        uint access = write ? (GenericRead | GenericWrite) : GenericRead;
        SafeFileHandle h = CreateFileW(path, access, ShareRead, IntPtr.Zero,
            create ? CreateNew : OpenExisting, OpenReparsePoint, IntPtr.Zero);
        if (h.IsInvalid) {
            throw new IOException(path + ": " + new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
        }
        Info info;
        if (!GetFileInformationByHandle(h, out info)) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new IOException(path + ": " + new System.ComponentModel.Win32Exception(err).Message);
        }
        if ((info.Attributes & (AttrDirectory | AttrReparsePoint)) != 0) {
            h.Dispose();
            throw new InvalidDataException(path + " is not a regular file");
        }
        return new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read);
    }
}
'@

# Open-LabFileNoFollow -Path P [-Write] [-Create]: a FileStream on P that is
# never a link's target (LabFile.Open above). Throws
# [IO.InvalidDataException] when P is a link, junction or folder.
function Open-LabFileNoFollow {
    param([Parameter(Mandatory)] [string] $Path, [switch] $Write, [switch] $Create)
    if (-not ('LabFile' -as [type])) { Add-Type -TypeDefinition $script:LabFileSource }
    return [LabFile]::Open($Path, [bool]$Write, [bool]$Create)
}

# Backup-LabFile PATH: before changing PATH, copy it to the run's backup
# folder and record it, so rollback can put it back. If PATH does not exist
# yet, record that the module creates it. PATH is read through one handle
# opened without following a link (Open-LabFileNoFollow), so a link put in
# its place after the check is never read: the backup then throws, records
# nothing, and the module must leave PATH alone.
function Backup-LabFile {
    param([Parameter(Mandatory)] [string] $Path)
    if ($Path -notmatch '^([A-Za-z]:\\|\\\\)') { throw "backup: path must be absolute: $Path" }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "backup: not a regular file: $Path"
        }
        $dir = Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $env:LAB_MODULE_ID
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $dest = Join-Path $dir ('{0}-{1}' -f (Get-LabManifestNextSeq), $item.Name)
        try {
            $in = Open-LabFileNoFollow -Path $Path
        } catch [IO.InvalidDataException] {
            throw "backup: $Path changed while it was being read (a link or another file in its place); it was not backed up, so leave it alone"
        }
        try {
            $out = [IO.File]::Open($dest, [IO.FileMode]::Create, [IO.FileAccess]::Write)
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        } catch {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            throw "backup: could not copy $Path to ${dest}: $($_.Exception.Message)"
        } finally {
            $in.Dispose()
        }
        Add-LabManifestEntry -Action file -Target $Path -Backup $dest
    } else {
        Add-LabManifestEntry -Action file_created -Target $Path
    }
}

# Copy-LabBackup -Backup B -Target T: put a backed-up file back. An existing
# target is overwritten in place, so it keeps its permissions (ACL). The
# target is opened without following a link (Open-LabFileNoFollow), and a
# missing one is created new, so a link put there after the check is never
# written through.
function Copy-LabBackup {
    param([Parameter(Mandatory)] [string] $Backup, [Parameter(Mandatory)] [string] $Target)
    if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) { throw "restore: backup missing: $Backup" }
    $exists = Test-Path -LiteralPath $Target
    if ($exists) {
        $item = Get-Item -LiteralPath $Target -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "restore: $Target is no longer a regular file; restore it by hand from $Backup"
        }
    }
    try {
        $out = Open-LabFileNoFollow -Path $Target -Write -Create:(-not $exists)
    } catch [IO.InvalidDataException] {
        throw "restore: $Target is no longer a regular file; restore it by hand from $Backup"
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($Backup)
        $out.SetLength(0)
        $out.Write($bytes, 0, $bytes.Length)
    } finally {
        $out.Dispose()
    }
}

# Restore-LabBackup: undo every file entry $env:LAB_MODULE_ID recorded in
# $env:LAB_RUN_ID, newest first. A file the module created is moved into the
# backup folder, never deleted, and made private to administrators there.
# Safe to run repeatedly.
function Restore-LabBackup {
    $entries = @(Get-LabManifestEntry)
    [array]::Reverse($entries)
    $failed = 0
    foreach ($e in $entries) {
        if ($e.module -cne $env:LAB_MODULE_ID) { continue }
        if ($e.action -ceq 'file') {
            try { Copy-LabBackup -Backup $e.backup -Target $e.target }
            catch { [Console]::Error.WriteLine($_.Exception.Message); $failed++ }
        } elseif ($e.action -ceq 'file_created' -and (Test-Path -LiteralPath $e.target)) {
            $dir = Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $env:LAB_MODULE_ID
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $aside = Join-Path $dir ('rolled-back-{0}-{1}' -f $e.seq, (Split-Path -Leaf $e.target))
            # A moved file keeps its own owner and access list, so it is made
            # private like every copy under the data root; they go in the log.
            try {
                if ((Get-Item -LiteralPath $e.target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "restore: $($e.target) is now a link; move it away by hand"
                }
                $was = 'unknown'
                try { $was = Get-LabFileSddl -Path $e.target } catch { Write-Verbose 'access list not read' }
                Move-Item -LiteralPath $e.target -Destination $aside
                Protect-LabCopy -Path $aside
                try { Write-LabLog -EventName rolled_back_file -Message "moved $($e.target), which the module created, to $aside (owner and access were $was)" } catch { Write-Verbose 'log not written' }
            } catch { [Console]::Error.WriteLine($_.Exception.Message); $failed++ }
        }
    }
    if ($failed -gt 0) { throw "restore: $failed file(s) could not be restored" }
}

# Get-LabAppliedModule -RunId RUN: the modules the run applied and has not
# rolled back since, oldest first.
function Get-LabAppliedModule {
    param([Parameter(Mandatory)] [string] $RunId)
    $mods = New-Object Collections.Generic.List[string]
    foreach ($e in @(Get-LabManifestEntry -RunId $RunId)) {
        if ($e.action -ceq 'apply_start' -and -not $mods.Contains($e.module)) { $mods.Add($e.module) }
        elseif ($e.action -ceq 'rolled_back') { [void]$mods.Remove($e.module) }
    }
    return , $mods.ToArray()
}

# Get-LabKeptModule -RunId RUN: the modules of the run that were kept once
# verified (module_kept) and not applied again or rolled back since, oldest
# first. rollback leaves them alone unless told -All (Conventions 3.1).
function Get-LabKeptModule {
    param([Parameter(Mandatory)] [string] $RunId)
    $mods = New-Object Collections.Generic.List[string]
    foreach ($e in @(Get-LabManifestEntry -RunId $RunId)) {
        if ($e.action -ceq 'module_kept') { if (-not $mods.Contains($e.module)) { $mods.Add($e.module) } }
        elseif ($e.action -ceq 'apply_start' -or $e.action -ceq 'rolled_back') { [void]$mods.Remove($e.module) }
    }
    return , $mods.ToArray()
}
