<#
.SYNOPSIS
    Labyrinth: plan, apply, keep and roll back hardening runs on this
    Windows host.

.DESCRIPTION
    Commands:
      labyrinth.ps1 plan <phase>       show what would change; changes nothing
      labyrinth.ps1 apply <phase>      plan, confirm, then make the changes
      labyrinth.ps1 keep [<run>]       keep a run: cancel its revert timer
      labyrinth.ps1 rollback <run>     undo a run, newest change first
      labyrinth.ps1 runs               list this host's runs and their state
      labyrinth.ps1 probe              test every scored service once
      labyrinth.ps1 help [<topic>]     help on a command, 'basics' or a
                                       module; also -Help or -h
      labyrinth.ps1 version            the version; also -Version or -V

    A phase is lockout, observe, deceive or sustain. A run is a run ID, or
    its last 4 characters.

    Options, before or after the command:
      -Profile NAME        use this profile, not the one in the hosts file
      -Root DIR            the data root (default C:\ProgramData\Labyrinth)
      -Config DIR          the configuration folder (default <root>\etc)
      -BreakGlass NAME     answer the break-glass prompt (apply only)
      -ConfirmGroup GROUP  answer the group-name prompt (apply only)

    Exit codes: 0 done or nothing to do, 10 change needed, 20 blocked,
    30 a check failed (probe: a service failed), 40 error.

    New to Labyrinth? 'labyrinth.ps1 help basics' explains the ideas in
    plain words. 'labyrinth.ps1 help <command>' explains one command, and
    'labyrinth.ps1 help <module-id>' one module. The operator manual is
    the Windows edition of the Labyrinth manual.

.EXAMPLE
    .\labyrinth.ps1 plan lockout

    Shows what the lockout phase would change on this host.

.EXAMPLE
    .\labyrinth.ps1 apply lockout

    Plans, asks you to confirm, then makes the changes and arms a revert
    timer that undoes them unless you keep them.

.EXAMPLE
    .\labyrinth.ps1 runs

    Lists this host's runs, with the state of each revert timer.

.EXAMPLE
    .\labyrinth.ps1 keep 4f2a

    Keeps the run whose ID ends in 4f2a: its revert timer is cancelled.

.NOTES
    apply, keep, rollback and runs need PowerShell opened with 'Run as
    administrator'. Use -h for help: PowerShell takes -? for itself. The
    common parameters, such as -Verbose and -ErrorAction, are not
    supported.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabVersion = '0.1.0-dev'
$Phases = @('lockout', 'observe', 'deceive', 'sustain')
$ModuleKeys = @('id', 'title', 'phase', 'priority', 'platforms', 'risk', 'touches_scored', 'requires', 'outputs', 'spec')
$RequiredKeys = @('id', 'title', 'phase', 'priority', 'platforms', 'risk', 'touches_scored')
$Risks = @('read-only', 'reversible', 'service-affecting', 'approval', 'manual-only')
$Platforms = @('ubuntu', 'rhel-family', 'windows', 'appliance')
$ReRunId = '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$'
$ReModuleId = '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'
# An item line from an approval module's plan, and one -Approve entry
# (docs/Conventions.md section 3.1).
$ReItem = "^item`t([a-z0-9-]+)`t([a-z0-9-]+)`t([0-9a-f]{12})`t(.*)$"
$ReApprove = '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+:[a-z0-9-]+@[0-9a-f]{12}$'
$Commands = @('plan', 'apply', 'keep', 'rollback', 'runs', 'probe', 'help', 'version')
$Self = 'labyrinth.ps1'          # the program's name, for hints

# The options, one row each (docs/Conventions.md section 3.1): the canonical
# name, how it is shown, the keys it is matched by (lower case, no dashes),
# and whether it takes a value. The same table as labyrinth.sh.
$script:LabOptions = @(
    @{ Name = 'profile'; Show = '-Profile'; Keys = @('profile', 'profilename'); Value = $true }
    @{ Name = 'root'; Show = '-Root'; Keys = @('root'); Value = $true }
    @{ Name = 'config'; Show = '-Config'; Keys = @('config'); Value = $true }
    @{ Name = 'break-glass'; Show = '-BreakGlass'; Keys = @('breakglass'); Value = $true }
    @{ Name = 'confirm-group'; Show = '-ConfirmGroup'; Keys = @('confirmgroup', 'confirm'); Value = $true }
    @{ Name = 'approve'; Show = '-Approve'; Keys = @('approve'); Value = $true }
    @{ Name = 'apply'; Show = '-Apply'; Keys = @('apply'); Value = $false }
    @{ Name = 'help'; Show = '-Help'; Keys = @('help'); Value = $false }
    @{ Name = 'version'; Show = '-Version'; Keys = @('version'); Value = $false }
)
$script:Arguments = @($args)     # the words, before any function runs
$script:Given = @{}              # canonical option name -> value given
$script:Words = @()              # the words that are not options, in order
$script:ParseError = ''          # the first option error, reported by main
$script:ErrorCount = 0           # ERROR lines in the Summary, for the Next line

$script:Mod = @{}
$script:ProfileIds = @()
$script:PendingWarnings = @()
$script:EntryRc = 0
$script:Approved = ''            # items approved for the module being applied
$script:Refused = @()            # approved items that changed since the plan
$script:PhaseCount = 0
$script:LoadErrors = 0           # modules of the phase that could not be loaded
$script:LoadSkipped = 0          # modules skipped: no entry points for this platform
$script:YmlErr = @()             # module.yml errors, printed under the ERROR line
$script:EntryOut = @()           # the output of an entry point run with -Capture
$script:Stopped = $false         # true when an apply stopped partway
$script:Applied = $false         # true once apply starts changing things
$script:Run = @()            # the modules of this run, in run order
$script:Protected = @{}
$script:Settings = @{}
$script:Before = @()
$script:HaveServices = $false
$script:BreakGlassAccount = ''
$script:GivenBreakGlass = ''     # -BreakGlass, read inside functions
$script:GivenGroup = ''          # -ConfirmGroup, read inside functions
$script:DataRoot = ''            # the data root (-Root)
$script:Answer = ''
$script:Command = ''             # the command being run, for the last catch
$script:RunRef = ''              # the run keep or rollback acts on
$script:RunOpen = $false         # true once an apply has recorded run_start
$script:GaveReason = $false      # did the last entry point end with a 'problem:' line?
$script:EntryLast = ''           # the last line an entry point printed that was not blank
$script:Titles = @{}             # module ID -> title, for the status lines
$script:LogFile = ''             # the run's output.log, once it is open
$script:LogOn = $false           # keep lines for the run log before it opens
$script:LogBuf = New-Object Collections.Generic.List[string]
$script:NoLog = $false           # true while a line is shown but not logged
$LogCap = 500                    # the most lines of one entry point in the log
$Labels = @('found', 'will do', 'did', 'why', 'risk', 'problem', 'cause', 'fix', 'undo')

