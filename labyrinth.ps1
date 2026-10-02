#Requires -Version 5.1
<#
.SYNOPSIS
    Labyrinth main program for Windows hosts (design 00, section 5;
    docs/Conventions.md section 3.1).

.DESCRIPTION
    labyrinth.ps1 <phase> [options]           plan: show what would change (default)
    labyrinth.ps1 <phase> -Apply [options]    apply the plan, behind the safety gates
    labyrinth.ps1 probe [options]             probe every scored service once
    labyrinth.ps1 keep <run> [options]        keep a run's changes: cancel its revert timer
    labyrinth.ps1 rollback <run> [options]    undo what a run applied, newest module first

    Exit codes (design 00, section 4); the highest code from any module wins:
    0 nothing to do or success, 10 change needed, 20 blocked,
    30 verify failed or a scored service regressed, 40 error.

.EXAMPLE
    .\labyrinth.ps1 observe -Profile windows-member
#>
param(
    [Parameter(Position = 0)] [string] $Command = '',
    [Parameter(Position = 1)] [string] $RunId = '',
    [Alias('Profile')] [string] $ProfileName = '',
    [string] $Root = 'C:\ProgramData\Labyrinth',
    [string] $Config = '',
    [switch] $Apply,
    [string] $BreakGlass = '',
    [string] $ConfirmGroup = '',
    [switch] $Version,
    [switch] $Help,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabVersion = '0.1.0-dev'
$Phases = @('lockout', 'observe', 'deceive', 'sustain')
$ModuleKeys = @('id', 'phase', 'priority', 'platforms', 'risk', 'touches_scored', 'requires', 'outputs', 'spec')
$RequiredKeys = @('id', 'phase', 'priority', 'platforms', 'risk', 'touches_scored')
$Risks = @('read-only', 'reversible', 'service-affecting', 'approval', 'manual-only')
$Platforms = @('ubuntu', 'rhel-family', 'windows', 'appliance')
$ReRunId = '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$'
$ReModuleId = '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'

$script:Mod = @{}
$script:ProfileIds = @()
$script:EntryRc = 0
$script:Approved = ''
$script:PhaseCount = 0
$script:Run = @()            # the modules of this run, in run order
$script:Protected = @{}
$script:Settings = @{}
$script:Before = @()
$script:HaveServices = $false
$script:BreakGlassAccount = ''
$script:GivenBreakGlass = $BreakGlass   # -BreakGlass, read inside functions
$script:GivenGroup = $ConfirmGroup      # -ConfirmGroup, read inside functions
$script:Answer = ''

$Usage = @'
usage: labyrinth.ps1 <phase> [options]
       labyrinth.ps1 <phase> -Apply [options]
       labyrinth.ps1 probe | keep <run> | rollback <run> [options]

  <phase>              lockout | observe | deceive | sustain
  -Profile NAME        host profile (default: this host's line in the hosts file)
  -Root DIR            Labyrinth data root (default C:\ProgramData\Labyrinth)
  -Config DIR          run-time configuration (default <root>\etc)
  -Apply               apply the plan, behind the safety gates
  -BreakGlass NAME     the break-glass account confirmed at this host's console
  -ConfirmGroup GROUP  the host's group name, typed to approve the plan
  -Version             print the version
  -Help                this help

Plan mode is the default: modules report what they would change, and
nothing is changed. After an apply, the revert timer undoes the run unless
it is kept: type keep when asked, or run 'labyrinth.ps1 keep <run>'.
'@

function Write-LabLine {
    param([AllowEmptyString()] [string] $Text = '')
    [Console]::Out.WriteLine($Text)
}

function Exit-Lab {
    param([string] $Message, [int] $Code = 40)
    [Console]::Error.WriteLine("labyrinth: $Message")
    exit $Code
}

function Write-YmlError {
    param([string] $Where, [string] $Message)
    [Console]::Error.WriteLine("${Where}: $Message")
}

# Parse module.yml, the strict flat subset in docs/Conventions.md
# section 2.1, into $script:Mod. Returns $false on any other construct.
function Read-LabModuleYml {
    param([string] $File)
    $script:Mod = @{}
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Write-YmlError $File 'missing'; return $false }
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($File)) {
        $n++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -cnotmatch '^([a-z_]+):\s*(.*)$') { Write-YmlError "${File}:$n" 'not a key: value line'; return $false }
        $key = $Matches[1]; $value = $Matches[2]
        if ($ModuleKeys -cnotcontains $key) { Write-YmlError "${File}:$n" "unknown key $key"; return $false }
        if ($script:Mod.ContainsKey($key)) { Write-YmlError "${File}:$n" "duplicate key $key"; return $false }
        if ($value.StartsWith('[') -and $value -notmatch '^\[[^\[\]]*\]$') { Write-YmlError "${File}:$n" 'malformed list'; return $false }
        if ($value -match '^[&*|>{!%@]') { Write-YmlError "${File}:$n" 'YAML construct outside the flat subset'; return $false }
        $script:Mod[$key] = $value
    }
    foreach ($key in $RequiredKeys) {
        if (-not $script:Mod.ContainsKey($key) -or $script:Mod[$key] -eq '') { Write-YmlError $File "missing key $key"; return $false }
    }
    return $true
}

