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
    for Get-Help about_Labyrinth and the tab completion for laby and
    labyrinth (the Labyrinth module; Import-Module Labyrinth turns it on), and
    copies the config\*.example templates
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
    Description       = 'The help topic for Labyrinth (Get-Help about_Labyrinth) and tab completion for laby and labyrinth. It has no commands.'
    PowerShellVersion = '5.1'
    RootModule        = 'Labyrinth.psm1'
    FunctionsToExport = @()
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FileList          = @('Labyrinth.psm1', 'en-US\about_Labyrinth.help.txt')
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
        '(Get-Help about_Labyrinth), adds tab completion for laby and labyrinth'
        '(the Labyrinth module; Import-Module Labyrinth turns it on) and copies'
        'the configuration templates into DIR\etc (files already there are'
        'kept). For tests only: -CodeDir, -ModuleDir and -NoPath.'
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
    return (Get-LabReleaseSha -Path $A) -ceq (Get-LabReleaseSha -Path $B)
}

# Test-LabDataRootLocked PATH: is PATH private, with nothing inherited from
# its parent, Administrators and SYSTEM given full control, and nobody but an
# administrator given anything? The runner adds the account that runs it
# (Protect-LabDataRoot), which is an administrator, so a data root it has
# used still counts as private.
function Test-LabDataRootLocked {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $admins = @(Get-LabAdminSid)
    $seen = @()
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow') { continue }
        if ($admins -cnotcontains $r.IdentityReference.Value) { return $false }
        if ($r.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl) { $seen += $r.IdentityReference.Value }
    }
    return (($seen -ccontains $AdminSid) -and ($seen -ccontains $SystemSid))
}