# Show-LabHelp [COMMAND]: the help for every command, or for one, on stdout.
# Each topic is at most 15 lines of at most 78 columns, with one Exit line
# and one Example line (docs/Conventions.md section 3.2).
function Show-LabHelp {
    param([string] $Topic = '')
    $where = @"
Where:
  -Root DIR              data root (default C:\ProgramData\Labyrinth)
  -Config DIR            configuration folder (default <root>\etc)
"@
    $text = switch ($Topic) {
        '' { @"
Usage: $Self <command> [<phase> | <run>] [options]
New to Labyrinth? Start with '$Self help basics'.

  plan <phase>      show what would change; changes nothing
  apply <phase>     plan, confirm, then make the changes
  keep [<run>]      keep a run: cancel its revert timer
  rollback <run>    undo a run, newest change first
  runs              list this host's runs and their state
  probe             test every scored service once
  help [<topic>]    help on a command, 'basics', or a module ID
  version           print the version

Phases: lockout, observe, deceive, sustain. <run>: an ID or its last 4.
Exit: 0 ok, 10 change needed, 20 blocked, 30 check failed, 40 error.
Example: $Self plan lockout
Manual: Get-Help about_Labyrinth once installed; docs\manual in the release.
"@ }
        'plan' { @"
Usage: $Self plan <phase> [options]

Show what every module of the phase would change on this host.
Nothing is changed and nothing is written. <phase> is lockout,
observe, deceive or sustain.

$where
  -Profile NAME          use this profile, not the one in the hosts file

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: $Self plan lockout
Compatibility: '$Self <phase>' also plans.
"@ }
        'apply' { @"
Usage: $Self apply <phase> [options]

Plan, confirm, then change; a revert timer undoes it unless kept.

$where
  -Profile NAME          must match this host's line in the hosts file
  -BreakGlass NAME       answer the break-glass prompt
  -ConfirmGroup GROUP    answer the group-name prompt
  -Approve LIST          approve without asking: module:item@fingerprint,...

Exit: 0 done, 10 manual steps left, 20 blocked, 30 check failed, 40 error.
Example: $Self apply lockout
Compatibility: '$Self <phase> -Apply' also applies.
"@ }
        'keep' { @"
Usage: $Self keep [<run>] [options]

Keep a run's changes: cancel its revert timer, then record the keep.
Without <run>, keep the one run whose timer is armed. <run> is a run
ID or its last 4 characters; '$Self runs' lists them.

$where

Exit: 0 kept, 20 not an Administrator or too late (rolled back), 40 error.
Example: $Self keep 4f2a
"@ }
        'rollback' { @"
Usage: $Self rollback <run> [options]

Undo everything the run changed, newest change first. This is what
the revert timer runs. Safe to run twice. <run> is a run ID or its
last 4 characters; '$Self runs' lists them.

$where

Exit: 0 rolled back, 20 not an Administrator, 40 error.
Example: $Self rollback 4f2a
"@ }
        'runs' { @"
Usage: $Self runs [options]

List this host's runs, oldest first: run ID, phase, start time (UTC)
and state (armed, kept, rolled back, or not kept, no timer).
Changes nothing; needs an Administrator.

$where

Exit: 0 listed, 20 not an Administrator, 40 error.
Example: $Self runs
"@ }
        'probe' { @"
Usage: $Self probe [options]

Test every scored service once, the way the scoring engine would,
and print one line per service. Changes nothing.

$where

Exit: 0 all pass, 20 no service list, 30 a service failed, 40 error.
Example: $Self probe
"@ }
        'help' { @"
Usage: $Self help [<command> | basics | <module-id>]

Print help for every command, or for one. '$Self <command> -Help'
and '$Self <command> -h' print the same. 'basics' explains the ideas
in plain words. A module ID, such as the ones a plan prints, explains
that module: what it checks and changes, and how to undo it.

Exit: 0 printed, 40 unknown topic.
Example: $Self help apply
"@ }
        'basics' { @"
Usage: $Self help basics

Labyrinth makes this host harder to break into, in four phases run in
order: lockout, observe, deceive and sustain. Each phase is a list of
modules. A module does one small job, such as turning off SMB version 1.
'$Self help <module-id>' explains any module.

1. Plan: '$Self plan lockout' shows what each module would change.
   It changes nothing, so run it as often as you like.
2. Apply: '$Self apply lockout' plans again, asks you to type this
   host's group name, then makes the changes and checks each one.
3. Keep: an apply is a run, named by an ID; its last 4 characters are
   enough. A revert timer undoes the run after a few minutes unless you
   keep it, so a change that locks you out undoes itself. Log in from
   a new session, and if that works, run '$Self keep'.

To undo a run yourself: '$Self rollback <run>'. To list the runs:
'$Self runs'. Scored services are the ones the scoring engine tests.
Labyrinth tests them before and after each change, and undoes a change
that breaks one. To test them now: '$Self probe'.

Exit: 0 printed.
Example: $Self help basics
"@ }
        'version' { @"
Usage: $Self version

Print the version of Labyrinth. '-V' and '-Version' do the same.

Exit: 0 printed.
Example: $Self version
"@ }
    }
    foreach ($l in ($text -split "`r?`n")) { [Console]::Out.WriteLine($l) }
}

# Get-LabRiskWord RISK: what a module's risk means, in plain words.
function Get-LabRiskWord {
    param([string] $Risk)
    switch -CaseSensitive ($Risk) {
        'read-only' { return 'only looks; it never changes anything' }
        'reversible' { return 'changes this host; each change is saved first and can be undone' }
        'service-affecting' { return 'may interrupt a service; each change can be undone' }
        'approval' { return 'changes only what a person approves; each can be undone' }
        'manual-only' { return 'never changes anything; it lists steps for a person' }
    }
    return $Risk
}

# Get-LabModuleId: every module ID in this release.
function Get-LabModuleId {
    $ids = @()
    foreach ($p in $Phases) {
        $dir = Join-Path $PSScriptRoot "phases\$p\modules"
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'module.yml') -PathType Leaf) { $ids += "$p.$($d.Name)" }
        }
    }
    return $ids
}

# Show-LabModuleHelp ID: one module's help page: its module.yml in plain
# words, then its about.txt (design 00, section 4).
function Show-LabModuleHelp {
    param([string] $Id)
    $phase = $Id.Split('.')[0]
    $dir = Join-Path $PSScriptRoot ('phases\{0}\modules\{1}' -f $phase, $Id.Substring($phase.Length + 1))
    if ($Id -cnotmatch $ReModuleId -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $hint = Get-LabSuggestion $Id (@('basics') + $Commands + @(Get-LabModuleId))
        if ($hint -ne '') { Exit-LabUsage "no module '$Id' (did you mean '$hint'?)" 'help' }
        Exit-LabUsage "no module '$Id'" 'help'
    }
    $file = Join-Path $dir 'module.yml'
    $script:YmlErr = @()
    if (-not (Read-LabModuleYml $file) -or -not (Test-LabModule $file $Id $phase)) {
        $err = $script:YmlErr[0]
        $at = $err.LastIndexOf(': ')
        [Console]::Error.WriteLine("labyrinth: the module.yml of $Id is not valid: $($err.Substring($at + 2))")
        [Console]::Error.WriteLine("Report the module to its author, or correct $($err.Substring(0, $at))")
        exit 40
    }
    $m = $script:Mod
    Write-LabLine ('{0} ({1})' -f $m['title'], $Id)
    Write-LabLine ''
    Write-LabLine ('Phase: {0}. Order: {1} (P0 runs first, P3 last).' -f $phase, $m['priority'])
    Write-LabLine ('Risk: {0}.' -f (Get-LabRiskWord $m['risk']))
    if ($m['touches_scored'] -ceq 'true') {
        Write-LabLine 'Scored services: it can affect one, so they are tested after it.'
    } else {
        Write-LabLine 'Scored services: it does not touch them.'
    }
    Write-LabLine ('Runs on: {0}.' -f ((Get-LabListItem $m['platforms']) -join ', '))
    Write-LabLine "Folder: $dir"
    Write-LabLine ''
    $about = Join-Path $dir 'about.txt'
    if (Test-Path -LiteralPath $about -PathType Leaf) {
        foreach ($l in [IO.File]::ReadAllLines($about)) { Write-LabLine $l }
    } else {
        Write-LabLine 'This module has no about.txt yet. Its scripts are in the folder above.'
    }
}

# Exit-LabUsage MESSAGE [COMMAND] [FIX]: a usage error: one line, the fix
# if there is one, a pointer to help, exit 40 (docs/Conventions.md 3.1).
function Exit-LabUsage {
    param([string] $Message, [string] $Command = '', [string] $Fix = '')
    $topic = ''
    if ($Command -ne '') { $topic = " $Command" }
    [Console]::Error.WriteLine("labyrinth: $Message")
    if ($Fix -ne '') { [Console]::Error.WriteLine($Fix) }
    [Console]::Error.WriteLine("Try '$Self help$topic' for more information.")
    exit 40
}

# Write-LabWarning MESSAGE: a warning on stderr.
function Write-LabWarning {
    param([string] $Message)
    [Console]::Error.WriteLine("labyrinth: warning: $Message")
}

# Measure-LabEditDistance A B: the Levenshtein distance between A and B.
function Measure-LabEditDistance {
    param([string] $A, [string] $B)
    $prev = New-Object 'int[]' ($B.Length + 1)
    for ($j = 0; $j -le $B.Length; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = New-Object 'int[]' ($B.Length + 1)
        $cur[0] = $i
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = 1
            if ($A[$i - 1] -ceq $B[$j - 1]) { $cost = 0 }
            $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$B.Length]
}

# Get-LabSuggestion WORD CANDIDATES: the candidate WORD most likely meant:
# the only one it is a prefix of, else the nearest within an edit distance
# of 2. Returns '' when there is none.
function Get-LabSuggestion {
    param([string] $Word, [string[]] $Candidates)
    if ($Word -eq '') { return '' }
    $prefix = @($Candidates | Where-Object { $_.StartsWith($Word, [StringComparison]::Ordinal) })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    $best = ''
    $bestd = 3
    foreach ($c in $Candidates) {
        $d = Measure-LabEditDistance $Word $c
        if ($d -lt $bestd) { $bestd = $d; $best = $c }
    }
    return $best
}

# Find-LabOption KEY: the row of the option matched by KEY (lower case, no
# dashes), or $null.
function Find-LabOption {
    param([string] $Key)
    foreach ($o in $script:LabOptions) {
        if ($o.Keys -ccontains $Key) { return $o }
    }
    return $null
}

# Add-LabParseError MESSAGE: note the first option error; main reports it
# once the command is known, so the pointer to help names that command.
function Add-LabParseError {
    param([string] $Message)
    if ($script:ParseError -eq '') { $script:ParseError = $Message }
}

# Read-LabArgument WORD...: sort the words into options ($script:Given) and
# the rest ($script:Words). Options may come anywhere; '--' ends them.
function Read-LabArgument {
    param([object[]] $Arguments)
    $words = New-Object System.Collections.Generic.List[string]
    $ended = $false
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]; $i++
        if ($a -isnot [string]) {
            # In a PowerShell session, 0123 arrives as the number 123.
            Exit-LabUsage "'$a' was read as a number: put it in quotes, like '0123'"
        }
        $w = [string] $a
        if ($ended -or $w -notlike '-?*') { $words.Add($w); continue }
        if ($w -ceq '--') { $ended = $true; continue }
        if ($w -ceq '-h' -or $w -ceq '-?') { $w = '-Help' }
        elseif ($w -ceq '-V') { $w = '-Version' }
        elseif ($w -ceq '-v') { Add-LabParseError "unknown option '-v' (did you mean '-V', the version?)"; continue }
        $key = $w.Substring(1)
        if ($key.StartsWith('-')) { $key = $key.Substring(1) }
        $sep = ''
        $val = ''
        if ($key -match '^([^=:]*)([=:])(.*)$') {
            $key = $Matches[1]; $sep = $Matches[2]; $val = $Matches[3]
        }
        $shown = ($w -split '[=:]', 2)[0]
        $o = Find-LabOption ($key.ToLowerInvariant().Replace('-', ''))
        if ($null -eq $o) {
            # One candidate per option, its first key, so a prefix of two
            # keys of the same option still counts as one.
            $hint = Get-LabSuggestion ($key.ToLowerInvariant().Replace('-', '')) @($script:LabOptions | ForEach-Object { $_.Keys[0] })
            if ($hint -ne '') {
                $h = Find-LabOption $hint
                Add-LabParseError "unknown option '$shown' (did you mean '$($h.Show)'?)"
            }
            Add-LabParseError "unknown option '$shown'"
            continue
        }
        if ($o.Value) {
            # '-Name value', or a session's '-Name:' with the value as the next word.
            if ($sep -eq '' -or ($sep -eq ':' -and $val -eq '')) {
                if ($i -ge $Arguments.Count) { Add-LabParseError "$($o.Show) needs a value"; continue }
                $next = $Arguments[$i]
                if ($next -is [string] -and $next -like '-?*') { Add-LabParseError "$($o.Show) needs a value, but got '$next'"; continue }
                $val = [string] $next; $i++
            }
            if ($val -eq '') { Add-LabParseError "$($o.Show) needs a value"; continue }
        } elseif ($sep -ne '') {
            Add-LabParseError "$($o.Show) takes no value"; continue
        }
        if ($script:Given.ContainsKey($o.Name)) { Add-LabParseError "$($o.Show) is given twice"; continue }
        $script:Given[$o.Name] = $val
    }
    $script:Words = @($words)
}

# Test-LabOptionUse COMMAND OPTION...: note a warning for each value option
# given that COMMAND does not use. Write-LabPendingWarning prints them once
# the command has passed its own checks, so a warning never comes before an
# error.
function Test-LabOptionUse {
    param([string] $Command, [string[]] $Used = @())
    foreach ($name in @('profile', 'break-glass', 'confirm-group', 'approve')) {
        if ($script:Given.ContainsKey($name) -and $Used -notcontains $name) {
            $o = $script:LabOptions | Where-Object { $_.Name -eq $name }
            $script:PendingWarnings += "$($o.Show) is not used by $Command"
        }
    }
}

# Write-LabPendingWarning: print the warnings Test-LabOptionUse noted.
function Write-LabPendingWarning {
    foreach ($w in $script:PendingWarnings) { Write-LabWarning $w }
    $script:PendingWarnings = @()
}

# Write-LabLine TEXT: one line to the operator, and to the run log unless
# NoLog is set.
function Write-LabLine {
    param([AllowEmptyString()] [string] $Text = '')
    [Console]::Out.WriteLine($Text)
    if (-not $script:NoLog) { Add-LabLogLine $Text }
}

# Write-LabErrorLine TEXT: one line on stderr, and to the run log.
function Write-LabErrorLine {
    param([AllowEmptyString()] [string] $Text = '')
    [Console]::Error.WriteLine($Text)
    Add-LabLogLine $Text
}

# Exit-Lab MESSAGE [CODE] [FIX]: the error, then how to recover, on stderr.
function Exit-Lab {
    param([string] $Message, [int] $Code = 40, [string] $Fix = '')
    Write-LabErrorLine "labyrinth: $Message"
    if ($Fix -ne '') { Write-LabErrorLine $Fix }
    exit $Code
}

# How to get the rights a command needs, and how to mend a bad line.
$FixAdmin = "Run it again in PowerShell opened with 'Run as administrator'."
$FixLine = 'Correct that line, then run the same command again.'

# Get-LabProfileName: the profiles this host can use, comma-separated.
function Get-LabProfileName {
    $names = @()
    foreach ($dir in @((Join-Path $env:LAB_CONFIG_DIR 'profiles'), (Join-Path $env:LAB_ROOT 'profiles'))) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.profile' -File | Sort-Object Name)) {
            if ($names -cnotcontains $f.BaseName) { $names += $f.BaseName }
        }
    }
    return ($names -join ', ')
}

# Write-LabStatus WORD TEXT: a result line, the status word padded to 9
# characters (docs/Conventions.md section 3.2).
function Write-LabStatus {
    param([string] $Word, [string] $Text)
    Write-LabLine ($Word.PadRight(9) + $Text)
}

# Get-LabSafeText TEXT: TEXT with a tab as a space and every other control
# character as '?', so the output of a module or of a probed service cannot
# move the cursor, clear a line or hide text, on the operator's screen or in
# the run log. A forged 'OK' line must never pass for the runner's own.
function Get-LabSafeText {
    param([AllowEmptyString()] [AllowNull()] [string] $Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`t", ' ') -replace '[\x00-\x1f\x7f]', '?')
}

# Write-LabDetail LABEL TEXT: a labelled line under a status line (section
# 3.2). Long text wraps onto more lines with the same label, so that each
# line makes sense alone; a word longer than a line, such as a path, is not
# split.
function Write-LabDetail {
    param([string] $Label, [AllowEmptyString()] [string] $Text)
    $Text = Get-LabSafeText $Text
    $head = '  ' + "${Label}:".PadRight(11)
    while ($Text.Length -gt 65) {
        $cut = $Text.Substring(0, 66).LastIndexOf(' ')
        if ($cut -le 0) { break }
        Write-LabLine ($head + $Text.Substring(0, $cut))
        $Text = $Text.Substring($cut + 1)
    }
    Write-LabLine ($head + $Text)
}

# Write-LabMore ID: the last line of a WARN, BLOCKED, FAIL or ERROR block.
function Write-LabMore {
    param([string] $Id)
    Write-LabDetail 'More' "$Self help $Id"
}

# Write-LabLogPath: the run log's path, under a FAIL or ERROR line.
function Write-LabLogPath {
    if ($script:LogFile -ne '') { Write-LabDetail 'Log' $script:LogFile }
}

# Get-LabModuleName ID: 'Title (id)', or the ID alone when its title is
# unknown.
function Get-LabModuleName {
    param([string] $Id)
    if ($script:Titles.ContainsKey($Id)) { return '{0} ({1})' -f $script:Titles[$Id], $Id }
    return $Id
}

# Import-LabModuleTitle ID: keep the title of module ID, if its module.yml
# reads.
function Import-LabModuleTitle {
    param([string] $Id)
    if ($script:Titles.ContainsKey($Id)) { return }
    $phase, $name = $Id -split '\.', 2
    $file = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $phase) 'modules') $name) 'module.yml'
    $script:YmlErr = @()
    if ((Read-LabModuleYml $file) -and $script:Mod.ContainsKey('title') -and $script:Mod['title'] -ne '') {
        $script:Titles[$Id] = $script:Mod['title']
    }
    $script:YmlErr = @()
}

# Get-LabItemWord ID CATEGORY FINGERPRINT REASON: an item as an Item line
# shows it: 'id@fingerprint (category): reason'.
function Get-LabItemWord {
    param([string] $Id, [string] $Category, [string] $Fingerprint, [AllowEmptyString()] [string] $Reason = '')
    $text = "$Id@$Fingerprint ($Category)"
    if ($Reason -ne '') { $text += ": $Reason" }
    return $text
}

# Write-LabLabelled LINE: one line a module printed, as a labelled line. An
# item line is an Item; a line 'key: text', with a key from the label list,
# keeps that label; any other line is a Note (docs/Conventions.md section
# 3.2). Blank lines are dropped.
function Write-LabLabelled {
    param([AllowEmptyString()] [string] $Line)
    $l = $Line.Trim()
    if ($l -eq '') { return }
    if ($Line.TrimStart() -cmatch $ReItem) {
        Write-LabDetail 'Item' (Get-LabItemWord $Matches[1] $Matches[2] $Matches[3] $Matches[4].Trim())
        return
    }
    if ($l -match '^([A-Za-z][A-Za-z ]*):\s+(.*)$') {
        $key = $Matches[1].ToLowerInvariant()
        if ($Labels -ccontains $key) {
            Write-LabDetail ($key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)) $Matches[2]
            return
        }
    }
    Write-LabDetail 'Note' $l
}

# Test-LabProblemLine LINE: is LINE a 'problem:' line?
function Test-LabProblemLine {
    param([AllowEmptyString()] [string] $Line)
    return ($Line -match '^\s*problem:\s')
}

# Test-LabLabel KEY LINE...: does any of the lines start with 'KEY:'?
function Test-LabLabel {
    param([string] $Key, [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line = @())
    foreach ($l in $Line) { if ($l -match ('^\s*' + [regex]::Escape($Key) + ':\s')) { return $true } }
    return $false
}

# Add-LabLogLine TEXT: add TEXT to the run log, or keep it until the log
# exists. A log that cannot be written never stops a run.
function Add-LabLogLine {
    param([AllowEmptyString()] [string] $Text)
    if ($script:LogFile -ne '') {
        try { [IO.File]::AppendAllText($script:LogFile, $Text + "`n", (New-Object Text.UTF8Encoding $false)) } catch { $null = $_ }
    } elseif ($script:LogOn) {
        $script:LogBuf.Add($Text)
    }
}

# Open-LabRunLog WHAT: open the run's output.log, with a line saying what
# writes to it, then the lines kept so far. It is in the data root, which
# only administrators can read (Protect-LabDataRoot), as umask 077 does on
# Linux.
function Open-LabRunLog {
    param([string] $What)
    $file = Join-Path (Get-LabRunDir $env:LAB_RUN_ID) 'output.log'
    try {
        $text = "$(Get-LabUtcNow) labyrinth ${LabVersion}: $What`n"
        foreach ($l in $script:LogBuf) { $text += "$l`n" }
        [IO.File]::AppendAllText($file, $text, (New-Object Text.UTF8Encoding $false))
        $script:LogFile = $file
    } catch { $null = $_ }
    $script:LogBuf.Clear()
}

# Write-LabEntryLog ID ENTRY: the raw output of an entry point (EntryOut)
# and its exit code, for the run log; at most LogCap lines.
function Write-LabEntryLog {
    param([string] $Id, [string] $Entry)
    if ($script:LogFile -eq '' -and -not $script:LogOn) { return }
    $n = 0
    foreach ($l in $script:EntryOut) {
        $n++
        if ($n -le $LogCap) { Add-LabLogLine "$Id $Entry| $(Get-LabSafeText $l)" }
    }
    if ($n -gt $LogCap) { Add-LabLogLine "${Id} ${Entry}: $($n - $LogCap) more lines not logged" }
    Add-LabLogLine "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Id $Entry exited $($script:EntryRc)"
}

# Show-LabOutput [LINE...]: the lines, or EntryOut, as labelled lines. The
# run log has the raw lines already.
function Show-LabOutput {
    param([AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line = $script:EntryOut)
    $script:NoLog = $true
    try { foreach ($l in $Line) { Write-LabLabelled $l } } finally { $script:NoLog = $false }
}

# Write-LabFailed ENTRY CODE SCRIPT: the Problem line after an entry point
# failed (design 00: a failing entry point prints a 'problem:' line last).
# Without one, the runner says it gave no reason, and where the script is.
function Write-LabFailed {
    param([string] $Entry, [int] $Code, [string] $Script)
    $what = "failed with exit code $Code"
    if ($Code -eq 20) { $what = 'was blocked (exit code 20)' }
    if ($script:GaveReason) {
        Write-LabDetail 'Problem' "its $Entry script $what, for the reason above"
    } else {
        Write-LabDetail 'Problem' "its $Entry script $what and gave no reason"
        Write-LabDetail 'Script' $Script
    }
}

# Write-LabExplain ENTRY CODE SCRIPT: in plan mode, what a failed entry
# point said: its labelled lines when it gave a reason; otherwise the
# runner's Problem line and its last 10 lines.
function Write-LabExplain {
    param([string] $Entry, [int] $Code, [string] $Script)
    if ($script:GaveReason) { Show-LabOutput; return }
    Write-LabFailed $Entry $Code $Script
    $said = @($script:EntryOut | Where-Object { $_.Trim() -ne '' })
    if ($said.Count -eq 0) { Write-LabDetail 'It said' 'nothing'; return }
    foreach ($l in ($said | Select-Object -Last 10)) { Write-LabDetail 'It said' $l.TrimEnd() }
}

# ConvertTo-LabOutputText ITEM: one item of an entry point's output as text.
# An error record becomes its message, never PowerShell's error view.
function ConvertTo-LabOutputText {
    param($Item)
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return $Item.Exception.Message }
    return "$Item"
}

# Write-LabSummary MODE: how many modules ended with each status word,
# counted from the run's list, not from the lines printed.
function Write-LabSummary {
    param([string] $Mode)
    $n = @{ OK = 0; CHANGE = 0; WARN = $script:LoadSkipped; BLOCKED = 0; FAIL = 0; ERROR = $script:LoadErrors }
    $notRun = 0
    foreach ($m in $script:Run) {
        $w = ''
        if ($Mode -ceq 'plan') {
            if ($m.Rc -eq 0) { $w = 'OK' } elseif ($m.Rc -eq 10) { $w = 'CHANGE' } elseif ($m.Rc -eq 20) { $w = 'BLOCKED' } else { $w = 'ERROR' }
            if ($w -ceq 'CHANGE' -and $m.Risk -eq 'manual-only') { $w = 'WARN' }
        } elseif ($m.State -ceq 'done') { $w = 'OK' }
        elseif ($m.State -ceq 'manual') { $w = 'WARN' }
        elseif ($m.State -ceq 'blocked') { $w = 'BLOCKED' }
        elseif ($m.State -ceq 'failed') { $w = 'FAIL' }
        elseif ($m.State -ceq 'error') { $w = 'ERROR' }
        else { $notRun++ }
        if ($w -ne '') { $n[$w]++ }
    }
    $parts = @()
    foreach ($w in @('OK', 'CHANGE', 'WARN', 'BLOCKED', 'FAIL', 'ERROR')) {
        if ($n[$w] -gt 0) { $parts += "$($n[$w]) $w" }
    }
    if ($notRun -gt 0) { $parts += "$notRun not run" }
    $script:ErrorCount = $n['ERROR']
    $total = $notRun
    foreach ($w in $n.Keys) { $total += $n[$w] }
    if ($total -eq 0) { Write-LabLine 'Summary: no modules.' }
    elseif ($total -eq 1) { Write-LabLine "Summary: 1 module: $($parts -join ', ')." }
    else { Write-LabLine "Summary: $total modules: $($parts -join ', ')." }
}

# ConvertTo-LabShellWord WORD: WORD, quoted if PowerShell would split it.
function ConvertTo-LabShellWord {
    param([string] $Word)
    if ($Word -match '^[A-Za-z0-9\\/._:@=-]+$') { return $Word }
    return "'" + $Word.Replace("'", "''") + "'"
}

# Write-LabNextStep MODE CODE PHASE: the one command to run next, if any.
function Write-LabNextStep {
    param([string] $Mode, [int] $Code, [string] $Phase)
    $short = $env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)
    if ($Mode -ceq 'apply' -and $script:Stopped) {
        Write-LabLine 'Next: keep the earlier changes or undo them, with the commands above.'
    } elseif ($Mode -ceq 'apply' -and $script:Applied -and (Test-LabRevertTimer -RunId $env:LAB_RUN_ID)) {
        Write-LabLine "Next: check you can log in from a NEW session, then '$Self keep $short'."
    } elseif ($Code -eq 40) {
        if ($script:ErrorCount -gt 1) {
            Write-LabLine 'Next: fix the errors above, then run the same command again.'
        } else {
            Write-LabLine 'Next: fix the error above, then run the same command again.'
        }
    } elseif ($Code -eq 20) {
        Write-LabLine 'Next: clear what blocked it above, then run the same command again.'
    } elseif ($Code -eq 10) {
        $other = @($script:Run | Where-Object { $_.Rc -eq 10 -and $_.Risk -ne 'manual-only' }).Count
        if ($other -eq 0) {
            Write-LabLine 'Next: a person carries out the manual steps above; apply changes nothing.'
        } else {
            $opts = ''
            if ($script:Given.ContainsKey('profile')) { $opts += " -Profile $($script:Given['profile'])" }
            if ($script:Given.ContainsKey('root')) { $opts += " -Root $(ConvertTo-LabShellWord $script:Given['root'])" }
            if ($script:Given.ContainsKey('config')) { $opts += " -Config $(ConvertTo-LabShellWord $script:Given['config'])" }
            # A command too long for one line goes on a line of its own.
            if (("$Self apply $Phase$opts").Length + 6 -gt 78) {
                Write-LabLine 'Next:'
                Write-LabLine "  $Self apply $Phase$opts"
            } else {
                Write-LabLine "Next: $Self apply $Phase$opts"
            }
        }
    }
}

# Exit-LabRun MODE CODE PHASE: the end of a plan or apply: Summary, what
# changed, the log, Next and the exit code with its meaning; then exit.
function Exit-LabRun {
    param([string] $Mode, [int] $Code, [string] $Phase)
    $what = 'error'
    if ($Mode -ceq 'plan' -and $Code -eq 0) { $what = 'nothing to do' }
    elseif ($Mode -ceq 'plan' -and $Code -eq 10) { $what = 'change needed' }
    elseif ($Mode -ceq 'plan' -and $Code -eq 40) { $what = 'error: a module could not be checked' }
    elseif ($Mode -ceq 'apply' -and $Code -eq 0) { $what = 'done' }
    elseif ($Mode -ceq 'apply' -and $Code -eq 10) { $what = 'manual steps needed' }
    elseif ($Code -eq 20) { $what = 'blocked' }
    elseif ($Code -eq 30) { $what = 'a check failed, and that change was undone' }
    Write-LabLine ''
    if ($Mode -ceq 'plan' -or -not $script:Applied) {
        Write-LabSummary 'plan'
        Write-LabLine 'Nothing on this host was changed.'
    } else {
        Write-LabSummary 'apply'
        $problems = $script:Stopped -or @($script:Run | Where-Object { $_.State -ceq 'failed' -or $_.State -ceq 'error' }).Count -gt 0
        if ($problems) { Add-LabProblemMark }
    }
    if ($script:LogFile -ne '') { Write-LabLine "Log: $($script:LogFile)" }
    Write-LabNextStep $Mode $Code $Phase
    Write-LabLine "$Mode finished: exit $Code ($what)"
    exit $Code
}

# Add-LabProblemMark: note in the run folder that the run had problems, so
# that 'runs' points to its log.
function Add-LabProblemMark {
    try { [IO.File]::WriteAllText((Join-Path (Get-LabRunDir $env:LAB_RUN_ID) 'problems'), '') } catch { $null = $_ }
}

# Get-LabRunStopped: what the operator needs after a run stops partway.
function Get-LabRunStopped {
    'The run stopped. Earlier changes stay until the revert timer undoes them.'
    $when = Get-LabDueWord $env:LAB_RUN_ID
    if ($when -ne '') { "The revert timer rolls this run back $when." }
    $short = $env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)
    "To keep them now: $Self keep $short"
    "To undo them now: $Self rollback $short"
}

# Get-LabDueWord RUN: when the run's revert timer fires, as 'at HH:MM UTC,
# in N minutes'; empty when the time is not known.
function Get-LabDueWord {
    param([string] $RunId)
    $due = ''
    try { $due = Get-LabRevertTimerDue -RunId $RunId } catch { return '' }
    if ($due -eq '') { return '' }
    $at = $due.Substring(11, 5)
    $when = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParseExact($due, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $when)) {
        return "at $at UTC"
    }
    $mins = [int][Math]::Floor((($when - [DateTime]::UtcNow).TotalSeconds + 59) / 60)
    if ($mins -gt 1) { return "at $at UTC, in $mins minutes" }
    if ($mins -eq 1) { return "at $at UTC, in 1 minute" }
    return "at $at UTC, which is now"
}