# Get-LabListItem VALUE: the items of an inline list; $null if not a list.
function Get-LabListItem {
    param([string] $Value)
    if ($Value -notmatch '^\[(.*)\]$') { return $null }
    return , @($Matches[1] -split '[,\s]+' | Where-Object { $_ -ne '' })
}

# Check $script:Mod's values against design 00, section 4.
function Test-LabModule {
    param([string] $File, [string] $WantId, [string] $WantPhase)
    $m = $script:Mod
    if ($m['id'] -cne $WantId) { Write-YmlError $File "id $($m['id']) does not match $WantId"; return $false }
    if ($m['phase'] -cne $WantPhase) { Write-YmlError $File "phase $($m['phase']) does not match $WantPhase"; return $false }
    if ($m['priority'] -cnotmatch '^P[0-3]$') { Write-YmlError $File 'priority must be P0 to P3'; return $false }
    if ($Risks -cnotcontains $m['risk']) { Write-YmlError $File "unknown risk $($m['risk'])"; return $false }
    if (@('true', 'false') -cnotcontains $m['touches_scored']) { Write-YmlError $File 'touches_scored must be true or false'; return $false }
    $list = Get-LabListItem $m['platforms']
    if ($null -eq $list) { Write-YmlError $File 'platforms must be a list'; return $false }
    if ($list.Count -eq 0) { Write-YmlError $File 'platforms is empty'; return $false }
    foreach ($p in $list) {
        if ($Platforms -cnotcontains $p) { Write-YmlError $File "unknown platform $p"; return $false }
    }
    if ($m.ContainsKey('requires') -and $null -eq (Get-LabListItem $m['requires'])) {
        Write-YmlError $File 'requires must be a list'; return $false
    }
    return $true
}

# Read a profile into $script:ProfileIds: one module id per line. A run-time
# profile of the same name replaces the shipped one (Conventions 2.3).
function Read-LabProfile {
    param([string] $Name)
    $file = Join-Path (Join-Path $env:LAB_CONFIG_DIR 'profiles') "$Name.profile"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $file = Join-Path (Join-Path $env:LAB_ROOT 'profiles') "$Name.profile"
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Exit-Lab "no profile named $Name" }
    $ids = @()
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($file)) {
        $n++
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -eq '') { continue }
        if ($line -cnotmatch $ReModuleId) { Exit-Lab "${file}:${n}: not a module id: $line" }
        $ids += $line
    }
    $script:ProfileIds = $ids
}

function Get-LabRunId {
    $bytes = New-Object byte[] 2
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return ('{0}-{1}' -f [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'"), $hex)
}

# Run one entry point as its own process with the contract's environment
# (docs/Conventions.md section 3). Its output goes straight to the
# operator; its exit code is left in $script:EntryRc.
function Invoke-LabEntry {
    param([string] $Dir, [string] $Entry, [string] $Id, [string] $DryRun = '1')
    $env:LAB_MODULE_ID = $Id
    $env:LAB_ENTRY = $Entry
    $env:LAB_DRY_RUN = $DryRun
    $env:LAB_APPROVED = $script:Approved
    $hostExe = (Get-Process -Id $PID).Path
    $script:EntryRc = 0
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Piped, so the module's output reaches the operator and never becomes
        # the return value of the function that called this one.
        & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Dir "$Entry.ps1") |
            ForEach-Object { [Console]::Out.WriteLine($_) }
        $script:EntryRc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
        $env:LAB_MODULE_ID = ''
        $env:LAB_ENTRY = ''
        $env:LAB_DRY_RUN = $script:DryRun
        $env:LAB_APPROVED = ''
    }
}

