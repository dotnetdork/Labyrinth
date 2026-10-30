#Requires -Version 5.1
<#
.SYNOPSIS
    The guided installer for Windows (docs\Conventions.md section 3.3;
    design 00 section 5.1 and design 21).

.DESCRIPTION
    Run it from the release folder in a PowerShell window opened with 'Run
    as administrator'. It checks the release against release.sha256, prints
    its plan and asks 'Install? [y/N]' (default no). Then it creates the data
    root (C:\ProgramData\Labyrinth, only Administrators and SYSTEM can use
    it), copies the code to C:\Program Files\Labyrinth, adds that folder to
    the machine PATH so that laby and labyrinth work, installs the help topic
    for Get-Help about_Labyrinth, and copies the config\*.example templates
    into <root>\etc without overwriting a file already there. Safe to run
    again. It refuses, changing nothing, while a revert timer is armed.

    -CodeDir, -ModuleDir and -NoPath exist for the tests only: they point the
    installer at throwaway folders and skip the PATH change, so a test run
    never edits the real system folders or the machine PATH.

    Exit codes: 0 installed, or nothing to change; 20 refused; 40 error.

.PARAMETER Yes
    Answer yes to the question (-y).

.PARAMETER Root
    The data root (default C:\ProgramData\Labyrinth).

.EXAMPLE
    .\install.ps1