# Get-LabRecovery: after an internal error, what changed and what to do next.
function Get-LabRecovery {
    if ($script:RunOpen) {
        if (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) { return Get-LabRunStopped }
        return @('The run stopped. Its manifest lists what it did.',
            "To undo it: $Self rollback $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4))")
    }
    $short = ''
    if ($script:RunRef -ne '') { $short = $script:RunRef.Substring($script:RunRef.Length - 4) }
    switch ($script:Command) {
        'rollback' {
            if ($short -ne '') { return @('The rollback did not finish, and it is safe to repeat.', "Retry: $Self rollback $short") }
            return 'Nothing was rolled back.'
        }
        'keep' {
            if ($short -ne '') { return @("The run may not be kept; '$Self runs' shows its state.", "Retry: $Self keep $short") }
            return 'Nothing was kept.'
        }
    }
    return 'Nothing was changed.'
}

# Write-YmlError WHERE MESSAGE: keep a module.yml error, to print under the
# module's ERROR line.
function Write-YmlError {
    param([string] $Where, [string] $Message)
    $script:YmlErr += "${Where}: $Message"
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
    if ($m['title'] -cnotmatch '^[ -~]+$') { Write-YmlError $File 'title must be plain ASCII text'; return $false }
    if ($m['title'].Length -gt 40) { Write-YmlError $File "title is $($m['title'].Length) characters; the most is 40"; return $false }
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
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $names = Get-LabProfileName
        if ($names -ne '') { Exit-Lab "no profile named $Name" 40 "Profiles here: $names." }
        Exit-Lab "no profile named $Name" 40 "There are no profiles in $(Join-Path $env:LAB_CONFIG_DIR 'profiles') or $(Join-Path $env:LAB_ROOT 'profiles')."
    }
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
# (docs/Conventions.md section 3). Its output, both streams, goes to the
# operator as it comes, as labelled lines (section 3.2), and to the run log.
# Its exit code is left in $script:EntryRc, and whether it ended with a
# 'problem:' line in $script:GaveReason. With -Capture, the output is kept
# in EntryOut instead, because the result line above it is known only
# when it ends.
function Invoke-LabEntry {
    param([string] $Dir, [string] $Entry, [string] $Id, [string] $DryRun = '1', [switch] $Capture)
    $env:LAB_MODULE_ID = $Id
    $env:LAB_ENTRY = $Entry
    $env:LAB_DRY_RUN = $DryRun
    $env:LAB_APPROVED = $script:Approved
    $hostExe = (Get-Process -Id $PID).Path
    $script:EntryRc = 0
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:EntryLast = ''
    try {
        # Piped, so the output never becomes the return value of the
        # function that called this one.
        $file = Join-Path $Dir "$Entry.ps1"
        if ($Capture) {
            $script:EntryOut = @(& $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 |
                    ForEach-Object { (ConvertTo-LabOutputText $_) -split "`r?`n" })
            $script:EntryRc = $LASTEXITCODE
            foreach ($l in $script:EntryOut) { if ($l.Trim() -ne '') { $script:EntryLast = $l } }
        } else {
            Add-LabLogLine "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Id $Entry started"
            $n = 0
            & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | ForEach-Object {
                foreach ($l in ((ConvertTo-LabOutputText $_) -split "`r?`n")) {
                    Show-LabOutput $l
                    $n++
                    if ($n -le $LogCap) { Add-LabLogLine "$Id $Entry| $(Get-LabSafeText $l)" }
                    if ($l.Trim() -ne '') { $script:EntryLast = $l }
                }
            }
            $script:EntryRc = $LASTEXITCODE
            if ($n -gt $LogCap) { Add-LabLogLine "${Id} ${Entry}: $($n - $LogCap) more lines not logged" }
        }
    } finally {
        $ErrorActionPreference = $saved
        $env:LAB_MODULE_ID = ''
        $env:LAB_ENTRY = ''
        $env:LAB_DRY_RUN = $script:DryRun
        $env:LAB_APPROVED = ''
    }
    $script:GaveReason = Test-LabProblemLine $script:EntryLast
    if ($Capture) { Write-LabEntryLog $Id $Entry }
    else { Add-LabLogLine "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Id $Entry exited $($script:EntryRc)" }
}