# Load and check every module of the phase in the profile, then put them in
# run order: by priority, P0 first, and in profile order within a priority.
# Returns 40 if any module is invalid.
function Import-LabRunModule {
    param([string] $Phase)
    $worst = 0
    $found = @()
    $script:PhaseCount = 0
    foreach ($id in $script:ProfileIds) {
        if (($id -split '\.', 2)[0] -cne $Phase) { continue }
        $script:PhaseCount++
        $name = ($id -split '\.', 2)[1]
        $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $Phase) 'modules') $name
        $yml = Join-Path $dir 'module.yml'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-LabLine "[$id] error: module not found"; $worst = 40; continue }
        if (-not (Read-LabModuleYml $yml) -or -not (Test-LabModule $yml $id $Phase)) {
            Write-LabLine "[$id] error: invalid module.yml"; $worst = 40; continue
        }
        if (@(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File).Count -eq 0) {
            Write-LabLine "[$id] skipped: no Windows entry points"; continue
        }
        $needed = @('check')
        if (@('reversible', 'service-affecting', 'approval') -ccontains $script:Mod['risk']) { $needed = @('check', 'apply', 'verify', 'rollback') }
        $missing = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir "$_.ps1") -PathType Leaf) })
        if ($missing.Count -gt 0) {
            Write-LabLine "[$id] error: missing $($missing[0]).ps1 (needed for risk $($script:Mod['risk']))"; $worst = 40; continue
        }
        $requires = @()
        if ($script:Mod.ContainsKey('requires')) { $requires = Get-LabListItem $script:Mod['requires'] }
        $found += [pscustomobject]@{
            Id = $id; Dir = $dir; Risk = $script:Mod['risk']; Scored = ($script:Mod['touches_scored'] -eq 'true')
            Requires = $requires; Priority = $script:Mod['priority']; Rc = 0; State = 'planned'
        }
    }
    $ordered = @()
    foreach ($p in @('P0', 'P1', 'P2', 'P3')) { $ordered += @($found | Where-Object { $_.Priority -ceq $p }) }
    $script:Run = $ordered
    return $worst
}

# Run check and, when a change is needed, plan; keep the module's code in .Rc.
function Invoke-LabPlanOne {
    param($M)
    $id = $M.Id
    Invoke-LabEntry $M.Dir 'check' $id
    switch ($script:EntryRc) {
        0 { Write-LabLine "[$id] check: nothing to do"; $M.Rc = 0; return }
        10 { }
        20 { Write-LabLine "[$id] check: blocked by a safety gate"; $M.Rc = 20; return }
        default { Write-LabLine "[$id] check: error (exit $($script:EntryRc))"; $M.Rc = 40; return }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'plan.ps1') -PathType Leaf)) {
        Write-LabLine "[$id] error: change needed but plan.ps1 is missing"; $M.Rc = 40; return
    }
    Write-LabLine "[$id] check: change needed; plan follows"
    Invoke-LabEntry $M.Dir 'plan' $id
    switch ($script:EntryRc) {
        { $_ -eq 0 -or $_ -eq 10 } { $M.Rc = 10; return }
        20 { Write-LabLine "[$id] plan: blocked by a safety gate"; $M.Rc = 20; return }
        default { Write-LabLine "[$id] plan: error (exit $($script:EntryRc))"; $M.Rc = 40; return }
    }
}

# Load and plan the phase's modules; return the worst code.
function Invoke-LabPlanAll {
    param([string] $Phase)
    $worst = Import-LabRunModule $Phase
    foreach ($m in $script:Run) {
        Invoke-LabPlanOne $m
        if ($m.Rc -gt $worst) { $worst = $m.Rc }
    }
    if ($script:PhaseCount -eq 0) { Write-LabLine "no $Phase modules in profile $script:ProfileName" }
    return $worst
}

