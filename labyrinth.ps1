#Requires -Version 5.1
<#
.SYNOPSIS
    Labyrinth main program for Windows hosts (design 00, section 5).

.DESCRIPTION
    This build runs plan mode only: for each module of the requested phase in
    the profile, it runs `check` and, when a change is needed, `plan`. Nothing
    is changed. `apply`, the safety gates, logging and the run manifest arrive
    with the core (design 00; docs/Conventions.md).

    Exit codes (design 00, section 4); the highest code from any module wins:
    0 nothing to do, 10 change needed, 20 blocked, 40 error.

.EXAMPLE
    .\labyrinth.ps1 observe -Profile windows-member
#>
param(
    [Parameter(Position = 0)] [string] $Phase = '',
    [Alias('Profile')] [string] $ProfileName = '',
    [string] $Root = 'C:\ProgramData\Labyrinth',
    [string] $Config = '',
    [switch] $Apply,
    [switch] $Version,
    [switch] $Help,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabVersion = '0.0.0-dev'
$Phases = @('lockout', 'observe', 'deceive', 'sustain')
$ModuleKeys = @('id', 'phase', 'priority', 'platforms', 'risk', 'touches_scored', 'requires', 'outputs', 'spec')
$RequiredKeys = @('id', 'phase', 'priority', 'platforms', 'risk', 'touches_scored')
$Risks = @('read-only', 'reversible', 'service-affecting', 'approval', 'manual-only')
$Platforms = @('ubuntu', 'rhel-family', 'windows', 'appliance')

$script:Mod = @{}
$script:ProfileIds = @()
$script:EntryRc = 0

$Usage = @'
usage: labyrinth.ps1 [options] <phase>

  <phase>            lockout | observe | deceive | sustain
  -Profile NAME      host profile to run (required)
  -Root DIR          Labyrinth data root (default C:\ProgramData\Labyrinth)
  -Config DIR        run-time configuration (default <root>\etc)
  -Apply             not available in this build
  -Version           print the version
  -Help              this help

Plan mode is the default: modules report what they would change, and
nothing is changed.
'@

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

# Check $script:Mod's values against design 00, section 4.
function Test-LabModule {
    param([string] $File, [string] $WantId, [string] $WantPhase)
    $m = $script:Mod
    if ($m['id'] -cne $WantId) { Write-YmlError $File "id $($m['id']) does not match $WantId"; return $false }
    if ($m['phase'] -cne $WantPhase) { Write-YmlError $File "phase $($m['phase']) does not match $WantPhase"; return $false }
    if ($m['priority'] -cnotmatch '^P[0-3]$') { Write-YmlError $File 'priority must be P0 to P3'; return $false }
    if ($Risks -cnotcontains $m['risk']) { Write-YmlError $File "unknown risk $($m['risk'])"; return $false }
    if (@('true', 'false') -cnotcontains $m['touches_scored']) { Write-YmlError $File 'touches_scored must be true or false'; return $false }
    if ($m['platforms'] -notmatch '^\[(.*)\]$') { Write-YmlError $File 'platforms must be a list'; return $false }
    $list = @($Matches[1] -split '[,\s]+' | Where-Object { $_ -ne '' })
    if ($list.Count -eq 0) { Write-YmlError $File 'platforms is empty'; return $false }
    foreach ($p in $list) {
        if ($Platforms -cnotcontains $p) { Write-YmlError $File "unknown platform $p"; return $false }
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
        if ($line -cnotmatch '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$') { Exit-Lab "${file}:${n}: not a module id: $line" }
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
    param([string] $Dir, [string] $Entry, [string] $Id)
    $env:LAB_MODULE_ID = $Id
    $env:LAB_DRY_RUN = '1'
    $hostExe = (Get-Process -Id $PID).Path
    $script:EntryRc = 0
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Dir "$Entry.ps1")
        $script:EntryRc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
}

# Plan one module; leaves its contract code in $script:ModuleRc.
function Invoke-LabPlanModule {
    param([string] $Id)
    $phase, $name = $Id -split '\.', 2
    $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $phase) 'modules') $name
    $yml = Join-Path $dir 'module.yml'
    $script:ModuleRc = 40
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Output "[$Id] error: module not found"; return }
    if (-not (Read-LabModuleYml $yml) -or -not (Test-LabModule $yml $Id $phase)) {
        Write-Output "[$Id] error: invalid module.yml"; return
    }
    if (@(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File).Count -eq 0) {
        Write-Output "[$Id] skipped: no Windows entry points"; $script:ModuleRc = 0; return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'check.ps1') -PathType Leaf)) {
        Write-Output "[$Id] error: missing check.ps1"; return
    }

    Invoke-LabEntry $dir 'check' $Id
    switch ($script:EntryRc) {
        0 { Write-Output "[$Id] check: nothing to do"; $script:ModuleRc = 0; return }
        10 { }
        20 { Write-Output "[$Id] check: blocked by a safety gate"; $script:ModuleRc = 20; return }
        default { Write-Output "[$Id] check: error (exit $($script:EntryRc))"; return }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $dir 'plan.ps1') -PathType Leaf)) {
        Write-Output "[$Id] error: change needed but plan.ps1 is missing"; return
    }
    Write-Output "[$Id] check: change needed; plan follows"
    Invoke-LabEntry $dir 'plan' $Id
    switch ($script:EntryRc) {
        { $_ -eq 0 -or $_ -eq 10 } { $script:ModuleRc = 10; return }
        20 { Write-Output "[$Id] plan: blocked by a safety gate"; $script:ModuleRc = 20; return }
        default { Write-Output "[$Id] plan: error (exit $($script:EntryRc))"; return }
    }
}