# Load and check every module of the phase in the profile, then put them in
# run order: by priority, P0 first, and in profile order within a priority.
# Returns 40 if any module is invalid.
function Import-LabRunModule {
    param([string] $Phase)
    $worst = 0
    $found = @()
    $script:PhaseCount = 0
    $script:LoadErrors = 0
    $script:LoadSkipped = 0
    foreach ($id in $script:ProfileIds) {
        if (($id -split '\.', 2)[0] -cne $Phase) { continue }
        $script:PhaseCount++
        $name = ($id -split '\.', 2)[1]
        $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $Phase) 'modules') $name
        $yml = Join-Path $dir 'module.yml'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            Write-LabStatus 'ERROR' $id
            Write-LabDetail 'Problem' 'module not found: the profile lists it, but there is no such module'
            Write-LabDetail 'Found' "no folder $dir"
            Write-LabDetail 'Fix' "correct the ID in profile $($script:ProfileName), or add the module"
            $script:LoadErrors++; $worst = 40; continue
        }
        $script:YmlErr = @()
        if (-not (Read-LabModuleYml $yml) -or -not (Test-LabModule $yml $id $Phase)) {
            Write-LabStatus 'ERROR' $id
            Write-LabDetail 'Problem' 'invalid module.yml, so the module cannot be loaded'
            foreach ($e in $script:YmlErr) {
                if ($e.StartsWith("$dir\")) { $e = $e.Substring($dir.Length + 1) }
                Write-LabDetail 'Found' $e
            }
            Write-LabDetail 'Fix' "report the module to its author, or correct it in $dir"
            $script:LoadErrors++; $worst = 40; continue
        }
        $script:Titles[$id] = $script:Mod['title']
        if (@(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File).Count -eq 0) {
            Write-LabStatus 'WARN' (Get-LabModuleName $id)
            Write-LabDetail 'Found' 'skipped: no Windows entry points; it runs on other hosts'
            Write-LabMore $id
            $script:LoadSkipped++; continue
        }
        $needed = @('check')
        if (@('reversible', 'service-affecting', 'approval') -ccontains $script:Mod['risk']) { $needed = @('check', 'apply', 'verify', 'rollback') }
        $missing = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir "$_.ps1") -PathType Leaf) })
        if ($missing.Count -gt 0) {
            Write-LabStatus 'ERROR' (Get-LabModuleName $id)
            Write-LabDetail 'Problem' "missing $($missing[0]).ps1, which a module of risk $($script:Mod['risk']) needs"
            Write-LabDetail 'Fix' 'report the module to its author'
            Write-LabMore $id
            $script:LoadErrors++; $worst = 40; continue
        }
        # A module that never changes anything ships no entry point that does.
        if (@('read-only', 'manual-only') -ccontains $script:Mod['risk']) {
            $extra = @('apply', 'rollback', 'cleanup' | Where-Object { Test-Path -LiteralPath (Join-Path $dir "$_.ps1") -PathType Leaf })
            if ($extra.Count -gt 0) {
                Write-LabStatus 'ERROR' (Get-LabModuleName $id)
                Write-LabDetail 'Problem' "$($extra[0]).ps1 is not allowed: a $($script:Mod['risk']) module changes nothing"
                Write-LabDetail 'Fix' 'report the module to its author'
                Write-LabMore $id
                $script:LoadErrors++; $worst = 40; continue
            }
        }
        $requires = @()
        if ($script:Mod.ContainsKey('requires')) { $requires = Get-LabListItem $script:Mod['requires'] }
        $found += [pscustomobject]@{
            Id = $id; Dir = $dir; Risk = $script:Mod['risk']; Scored = ($script:Mod['touches_scored'] -eq 'true')
            Requires = $requires; Priority = $script:Mod['priority']; Rc = 0; State = 'planned'; Items = @()
        }
    }
    $ordered = @()
    foreach ($p in @('P0', 'P1', 'P2', 'P3')) { $ordered += @($found | Where-Object { $_.Priority -ceq $p }) }
    $script:Run = $ordered
    return $worst
}

# Invoke-LabPlanOne M: run check and, when a change is needed, plan; print
# the module's status line and its labelled lines. Keeps the module's
# contract code in .Rc.
function Invoke-LabPlanOne {
    param($M)
    $id = $M.Id
    $name = Get-LabModuleName $id
    $fixBlocked = 'clear what blocked it, then run the same command again'
    $fixError = 'report the module to its author; the others were still checked'
    Invoke-LabEntry $M.Dir 'check' $id -Capture
    switch ($script:EntryRc) {
        0 {
            Write-LabStatus 'OK' $name
            if (@($script:EntryOut | Where-Object { $_.Trim() -ne '' }).Count -gt 0) { Show-LabOutput } else { Write-LabDetail 'Found' 'nothing to do' }
            $M.Rc = 0; return
        }
        10 { }
        20 {
            Write-LabStatus 'BLOCKED' $name
            Write-LabExplain 'check' 20 (Join-Path $M.Dir 'check.ps1')
            Write-LabDetail 'Fix' $fixBlocked; Write-LabMore $id
            $M.Rc = 20; return
        }
        default {
            Write-LabStatus 'ERROR' $name
            Write-LabExplain 'check' $script:EntryRc (Join-Path $M.Dir 'check.ps1')
            Write-LabDetail 'Fix' $fixError; Write-LabMore $id
            $M.Rc = 40; return
        }
    }
    $said = $script:EntryOut
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'plan.ps1') -PathType Leaf)) {
        Write-LabStatus 'ERROR' $name; Show-LabOutput
        Write-LabDetail 'Problem' 'its check found a change to make, but plan.ps1 is missing'
        Write-LabDetail 'Fix' $fixError; Write-LabMore $id
        $M.Rc = 40; return
    }
    Invoke-LabEntry $M.Dir 'plan' $id -Capture
    $rc = $script:EntryRc
    if ($M.Risk -eq 'approval' -and ($rc -eq 0 -or $rc -eq 10)) {
        $why = Read-LabItem $M
        if ($why -ne '') {
            Write-LabStatus 'ERROR' $name; Show-LabOutput $said; Show-LabOutput
            Write-LabDetail 'Problem' "its plan listed an item wrongly: $why"
            Write-LabDetail 'Fix' $fixError; Write-LabMore $id
            $M.Rc = 40; return
        }
    }
    if ($rc -eq 0 -or $rc -eq 10) {
        if ($M.Risk -eq 'manual-only') {
            Write-LabStatus 'WARN' $name
            Write-LabDetail 'Found' 'this needs a person; Labyrinth will not change it'
        } else {
            Write-LabStatus 'CHANGE' $name
        }
        Show-LabOutput $said; Show-LabOutput
        if ($M.Risk -eq 'manual-only') {
            Write-LabMore $id
        } elseif (-not (Test-LabLabel 'risk' (@($said) + @($script:EntryOut)))) {
            Write-LabDetail 'Risk' (Get-LabRiskWord $M.Risk)
        }
        $M.Rc = 10; return
    }
    if ($rc -eq 20) {
        Write-LabStatus 'BLOCKED' $name; Show-LabOutput $said
        Write-LabExplain 'plan' 20 (Join-Path $M.Dir 'plan.ps1')
        Write-LabDetail 'Fix' $fixBlocked; Write-LabMore $id
        $M.Rc = 20; return
    }
    Write-LabStatus 'ERROR' $name; Show-LabOutput $said
    Write-LabExplain 'plan' $rc (Join-Path $M.Dir 'plan.ps1')
    Write-LabDetail 'Fix' $fixError; Write-LabMore $id
    $M.Rc = 40
}

# Read-LabItem M: keep the items an approval module's plan listed
# ($script:EntryOut) in M.Items (docs/Conventions.md section 3.1). Returns
# '' or, when an item line is malformed or an id is listed twice, why.
function Read-LabItem {
    param($M)
    $items = @()
    foreach ($raw in @($script:EntryOut)) {
        $line = "$raw".TrimStart().TrimEnd("`r")
        if (-not $line.StartsWith("item`t")) { continue }
        if ($line -cnotmatch $ReItem) {
            return "not 'item', id, category, fingerprint and reason, separated by tabs: $($line.Replace("`t", ' '))"
        }
        $item = [pscustomobject]@{ Id = $Matches[1]; Category = $Matches[2]; Fingerprint = $Matches[3]; Reason = $Matches[4].Trim() }
        if (@($items | Where-Object { $_.Id -ceq $item.Id }).Count -gt 0) { return "the id $($item.Id) is listed twice" }
        $items += $item
    }
    $M.Items = $items
    return ''
}

# Load and plan the phase's modules; return the worst code.
function Invoke-LabPlanAll {
    param([string] $Phase)
    $worst = Import-LabRunModule $Phase
    foreach ($m in $script:Run) {
        Invoke-LabPlanOne $m
        if ($m.Rc -gt $worst) { $worst = $m.Rc }
    }
    if ($script:PhaseCount -eq 0) {
        Write-LabStatus 'WARN' "Phase $Phase"
        Write-LabDetail 'Found' "profile $($script:ProfileName) lists no $Phase modules: nothing to check"
        Write-LabDetail 'Fix' "add $Phase modules to the profile, or plan another phase"
        Write-LabDetail 'More' "$Self help basics"
    }
    return $worst
}

# Only administrators may be able to change Labyrinth's code, its
# configuration and its data root, because they run as SYSTEM, later too,
# by the revert timer (design 07, section 5).
function Assert-LabTrustedTree {
    $bad = Find-LabUntrustedItem -Path @($env:LAB_ROOT, $env:LAB_CONFIG_DIR, $script:DataRoot)
    if ($null -ne $bad) {
        Exit-Lab "$bad can be changed by an account that is not an administrator, so Labyrinth will not run as SYSTEM from it" 20 `
            "Keep Labyrinth's folders owned by Administrators, with no other account allowed to change them, as under C:\ProgramData\Labyrinth."
    }
}

# The protected set must load and hold at least one account (design 01,
# section 7). Plan mode needs it too, because plans that touch accounts depend on it.
function Assert-LabProtectedSet {
    $set = $null
    try { $set = Read-LabProtectedSet } catch { Exit-Lab "the protected set is malformed: $($_.Exception.Message)" 40 $FixLine }
    if ($null -eq $set) {
        $file = Join-Path $env:LAB_CONFIG_DIR 'protected-accounts'
        $why = "$file lists no accounts"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $why = "there is no $file" }
        Exit-Lab "the protected set is not loaded, so nothing runs: $why" 20 'List, one "account class" per line, the accounts Labyrinth must never change.'
    }
    $script:Protected = $set
}