#>
param(
    [Alias('y')] [switch] $Yes,
    [string] $Root = 'C:\ProgramData\Labyrinth',
    [string] $CodeDir = '',
    [string] $ModuleDir = '',
    [switch] $NoPath,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultRoot = 'C:\ProgramData\Labyrinth'
$Here = $PSScriptRoot
$Me = 'install.ps1'
# The accounts that may use the data root and change the code: Administrators
# and SYSTEM, by their well-known SIDs, so the names do not depend on the language.
$AdminSid = 'S-1-5-32-544'
$SystemSid = 'S-1-5-18'
$EnvKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
# The help module has no commands: it carries the help topic only. The GUID is
# fixed, so running the installer again writes the same manifest.
$ModuleManifest = @"
@{
    ModuleVersion     = '1.0.0'
    GUID              = '6f1c9d1e-2a4b-4c8e-9a53-0b7d5e2f4a11'
    Author            = 'Labyrinth'
    Description       = 'The help topic for Labyrinth: Get-Help about_Labyrinth. It has no commands.'
    PowerShellVersion = '5.1'
    FileList          = @('en-US\about_Labyrinth.help.txt')
}

"@

function Show-LabInstallHelp {
    @(
        'Usage: .\install.ps1 [-y] [-Root DIR]'
        ''
        'Installs Labyrinth from this release folder. Run it as an Administrator.'
        'It checks the release, shows what it will do and asks before it changes'
        'anything. Safe to run again.'
        ''
        '  -y, -Yes      answer yes to the question'
        '  -Root DIR     the data root (default C:\ProgramData\Labyrinth)'
        '  -Help         this page'
        ''
        'It adds the code in C:\Program Files\Labyrinth, puts that folder on the'
        'machine PATH (the commands laby and labyrinth), installs the help topic'
        '(Get-Help about_Labyrinth) and copies the configuration templates into'
        'DIR\etc (files already there are kept). For tests only: -CodeDir,'
        '-ModuleDir and -NoPath.'
        'Exit: 0 done, 20 refused, 40 error.'
        'Example: .\install.ps1'
    ) | ForEach-Object { [Console]::Out.WriteLine($_) }
}

# Exit-LabInstall CODE WHAT [HINT]: say what stopped the install, and exit.
function Exit-LabInstall {
    param([int] $Code, [string] $What, [string] $Hint = '')
    [Console]::Error.WriteLine("${Me}: $What")
    if ($Hint -ne '') { [Console]::Error.WriteLine($Hint) }
    exit $Code
}

function Write-LabRow {
    param([string] $Label, [string] $Text)
    [Console]::Out.WriteLine(('  ' + $Label.PadRight(11) + $Text))
}

# Get-LabFullPath PATH: PATH as a full path with no closing backslash.
function Get-LabFullPath {
    param([string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $rootOnly = [IO.Path]::GetPathRoot($full)
    if ($full -eq $rootOnly) { return $full }
    return $full.TrimEnd('\')
}

# Test-LabSameFile A B: do two files hold the same bytes?
function Test-LabSameFile {
    param([string] $A, [string] $B)
    if (-not ((Test-Path -LiteralPath $A -PathType Leaf) -and (Test-Path -LiteralPath $B -PathType Leaf))) { return $false }
    return (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

# Test-LabDataRootLocked PATH: can only Administrators and SYSTEM use PATH,
# with nothing inherited from its parent?
function Test-LabDataRootLocked {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $seen = @()
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow' -or $r.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) { return $false }
        if (@($AdminSid, $SystemSid) -cnotcontains $r.IdentityReference.Value) { return $false }
        $seen += $r.IdentityReference.Value
    }
    return (($seen -ccontains $AdminSid) -and ($seen -ccontains $SystemSid))
}

# Lock-LabDataRoot PATH: make PATH usable by Administrators and SYSTEM only,
# without the rights it would inherit from C:\ProgramData, where every user
# may create files. A new folder is made with that access list, so nobody
# can slip a file in first.
function Lock-LabDataRoot {
    param([string] $Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($AdminSid, $SystemSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    if (Test-Path -LiteralPath $Path) {
        Set-Acl -LiteralPath $Path -AclObject $acl
    } elseif ($PSVersionTable.PSVersion.Major -le 5) {
        [void][IO.Directory]::CreateDirectory($Path, $acl)
    } else {
        [void][IO.Directory]::CreateDirectory($Path)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

# Test-LabMachinePath FOLDER: is FOLDER already on the machine PATH?
function Test-LabMachinePath {
    param([string] $Folder)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($EnvKey)
    try {
        $cur = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Close()
    }
    foreach ($part in $cur.Split(';')) {
        if ($part.Trim() -eq '') { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($part.Trim()).TrimEnd('\')
        if ($expanded -ieq $Folder.TrimEnd('\')) { return $true }
    }
    return $false
}

# Add-LabMachinePath FOLDER: add FOLDER to the end of the machine PATH. The
# value is read without expanding names such as %SystemRoot% and written back
# as an expandable string, so the other entries keep their form.
function Add-LabMachinePath {
    param([string] $Folder)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($EnvKey, $true)
    try {
        $cur = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $new = $Folder
        if ($cur.Trim() -ne '') { $new = $cur.TrimEnd(';') + ';' + $Folder }
        $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Close()
    }
}

if ($Help) { Show-LabInstallHelp; exit 0 }

# The folders: the code in Program Files, the help module in the machine-wide
# module folder. ProgramW6432 is the 64-bit Program Files, also from a 32-bit shell.
$programFiles = $env:ProgramW6432
if (-not $programFiles) { $programFiles = $env:ProgramFiles }
if ($CodeDir -eq '') { $CodeDir = Join-Path $programFiles 'Labyrinth' }
if ($ModuleDir -eq '') { $ModuleDir = Join-Path $programFiles 'WindowsPowerShell\Modules' }
foreach ($p in @($Root, $CodeDir, $ModuleDir)) {
    if (-not [IO.Path]::IsPathRooted($p) -or $p -notmatch '^[A-Za-z]:\\') {
        [Console]::Error.WriteLine("${Me}: the folder must be a full path, not '$p'")
        [Console]::Error.WriteLine("Try '.\$Me -Help'.")
        exit 40
    }
}
$Root = Get-LabFullPath $Root
$CodeDir = Get-LabFullPath $CodeDir
$ModuleDir = Get-LabFullPath $ModuleDir
$HelpModule = Join-Path $ModuleDir 'Labyrinth'

$stage = ''
$old = ''
try {
    # 1. The release. Checked before any of its files is run.
    if (-not (Test-Path -LiteralPath (Join-Path $Here 'labyrinth.ps1') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Here 'core\Lab.ps1') -PathType Leaf)) {
        Exit-LabInstall 20 "$Here is not a Labyrinth release folder" 'Run install.ps1 from the folder you unpacked.'
    }
    . (Join-Path $Here 'core\safety\Release.ps1')
    $release = Test-LabRelease -Root $Here
    if ($release.Status -eq 'problem') {
        Exit-LabInstall 20 "$($release.Problem), so this is not the release" `
            "Copy Labyrinth here again from the team's copy, as manual section 11 says."
    }
    $env:LAB_ROOT = $Here
    . (Join-Path $Here 'core\Lab.ps1')
    if (-not (Test-LabAdmin)) {
        Exit-LabInstall 20 'the installer must run as an Administrator' 'Open PowerShell with Run as administrator, then run it again.'
    }

    $files = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-LabReleaseFile -Root $Here)) {
        if ($f -cnotmatch '^[A-Za-z0-9._/-]+$' -or -not (Test-LabReleasePlain -Path (Join-Path $Here $f))) {
            Exit-LabInstall 20 "$f is not a plain file with a plain name, so the release cannot be installed"
        }
        $files.Add($f)
    }
    if ($release.Status -eq 'ok') { $files.Add('release.sha256') }

    # 2. Checks before anything changes.
    $hereFull = Get-LabFullPath $Here
    if ($hereFull -ieq $CodeDir -or $hereFull.StartsWith($CodeDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Exit-LabInstall 20 'this is the installed copy of Labyrinth' 'Run install.ps1 from the release folder you unpacked, not from the installed code.'
    }
    if ($CodeDir.StartsWith($hereFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Exit-LabInstall 20 "the code folder $CodeDir is inside the release folder" 'Choose a code folder outside it.'
    }
    if (Test-Path -LiteralPath $CodeDir) {
        $item = Get-Item -LiteralPath $CodeDir -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Exit-LabInstall 20 "$CodeDir is not a plain folder"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $CodeDir 'labyrinth.ps1') -PathType Leaf) -and
            @(Get-ChildItem -LiteralPath $CodeDir -Force).Count -gt 0) {
            Exit-LabInstall 20 "$CodeDir is not empty and is not a Labyrinth folder, so it will not be replaced" `
                'Move what is in it away, then run the installer again.'
        }
    }

    # A revert timer that is armed would run code that this install replaces.
    $env:LAB_STATE_DIR = Join-Path $Root 'state'
    $armed = @()
    $runsDir = Join-Path $env:LAB_STATE_DIR 'runs'
    if (Test-Path -LiteralPath $runsDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $runsDir -Directory -Force)) {
            if (-not (Test-LabRevertTimer -RunId $d.Name)) { continue }
            $due = Get-LabRevertTimerDue -RunId $d.Name
            if ($due -ne '') { $armed += "  run $($d.Name): its revert timer fires at $due (UTC)" }
            else { $armed += "  run $($d.Name): its revert timer is armed (fire time unknown)" }
        }
    }
    if ($armed.Count -gt 0) {
        [Console]::Error.WriteLine("${Me}: not installing, because a revert timer is armed:")
        foreach ($l in $armed) { [Console]::Error.WriteLine($l) }
        [Console]::Error.WriteLine("Keep the run ('laby -k ID') or undo it ('laby -u ID') first, then run the installer again.")
        exit 20
    }

    # Only Administrators, SYSTEM and TrustedInstaller may change the code, the
    # data root, the help module or any folder above them: SYSTEM runs this
    # code, and so does the revert timer.
    $untrusted = Find-LabUntrustedItem -Path @($Root, $CodeDir, $HelpModule)
    if ($untrusted) {
        Exit-LabInstall 20 "$untrusted can be changed by an account other than an administrator, so nothing was installed" `
            'Fix its permissions so only Administrators and SYSTEM can write there, then run the installer again.'
    }

    # Another command with the same name, found on the PATH before ours.
    $shadow = @()
    foreach ($n in @('laby', 'labyrinth')) {
        foreach ($c in @(Get-Command $n -All -ErrorAction SilentlyContinue)) {
            if ($c.CommandType -notin 'Application', 'ExternalScript') { continue }
            if ($c.Source -and -not $c.Source.StartsWith($CodeDir + '\', [StringComparison]::OrdinalIgnoreCase)) { $shadow += "$n is also at $($c.Source)" }
        }
    }
    if ($shadow.Count -gt 0) {
        [Console]::Error.WriteLine("${Me}: warning: another command has the same name: $($shadow -join '; ')")
        [Console]::Error.WriteLine('The one earlier on the PATH is the one that runs. Remove it, or use the other name.')
    }

    # 3. What is already there, and so what the install will do.
    $codeState = 'new'
    if (Test-Path -LiteralPath $CodeDir) {
        $codeState = 'replace'
        if ($release.Status -eq 'ok') {
            $have = Test-LabRelease -Root $CodeDir
            if ($have.Status -eq 'ok' -and $have.Hash -ceq $release.Hash) { $codeState = 'same' }
        }
    }
    $rootNew = -not (Test-Path -LiteralPath $Root)
    $rootLocked = (-not $rootNew) -and (Test-LabDataRootLocked -Path $Root)
    $subsMissing = $false
    foreach ($sub in @('etc', 'state', 'logs', 'backup')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $sub))) { $subsMissing = $true }
    }
    $templates = @()
    $kept = 0
    $cfg = Join-Path $Here 'config'
    if (Test-Path -LiteralPath $cfg) {
        foreach ($f in @(Get-ChildItem -LiteralPath $cfg -Filter '*.example' -File)) {
            $base = $f.Name.Substring(0, $f.Name.Length - '.example'.Length)
            if (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'etc') $base)) { $kept++ } else { $templates += $base }
        }
    }
    $topic = Join-Path $Here 'manual\about_Labyrinth.help.txt'
    $helpState = 'skip'
    if (Test-Path -LiteralPath $topic -PathType Leaf) {
        $helpState = 'new'
        $manifestFile = Join-Path $HelpModule 'Labyrinth.psd1'
        $topicFile = Join-Path $HelpModule 'en-US\about_Labyrinth.help.txt'
        if ((Test-LabSameFile $topic $topicFile) -and (Test-Path -LiteralPath $manifestFile -PathType Leaf) -and
            ([IO.File]::ReadAllText($manifestFile) -ceq $ModuleManifest)) { $helpState = 'same' }
    }
    $pathState = 'skip'
    if (-not $NoPath) { $pathState = 'new'; if (Test-LabMachinePath -Folder $CodeDir) { $pathState = 'same' } }

    $todo = ($codeState -ne 'same') -or $rootNew -or $subsMissing -or (-not $rootLocked) -or ($templates.Count -gt 0) -or
        ($helpState -eq 'new') -or ($pathState -eq 'new')

    # 4. The plan, before the question.
    [Console]::Out.WriteLine('Labyrinth install plan:')
    if ($release.Status -eq 'ok') { Write-LabRow 'Release:' $release.Hash }
    else { Write-LabRow 'Release:' 'not checked: this copy has no release.sha256' }
    if ($codeState -eq 'new') { Write-LabRow 'Code:' "$CodeDir (new)" }
    elseif ($codeState -eq 'replace') { Write-LabRow 'Code:' "$CodeDir (replaced completely)" }
    else { Write-LabRow 'Code:' "$CodeDir (already this release, unchanged)" }
    if ($rootNew) { Write-LabRow 'Data root:' "$Root (new; only Administrators and SYSTEM can use it)" }
    elseif ($rootLocked) { Write-LabRow 'Data root:' "$Root (already there and private; its files are never touched)" }
    else { Write-LabRow 'Data root:' "$Root (already there; made private to Administrators and SYSTEM)" }
    Write-LabRow 'Commands:' "laby.cmd and labyrinth.cmd, in $CodeDir"
    if ($pathState -eq 'skip') { Write-LabRow 'PATH:' 'not changed (-NoPath)' }
    elseif ($pathState -eq 'same') { Write-LabRow 'PATH:' "$CodeDir is already on the machine PATH" }
    else { Write-LabRow 'PATH:' "$CodeDir is added to the machine PATH (new windows only)" }
    if ($helpState -eq 'skip') { Write-LabRow 'Manual:' 'skipped: this copy has no built manual (manual\about_Labyrinth.help.txt)' }
    elseif ($helpState -eq 'same') { Write-LabRow 'Manual:' "$HelpModule (unchanged)" }
    else { Write-LabRow 'Manual:' "$HelpModule, for Get-Help about_Labyrinth" }
    Write-LabRow 'Settings:' "$($templates.Count) template(s) copied into $Root\etc; $kept file(s) already there kept"

    if (-not $todo) {
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('Labyrinth is already installed from this release. Nothing to change.')
        exit 0
    }

    # 5. The question. Default no. Without a terminal and without -y, refuse.
    [Console]::Out.WriteLine('')
    if (-not $Yes) {
        if (-not (Test-LabTerminal)) {
            [Console]::Error.WriteLine("${Me}: no terminal to ask on, so nothing was installed")
            [Console]::Error.WriteLine('Run it from a PowerShell window, or add -y to answer yes.')
            exit 40
        }
        Write-LabTerminal 'Install? [y/N] '
        $answer = Read-LabTerminal
        if ($null -eq $answer -or @('y', 'yes') -cnotcontains "$answer".Trim().ToLowerInvariant()) {
            [Console]::Out.WriteLine('Nothing was changed.')
            exit 0
        }
    }

    # 6. The install.
    # The data root: private to Administrators and SYSTEM. What is inside an
    # existing one is not touched.
    if ($rootNew -or -not $rootLocked) { Lock-LabDataRoot -Path $Root }
    foreach ($sub in @('etc', 'state', 'logs', 'backup')) {
        $dir = Join-Path $Root $sub
        if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    }

    # The code: built next to its final place, checked, then swapped in whole,
    # so no file of the old copy is left to fail the release check.
    if ($codeState -ne 'same') {
        $parent = Split-Path -Parent $CodeDir
        if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $stage = "$CodeDir.new-$suffix"
        [void][IO.Directory]::CreateDirectory($stage)
        foreach ($f in $files) {
            $target = Join-Path $stage ($f.Replace('/', '\'))
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
            [IO.File]::Copy((Join-Path $Here ($f.Replace('/', '\'))), $target, $false)
        }
        if ($release.Status -eq 'ok') {
            $made = Test-LabRelease -Root $stage
            if ($made.Status -ne 'ok') { Exit-LabInstall 20 "the copy made in $stage does not match the release: $($made.Problem)" }
        }
        if (Test-Path -LiteralPath $CodeDir) {
            $old = "$CodeDir.old-$suffix"
            [IO.Directory]::Move($CodeDir, $old)
        }
        [IO.Directory]::Move($stage, $CodeDir)
        $stage = ''
        if ($old -ne '') {
            # The old copy of Labyrinth's own code, now replaced. The .NET call does
            # not follow a junction the way Remove-Item -Recurse does in PowerShell 5.1.
            [IO.Directory]::Delete($old, $true)
            $old = ''
        }
    }

    # The configuration templates: a file that is already there is never touched.
    foreach ($base in $templates) {
        [IO.File]::Copy((Join-Path $cfg "$base.example"), (Join-Path (Join-Path $Root 'etc') $base), $false)
    }

    # The help topic, where Get-Help about_Labyrinth looks: a module folder with
    # a manifest and the topic in its en-US folder (Microsoft Learn, "Writing
    # Help for PowerShell Modules").
    if ($helpState -eq 'new') {
        $lang = Join-Path $HelpModule 'en-US'
        if (-not (Test-Path -LiteralPath $lang)) { [void][IO.Directory]::CreateDirectory($lang) }
        [IO.File]::Copy($topic, (Join-Path $lang 'about_Labyrinth.help.txt'), $true)
        [IO.File]::WriteAllText((Join-Path $HelpModule 'Labyrinth.psd1'), $ModuleManifest, (New-Object Text.UTF8Encoding $false))
    }

    # The commands (laby.cmd and labyrinth.cmd) came with the code. Last, the PATH,
    # so the names work only once the code they run is in place.
    if ($pathState -eq 'new') { Add-LabMachinePath -Folder $CodeDir }

    # 7. Check the result: only administrators can change what was installed.
    $after = Find-LabUntrustedItem -Path @($CodeDir)
    if ($after) {
        Exit-LabInstall 20 "$after can be changed by an account other than an administrator" `
            'The install is in place, but Labyrinth will refuse to run until that is fixed.'
    }

    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('Installed.')
    [Console]::Out.WriteLine("The templates are in $Root\etc without the .example ending. They hold")
    [Console]::Out.WriteLine('placeholders: replace the names in hosts and protected-accounts with the')
    [Console]::Out.WriteLine("event's, and see the manual (section 10) for the other files.")
    if ($pathState -eq 'new') { [Console]::Out.WriteLine('Open a new PowerShell window so that it finds the laby command.') }
    if ($Root -ne $DefaultRoot) { [Console]::Out.WriteLine("Next: laby -Root `"$Root`"") }
    else { [Console]::Out.WriteLine('Next: laby') }
} catch {
    [Console]::Error.WriteLine("${Me}: stopped: $($_.Exception.Message), exit 40")
    [Console]::Error.WriteLine('Some steps may be done. It is safe to run the installer again.')
    exit 40
} finally {
    # Only this installer's own staging and swap folders, made next to the code.
    if ($stage -ne '' -and (Test-Path -LiteralPath $stage)) { try { [IO.Directory]::Delete($stage, $true) } catch { $null = $_ } }
    if ($old -ne '' -and (Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $CodeDir)) {
        try { [IO.Directory]::Move($old, $CodeDir) } catch { $null = $_ }
    }
}