# The protected set must load and hold at least one account (design 01,
# section 7). Plan mode needs it too, because plans that touch accounts depend on it.
function Assert-LabProtectedSet {
    $set = $null
    try { $set = Read-LabProtectedSet } catch { Exit-Lab "the protected set is malformed: $($_.Exception.Message)" }
    if ($null -eq $set) { Exit-Lab 'the protected set is not loaded, so Labyrinth refuses to run (design 01, section 7)' 20 }
    $script:Protected = $set
}

# Read-LabAnswer PROMPT: print PROMPT and read one line into $script:Answer.
# Returns $false at the end of input.
function Read-LabAnswer {
    param([string] $Prompt)
    [Console]::Out.Write($Prompt)
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { Write-LabLine; $script:Answer = ''; return $false }
    $script:Answer = $line.Trim()
    return $true
}

function Assert-LabBreakGlass {
    $account = Get-LabBreakGlass -Protected $script:Protected
    if ($account) {
        Write-LabLine "break-glass: confirmed earlier for $account"
    } else {
        if ($script:GivenBreakGlass -ne '') {
            $account = $script:GivenBreakGlass
        } else {
            if (-not (Read-LabAnswer "Break-glass check: log in at this host's console with the break-glass account, then type its name: ")) {
                Exit-Lab 'no answer: break-glass not confirmed; nothing was changed' 20
            }
            $account = $script:Answer
        }
        try { Save-LabBreakGlass -Protected $script:Protected -Account $account }
        catch { [Console]::Error.WriteLine($_.Exception.Message); Exit-Lab 'break-glass not confirmed; nothing was changed' 20 }
        Write-LabLine "break-glass: $account confirmed and recorded"
    }
    $script:BreakGlassAccount = $account
}

function Assert-LabPlanConfirmed {
    param([string] $Group)
    $typed = $script:GivenGroup
    if ($typed -eq '') {
        [void](Read-LabAnswer "Type the group name ($Group) to apply this plan: ")
        $typed = $script:Answer
    }
    if ($typed -cne $Group) { Exit-Lab 'the plan was not confirmed; nothing was changed' 20 }
}

# A manifest entry on a module's behalf.
function Add-LabEntryFor {
    param([string] $Id, [string] $Action, [string] $Target = '', [string] $Note = '')
    $env:LAB_MODULE_ID = $Id
    try { Add-LabManifestEntry -Action $Action -Target $Target -Note $Note } finally { $env:LAB_MODULE_ID = '' }
}

function Write-LabLogFor {
    param([string] $Id, [string] $Level, [string] $EventName, [string] $Message)
    $env:LAB_MODULE_ID = $Id
    try { Write-LabLog -Level $Level -EventName $EventName -Message $Message } finally { $env:LAB_MODULE_ID = '' }
}

# Undo one module's changes in the current run; returns 0 or 40.
function Undo-LabModule {
    param([string] $Id)
    $phase, $name = $Id -split '\.', 2
    $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $phase) 'modules') $name
    $rc = 0
    if (Test-Path -LiteralPath (Join-Path $dir 'rollback.ps1') -PathType Leaf) {
        Invoke-LabEntry $dir 'rollback' $Id '0'
        $rc = $script:EntryRc
    } else {
        $env:LAB_MODULE_ID = $Id
        try { Restore-LabBackup } catch { [Console]::Error.WriteLine($_.Exception.Message); $rc = 40 } finally { $env:LAB_MODULE_ID = '' }
    }
    if ($rc -eq 0) {
        Add-LabEntryFor $Id 'rolled_back'
        Write-LabLine "[$Id] rolled back"
        Write-LabLogFor $Id 'warn' 'rolled_back' 'rolled back'
        return 0
    }
    Write-LabLine "[$Id] rollback FAILED (exit $rc): restore this module by hand from $(Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $Id)"
    Write-LabLogFor $Id 'error' 'rollback_failed' "rollback failed with exit $rc"
    return 40
}

# Did every module this one requires, in this run, finish?
function Test-LabRequire {
    param($M)
    foreach ($req in $M.Requires) {
        foreach ($other in $script:Run) {
            if ($other.Id -ceq $req -and @('done', 'planned') -notcontains $other.State) {
                Write-LabLine "[$($M.Id)] blocked: requires $req, which did not complete"
                return $false
            }
        }
    }
    return $true
}