# Read-LabAnswer PROMPT: print PROMPT and read one line into $script:Answer.
# Returns $false at the end of input. The run log keeps the prompt and the
# answer.
function Read-LabAnswer {
    param([string] $Prompt)
    [Console]::Out.Write($Prompt)
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        [Console]::Out.WriteLine()
        Add-LabLogLine "$Prompt(no answer)"
        $script:Answer = ''
        return $false
    }
    $script:Answer = $line.Trim()
    Add-LabLogLine "$Prompt$($script:Answer)"
    return $true
}

function Assert-LabBreakGlass {
    $account = Get-LabBreakGlass -Protected $script:Protected
    if ($account) {
        Write-LabLine "Break-glass account ${account}: confirmed earlier, so not asked again."
    } else {
        if ($script:GivenBreakGlass -ne '') {
            $account = $script:GivenBreakGlass
        } else {
            Write-LabLine 'Before any change, prove you can still get in if remote logins break.'
            if (-not (Read-LabAnswer "Break-glass check: log in at this host's console with the break-glass account, then type its name: ")) {
                Exit-Lab 'no answer: break-glass not confirmed; nothing was changed' 20
            }
            $account = $script:Answer
        }
        try { Save-LabBreakGlass -Protected $script:Protected -Account $account }
        catch { Write-LabErrorLine $_.Exception.Message; Exit-Lab 'break-glass not confirmed; nothing was changed' 20 }
        Write-LabLine "Break-glass account ${account}: confirmed and recorded."
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

# Write-LabLogFor ID LEVEL EVENT MESSAGE: a log event on a module's behalf.
# The runner has said it already, so a warn or error event is not echoed
# to the console.
function Write-LabLogFor {
    param([string] $Id, [string] $Level, [string] $EventName, [string] $Message)
    $env:LAB_MODULE_ID = $Id
    $err = [Console]::Error
    try {
        [Console]::SetError([IO.TextWriter]::Null)
        Write-LabLog -Level $Level -EventName $EventName -Message $Message
    } finally {
        [Console]::SetError($err)
        $env:LAB_MODULE_ID = ''
    }
}

# Undo-LabModule ID [-Inline]: undo one module's changes in the current
# run; returns 0 or 40. Inline, under the FAIL or ERROR block of a failed
# apply, success is one Did line; otherwise the module gets its own CHANGE
# and OK lines.
function Undo-LabModule {
    param([string] $Id, [switch] $Inline)
    $phase, $short = $Id -split '\.', 2
    $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $phase) 'modules') $short
    $name = Get-LabModuleName $Id
    $script_ = Join-Path $dir 'rollback.ps1'
    if (-not $Inline) {
        Write-LabStatus 'CHANGE' $name
        Write-LabDetail 'Will do' 'undo what this run changed'
    }
    $rc = 0
    if (Test-Path -LiteralPath $script_ -PathType Leaf) {
        Invoke-LabEntry $dir 'rollback' $Id '0'
        $rc = $script:EntryRc
    } else {
        $env:LAB_MODULE_ID = $Id
        try { Restore-LabBackup } catch { Write-LabErrorLine $_.Exception.Message; $rc = 40 } finally { $env:LAB_MODULE_ID = '' }
    }
    $run = $env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)
    if ($rc -eq 0) {
        try {
            Add-LabEntryFor $Id 'rolled_back'
        } catch {
            Write-LabStatus 'ERROR' $name
            Write-LabDetail 'Problem' 'rolled back, but the manifest cannot be written'
            Write-LabDetail 'Found' 'the manifest still lists the change; rolling back again is safe'
            Write-LabDetail 'Fix' "run '$Self rollback $run' again"
            Write-LabLogPath; Write-LabMore $Id
            return 40
        }
        if (-not $Inline) { Write-LabStatus 'OK' $name }
        Write-LabDetail 'Did' 'rolled back'
        Write-LabLogFor $Id 'warn' 'rolled_back' 'rolled back'
        return 0
    }
    Write-LabStatus 'ERROR' $name
    Write-LabDetail 'Problem' "its rollback stopped with exit code $rc; the change may still be in place"
    if (Test-Path -LiteralPath $script_ -PathType Leaf) { Write-LabDetail 'Script' $script_ }
    Write-LabDetail 'Fix' "restore its files by hand from $(Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $Id)"
    Write-LabLogPath; Write-LabMore $Id
    Write-LabLogFor $Id 'error' 'rollback_failed' "rollback failed with exit $rc"
    return 40
}

# Did every module this one requires, in this run, finish?
function Test-LabRequire {
    param($M)
    foreach ($req in $M.Requires) {
        foreach ($other in $script:Run) {
            if ($other.Id -ceq $req -and @('done', 'planned') -notcontains $other.State) {
                Write-LabStatus 'BLOCKED' (Get-LabModuleName $M.Id)
                Write-LabDetail 'Problem' "it needs $(Get-LabModuleName $req) to finish first, and it did not"
                Write-LabDetail 'Fix' 'fix that module first, then run the same command again'
                Write-LabMore $M.Id
                return $false
            }
        }
    }
    return $true
}

# Write-LabProbeLine RESULTS [NAMES]: probe lines as Found lines; with
# NAMES, only those services, each of which passed before the change.
function Write-LabProbeLine {
    param([AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Result, [string[]] $Name = $null)
    foreach ($l in $Result) {
        if ($l.Trim() -eq '') { continue }
        $f = $l.Trim() -split '\s+', 3
        $text = "$($f[0]): $($f[1])"
        if ($f.Count -gt 2 -and $f[2] -ne '') { $text += " ($($f[2]))" }
        if ($null -ne $Name) {
            if ($Name -cnotcontains $f[0]) { continue }
            $text += '; it passed before'
        }
        Write-LabDetail 'Found' $text
    }
}

function Get-LabProbeNow {
    if (-not $script:HaveServices) { return , @() }
    # Assigned first: Get-LabProbeResult returns its lines as one array.
    $lines = Get-LabProbeResult -Timeout $script:Settings['PROBE_TIMEOUT']
    return , @($lines)
}

# Apply, verify and probe one module. Returns 0 (done or nothing to do),
# 20 (blocked; continue), or 30/40 (rolled back; stop).
function Get-LabApproveEntry {
    return @($script:Given['approve'].Split(','))
}

# Select-LabItem M: the items of approval module M that a person approved,
# as 'id@fingerprint' words in $script:Approved (docs/Conventions.md
# section 3.1): the -Approve entries that name the module when it was given,
# otherwise the ids and categories typed at the prompt. An -Approve entry
# whose fingerprint differs from this run's plan is recorded as refused and
# left out. Returns 0 with something approved; 1, after an OK block, when
# nothing was; 20, after a BLOCKED block, when the answer is not ids and
# categories.
function Select-LabItem {
    param($M)
    $id = $M.Id
    $name = Get-LabModuleName $id
    $script:Approved = ''
    $script:Refused = @()
    $list = @()
    if (@($M.Items).Count -eq 0) {
        Write-LabStatus 'OK' $name
        Write-LabDetail 'Did' 'its plan listed no items to approve, so nothing changed'
        return 1
    }
    if ($script:Given.ContainsKey('approve')) {
        foreach ($tok in (Get-LabApproveEntry)) {
            $colon = $tok.IndexOf(':')
            if ($tok.Substring(0, $colon) -cne $id) { continue }
            $want = $tok.Substring($colon + 1)
            $at = $want.LastIndexOf('@')
            $iid = $want.Substring(0, $at)
            $item = @($M.Items | Where-Object { $_.Id -ceq $iid })
            if ($item.Count -eq 0) { continue }   # reported after the plan
            if (@($list | Where-Object { $_.StartsWith("$iid@") }).Count -gt 0) { continue }
            if ($item[0].Fingerprint -cne $want.Substring($at + 1)) {
                try {
                    Add-LabEntryFor $id 'approval_refused' $iid "approved $($want.Substring($at + 1)), changed since the plan; now $($item[0].Fingerprint)"
                } catch { Write-LabErrorLine $_.Exception.Message }
                $script:Refused += $iid
                continue
            }
            $list += $want
        }
    } else {
        Write-LabLine "$name changes only the items you approve:"
        foreach ($i in $M.Items) { Write-LabDetail 'Item' (Get-LabItemWord $i.Id $i.Category $i.Fingerprint $i.Reason) }
        Write-LabLine 'To approve every item of a category, type category: and its name.'
        if (-not (Read-LabAnswer 'Type the ids of the items to approve, separated by spaces, or press Enter for none: ')) { $script:Answer = '' }
        $words = @($script:Answer -split '\s+' | Where-Object { $_ -ne '' })
        foreach ($tok in $words) {
            if ($tok -cnotmatch '^(category:)?[a-z0-9-]+$') {
                Write-LabStatus 'BLOCKED' $name
                Write-LabDetail 'Problem' "not an item id or a category: $tok"
                Write-LabDetail 'Fix' 'type ids from its plan above, separated by spaces'
                Write-LabMore $id
                return 20
            }
        }
        foreach ($tok in $words) {
            $hit = $false
            foreach ($i in $M.Items) {
                if ($tok -ceq $i.Id -or $tok -ceq "category:$($i.Category)") {
                    $hit = $true
                    if (@($list | Where-Object { $_.StartsWith("$($i.Id)@") }).Count -eq 0) { $list += "$($i.Id)@$($i.Fingerprint)" }
                }
            }
            if (-not $hit) { Write-LabLine "Not in its plan, so ignored: $tok" }
        }
    }
    $script:Approved = $list -join ' '
    if ($script:Approved -eq '') {
        Write-LabStatus 'OK' $name
        Write-LabChoice
        Write-LabDetail 'Did' 'nothing approved, so nothing changed'
        return 1
    }
    return 0
}

# Write-LabChoice: under a module's status line, the items approved and
# those left alone because they changed since the plan.
function Write-LabChoice {
    $ids = @($script:Approved -split ' ' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(0, $_.LastIndexOf('@')) })
    if ($ids.Count -gt 0) { Write-LabDetail 'Approved' ($ids -join ', ') }
    foreach ($r in $script:Refused) { Write-LabDetail 'Found' "$r changed since the plan, so it is left alone" }
}

# Write-LabApproveUnmatched: after the plan, each -Approve entry that names
# no item of an approval module in this run's plan is ignored, with a line
# saying so.
function Write-LabApproveUnmatched {
    $said = $false
    foreach ($tok in (Get-LabApproveEntry)) {
        $colon = $tok.IndexOf(':')
        $mod = $tok.Substring(0, $colon)
        $want = $tok.Substring($colon + 1)
        $iid = $want.Substring(0, $want.LastIndexOf('@'))
        $found = @($script:Run | Where-Object {
                $_.Id -ceq $mod -and $_.Risk -eq 'approval' -and $_.Rc -eq 10 -and @($_.Items | Where-Object { $_.Id -ceq $iid }).Count -gt 0
            }).Count -gt 0
        if (-not $found) {
            if (-not $said) { Write-LabLine ''; $said = $true }
            Write-LabLine "Not in this run's plan, so ignored: $tok"
        }
    }
}

# Assert-LabApprove: each -Approve entry must be <module-id>:<item-id>@<fingerprint>.
function Assert-LabApprove {
    $fix = 'Copy each item from a plan: the module ID, a colon, then the item as its Item line shows it.'
    foreach ($tok in (Get-LabApproveEntry)) {
        if ($tok -like '*:category:*') { Exit-LabUsage "-Approve takes no categories, only items: '$tok'" 'apply' $fix }
        if ($tok -cnotmatch $ReApprove) { Exit-LabUsage "-Approve: not <module-id>:<item-id>@<fingerprint>: '$tok'" 'apply' $fix }
    }
}

