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

# Backup-LabFile PATH: before changing PATH, copy it to the run's backup
# folder and record it, so rollback can put it back. If PATH does not exist
# yet, record that the module creates it.
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
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        Add-LabManifestEntry -Action file -Target $Path -Backup $dest
    } else {
        Add-LabManifestEntry -Action file_created -Target $Path
    }
}

# Copy-LabBackup -Backup B -Target T: put a backed-up file back. An existing
# target is overwritten in place, so it keeps its permissions (ACL).
function Copy-LabBackup {
    param([Parameter(Mandatory)] [string] $Backup, [Parameter(Mandatory)] [string] $Target)
    if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) { throw "restore: backup missing: $Backup" }
    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "restore: $Target is no longer a regular file; restore it by hand from $Backup"
        }
        [IO.File]::WriteAllBytes($Target, [IO.File]::ReadAllBytes($Backup))
    } else {
        Copy-Item -LiteralPath $Backup -Destination $Target
    }
}

# Restore-LabBackup: undo every file entry $env:LAB_MODULE_ID recorded in
# $env:LAB_RUN_ID, newest first. A file the module created is moved into the
# backup folder, never deleted. Safe to run repeatedly.
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
            try { Move-Item -LiteralPath $e.target -Destination $aside }
            catch { [Console]::Error.WriteLine($_.Exception.Message); $failed++ }
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