try {
    if ($Help) { Write-Output $Usage; exit 0 }
    if ($Version) { Write-Output "labyrinth $LabVersion"; exit 0 }
    if ($Rest.Count -gt 0) { Exit-Lab "unexpected argument: $($Rest[0])" }
    if ($Apply) { Exit-Lab 'apply is not available in this build; plan mode only' }
    if ($Phase -eq '') { [Console]::Error.WriteLine($Usage); exit 40 }
    if ($Phases -cnotcontains $Phase) { Exit-Lab "unknown phase: $Phase" }
    if ($ProfileName -eq '') { Exit-Lab 'a profile is required (-Profile NAME)' }
    if ($ProfileName -cnotmatch '^[a-z0-9-]+$') { Exit-Lab "invalid profile name: $ProfileName" }
    if ($Root -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-Lab '-Root must be an absolute path' }

    $env:LAB_ROOT = $PSScriptRoot
    if ($Config -ne '') { $env:LAB_CONFIG_DIR = $Config } else { $env:LAB_CONFIG_DIR = Join-Path $Root 'etc' }
    $env:LAB_STATE_DIR = Join-Path $Root 'state'
    $env:LAB_LOG_DIR = Join-Path $Root 'logs'
    $env:LAB_BACKUP_DIR = Join-Path $Root 'backup'
    $env:LAB_RUN_ID = Get-LabRunId

    Read-LabProfile $ProfileName

    Write-Output ('labyrinth {0} - run {1} - {2} - profile {3} - plan mode' -f $LabVersion, $env:LAB_RUN_ID, $Phase, $ProfileName)
    $worst = 0
    $count = 0
    foreach ($id in $script:ProfileIds) {
        if (($id -split '\.', 2)[0] -cne $Phase) { continue }
        $count++
        Invoke-LabPlanModule $id
        if ($script:ModuleRc -gt $worst) { $worst = $script:ModuleRc }
    }
    if ($count -eq 0) { Write-Output "no $Phase modules in profile $ProfileName" }
    Write-Output "plan finished: exit $worst"
    exit $worst
} catch {
    [Console]::Error.WriteLine("labyrinth: $($_.Exception.Message)")
    exit 40
}