function Invoke-LabApplyOne {
    param($M)
    $id = $M.Id
    $name = Get-LabModuleName $id
    $script:Approved = ''
    if ($M.Risk -eq 'manual-only') {
        Write-LabStatus 'WARN' $name
        Write-LabDetail 'Found' 'this needs a person; Labyrinth changed nothing'
        Write-LabDetail 'Fix' 'carry out the steps its plan listed above'
        Write-LabMore $id
        $M.State = 'manual'; return 0
    }
    if ($M.Scored) {
        try { $allow = Read-LabAddressList 'scoring-allowlist' }
        catch {
            Write-LabStatus 'ERROR' $name
            Write-LabDetail 'Problem' 'the scoring allowlist is malformed'
            foreach ($l in ($_.Exception.Message -split "`r?`n")) {
                if ($l.StartsWith("$($env:LAB_CONFIG_DIR)\")) { $l = $l.Substring($env:LAB_CONFIG_DIR.Length + 1) }
                if ($l -ne '') { Write-LabDetail 'Found' $l }
            }
            Write-LabDetail 'Fix' $FixLine
            Write-LabMore $id
            $M.State = 'error'; return 40
        }
        if ($null -eq $allow) {
            Write-LabStatus 'BLOCKED' $name
            Write-LabDetail 'Problem' 'it can affect a scored service, and the scoring allowlist is missing or empty'
            Write-LabDetail 'Fix' "list the scoring addresses in $(Join-Path $env:LAB_CONFIG_DIR 'scoring-allowlist')"
            Write-LabMore $id
            $M.State = 'blocked'; return 20
        }
        if (-not $script:HaveServices) {
            Write-LabStatus 'BLOCKED' $name
            Write-LabDetail 'Problem' 'it can affect a scored service, and there is no service list to test it with'
            Write-LabDetail 'Fix' "list the scored services in $(Join-Path $env:LAB_CONFIG_DIR 'services')"
            Write-LabMore $id
            $M.State = 'blocked'; return 20
        }
    }
    if (-not (Test-LabRequire $M)) { $M.State = 'blocked'; return 20 }
    if ($M.Risk -eq 'approval') {
        $rc = Select-LabItem $M
        if ($rc -eq 1) { $M.State = 'done'; return 0 }
        if ($rc -eq 20) { $M.State = 'blocked'; return 20 }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'apply.ps1') -PathType Leaf)) {
        Write-LabStatus 'OK' $name
        Write-LabDetail 'Found' 'it has no apply step; nothing changed'
        $M.State = 'done'; return 0
    }
    if ($M.Risk -ne 'read-only') {
        $exe = (Get-Process -Id $PID).Path
        $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} rollback {1} -Root {2} -Config {3}' -f `
            (ConvertTo-LabCommandLineArgument (Join-Path $env:LAB_ROOT 'labyrinth.ps1')), $env:LAB_RUN_ID,
            (ConvertTo-LabCommandLineArgument $script:DataRoot), (ConvertTo-LabCommandLineArgument $env:LAB_CONFIG_DIR)
        try {
            Register-LabRevertTimer -Seconds ($script:Settings['REVERT_MINUTES'] * 60) -RunId $env:LAB_RUN_ID -Execute $exe -Argument $arg
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Write-LabStatus 'BLOCKED' $name
            Write-LabDetail 'Problem' 'the revert timer could not be armed, so nothing was changed'
            Write-LabDetail 'Fix' 'check that Task Scheduler works on this host, then run the same command again'
            Write-LabMore $id
            $M.State = 'blocked'; return 20
        }
    }

    # A change the manifest does not list could never be rolled back.
    try {
        $note = "risk $($M.Risk)"
        if ($script:Approved -ne '') { $note += ", approved $($script:Approved)" }
        Add-LabEntryFor $id 'apply_start' '' $note
    } catch {
        Write-LabErrorLine $_.Exception.Message
        Write-LabStatus 'ERROR' $name
        Write-LabDetail 'Problem' 'not applied: the run manifest cannot be written'
        Write-LabDetail 'Fix' "check that $($env:LAB_STATE_DIR) can be written, then run the same command again"
        Write-LabLogPath; Write-LabMore $id
        $M.State = 'error'; return 40
    }
    Write-LabLogFor $id 'info' 'apply_start' 'applying'
    Write-LabStatus 'CHANGE' $name
    if ($script:Approved -ne '') { Write-LabChoice }
    $applyScript = Join-Path $M.Dir 'apply.ps1'
    Invoke-LabEntry $M.Dir 'apply' $id '0'
    $rc = $script:EntryRc
    if ($rc -eq 20) {
        Write-LabStatus 'BLOCKED' $name
        Write-LabFailed 'apply' 20 $applyScript
        Write-LabDetail 'Found' 'it stopped before changing anything'
        Write-LabDetail 'Fix' 'clear what blocked it, then run the same command again'
        Write-LabMore $id
        Add-LabEntryFor $id 'rolled_back' '' 'apply blocked before any change'
        $M.State = 'blocked'; return 20
    }
    if ($rc -ne 0) {
        Write-LabStatus 'ERROR' $name
        Write-LabFailed 'apply' $rc $applyScript
        $M.State = 'error'
        [void](Undo-LabModule $id -Inline)
        Write-LabLogPath; Write-LabMore $id
        return 40
    }

    $verifyScript = Join-Path $M.Dir 'verify.ps1'
    if (Test-Path -LiteralPath $verifyScript -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'verify' $id '0'
        $rc = $script:EntryRc
        if ($rc -ne 0) {
            Write-LabStatus 'FAIL' $name
            Write-LabFailed 'verify' $rc $verifyScript
            Write-LabLogFor $id 'error' 'verify_failed' "verify exited $rc"
            $M.State = 'failed'
            if ((Undo-LabModule $id -Inline) -ne 0) { $M.State = 'error' }
            Write-LabLogPath; Write-LabMore $id
            if ($rc -eq 30) { return 30 }
            return 40
        }
    }

    if ($script:HaveServices) {
        $after = Get-LabProbeNow
        $reg = @(Get-LabProbeRegression -Before $script:Before -After $after)
        if ($reg.Count -gt 0) {
            Write-LabStatus 'FAIL' $name
            Write-LabDetail 'Problem' "a scored service stopped working after the change: $($reg -join ', ')"
            Write-LabProbeLine $after $reg
            Write-LabLogFor $id 'error' 'regression' "scored service regressed: $($reg -join ' ')"
            $M.State = 'failed'
            if ((Undo-LabModule $id -Inline) -ne 0) { $M.State = 'error' }
            Write-LabLogPath; Write-LabMore $id
            return 30
        }
    }

    if (Test-Path -LiteralPath (Join-Path $M.Dir 'cleanup.ps1') -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'cleanup' $id '0'
        if ($script:EntryRc -ne 0) {
            Write-LabStatus 'WARN' $name
            Write-LabDetail 'Problem' "its cleanup script stopped with exit code $($script:EntryRc); the change is kept"
            Write-LabMore $id
        }
    }
    Write-LabStatus 'OK' $name
    Write-LabDetail 'Did' 'applied and verified'
    Write-LabLogFor $id 'info' 'applied' 'applied and verified'
    $M.State = 'done'
    return 0
}

function Read-LabSetting {
    try { $script:Settings = Read-LabEventConfig } catch { Exit-Lab "event.conf is malformed: $($_.Exception.Message)" 40 $FixLine }
}

# Assert-LabThisHost: the host checks for plan, apply and probe
# (docs\Conventions.md section 3.1). keep, rollback and runs skip them, so
# a stored revert-timer command still works after the configuration changes.
function Assert-LabThisHost {
    param([string] $Config)
    $fix = 'Give the folder with the hosts file, or leave out -Config to use <root>\etc.'
    if ($Config -ne '' -and (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Exit-Lab "the -Config path is a file, not a folder: $Config" 40 $fix
    }
    if ($Config -ne '' -and -not (Test-Path -LiteralPath $Config -PathType Container)) {
        Exit-Lab "the -Config folder does not exist: $Config" 40 $fix
    }
    $entry = Find-LabThisHost
    if ($null -eq $entry) { return }    # not listed: plan may still run
    $hostName = Get-LabHostName
    $hostsFile = Join-Path $env:LAB_CONFIG_DIR 'hosts'
    switch -CaseSensitive ($entry.Platform) {
        'windows' { }
        'appliance' { Exit-Lab "this host ($hostName) is an appliance: Labyrinth never changes it" 20 "Configure it by hand, from its runbook, or correct its line in $hostsFile" }
        default { Exit-Lab "this runner does not serve this host's platform, $($entry.Platform)" 20 "Use the runner for $($entry.Platform), or correct this host's line in $hostsFile" }
    }
}

function Find-LabThisHost {
    try { return Find-LabHost -Name (Get-LabHostName) } catch { Exit-Lab "the hosts file is malformed: $($_.Exception.Message)" 40 'Each line is: host group profile platform. Correct it, then retry.' }
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
    Write-LabPendingWarning
    Write-LabLine ('labyrinth {0}: plan {1}, profile {2}' -f $LabVersion, $Phase, $script:ProfileName)
    Write-LabLine "run $env:LAB_RUN_ID (plan mode: nothing is recorded)"
    Write-LabPlanIntro 'plan' $Phase $entry
    $worst = Invoke-LabPlanAll $Phase
    Exit-LabRun 'plan' $worst $Phase
}

# Write-LabPlanIntro MODE PHASE HOSTENTRY: after the two-line header, what
# happens next and how many modules are checked.
function Write-LabPlanIntro {
    param([string] $Mode, [string] $Phase, $HostEntry)
    $hostName = Get-LabHostName
    $n = @($script:ProfileIds | Where-Object { ($_ -split '\.', 2)[0] -ceq $Phase }).Count
    if ($Mode -ceq 'plan') {
        Write-LabLine "This is a plan: Labyrinth only looks, and nothing on $hostName changes."
        if ($null -ne $HostEntry) {
            Write-LabLine "Host $hostName is in group $($HostEntry.Group)."
        } else {
            Write-LabLine "Host $hostName is not in the hosts file; apply needs it there."
        }
    } else {
        Write-LabLine 'First Labyrinth plans; nothing changes until you confirm.'
    }
    if ($n -eq 1) {
        Write-LabLine "Checking 1 module of profile $($script:ProfileName)."
    } else {
        Write-LabLine "Checking $n modules of profile $($script:ProfileName), most urgent first."
    }
    Write-LabLine ''
}

# Write-LabRecap HOST GROUP: what apply is about to do, before the group-name
# prompt.
function Write-LabRecap {
    param([string] $HostName, [string] $Group)
    $remote = $false
    Write-LabLine ''
    Write-LabLine "About to apply on host $HostName, group ${Group}:"
    foreach ($m in $script:Run) {
        $what = ''
        if ($m.Rc -eq 10 -and $m.Risk -eq 'manual-only') { $what = 'Manual:' }
        elseif ($m.Rc -eq 10) { $what = 'Will change:'; if ($m.Risk -eq 'service-affecting') { $remote = $true } }
        elseif ($m.Rc -eq 20) { $what = 'Blocked:' }
        if ($what -ne '') { Write-LabLine ('  {0}{1}' -f $what.PadRight(13), (Get-LabModuleName $m.Id)) }
    }
    Write-LabLine "A revert timer undoes this whole run in $($script:Settings['REVERT_MINUTES']) minutes unless you keep it."
    if ($remote) {
        if ("$env:SSH_CONNECTION$env:SSH_CLIENT$env:SSH_TTY" -ne '') {
            Write-LabLine 'You are connected over SSH, and a change may interrupt a service.'
            Write-LabLine 'Keep a second session open until you have checked you can log in.'
        } elseif ($null -ne (Get-Variable -Name PSSenderInfo -ValueOnly -ErrorAction SilentlyContinue)) {
            Write-LabLine 'You are in a remote session, and a change may interrupt a service.'
            Write-LabLine 'Keep a second session open until you have checked you can log in.'
        }
    }
    Write-LabLine 'To go ahead, type the group name. Anything else stops here; nothing changes.'
}

function Invoke-LabApplyCommand {
    param([string] $Phase)
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    $hostName = Get-LabHostName
    if (-not (Test-LabAdmin)) { Exit-Lab 'apply needs an elevated Administrator session' 20 $FixAdmin }
    # Before any configuration under the root is trusted.
    try { Protect-LabDataRoot -Path $script:DataRoot } catch { Exit-Lab "$($_.Exception.Message); nothing was changed" 20 }
    Assert-LabTrustedTree
    $entry = Find-LabThisHost
    if ($null -eq $entry) { Exit-Lab 'this host is not in the hosts file, so its ring group is unknown' 20 "Add the line '$hostName <group> <profile> <platform>' to $(Join-Path $env:LAB_CONFIG_DIR 'hosts')" }
    $group = $entry.Group
    if ($group -eq 'manual') { Exit-Lab 'this host is in the manual group: Labyrinth never changes it' 20 'Configure it by hand, from its runbook.' }
    if ($script:ProfileName -ne '' -and $script:ProfileName -cne $entry.Profile) {
        Exit-Lab "the hosts file gives this host profile $($entry.Profile), not $($script:ProfileName)"
    }
    $script:ProfileName = $entry.Profile
    Read-LabProfile $script:ProfileName
    Read-LabSetting
    Assert-LabProtectedSet
    if (-not (Enter-LabLock -WaitSeconds 0)) { exit 20 }
    try {
        Write-LabPendingWarning
        # The run log keeps every line from here; it is written once the
        # run folder exists, after the group is confirmed.
        $script:LogOn = $true
        Write-LabLine ('labyrinth {0}: APPLY {1}, profile {2}' -f $LabVersion, $Phase, $script:ProfileName)
        Write-LabLine "run $env:LAB_RUN_ID on host $hostName, group $group"
        Write-LabPlanIntro 'apply' $Phase $entry
        $worst = Invoke-LabPlanAll $Phase
        if ($worst -ge 40) { Exit-Lab 'the plan has errors; nothing was changed' }
        if ($script:Given.ContainsKey('approve')) { Write-LabApproveUnmatched }
        $todo = @($script:Run | Where-Object { $_.Rc -eq 10 -and $_.Risk -ne 'manual-only' }).Count
        if ($todo -eq 0) {
            Write-LabLine ''
            Write-LabLine 'There is nothing to apply: no module needs a change Labyrinth can make.'
            Exit-LabRun 'apply' $worst $Phase
        }

        Assert-LabBreakGlass
        Write-LabRecap $hostName $group
        Assert-LabPlanConfirmed $group

        # From here on, changes are made: everything is recorded first.
        $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
        try {
            New-Item -ItemType Directory -Force -Path (Get-LabRunDir $env:LAB_RUN_ID), (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) | Out-Null
        } catch { Exit-Lab 'the run and backup folders cannot be created; nothing was changed' 20 }
        try {
            Add-LabEntryFor '' 'run_start' $hostName "phase $Phase, profile $($script:ProfileName), group $group"
            Add-LabEntryFor '' 'breakglass_verified' $script:BreakGlassAccount
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Exit-Lab 'the run manifest cannot be written; nothing was changed'
        }
        $script:RunOpen = $true
        $script:Applied = $true
        Open-LabRunLog "apply $Phase, run $env:LAB_RUN_ID, host $hostName"
        Write-LabLog -Level info -EventName run_start -Message "apply $Phase, profile $($script:ProfileName), group $group"
        $services = $null
        try { $services = Read-LabServiceList } catch { Exit-Lab "the service list is malformed; nothing was changed: $($_.Exception.Message)" }
        Write-LabLine ''
        if ($null -ne $services) {
            $script:HaveServices = $true
            $script:Before = Get-LabProbeNow
            [IO.File]::WriteAllText((Join-Path (Get-LabRunDir $env:LAB_RUN_ID) 'probes-before'), (($script:Before -join "`n") + "`n"))
            Write-LabLine 'Scored services before any change:'
            Write-LabProbeLine $script:Before
        } else {
            Write-LabLine "No scored service is tested: there is no list at $(Join-Path $env:LAB_CONFIG_DIR 'services')"
        }
        Write-LabLine ''

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

    $script:Stopped = $stopped
    Write-LabLine ''
    if ($stopped) {
        foreach ($l in (Get-LabRunStopped)) { Write-LabLine $l }
    } elseif (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) {
        Write-LabLine 'All changes are applied and verified.'
        Write-LabLine 'From a NEW session, check that you can still log in.'
        $when = Get-LabDueWord $env:LAB_RUN_ID
        if ($when -ne '') { Write-LabLine "The revert timer rolls this run back $when." }
        $ok = Read-LabAnswer "Type keep to keep the changes; anything else leaves the revert timer to undo them in $($script:Settings['REVERT_MINUTES']) minutes: "
        if ($ok -and $script:Answer -ceq 'keep') {
            $rc = Invoke-LabKeep
            if ($rc -gt $worst) { $worst = $rc }
        } else {
            $short = $env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)
            Write-LabLine "Not kept. To keep later: $Self keep $short"
            Write-LabLine "To undo now: $Self rollback $short"
        }
    }
    Exit-LabRun 'apply' $worst $Phase
}

# Has the current run already been rolled back as a whole?
function Test-LabRunRolledBack {
    return (@(Get-LabManifestEntry | Where-Object { $_.action -ceq 'run_rolled_back' }).Count -gt 0)
}

# Cancel the current run's revert timer and record it; returns 0, 20 or 40.
function Invoke-LabKeep {
    if (-not (Enter-LabLock -WaitSeconds 10)) { return 20 }
    try {
        if (Test-LabRunRolledBack) {
            Write-LabLine "too late: run $env:LAB_RUN_ID was already rolled back"
            return 20
        }
        try {
            Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        } catch {
            Write-LabErrorLine $_.Exception.Message
            $when = Get-LabDueWord $env:LAB_RUN_ID
            if ($when -ne '') { $when = " $when" }
            Write-LabErrorLine "labyrinth: the revert timer for run $env:LAB_RUN_ID could not be cancelled"
            Write-LabErrorLine "The run is not kept, and the timer still rolls it back$when."
            Write-LabErrorLine "Retry: $Self keep $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4))"
            return 40
        }
        try {
            Add-LabEntryFor '' 'run_kept'
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Write-LabErrorLine "labyrinth: the keep of run $env:LAB_RUN_ID could not be recorded"
            Write-LabErrorLine 'Its revert timer is cancelled, so the changes stay.'
            return 40
        }
        Write-LabLog -Level info -EventName run_kept -Message 'changes kept; revert timer cancelled'
        Write-LabLine "kept: the revert timer for run $env:LAB_RUN_ID is cancelled"
        return 0
    } finally {
        Exit-LabLock
    }
}

# Get-LabRunList: this host's run IDs, oldest first; only runs with a
# manifest, because a plan writes nothing.
function Get-LabRunList {
    $dir = Join-Path $env:LAB_STATE_DIR 'runs'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object {
            $_.Name -cmatch $ReRunId -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.jsonl') -PathType Leaf)
        } | Sort-Object Name | ForEach-Object { $_.Name })
}