# Find-LabForeignOwner PATH: the first item in PATH, PATH included, owned by
# an account other than Administrators, SYSTEM or the one running this, or
# $null. Such an item was planted: its owner can still change it after the
# folder is made private, so a person must check it.
function Find-LabForeignOwner {
    param([string] $Path)
    $trusted = @(Get-LabTrustedSid)
    foreach ($i in @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        $owner = $i.GetAccessControl('Owner').GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($trusted -cnotcontains $owner) { return $i.FullName }
    }
    return $null
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
    } elseif ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 has no CreateDirectory(path, security); this creates the
        # folder with its access list in one step all the same (Microsoft Learn,
        # FileSystemAclExtensions.Create).
        [IO.FileSystemAclExtensions]::Create((New-Object IO.DirectoryInfo $Path), $acl)
    } else {
        [void][IO.Directory]::CreateDirectory($Path, $acl)
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
    # Get-LabReleaseFile returns its list as one object: @() would wrap it again.
    foreach ($f in (Get-LabReleaseFile -Root $Here)) {
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
    # code, and so does the revert timer. A data root that is already there
    # but still open (C:\ProgramData lets every user create files) is made
    # private first and checked after that, unless something in it belongs
    # to another account.
    $rootNew = -not (Test-Path -LiteralPath $Root)
    $rootLocked = (-not $rootNew) -and (Test-LabDataRootLocked -Path $Root)
    if (-not $rootNew) {
        $foreign = Find-LabForeignOwner -Path $Root
        if ($foreign) {
            Exit-LabInstall 20 "$foreign belongs to an account that is not an administrator, so nothing was installed" `
                'Check it and remove it by hand, then run the installer again.'
        }
    }
    $checkNow = @($CodeDir, $HelpModule)
    if ($rootNew -or $rootLocked) { $checkNow += $Root }
    $untrusted = Find-LabUntrustedItem -Path $checkNow
    if ($untrusted) {
        Exit-LabInstall 20 "$untrusted can be changed by an account other than an administrator, so nothing was installed" `
            'Fix its permissions so only Administrators and SYSTEM can write there, then run the installer again.'
    }

    # Another program with one of the names. The code folder goes at the end
    # of the PATH, so the other program would win. A taken labyrinth is
    # refused, as on Linux. laby.cmd is part of the release and stays, but a
    # taken laby is named in the plan and the command to type is labyrinth.
    $taken = @{}
    foreach ($n in @('laby', 'labyrinth')) {
        foreach ($c in @(Get-Command $n -All -ErrorAction SilentlyContinue)) {
            if ($c.CommandType -notin 'Application', 'ExternalScript') { continue }
            if ($c.Source -and -not $c.Source.StartsWith($CodeDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $taken.ContainsKey($n)) { $taken[$n] = $c.Source }
            }
        }
    }
    if ($taken.ContainsKey('labyrinth')) {
        Exit-LabInstall 20 "the command name labyrinth is taken: a command named labyrinth is already at $($taken['labyrinth'])" `
            'Nothing was installed. Remove or rename that command, then run the installer again.'
    }
    $cmd = 'laby'
    if ($taken.ContainsKey('laby')) { $cmd = 'labyrinth' }

    # 3. What is already there, and so what the install will do.
    $codeState = 'new'
    if (Test-Path -LiteralPath $CodeDir) {
        $codeState = 'replace'
        if ($release.Status -eq 'ok') {
            $have = Test-LabRelease -Root $CodeDir
            if ($have.Status -eq 'ok' -and $have.Hash -ceq $release.Hash) { $codeState = 'same' }
        }
    }
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
    # The tab completion: a module file beside the help topic. A copy with no
    # completion file keeps the module as the help topic alone.
    $completer = Join-Path $Here 'core\completion\Labyrinth.psm1'
    $compState = 'skip'
    if (Test-Path -LiteralPath $completer -PathType Leaf) {
        $compState = 'new'
        if ((Test-LabSameFile $completer (Join-Path $HelpModule 'Labyrinth.psm1')) -and
            (Test-Path -LiteralPath (Join-Path $HelpModule 'Labyrinth.psd1') -PathType Leaf) -and
            ([IO.File]::ReadAllText((Join-Path $HelpModule 'Labyrinth.psd1')) -ceq $ModuleManifest)) { $compState = 'same' }
    }
    $pathState = 'skip'
    if (-not $NoPath) { $pathState = 'new'; if (Test-LabMachinePath -Folder $CodeDir) { $pathState = 'same' } }

    $todo = ($codeState -ne 'same') -or $rootNew -or $subsMissing -or (-not $rootLocked) -or ($templates.Count -gt 0) -or
        ($helpState -eq 'new') -or ($compState -eq 'new') -or ($pathState -eq 'new')

    # 4. The screen, before the question: the release hash to compare by eye
    # with the offline record, then what changes on this host.
    if ($taken.ContainsKey('laby')) {
        [Console]::Error.WriteLine("${Me}: warning: laby is taken by $($taken['laby']): type labyrinth instead")
    }
    . (Join-Path $Here 'core\banner\Banner.ps1')
    $unicode = Test-LabBannerUnicode
    $arrow = $unicode -and (Test-LabBannerText $LabBox.Arrow)
    $version = 'unknown'
    $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Here 'labyrinth.ps1')), "(?m)^\`$LabVersion = '([^']+)'")
    if ($m.Success) { $version = $m.Groups[1].Value }
    $sha = ''
    if ($release.Status -eq 'ok') { $sha = $release.Hash }
    $state = @{ new = 'new'; replace = 'replaced'; same = 'unchanged' }[$codeState]
    $program = $state
    if ($codeState -eq 'replace') {
        # The version being replaced, when it differs from this one.
        $installed = Join-Path $CodeDir 'labyrinth.ps1'
        if (Test-Path -LiteralPath $installed -PathType Leaf) {
            $o = [regex]::Match([IO.File]::ReadAllText($installed), "(?m)^\`$LabVersion = '([^']+)'")
            if ($o.Success -and $version -ne 'unknown' -and $o.Groups[1].Value -cne $version) {
                $program = "replaced: $($o.Groups[1].Value) -> $version"
            }
        }
    }
    $rows = @(, @('Program', "$CodeDir ($program)"))
    if ($rootNew) { $rows += , @('Data', "$Root (new, private)") }
    elseif ($rootLocked) { $rows += , @('Data', "$Root (kept)") }
    else { $rows += , @('Data', "$Root (kept, made private)") }
    if ($taken.ContainsKey('laby')) { $rows += , @('Commands', "labyrinth ($state; laby is taken)") }
    else { $rows += , @('Commands', "laby, labyrinth ($state)") }
    if ($pathState -eq 'skip') { $rows += , @('PATH', 'not changed (-NoPath)') }
    elseif ($pathState -eq 'same') { $rows += , @('PATH', "has $CodeDir (unchanged)") }
    else { $rows += , @('PATH', "adds $CodeDir") }
    if ($helpState -eq 'skip') { $rows += , @('Manual', 'skipped: this copy has no built manual (manual\about_Labyrinth.help.txt)') }
    elseif ($helpState -eq 'same') { $rows += , @('Manual', 'Get-Help about_Labyrinth (unchanged)') }
    else { $rows += , @('Manual', 'Get-Help about_Labyrinth (new)') }
    if ($compState -eq 'same') { $rows += , @('Tab keys', 'Import-Module Labyrinth (unchanged)') }
    elseif ($compState -eq 'new') { $rows += , @('Tab keys', 'Import-Module Labyrinth turns it on (new)') }
    else { $rows += , @('Tab keys', 'skipped: this copy has no core\completion\Labyrinth.psm1') }
    $config = "$($templates.Count) templates"
    if ($kept -gt 0) { $config = "$($templates.Count) copied, $kept kept" }
    elseif ($templates.Count -eq 1) { $config = '1 template' }
    $rows += , @('Config', "$config -> $Root\etc")
    foreach ($line in @(Get-LabBanner -Unicode $unicode -Version $version -Sha $sha) + @('') +
        @(Get-LabBannerTree -Unicode $unicode -Arrow $arrow -Rows $rows)) {
        [Console]::Out.WriteLine($line)
    }

    if (-not $todo) {
        [Console]::Out.WriteLine('')
        foreach ($line in @(Get-LabBannerList -Unicode $unicode -Heading 'ALREADY INSTALLED' `
                    -Items @('This release is already in place. Nothing to change.'))) {
            [Console]::Out.WriteLine($line)
        }
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
        Write-LabTerminal '  Install? [y/N] '
        $answer = Read-LabTerminal
        if ($null -eq $answer -or @('y', 'yes') -cnotcontains "$answer".Trim().ToLowerInvariant()) {
            [Console]::Out.WriteLine('')
            [Console]::Out.WriteLine('  Nothing was changed.')
            exit 0
        }
    }

    # 6. The install.
    # The data root: private to Administrators and SYSTEM. What is inside an
    # existing one is not touched.
    if ($rootNew -or -not $rootLocked) { Lock-LabDataRoot -Path $Root }
    if (-not $rootNew -and -not $rootLocked) {
        $untrusted = Find-LabUntrustedItem -Path @($Root)
        if ($untrusted) {
            Exit-LabInstall 20 "the data root was made private, but $untrusted can still be changed by an account other than an administrator" `
                'Nothing else was installed. Fix its permissions so only Administrators and SYSTEM can write there, then run the installer again.'
        }
    }
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
    # The tab completion goes in the same module: Labyrinth.psm1 registers it
    # when the module is imported.
    if ($helpState -eq 'new' -or $compState -eq 'new') {
        $lang = Join-Path $HelpModule 'en-US'
        if (-not (Test-Path -LiteralPath $lang)) { [void][IO.Directory]::CreateDirectory($lang) }
        if ($helpState -eq 'new') { [IO.File]::Copy($topic, (Join-Path $lang 'about_Labyrinth.help.txt'), $true) }
        if ($compState -eq 'new') { [IO.File]::Copy($completer, (Join-Path $HelpModule 'Labyrinth.psm1'), $true) }
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

    $items = @("Fill in $Root\etc: hosts and protected-accounts`nhold placeholder names (manual, section 10)")
    if ($taken.ContainsKey('laby')) { $items += 'laby is taken here, so the command is labyrinth' }
    if ($pathState -eq 'new') { $items += "Open a new PowerShell window so it finds $cmd" }
    if ($compState -ne 'skip') { $items += "For tab completion, add this line to your PowerShell profile:`nImport-Module Labyrinth" }
    $rootArg = ''
    if ($Root -ne $DefaultRoot) { $rootArg = " -Root `"$Root`"" }
    # Each host makes its own decoy seed once it runs, never here: a seed made
    # by the installer would be copied with the machine (design 16, section 4.1).
    $items += "Make this host's decoy seed: $cmd -NewSeed$rootArg`nand post it in the team chat with the host name"
    $items += "Next: $cmd$rootArg"
    # After the question, a blank line; with -y one is already there.
    if (-not $Yes) { [Console]::Out.WriteLine('') }
    foreach ($line in @(Get-LabBannerList -Unicode $unicode -Heading 'INSTALLED' -Items $items)) {
        [Console]::Out.WriteLine($line)
    }
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