function Get-LabProbeNow {
    if (-not $script:HaveServices) { return , @() }
    # Assigned first: Get-LabProbeResult returns its lines as one array.
    $lines = Get-LabProbeResult -Timeout $script:Settings['PROBE_TIMEOUT']
    return , @($lines)
}

# Apply, verify and probe one module. Returns 0 (done or nothing to do),
# 20 (blocked; continue), or 30/40 (rolled back; stop).
function Invoke-LabApplyOne {
    param($M)
    $id = $M.Id
    $script:Approved = ''
    if ($M.Risk -eq 'manual-only') {
        Write-LabLine "[$id] manual-only: a person carries out the checklist above; nothing changed"
        $M.State = 'manual'; return 0
    }
    if ($M.Scored) {
        $allow = Read-LabAddressList 'scoring-allowlist'
        if ($null -eq $allow) {
            Write-LabLine "[$id] blocked: it touches scored services and the scoring allowlist is missing or empty"
            $M.State = 'blocked'; return 20
        }
        if (-not $script:HaveServices) {
            Write-LabLine "[$id] blocked: it touches scored services and there is no service list to probe"
            $M.State = 'blocked'; return 20
        }
    }
    if (-not (Test-LabRequire $M)) { $M.State = 'blocked'; return 20 }
    if ($M.Risk -eq 'approval') {
        if (-not (Read-LabAnswer "[$id] Type the ids of the items to approve, separated by spaces, or press Enter for none: ")) { $script:Answer = '' }
        foreach ($tok in @($script:Answer -split '\s+' | Where-Object { $_ -ne '' })) {
            if ($tok -cnotmatch '^[A-Za-z0-9._:@-]+$') { Write-LabLine "[$id] blocked: not an item id: $tok"; $M.State = 'blocked'; return 20 }
        }
        $script:Approved = (@($script:Answer -split '\s+' | Where-Object { $_ -ne '' })) -join ' '
        if ($script:Approved -eq '') { Write-LabLine "[$id] nothing approved; nothing changed"; $M.State = 'done'; return 0 }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'apply.ps1') -PathType Leaf)) { $M.State = 'done'; return 0 }
    if ($M.Risk -ne 'read-only') {
        $exe = (Get-Process -Id $PID).Path
        $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} rollback {1} -Root {2} -Config {3}' -f `
            (ConvertTo-LabCommandLineArgument (Join-Path $env:LAB_ROOT 'labyrinth.ps1')), $env:LAB_RUN_ID,
            (ConvertTo-LabCommandLineArgument $Root), (ConvertTo-LabCommandLineArgument $env:LAB_CONFIG_DIR)
        try {
            Register-LabRevertTimer -Seconds ($script:Settings['REVERT_MINUTES'] * 60) -RunId $env:LAB_RUN_ID -Execute $exe -Argument $arg
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            Write-LabLine "[$id] blocked: the revert timer could not be armed"
            $M.State = 'blocked'; return 20
        }
    }

    Add-LabEntryFor $id 'apply_start' '' "risk $($M.Risk)"
    Write-LabLogFor $id 'info' 'apply_start' 'applying'
    Invoke-LabEntry $M.Dir 'apply' $id '0'
    $rc = $script:EntryRc
    if ($rc -eq 20) {
        Write-LabLine "[$id] apply: blocked by a safety gate"
        Add-LabEntryFor $id 'rolled_back' '' 'apply blocked before any change'
        $M.State = 'blocked'; return 20
    }
    if ($rc -ne 0) {
        Write-LabLine "[$id] apply: error (exit $rc); rolling back"
        $M.State = 'failed'; [void](Undo-LabModule $id); return 40
    }

    if (Test-Path -LiteralPath (Join-Path $M.Dir 'verify.ps1') -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'verify' $id '0'
        $rc = $script:EntryRc
        if ($rc -ne 0) {
            Write-LabLine "[$id] verify failed (exit $rc); rolling back"
            Write-LabLogFor $id 'error' 'verify_failed' "verify exited $rc"
            $M.State = 'failed'; [void](Undo-LabModule $id)
            if ($rc -eq 30) { return 30 }
            return 40
        }
    }

    if ($script:HaveServices) {
        $after = Get-LabProbeNow
        $reg = @(Get-LabProbeRegression -Before $script:Before -After $after)
        if ($reg.Count -gt 0) {
            Write-LabLine "[$id] scored service regressed: $($reg -join ' '); rolling back"
            Write-LabLogFor $id 'error' 'regression' "scored service regressed: $($reg -join ' ')"
            $M.State = 'failed'; [void](Undo-LabModule $id)
            return 30
        }
    }

    if (Test-Path -LiteralPath (Join-Path $M.Dir 'cleanup.ps1') -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'cleanup' $id '0'
        if ($script:EntryRc -ne 0) { Write-LabLine "[$id] cleanup: exit $($script:EntryRc) (the change is kept)" }
    }
    Write-LabLine "[$id] applied and verified"
    Write-LabLogFor $id 'info' 'applied' 'applied and verified'
    $M.State = 'done'
    return 0
}