# Get-LabRunState RUN: the run's state, the first that applies: rolled
# back, kept, armed (with when the timer fires), or not kept, no timer.
function Get-LabRunState {
    param([string] $RunId)
    $entries = @(Get-LabManifestEntry -RunId $RunId)
    $rolled = @($entries | Where-Object { $_.action -ceq 'run_rolled_back' })
    if ($rolled.Count -gt 0) {
        if ($rolled[-1].note -ceq 'exit 0') { return 'rolled back' }
        return 'rolled back with errors'
    }
    if (@($entries | Where-Object { $_.action -ceq 'run_kept' }).Count -gt 0) { return 'kept' }
    if (Test-LabRevertTimer -RunId $RunId) {
        $due = Get-LabRevertTimerDue -RunId $RunId
        if ($due -eq '') { return 'armed: rollback time unknown' }
        # The times are UTC in one fixed format, so they compare as strings.
        $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        if ([string]::CompareOrdinal($due, $now) -gt 0) { return "armed: rolls back at $($due.Substring(11, 5)) UTC" }
        return "armed: was due $($due.Substring(11, 5)) UTC"
    }
    return 'not kept, no timer'
}

# Get-LabRunPhase RUN: the phase the run applied, from its run_start entry.
function Get-LabRunPhase {
    param([string] $RunId)
    $start = @(Get-LabManifestEntry -RunId $RunId | Where-Object { $_.action -ceq 'run_start' })
    if ($start.Count -eq 0 -or $start[0].note -cnotmatch '^phase ([^,]+)') { return '-' }
    return $Matches[1]
}

# Get-LabRunTable RUN...: the runs table, at most 78 columns.
function Get-LabRunTable {
    param([string[]] $RunIds)
    $f = '{0,-21} {1,-7} {2,-16} {3}'
    $f -f 'RUN', 'PHASE', 'START (UTC)', 'STATE'
    foreach ($id in $RunIds) {
        $start = '{0}-{1}-{2} {3}:{4}' -f $id.Substring(0, 4), $id.Substring(4, 2), $id.Substring(6, 2), $id.Substring(9, 2), $id.Substring(11, 2)
        $f -f $id, (Get-LabRunPhase $id), $start, (Get-LabRunState $id)
    }
}

# Get-LabArmedRun: the runs whose revert timer is armed and not yet kept
# or rolled back.
function Get-LabArmedRun {
    return @(Get-LabRunList | Where-Object { (Get-LabRunState $_) -like 'armed*' })
}

function Invoke-LabRunsCommand {
    if (-not (Test-LabAdmin)) { Exit-Lab 'runs needs an elevated Administrator session' 20 $FixAdmin }
    $runs = @(Get-LabRunList)
    Write-LabPendingWarning
    if ($runs.Count -eq 0) {
        Write-LabLine 'no runs on this host'
        Write-LabLine "Runs are recorded in $(Join-Path $env:LAB_STATE_DIR 'runs')"
        exit 0
    }
    foreach ($l in (Get-LabRunTable $runs)) { Write-LabLine $l }
    # The example names the newest armed run, the one most likely to be kept.
    $example = $runs[-1]
    $armed = @(Get-LabArmedRun)
    if ($armed.Count -gt 0) { $example = $armed[-1] }
    Write-LabLine ''
    Write-LabLine "Name a run by its last 4 characters, like '$Self keep $($example.Substring($example.Length - 4))'."
    $problems = @($runs | Where-Object { Test-Path -LiteralPath (Join-Path (Get-LabRunDir $_) 'problems') -PathType Leaf })
    if ($problems.Count -gt 0) {
        Write-LabLine ''
        Write-LabLine 'These runs had problems; their logs say what happened:'
        foreach ($id in $problems) {
            Write-LabLine ('  {0}  {1}' -f $id.Substring($id.Length - 4), (Join-Path (Get-LabRunDir $id) 'output.log'))
        }
    }
    exit 0
}

# Resolve-LabRunId COMMAND REF: the full run ID REF names. REF is a full
# ID, or its last 4 characters if they match exactly one run.
function Resolve-LabRunId {
    param([string] $Command, [string] $Ref)
    if ($Ref -cmatch $ReRunId) {
        $manifest = Join-Path (Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $Ref) 'manifest.jsonl'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Exit-LabUsage "no run $Ref on this host" $Command "'$Self runs' lists them." }
        return $Ref
    }
    $suffix = $Ref.ToLowerInvariant()
    $hits = @(Get-LabRunList | Where-Object { $_.EndsWith("-$suffix", [StringComparison]::Ordinal) })
    if ($hits.Count -eq 0) { Exit-LabUsage "no run ending in '$Ref' on this host" $Command "'$Self runs' lists them." }
    if ($hits.Count -gt 1) { Exit-LabUsage "'$Ref' ends more than one run; give the full ID" $Command "'$Self runs' lists them." }
    Write-LabLine "using run $($hits[0])"
    return $hits[0]
}

function Invoke-LabKeepCommand {
    param([string] $Ref)
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if (-not (Test-LabAdmin)) { Exit-Lab 'keep needs an elevated Administrator session' 20 $FixAdmin }
    Assert-LabTrustedTree
    if ($Ref -eq '') {
        # Without a run, keep the one run whose timer is armed (section 3.1).
        $armed = @(Get-LabArmedRun)
        if ($armed.Count -eq 0) { Exit-LabUsage 'no run on this host has an armed revert timer' 'keep' 'There is nothing to keep.' }
        if ($armed.Count -gt 1) {
            foreach ($l in (Get-LabRunTable $armed)) { [Console]::Error.WriteLine($l) }
            Exit-LabUsage 'more than one run has an armed revert timer' 'keep' "Name one, like '$Self keep $($armed[0].Substring($armed[0].Length - 4))'."
        }
        $env:LAB_RUN_ID = $armed[0]
        Write-LabLine "using run $($armed[0])"
    } else {
        $env:LAB_RUN_ID = Resolve-LabRunId 'keep' $Ref
    }
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    Write-LabPendingWarning
    Open-LabRunLog "keep run $env:LAB_RUN_ID"
    $rc = Invoke-LabKeep
    if ($script:LogFile -ne '') { Write-LabLine "Log: $($script:LogFile)" }
    exit $rc
}

function Invoke-LabRollbackCommand {
    param([string] $Ref)
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if ($Ref -eq '') {
        # Rollback always needs a run (decision D3): list them, change nothing.
        $need = 'rollback needs a run ID, or its last 4 characters'
        if (-not (Test-LabAdmin)) { Exit-LabUsage $need 'rollback' "As Administrator, '$Self runs' lists them." }
        $runs = @(Get-LabRunList)
        if ($runs.Count -eq 0) { Exit-LabUsage $need 'rollback' 'There are no runs on this host.' }
        foreach ($l in (Get-LabRunTable $runs)) { [Console]::Error.WriteLine($l) }
        Exit-LabUsage $need 'rollback' 'Pick one from the list above.'
    }
    if (-not (Test-LabAdmin)) { Exit-Lab 'rollback needs an elevated Administrator session' 20 $FixAdmin }
    Assert-LabTrustedTree
    $env:LAB_RUN_ID = Resolve-LabRunId 'rollback' $Ref
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    Write-LabPendingWarning
    # The revert timer must work even if a run still holds the lock, hung or
    # waiting at a prompt. That run is stopped first: rolling back beside it
    # would undo changes while it goes on making them and reports success.
    $locked = Enter-LabLock -WaitSeconds 10
    if (-not $locked) {
        [void](Stop-LabLockHolder -WaitSeconds 30)
        $locked = Enter-LabLock -WaitSeconds 10
    }
    if (-not $locked) { [Console]::Error.WriteLine('warning: rolling back without the run lock') }
    try {
        $rc = 0
        $ok = 0
        $bad = 0
        $mods = @(Get-LabAppliedModule -RunId $env:LAB_RUN_ID)
        # A rollback started by the revert timer is logged too, though no
        # one watches it.
        Open-LabRunLog "rollback run $env:LAB_RUN_ID"
        Write-LabLine "labyrinth ${LabVersion}: rollback run $env:LAB_RUN_ID"
        if ($mods.Count -eq 0) { Write-LabLine 'This run changed nothing that needs undoing.' }
        elseif ($mods.Count -eq 1) { Write-LabLine 'Undoing 1 module.' }
        else { Write-LabLine "Undoing $($mods.Count) modules, newest change first." }
        Write-LabLine ''
        for ($i = $mods.Count - 1; $i -ge 0; $i--) {
            $id = $mods[$i]
            if ($id -cnotmatch $ReModuleId) {
                Write-LabStatus 'ERROR' 'Run manifest'
                Write-LabDetail 'Problem' "it lists a bad module ID, which was skipped: $id"
                $bad++; $rc = 40; continue
            }
            Import-LabModuleTitle $id
            if ((Undo-LabModule $id) -eq 0) { $ok++ } else { $bad++; $rc = 40 }
        }
        # A timer left armed runs this rollback again, which is safe.
        try {
            Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Write-LabErrorLine "warning: the revert timer for run $env:LAB_RUN_ID could not be removed"
            Write-LabErrorLine 'When it fires, it repeats this rollback, which is safe.'
        }
        try {
            Add-LabEntryFor '' 'run_rolled_back' '' "exit $rc"
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Write-LabErrorLine 'labyrinth: rolled back, but the manifest cannot be written to record it'
            $rc = 40
        }
        Write-LabLogFor '' 'warn' 'run_rolled_back' "run rolled back, exit $rc"
        Write-LabLine ''
        $parts = @()
        if ($ok -gt 0) { $parts += "$ok OK" }
        if ($bad -gt 0) { $parts += "$bad ERROR" }
        if ($ok + $bad -eq 0) { Write-LabLine 'Summary: no changes to undo.' }
        elseif ($ok + $bad -eq 1) { Write-LabLine "Summary: 1 module: $($parts -join ', ')." }
        else { Write-LabLine "Summary: $($ok + $bad) modules: $($parts -join ', ')." }
        if ($script:LogFile -ne '') { Write-LabLine "Log: $($script:LogFile)" }
        if ($rc -eq 0) {
            Write-LabLine 'rollback finished: exit 0 (rolled back)'
        } else {
            Add-LabProblemMark
            Write-LabLine 'Next: fix what is listed above, then run the rollback again; it is safe:'
            Write-LabLine "  $Self rollback $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4))"
            Write-LabLine "rollback finished: exit $rc (error)"
        }
    } finally {
        if ($locked) { Exit-LabLock }
    }
    exit $rc
}

function Invoke-LabProbeCommand {
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    Read-LabSetting
    $out = $null
    try { $out = Get-LabProbeResult -Timeout $script:Settings['PROBE_TIMEOUT'] } catch { Exit-Lab "the service list is malformed: $($_.Exception.Message)" 40 $FixLine }
    if ($null -eq $out) { Exit-Lab "no service list at $(Join-Path $env:LAB_CONFIG_DIR 'services')" 20 'List the scored services there, one "name proto host port expect" per line.' }
    Write-LabPendingWarning
    Write-LabProbeReport @($out)
}

# Write-LabProbeReport LINES: the probe's lines as status lines, then the
# Summary, Next and finished lines; exit 30 when a service failed.
function Write-LabProbeReport {
    param([string[]] $Lines)
    $n = @{ OK = 0; WARN = 0; FAIL = 0 }
    Write-LabLine "labyrinth ${LabVersion}: probe the scored services"
    foreach ($l in $Lines) {
        if ($l -eq '') { continue }
        $f = $l -split ' ', 3
        $w = 'WARN'
        if ($f[1] -ceq 'pass') { $w = 'OK' } elseif ($f[1] -ceq 'fail') { $w = 'FAIL' }
        $n[$w]++
        $text = "[$($f[0])] $($f[1])"
        if ($f.Count -gt 2 -and $f[2] -ne '') { $text += ": $($f[2])" }
        Write-LabStatus $w $text
    }
    $parts = @()
    foreach ($w in @('OK', 'WARN', 'FAIL')) { if ($n[$w] -gt 0) { $parts += "$($n[$w]) $w" } }
    $text = 'no services'
    if ($parts.Count -gt 0) { $text = $parts -join ', ' }
    Write-LabLine "Summary: $text"
    if ($n['FAIL'] -eq 1) {
        Write-LabLine "Next: bring the failed service back, then run '$Self probe' again."
        Write-LabLine 'probe finished: exit 30 (a service failed)'
        exit 30
    }
    if ($n['FAIL'] -gt 1) {
        Write-LabLine "Next: bring the failed services back, then run '$Self probe' again."
        Write-LabLine "probe finished: exit 30 ($($n['FAIL']) services failed)"
        exit 30
    }
    Write-LabLine 'probe finished: exit 0 (no service failed)'
    exit 0
}

try {
    Read-LabArgument $script:Arguments
    $words = $script:Words
    if ($script:ParseError -ne '') {
        # Point to the help of the command the line names, if it names one.
        $topic = ''
        if ($words.Count -gt 0) { $topic = $words[0].ToLowerInvariant() }
        if ($Phases -ccontains $topic) {
            if ($script:Given.ContainsKey('apply')) { $topic = 'apply' } else { $topic = 'plan' }
        } elseif ($Commands -cnotcontains $topic -or $topic -ceq 'help' -or $topic -ceq 'version') {
            $topic = ''
        }
        Exit-LabUsage $script:ParseError $topic
    }
    $cmd = ''
    $first = ''
    $rest = @()

    # Work out the command; the whole line must parse before help is shown.
    if ($words.Count -gt 0) {
        $first = $words[0].ToLowerInvariant()
        if ($Commands -ccontains $first) {
            $cmd = $first
            $rest = @($words | Select-Object -Skip 1)
        } elseif ($Phases -ccontains $first) {
            $cmd = 'plan'                     # compatibility: a phase alone
            $rest = @($words)
        } else {
            $hint = Get-LabSuggestion $first ($Commands + $Phases)
            if ($words[0] -ceq '/?') { $hint = 'help' }
            if ($hint -ne '') { Exit-LabUsage "unknown command '$($words[0])' (did you mean '$hint'?)" }
            Exit-LabUsage "unknown command '$($words[0])'"
        }
    }
    if ($script:Given.ContainsKey('apply')) {
        switch ($cmd) {
            'plan' {
                if ($first -ceq 'plan') { Exit-LabUsage "plan and -Apply conflict; use '$Self apply <phase>'" 'apply' }
                $cmd = 'apply'
            }
            'apply' { }
            '' { Exit-LabUsage '-Apply needs a phase' 'apply' }
            default { Exit-LabUsage "-Apply cannot be used with $cmd" $cmd }
        }
    }
    # The whole line must parse before help or the version is shown.
    $helping = $script:Given.ContainsKey('help') -or $script:Given.ContainsKey('version')
    $used = @()
    $phase = ''
    $run = ''
    switch ($cmd) {
        '' {
            if ($script:Given.ContainsKey('help')) { Show-LabHelp ''; exit 0 }
            if ($script:Given.ContainsKey('version')) { Write-LabLine "labyrinth $LabVersion"; exit 0 }
            [Console]::Error.WriteLine('labyrinth: no command given')
            [Console]::Error.WriteLine('Start here:')
            [Console]::Error.WriteLine("  1. $Self help basics    what Labyrinth does, in plain words")
            [Console]::Error.WriteLine("  2. $Self plan lockout   what the first phase would change; safe")
            [Console]::Error.WriteLine("  3. $Self help           every command")
            [Console]::Error.WriteLine("Usage: $Self <command> [<phase> | <run>] [options]")
            exit 40
        }
        'help' {
            if ($rest.Count -gt 1) {
                $topic = $rest[0].ToLowerInvariant()
                if ($Commands -cnotcontains $topic) { $topic = 'help' }
                Exit-LabUsage "unexpected word '$($rest[1])' after 'help $($rest[0])'" $topic
            }
            $topic = ''
            if ($rest.Count -eq 1) { $topic = $rest[0].ToLowerInvariant() }
            if ($topic -ceq 'basics') { Show-LabHelp 'basics'; exit 0 }
            if ($topic.Contains('.')) { Show-LabModuleHelp $topic; exit 0 }
            if ($topic -ne '' -and $Commands -cnotcontains $topic) {
                $hint = Get-LabSuggestion $topic (@('basics') + $Commands)
                if ($hint -ne '') { Exit-LabUsage "no help for '$($rest[0])' (did you mean '$hint'?)" }
                Exit-LabUsage "no help for '$($rest[0])'"
            }
            # 'help plan -Help' is help on plan; 'help -Help' is help on help.
            if ($topic -eq '' -and $script:Given.ContainsKey('help')) { $topic = 'help' }
            Show-LabHelp $topic
            exit 0
        }
        'version' {
            if ($rest.Count -gt 0) { Exit-LabUsage "unexpected word '$($rest[0])' after 'version'" 'version' }
        }
        { $_ -ceq 'plan' -or $_ -ceq 'apply' } {
            if ($rest.Count -eq 0) {
                if (-not $helping) { Exit-LabUsage "$cmd needs a phase: lockout, observe, deceive or sustain" $cmd }
            } else {
                $phase = $rest[0].ToLowerInvariant()
                if ($phase -ceq 'probe') { Exit-LabUsage "probe is a command, not a phase: run '$Self probe'" 'probe' }
                if ($Phases -cnotcontains $phase) {
                    $hint = Get-LabSuggestion $phase $Phases
                    if ($hint -ne '') { Exit-LabUsage "unknown phase '$($rest[0])' (did you mean '$hint'?)" $cmd }
                    Exit-LabUsage "unknown phase '$($rest[0])'" $cmd
                }
                if ($rest.Count -gt 1) { Exit-LabUsage "unexpected word '$($rest[1])' after '$cmd $phase'" $cmd }
            }
            if ($cmd -ceq 'plan') { $used = @('profile') } else { $used = @('profile', 'break-glass', 'confirm-group', 'approve') }
        }
        { $_ -ceq 'keep' -or $_ -ceq 'rollback' } {
            # Without a run, keep and rollback decide what to do (section 3.1).
            if ($rest.Count -gt 1) { Exit-LabUsage "unexpected word '$($rest[1])' after '$cmd $($rest[0])'" $cmd }
            if ($rest.Count -eq 1) { $run = $rest[0] }
            # A full run ID is accepted in any case, like its last 4 characters.
            if ($run -match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$') {
                $low = $run.ToLowerInvariant()
                $run = $low.Substring(0, 8) + 'T' + $low.Substring(9, 6) + 'Z' + $low.Substring(16)
            }
            if ($run -ne '' -and $run -cnotmatch $ReRunId -and $run -notmatch '^[0-9a-fA-F]{4}$') {
                Exit-LabUsage "not a run ID: '$run' (give the ID or its last 4 characters)" $cmd
            }
        }
        { $_ -ceq 'runs' -or $_ -ceq 'probe' } {
            if ($rest.Count -gt 0) { Exit-LabUsage "unexpected word '$($rest[0])' after '$cmd'" $cmd }
        }
    }
    if ($script:Given.ContainsKey('help')) { Show-LabHelp $cmd; exit 0 }
    if ($script:Given.ContainsKey('version') -or $cmd -ceq 'version') { Write-LabLine "labyrinth $LabVersion"; exit 0 }

    $profileName = ''
    if ($script:Given.ContainsKey('profile')) { $profileName = $script:Given['profile'] }
    $script:DataRoot = 'C:\ProgramData\Labyrinth'
    if ($script:Given.ContainsKey('root')) { $script:DataRoot = $script:Given['root'] }
    $config = ''
    if ($script:Given.ContainsKey('config')) { $config = $script:Given['config'] }
    if ($script:Given.ContainsKey('break-glass')) { $script:GivenBreakGlass = $script:Given['break-glass'] }
    if ($script:Given.ContainsKey('confirm-group')) { $script:GivenGroup = $script:Given['confirm-group'] }
    if ($profileName -ne '' -and $profileName -cnotmatch '^[a-z0-9-]+$') {
        Exit-LabUsage "invalid profile name '$profileName' (lower-case letters, digits and -)" $cmd
    }
    # Windows takes / as well as \ in a path, so C:/x is accepted as C:\x.
    $script:DataRoot = $script:DataRoot.Replace('/', '\')
    $config = $config.Replace('/', '\')
    if ($script:DataRoot -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-LabUsage "-Root must be a full path, not '$($script:DataRoot)'" $cmd }
    if ($config -ne '' -and $config -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-LabUsage "-Config must be a full path, not '$config'" $cmd }
    if ($cmd -ceq 'apply' -and $script:Given.ContainsKey('approve')) { Assert-LabApprove }
    # Noted now, printed by each command once its own checks pass.
    Test-LabOptionUse $cmd $used
    $script:ProfileName = $profileName
    $script:DryRun = '1'

    $env:LAB_ROOT = $PSScriptRoot
    if ($config -ne '') { $env:LAB_CONFIG_DIR = $config } else { $env:LAB_CONFIG_DIR = Join-Path $script:DataRoot 'etc' }
    $env:LAB_STATE_DIR = Join-Path $script:DataRoot 'state'
    $env:LAB_LOG_DIR = Join-Path $script:DataRoot 'logs'
    $env:LAB_BACKUP_DIR = Join-Path $script:DataRoot 'backup'
    $env:LAB_RUN_ID = Get-LabRunId
    . (Join-Path $PSScriptRoot 'core\Lab.ps1')

    $script:Command = $cmd
    if ($cmd -in 'plan', 'apply', 'probe') { Assert-LabThisHost $config }
    switch ($cmd) {
        'plan' { Invoke-LabPlanCommand $phase }
        'apply' { Invoke-LabApplyCommand $phase }
        'keep' { Invoke-LabKeepCommand $run }
        'rollback' { Invoke-LabRollbackCommand $run }
        'probe' { Invoke-LabProbeCommand }
        'runs' { Invoke-LabRunsCommand }
    }
} catch {
    # An unexpected failure (docs/Conventions.md section 4): say what is
    # known about the run instead of only the exception.
    [Console]::Error.WriteLine("labyrinth: internal error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)")
    try {
        foreach ($l in (Get-LabRecovery)) { [Console]::Error.WriteLine($l) }
    } catch {
        [Console]::Error.WriteLine('The state of the run is unknown; check it with runs.')
    }
    exit 40
}