function Read-LabSetting {
    try { $script:Settings = Read-LabEventConfig } catch { Exit-Lab "event.conf is malformed: $($_.Exception.Message)" }
}

function Find-LabThisHost {
    try { return Find-LabHost -Name (Get-LabHostName) } catch { Exit-Lab "the hosts file is malformed: $($_.Exception.Message)" }
}

function Invoke-LabPlanCommand {
    param([string] $Phase)
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    $entry = Find-LabThisHost
    if ($script:ProfileName -eq '') {
        if ($null -eq $entry) { Exit-Lab "no profile: give -Profile, or list this host ($(Get-LabHostName)) in $(Join-Path $env:LAB_CONFIG_DIR 'hosts')" }
        $script:ProfileName = $entry.Profile
    }
    Read-LabProfile $script:ProfileName
    Read-LabSetting
    Assert-LabProtectedSet
    Write-LabLine ('labyrinth {0} - run {1} - {2} - profile {3} - plan mode' -f $LabVersion, $env:LAB_RUN_ID, $Phase, $script:ProfileName)
    $worst = Invoke-LabPlanAll $Phase
    Write-LabLine "plan finished: exit $worst"
    exit $worst
}

function Invoke-LabApplyCommand {
    param([string] $Phase)
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    $hostName = Get-LabHostName
    if (-not (Test-LabAdmin)) { Exit-Lab 'apply needs an elevated Administrator session' 20 }
    # Before any configuration under the root is trusted.
    try { Protect-LabDataRoot -Path $Root } catch { Exit-Lab "$($_.Exception.Message); nothing was changed" 20 }
    $entry = Find-LabThisHost
    if ($null -eq $entry) { Exit-Lab "this host ($hostName) is not in $(Join-Path $env:LAB_CONFIG_DIR 'hosts'), so its ring group is unknown" 20 }
    $group = $entry.Group
    if ($group -eq 'manual') { Exit-Lab "this host ($hostName) is in the manual group: Labyrinth never changes it" 20 }
    if ($script:ProfileName -ne '' -and $script:ProfileName -cne $entry.Profile) {
        Exit-Lab "the hosts file gives this host profile $($entry.Profile), not $($script:ProfileName)"
    }
    $script:ProfileName = $entry.Profile
    Read-LabProfile $script:ProfileName
    Read-LabSetting
    Assert-LabProtectedSet
    if (-not (Enter-LabLock -WaitSeconds 0)) { exit 20 }
    try {
        Write-LabLine ('labyrinth {0} - run {1} - {2} - profile {3} - host {4}, group {5} - APPLY' -f `
                $LabVersion, $env:LAB_RUN_ID, $Phase, $script:ProfileName, $hostName, $group)
        $worst = Invoke-LabPlanAll $Phase
        if ($worst -ge 40) { Exit-Lab 'the plan has errors; nothing was changed' }
        $todo = @($script:Run | Where-Object { $_.Rc -eq 10 -and $_.Risk -ne 'manual-only' }).Count
        if ($todo -eq 0) {
            Write-LabLine 'nothing to apply'
            Write-LabLine "apply finished: exit $worst"
            exit $worst
        }

        Assert-LabBreakGlass
        Assert-LabPlanConfirmed $group

        # From here on, changes are made: everything is recorded first.
        $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
        try {
            New-Item -ItemType Directory -Force -Path (Get-LabRunDir $env:LAB_RUN_ID), (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) | Out-Null
        } catch { Exit-Lab 'the run and backup folders cannot be created; nothing was changed' 20 }
        Add-LabEntryFor '' 'run_start' $hostName "phase $Phase, profile $($script:ProfileName), group $group"
        Add-LabEntryFor '' 'breakglass_verified' $script:BreakGlassAccount
        Write-LabLog -Level info -EventName run_start -Message "apply $Phase, profile $($script:ProfileName), group $group"
        $services = $null
        try { $services = Read-LabServiceList } catch { Exit-Lab "the service list is malformed; nothing was changed: $($_.Exception.Message)" }
        if ($null -ne $services) {
            $script:HaveServices = $true
            $script:Before = Get-LabProbeNow
            [IO.File]::WriteAllText((Join-Path (Get-LabRunDir $env:LAB_RUN_ID) 'probes-before'), (($script:Before -join "`n") + "`n"))
            Write-LabLine 'probes before the run:'
            foreach ($l in $script:Before) { Write-LabLine $l }
        } else {
            Write-LabLine "warning: no service list ($(Join-Path $env:LAB_CONFIG_DIR 'services')), so no before-and-after probes"
        }

        $worst = 0
        $stopped = $false
        foreach ($m in $script:Run) {
            if ($m.Rc -eq 20) { $worst = [Math]::Max($worst, 20); $m.State = 'blocked'; continue }
            if ($m.Rc -ne 10) { $m.State = 'done'; continue }
            $rc = Invoke-LabApplyOne $m
            if ($rc -gt $worst) { $worst = $rc }
            if ($rc -ge 30) { $stopped = $true; break }
        }
    } finally {
        Exit-LabLock
    }

    if ($stopped) {
        Write-LabLine 'The run stopped. Earlier changes stay until the revert timer undoes them.'
        Write-LabLine "To keep them now: labyrinth.ps1 keep $env:LAB_RUN_ID    To undo them now: labyrinth.ps1 rollback $env:LAB_RUN_ID"
    } elseif (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) {
        Write-LabLine 'All changes are applied and verified. From a NEW session, check that you can still log in.'
        $ok = Read-LabAnswer "Type keep to keep the changes; anything else leaves the revert timer to undo them in $($script:Settings['REVERT_MINUTES']) minutes: "
        if ($ok -and $script:Answer -ceq 'keep') {
            $rc = Invoke-LabKeep
            if ($rc -gt $worst) { $worst = $rc }
        } else {
            Write-LabLine "Not kept. To keep later: labyrinth.ps1 keep $env:LAB_RUN_ID    To undo now: labyrinth.ps1 rollback $env:LAB_RUN_ID"
        }
    }
    Write-LabLine "apply finished: exit $worst"
    exit $worst
}

# Has the current run already been rolled back as a whole?
function Test-LabRunRolledBack {
    return (@(Get-LabManifestEntry | Where-Object { $_.action -ceq 'run_rolled_back' }).Count -gt 0)
}

# Cancel the current run's revert timer and record it; returns 0 or 20.
function Invoke-LabKeep {
    if (-not (Enter-LabLock -WaitSeconds 10)) { return 20 }
    try {
        if (Test-LabRunRolledBack) {
            Write-LabLine "too late: run $env:LAB_RUN_ID was already rolled back"
            return 20
        }
        Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        Add-LabEntryFor '' 'run_kept'
        Write-LabLog -Level info -EventName run_kept -Message 'changes kept; revert timer cancelled'
        Write-LabLine "kept: the revert timer for run $env:LAB_RUN_ID is cancelled"
        return 0
    } finally {
        Exit-LabLock
    }
}

function Invoke-LabKeepCommand {
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if (-not (Test-LabAdmin)) { Exit-Lab 'keep needs an elevated Administrator session' 20 }
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    exit (Invoke-LabKeep)
}

function Invoke-LabRollbackCommand {
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if (-not (Test-LabAdmin)) { Exit-Lab 'rollback needs an elevated Administrator session' 20 }
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    # The revert timer must work even if a hung run still holds the lock.
    $locked = Enter-LabLock -WaitSeconds 120
    if (-not $locked) { [Console]::Error.WriteLine('warning: rolling back without the run lock') }
    try {
        $rc = 0
        $mods = @(Get-LabAppliedModule -RunId $env:LAB_RUN_ID)
        Write-LabLine "labyrinth $LabVersion - rolling back run $env:LAB_RUN_ID"
        for ($i = $mods.Count - 1; $i -ge 0; $i--) {
            $id = $mods[$i]
            if ($id -cnotmatch $ReModuleId) { Write-LabLine "skipping a bad module id in the manifest: $id"; $rc = 40; continue }
            if ((Undo-LabModule $id) -ne 0) { $rc = 40 }
        }
        Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        Add-LabEntryFor '' 'run_rolled_back' '' "exit $rc"
        Write-LabLog -Level warn -EventName run_rolled_back -Message "run rolled back, exit $rc"
        Write-LabLine "rollback finished: exit $rc"
    } finally {
        if ($locked) { Exit-LabLock }
    }
    exit $rc
}

function Invoke-LabProbeCommand {
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    Read-LabSetting
    $out = $null
    try { $out = Get-LabProbeResult -Timeout $script:Settings['PROBE_TIMEOUT'] } catch { Exit-Lab "the service list is malformed: $($_.Exception.Message)" }
    if ($null -eq $out) { Exit-Lab "no service list at $(Join-Path $env:LAB_CONFIG_DIR 'services')" 20 }
    foreach ($l in $out) { Write-LabLine $l }
    if (@($out | Where-Object { ($_ -split ' ', 3)[1] -eq 'fail' }).Count -gt 0) { exit 30 }
    exit 0
}

try {
    if ($Help) { Write-LabLine $Usage; exit 0 }
    if ($Version) { Write-LabLine "labyrinth $LabVersion"; exit 0 }
    if ($Rest.Count -gt 0) { Exit-Lab "unexpected argument: $($Rest[0])" }
    if ($Command -eq '') { [Console]::Error.WriteLine($Usage); exit 40 }
    if ($ProfileName -ne '' -and $ProfileName -cnotmatch '^[a-z0-9-]+$') { Exit-Lab "invalid profile name: $ProfileName" }
    if ($Root -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-Lab '-Root must be an absolute path' }
    if ($Config -ne '' -and $Config -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-Lab '-Config must be an absolute path' }
    $script:ProfileName = $ProfileName
    $script:DryRun = '1'

    $env:LAB_ROOT = $PSScriptRoot
    if ($Config -ne '') { $env:LAB_CONFIG_DIR = $Config } else { $env:LAB_CONFIG_DIR = Join-Path $Root 'etc' }
    $env:LAB_STATE_DIR = Join-Path $Root 'state'
    $env:LAB_LOG_DIR = Join-Path $Root 'logs'
    $env:LAB_BACKUP_DIR = Join-Path $Root 'backup'
    $env:LAB_RUN_ID = Get-LabRunId
    . (Join-Path $PSScriptRoot 'core\Lab.ps1')

    switch -CaseSensitive ($Command) {
        'probe' {
            if ($RunId -ne '' -or $Apply) { Exit-Lab 'usage: labyrinth.ps1 probe' }
            Invoke-LabProbeCommand
        }
        { $_ -ceq 'keep' -or $_ -ceq 'rollback' } {
            if ($Apply) { Exit-Lab "usage: labyrinth.ps1 $Command <run>" }
            if ($RunId -cnotmatch $ReRunId) { Exit-Lab "not a run id: $RunId" }
            $env:LAB_RUN_ID = $RunId
            if ($Command -ceq 'keep') { Invoke-LabKeepCommand } else { Invoke-LabRollbackCommand }
        }
        default {
            if ($RunId -ne '') { Exit-Lab "unexpected argument: $RunId" }
            if ($Phases -cnotcontains $Command) { Exit-Lab "unknown phase or command: $Command" }
            if ($Apply) { Invoke-LabApplyCommand $Command } else { Invoke-LabPlanCommand $Command }
        }
    }
} catch {
    [Console]::Error.WriteLine("labyrinth: $($_.Exception.Message)")
    exit 40
}
