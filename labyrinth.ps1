<#
.SYNOPSIS
    Labyrinth: plan, apply, keep and roll back hardening runs on a Windows
    host (design 00, section 5; docs/Conventions.md sections 3.1 and 3.2).

.DESCRIPTION
    labyrinth.ps1 plan <phase>        show what would change; changes nothing
    labyrinth.ps1 apply <phase>       plan, confirm, then make the changes
    labyrinth.ps1 keep [<run>]        keep a run: cancel its revert timer
    labyrinth.ps1 rollback <run>      undo a run, newest change first
    labyrinth.ps1 runs                list this host's runs and their state
    labyrinth.ps1 probe               test every scored service once
    labyrinth.ps1 help [<command>]    help; also -Help, -h and -?
    labyrinth.ps1 version             the version; also -Version and -V

    Options may come anywhere; 'labyrinth.ps1 help' lists them. Exit codes
    (design 00, section 4); the highest code from any module wins:
    0 nothing to do or success, 10 change needed, 20 blocked,
    30 verify failed or a scored service regressed, 40 error.

    The words are parsed by the same rules as labyrinth.sh, so there is no
    param block: every word arrives in $args.

.EXAMPLE
    .\labyrinth.ps1 plan lockout
#>

#Requires -Version 5.1

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
    @{ Name = 'apply'; Show = '-Apply'; Keys = @('apply'); Value = $false }
    @{ Name = 'help'; Show = '-Help'; Keys = @('help'); Value = $false }
    @{ Name = 'version'; Show = '-Version'; Keys = @('version'); Value = $false }
)
$script:Arguments = @($args)     # the words, before any function runs
$script:Given = @{}              # canonical option name -> value given
$script:Words = @()              # the words that are not options, in order

$script:Mod = @{}
$script:ProfileIds = @()
$script:PendingWarnings = @()
$script:EntryRc = 0
$script:Approved = ''
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

  plan <phase>      show what would change; changes nothing
  apply <phase>     plan, confirm, then make the changes
  keep [<run>]      keep a run: cancel its revert timer
  rollback <run>    undo a run, newest change first
  runs              list this host's runs and their state
  probe             test every scored service once
  help [<command>]  help for one command
  version           print the version

Phases: lockout, observe, deceive, sustain. <run>: an ID or its last 4.
Options: -Root DIR, -Config DIR, -Profile NAME, -Help, -V; see each command.
Exit: 0 ok, 10 change needed, 20 blocked, 30 check failed, 40 error.
Example: $Self plan lockout
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
Apply only:
  -BreakGlass NAME       answer the break-glass prompt
  -ConfirmGroup GROUP    answer the group-name prompt

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
Usage: $Self help [<command>]

Print help for every command, or for one. '$Self <command> -Help'
and '$Self <command> -h' print the same.

Exit: 0 printed, 40 unknown command.
Example: $Self help apply
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

# Exit-LabUsage MESSAGE [COMMAND]: a usage error: one line, a pointer to
# help, exit 40 (docs/Conventions.md section 3.1).
function Exit-LabUsage {
    param([string] $Message, [string] $Command = '')
    $topic = ''
    if ($Command -ne '') { $topic = " $Command" }
    [Console]::Error.WriteLine("labyrinth: $Message")
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
        elseif ($w -ceq '-v') { Exit-LabUsage "unknown option '-v' (did you mean '-V', the version?)" }
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
                Exit-LabUsage "unknown option '$shown' (did you mean '$($h.Show)'?)"
            }
            Exit-LabUsage "unknown option '$shown'"
        }
        if ($o.Value) {
            # '-Name value', or a session's '-Name:' with the value as the next word.
            if ($sep -eq '' -or ($sep -eq ':' -and $val -eq '')) {
                if ($i -ge $Arguments.Count) { Exit-LabUsage "$($o.Show) needs a value" }
                $next = $Arguments[$i]
                if ($next -is [string] -and $next -like '-?*') { Exit-LabUsage "$($o.Show) needs a value, but got '$next'" }
                $val = [string] $next; $i++
            }
            if ($val -eq '') { Exit-LabUsage "$($o.Show) needs a value" }
        } elseif ($sep -ne '') {
            Exit-LabUsage "$($o.Show) takes no value"
        }
        if ($script:Given.ContainsKey($o.Name)) { Exit-LabUsage "$($o.Show) is given twice" }
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
    foreach ($name in @('profile', 'break-glass', 'confirm-group')) {
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

function Write-LabLine {
    param([AllowEmptyString()] [string] $Text = '')
    [Console]::Out.WriteLine($Text)
}

function Exit-Lab {
    param([string] $Message, [int] $Code = 40)
    [Console]::Error.WriteLine("labyrinth: $Message")
    exit $Code
}

# Write-LabStatus WORD TEXT: a result line, the status word padded to 9
# characters (docs/Conventions.md section 3.2).
function Write-LabStatus {
    param([string] $Word, [string] $Text)
    [Console]::Out.WriteLine($Word.PadRight(9) + $Text)
}

# Write-LabIndented LINE...: lines of module output, each indented 11 spaces.
function Write-LabIndented {
    param([AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line = @())
    foreach ($text in $Line) {
        foreach ($l in ($text -split "`r?`n")) { [Console]::Out.WriteLine((' ' * 11) + $l) }
    }
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
    $text = 'no modules'
    if ($parts.Count -gt 0) { $text = $parts -join ', ' }
    Write-LabLine "Summary: $text"
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
        Write-LabLine "Next: from a NEW session, check you can log in, then '$Self keep $short'."
    } elseif ($Code -eq 40) {
        Write-LabLine 'Next: fix the error above, then run the same command again.'
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
            Write-LabLine "Next: $Self apply $Phase$opts"
        }
    }
}

# Exit-LabRun MODE CODE PHASE: the end of a plan or apply: Summary, Next
# and the exit code with its meaning; then exit with CODE.
function Exit-LabRun {
    param([string] $Mode, [int] $Code, [string] $Phase)
    $what = 'error'
    if ($Mode -ceq 'plan' -and $Code -eq 0) { $what = 'nothing to do' }
    elseif ($Mode -ceq 'plan' -and $Code -eq 10) { $what = 'change needed' }
    elseif ($Mode -ceq 'apply' -and $Code -eq 0) { $what = 'done' }
    elseif ($Mode -ceq 'apply' -and $Code -eq 10) { $what = 'manual steps needed' }
    elseif ($Code -eq 20) { $what = 'blocked' }
    elseif ($Code -eq 30) { $what = 'a check failed, and that change was undone' }
    if ($Mode -ceq 'plan' -or -not $script:Applied) { Write-LabSummary 'plan' } else { Write-LabSummary 'apply' }
    Write-LabNextStep $Mode $Code $Phase
    Write-LabLine "$Mode finished: exit $Code ($what)"
    exit $Code
}

# Get-LabRunStopped: what the operator needs after a run stops partway.
function Get-LabRunStopped {
    'The run stopped. Earlier changes stay until the revert timer undoes them.'
    $due = Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID
    if ($due -ne '') { "The revert timer rolls this run back at $($due.Substring(11, 5)) UTC." }
    $short = $env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)
    "To keep them now: $Self keep $short"
    "To undo them now: $Self rollback $short"
}

# Get-LabRecovery: after an internal error, what changed and what to do next.
function Get-LabRecovery {
    if ($script:RunOpen) {
        if (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) { return Get-LabRunStopped }
        return "The run stopped. Its manifest lists what it did; '$Self rollback $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4))' undoes it."
    }
    $short = ''
    if ($script:RunRef -ne '') { $short = $script:RunRef.Substring($script:RunRef.Length - 4) }
    switch ($script:Command) {
        'rollback' {
            if ($short -ne '') { return "The rollback did not finish. Run '$Self rollback $short' again; it is safe to repeat." }
            return 'Nothing was rolled back.'
        }
        'keep' {
            if ($short -ne '') { return "The run may not be kept. Check with '$Self runs', then run '$Self keep $short' again." }
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
    param([string] $Dir, [string] $Entry, [string] $Id, [string] $DryRun = '1', [switch] $Capture)
    $env:LAB_MODULE_ID = $Id
    $env:LAB_ENTRY = $Entry
    $env:LAB_DRY_RUN = $DryRun
    $env:LAB_APPROVED = $script:Approved
    $hostExe = (Get-Process -Id $PID).Path
    $script:EntryRc = 0
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Both streams, indented under the module's result line (section
        # 3.2). Piped, so the output never becomes the return value of the
        # function that called this one. With -Capture, the output is kept
        # in EntryOut, because the result line above it is known only later.
        $file = Join-Path $Dir "$Entry.ps1"
        if ($Capture) {
            $script:EntryOut = @(& $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 |
                    ForEach-Object { ConvertTo-LabOutputText $_ })
        } else {
            & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 |
                ForEach-Object { Write-LabIndented (ConvertTo-LabOutputText $_) }
        }
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
    $script:LoadErrors = 0
    $script:LoadSkipped = 0
    foreach ($id in $script:ProfileIds) {
        if (($id -split '\.', 2)[0] -cne $Phase) { continue }
        $script:PhaseCount++
        $name = ($id -split '\.', 2)[1]
        $dir = Join-Path (Join-Path (Join-Path (Join-Path $env:LAB_ROOT 'phases') $Phase) 'modules') $name
        $yml = Join-Path $dir 'module.yml'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            Write-LabStatus 'ERROR' "[$id] error: module not found"
            Write-LabIndented "looked in: $dir"
            $script:LoadErrors++; $worst = 40; continue
        }
        $script:YmlErr = @()
        if (-not (Read-LabModuleYml $yml) -or -not (Test-LabModule $yml $id $Phase)) {
            Write-LabStatus 'ERROR' "[$id] error: invalid module.yml"
            Write-LabIndented $script:YmlErr
            $script:LoadErrors++; $worst = 40; continue
        }
        if (@(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File).Count -eq 0) {
            Write-LabStatus 'WARN' "[$id] skipped: no Windows entry points"
            $script:LoadSkipped++; continue
        }
        $needed = @('check')
        if (@('reversible', 'service-affecting', 'approval') -ccontains $script:Mod['risk']) { $needed = @('check', 'apply', 'verify', 'rollback') }
        $missing = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir "$_.ps1") -PathType Leaf) })
        if ($missing.Count -gt 0) {
            Write-LabStatus 'ERROR' "[$id] error: missing $($missing[0]).ps1 (needed for risk $($script:Mod['risk']))"
            $script:LoadErrors++; $worst = 40; continue
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
    Invoke-LabEntry $M.Dir 'check' $id -Capture
    switch ($script:EntryRc) {
        0 { Write-LabStatus 'OK' "[$id] check: nothing to do"; Write-LabIndented $script:EntryOut; $M.Rc = 0; return }
        10 { }
        20 { Write-LabStatus 'BLOCKED' "[$id] check: blocked by a safety gate"; Write-LabIndented $script:EntryOut; $M.Rc = 20; return }
        default { Write-LabStatus 'ERROR' "[$id] check: error (exit $($script:EntryRc))"; Write-LabIndented $script:EntryOut; $M.Rc = 40; return }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'plan.ps1') -PathType Leaf)) {
        Write-LabStatus 'ERROR' "[$id] error: change needed but plan.ps1 is missing"; Write-LabIndented $script:EntryOut; $M.Rc = 40; return
    }
    if ($M.Risk -eq 'manual-only') {
        Write-LabStatus 'WARN' "[$id] check: manual steps needed; plan follows"
    } else {
        Write-LabStatus 'CHANGE' "[$id] check: change needed; plan follows"
    }
    Write-LabIndented $script:EntryOut
    Invoke-LabEntry $M.Dir 'plan' $id
    switch ($script:EntryRc) {
        { $_ -eq 0 -or $_ -eq 10 } { $M.Rc = 10; return }
        20 { Write-LabStatus 'BLOCKED' "[$id] plan: blocked by a safety gate"; $M.Rc = 20; return }
        default { Write-LabStatus 'ERROR' "[$id] plan: error (exit $($script:EntryRc))"; $M.Rc = 40; return }
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
    if ($script:PhaseCount -eq 0) { Write-LabStatus 'WARN' "no $Phase modules in profile $script:ProfileName" }
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
        try {
            Add-LabEntryFor $Id 'rolled_back'
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            Write-LabStatus 'ERROR' "[$Id] rolled back, but the manifest cannot be written, so it still lists the change; rolling back again is safe"
            return 40
        }
        Write-LabStatus 'OK' "[$Id] rolled back"
        Write-LabLogFor $Id 'warn' 'rolled_back' 'rolled back'
        return 0
    }
    Write-LabStatus 'ERROR' "[$Id] rollback FAILED (exit $rc): restore this module by hand from $(Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $Id)"
    Write-LabLogFor $Id 'error' 'rollback_failed' "rollback failed with exit $rc"
    return 40
}

# Did every module this one requires, in this run, finish?
function Test-LabRequire {
    param($M)
    foreach ($req in $M.Requires) {
        foreach ($other in $script:Run) {
            if ($other.Id -ceq $req -and @('done', 'planned') -notcontains $other.State) {
                Write-LabStatus 'BLOCKED' "[$($M.Id)] blocked: requires $req, which did not complete"
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
        Write-LabStatus 'WARN' "[$id] manual-only: a person carries out the checklist above; nothing changed"
        $M.State = 'manual'; return 0
    }
    if ($M.Scored) {
        try { $allow = Read-LabAddressList 'scoring-allowlist' }
        catch {
            Write-LabStatus 'ERROR' "[$id] error: the scoring allowlist is malformed"
            Write-LabIndented $_.Exception.Message
            $M.State = 'error'; return 40
        }
        if ($null -eq $allow) {
            Write-LabStatus 'BLOCKED' "[$id] blocked: it touches scored services and the scoring allowlist is missing or empty"
            $M.State = 'blocked'; return 20
        }
        if (-not $script:HaveServices) {
            Write-LabStatus 'BLOCKED' "[$id] blocked: it touches scored services and there is no service list to probe"
            $M.State = 'blocked'; return 20
        }
    }
    if (-not (Test-LabRequire $M)) { $M.State = 'blocked'; return 20 }
    if ($M.Risk -eq 'approval') {
        if (-not (Read-LabAnswer "[$id] Type the ids of the items to approve, separated by spaces, or press Enter for none: ")) { $script:Answer = '' }
        foreach ($tok in @($script:Answer -split '\s+' | Where-Object { $_ -ne '' })) {
            if ($tok -cnotmatch '^[A-Za-z0-9._:@-]+$') { Write-LabStatus 'BLOCKED' "[$id] blocked: not an item id: $tok"; $M.State = 'blocked'; return 20 }
        }
        $script:Approved = (@($script:Answer -split '\s+' | Where-Object { $_ -ne '' })) -join ' '
        if ($script:Approved -eq '') { Write-LabStatus 'OK' "[$id] nothing approved; nothing changed"; $M.State = 'done'; return 0 }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $M.Dir 'apply.ps1') -PathType Leaf)) {
        Write-LabStatus 'OK' "[$id] no apply step; nothing changed"
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
            [Console]::Error.WriteLine($_.Exception.Message)
            Write-LabStatus 'BLOCKED' "[$id] blocked: the revert timer could not be armed"
            $M.State = 'blocked'; return 20
        }
    }

    # A change the manifest does not list could never be rolled back.
    try {
        Add-LabEntryFor $id 'apply_start' '' "risk $($M.Risk)"
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        Write-LabStatus 'ERROR' "[$id] error: the run manifest cannot be written, so it is not applied"
        $M.State = 'error'; return 40
    }
    Write-LabLogFor $id 'info' 'apply_start' 'applying'
    Write-LabStatus 'CHANGE' "[$id] applying"
    Invoke-LabEntry $M.Dir 'apply' $id '0'
    $rc = $script:EntryRc
    if ($rc -eq 20) {
        Write-LabStatus 'BLOCKED' "[$id] apply: blocked by a safety gate"
        Add-LabEntryFor $id 'rolled_back' '' 'apply blocked before any change'
        $M.State = 'blocked'; return 20
    }
    if ($rc -ne 0) {
        Write-LabStatus 'ERROR' "[$id] apply: error (exit $rc); rolling back"
        $M.State = 'error'; [void](Undo-LabModule $id); return 40
    }

    if (Test-Path -LiteralPath (Join-Path $M.Dir 'verify.ps1') -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'verify' $id '0'
        $rc = $script:EntryRc
        if ($rc -ne 0) {
            Write-LabStatus 'FAIL' "[$id] verify failed (exit $rc); rolling back"
            Write-LabLogFor $id 'error' 'verify_failed' "verify exited $rc"
            $M.State = 'failed'
            if ((Undo-LabModule $id) -ne 0) { $M.State = 'error' }
            if ($rc -eq 30) { return 30 }
            return 40
        }
    }

    if ($script:HaveServices) {
        $after = Get-LabProbeNow
        $reg = @(Get-LabProbeRegression -Before $script:Before -After $after)
        if ($reg.Count -gt 0) {
            Write-LabStatus 'FAIL' "[$id] scored service regressed: $($reg -join ' '); rolling back"
            Write-LabLogFor $id 'error' 'regression' "scored service regressed: $($reg -join ' ')"
            $M.State = 'failed'
            if ((Undo-LabModule $id) -ne 0) { $M.State = 'error' }
            return 30
        }
    }

    if (Test-Path -LiteralPath (Join-Path $M.Dir 'cleanup.ps1') -PathType Leaf) {
        Invoke-LabEntry $M.Dir 'cleanup' $id '0'
        if ($script:EntryRc -ne 0) { Write-LabStatus 'WARN' "[$id] cleanup: exit $($script:EntryRc) (the change is kept)" }
    }
    Write-LabStatus 'OK' "[$id] applied and verified"
    Write-LabLogFor $id 'info' 'applied' 'applied and verified'
    $M.State = 'done'
    return 0
}

function Read-LabSetting {
    try { $script:Settings = Read-LabEventConfig } catch { Exit-Lab "event.conf is malformed: $($_.Exception.Message)" }
}

# Assert-LabThisHost: the host checks for plan, apply and probe
# (docs\Conventions.md section 3.1). keep, rollback and runs skip them, so
# a stored revert-timer command still works after the configuration changes.
function Assert-LabThisHost {
    param([string] $Config)
    if ($Config -ne '' -and -not (Test-Path -LiteralPath $Config -PathType Container)) {
        Exit-Lab "the -Config folder does not exist: $Config"
    }
    $entry = Find-LabThisHost
    if ($null -eq $entry) { return }    # not listed: plan may still run
    $hostName = Get-LabHostName
    $hostsFile = Join-Path $env:LAB_CONFIG_DIR 'hosts'
    switch -CaseSensitive ($entry.Platform) {
        'windows' { }
        'appliance' { Exit-Lab "this host ($hostName) is an appliance in ${hostsFile}: Labyrinth never changes it (design 16)" 20 }
        default { Exit-Lab "this host ($hostName) is listed as $($entry.Platform) in ${hostsFile}, not a platform this runner serves" 20 }
    }
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
    Write-LabPendingWarning
    Write-LabLine ('labyrinth {0}: plan {1}, profile {2}' -f $LabVersion, $Phase, $script:ProfileName)
    Write-LabLine "run $env:LAB_RUN_ID (plan mode: nothing is recorded)"
    $worst = Invoke-LabPlanAll $Phase
    Exit-LabRun 'plan' $worst $Phase
}

# Write-LabRecap HOST GROUP: what apply is about to do, before the group-name
# prompt.
function Write-LabRecap {
    param([string] $HostName, [string] $Group)
    Write-LabLine "About to apply on host $HostName, group ${Group}:"
    foreach ($m in $script:Run) {
        $what = ''
        if ($m.Rc -eq 10 -and $m.Risk -eq 'manual-only') { $what = 'manual' }
        elseif ($m.Rc -eq 10) { $what = 'will change' }
        elseif ($m.Rc -eq 20) { $what = 'blocked' }
        if ($what -ne '') { Write-LabLine ('  {0} {1}' -f $what.PadRight(12), $m.Id) }
    }
    Write-LabLine "Each change arms a revert timer that undoes the run in $($script:Settings['REVERT_MINUTES']) minutes"
    Write-LabLine 'unless you keep it.'
}

function Invoke-LabApplyCommand {
    param([string] $Phase)
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    $hostName = Get-LabHostName
    if (-not (Test-LabAdmin)) { Exit-Lab 'apply needs an elevated Administrator session' 20 }
    # Before any configuration under the root is trusted.
    try { Protect-LabDataRoot -Path $script:DataRoot } catch { Exit-Lab "$($_.Exception.Message); nothing was changed" 20 }
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
        Write-LabPendingWarning
        Write-LabLine ('labyrinth {0}: APPLY {1}, profile {2}' -f $LabVersion, $Phase, $script:ProfileName)
        Write-LabLine "run $env:LAB_RUN_ID on host $hostName, group $group"
        $worst = Invoke-LabPlanAll $Phase
        if ($worst -ge 40) { Exit-Lab 'the plan has errors; nothing was changed' }
        $todo = @($script:Run | Where-Object { $_.Rc -eq 10 -and $_.Risk -ne 'manual-only' }).Count
        if ($todo -eq 0) {
            Write-LabLine 'nothing to apply'
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
            [Console]::Error.WriteLine($_.Exception.Message)
            Exit-Lab 'the run manifest cannot be written; nothing was changed'
        }
        $script:RunOpen = $true
        $script:Applied = $true
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

    $script:Stopped = $stopped
    if ($stopped) {
        foreach ($l in (Get-LabRunStopped)) { Write-LabLine $l }
    } elseif (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) {
        Write-LabLine 'All changes are applied and verified. From a NEW session, check that you can still log in.'
        $due = Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID
        if ($due -ne '') { Write-LabLine "The revert timer rolls this run back at $($due.Substring(11, 5)) UTC." }
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
            [Console]::Error.WriteLine($_.Exception.Message)
            $due = Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID
            $when = ''
            if ($due -ne '') { $when = " at $($due.Substring(11, 5)) UTC" }
            [Console]::Error.WriteLine("labyrinth: the revert timer for run $env:LAB_RUN_ID could not be cancelled, so the run is not kept and the timer will still roll it back$when")
            [Console]::Error.WriteLine("Retry: $Self keep $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4))")
            return 40
        }
        try {
            Add-LabEntryFor '' 'run_kept'
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            [Console]::Error.WriteLine("labyrinth: the revert timer for run $env:LAB_RUN_ID is cancelled, so the changes stay, but the keep could not be recorded")
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
    if (-not (Test-LabAdmin)) { Exit-Lab 'runs needs an elevated Administrator session' 20 }
    $runs = @(Get-LabRunList)
    Write-LabPendingWarning
    if ($runs.Count -eq 0) {
        Write-LabLine "no runs on this host ($(Join-Path $env:LAB_STATE_DIR 'runs'))"
        exit 0
    }
    foreach ($l in (Get-LabRunTable $runs)) { Write-LabLine $l }
    # The example names the newest armed run, the one most likely to be kept.
    $example = $runs[-1]
    $armed = @(Get-LabArmedRun)
    if ($armed.Count -gt 0) { $example = $armed[-1] }
    Write-LabLine ''
    Write-LabLine "Name a run by its last 4 characters, like '$Self keep $($example.Substring($example.Length - 4))'."
    exit 0
}

# Resolve-LabRunId COMMAND REF: the full run ID REF names. REF is a full
# ID, or its last 4 characters if they match exactly one run.
function Resolve-LabRunId {
    param([string] $Command, [string] $Ref)
    if ($Ref -cmatch $ReRunId) {
        $manifest = Join-Path (Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $Ref) 'manifest.jsonl'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Exit-LabUsage "no run $Ref on this host; '$Self runs' lists them" $Command }
        return $Ref
    }
    $suffix = $Ref.ToLowerInvariant()
    $hits = @(Get-LabRunList | Where-Object { $_.EndsWith("-$suffix", [StringComparison]::Ordinal) })
    if ($hits.Count -eq 0) { Exit-LabUsage "no run ending in '$Ref' on this host; '$Self runs' lists them" $Command }
    if ($hits.Count -gt 1) { Exit-LabUsage "'$Ref' ends more than one run ($($hits -join ' ')); give the full ID" $Command }
    Write-LabLine "using run $($hits[0])"
    return $hits[0]
}

function Invoke-LabKeepCommand {
    param([string] $Ref)
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if (-not (Test-LabAdmin)) { Exit-Lab 'keep needs an elevated Administrator session' 20 }
    if ($Ref -eq '') {
        # Without a run, keep the one run whose timer is armed (section 3.1).
        $armed = @(Get-LabArmedRun)
        if ($armed.Count -eq 0) { Exit-LabUsage 'no run on this host has an armed revert timer, so there is nothing to keep' 'keep' }
        if ($armed.Count -gt 1) {
            foreach ($l in (Get-LabRunTable $armed)) { [Console]::Error.WriteLine($l) }
            Exit-LabUsage "more than one run has an armed revert timer; name one, like '$Self keep $($armed[0].Substring($armed[0].Length - 4))'" 'keep'
        }
        $env:LAB_RUN_ID = $armed[0]
        Write-LabLine "using run $($armed[0])"
    } else {
        $env:LAB_RUN_ID = Resolve-LabRunId 'keep' $Ref
    }
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    Write-LabPendingWarning
    exit (Invoke-LabKeep)
}

function Invoke-LabRollbackCommand {
    param([string] $Ref)
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if ($Ref -eq '') {
        # Rollback always needs a run (decision D3): list them, change nothing.
        if (-not (Test-LabAdmin)) {
            Exit-LabUsage "rollback needs a run ID, or its last 4 characters; as Administrator, '$Self runs' lists them" 'rollback'
        }
        $runs = @(Get-LabRunList)
        if ($runs.Count -gt 0) { foreach ($l in (Get-LabRunTable $runs)) { [Console]::Error.WriteLine($l) } }
        Exit-LabUsage "rollback needs a run ID, or its last 4 characters; '$Self runs' lists them" 'rollback'
    }
    if (-not (Test-LabAdmin)) { Exit-Lab 'rollback needs an elevated Administrator session' 20 }
    $env:LAB_RUN_ID = Resolve-LabRunId 'rollback' $Ref
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" }
    Write-LabPendingWarning
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
        # A timer left armed runs this rollback again, which is safe.
        try {
            Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            [Console]::Error.WriteLine("warning: the revert timer for run $env:LAB_RUN_ID could not be removed; when it fires it repeats this rollback, which is safe")
        }
        try {
            Add-LabEntryFor '' 'run_rolled_back' '' "exit $rc"
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            [Console]::Error.WriteLine("labyrinth: run $env:LAB_RUN_ID is rolled back, but the manifest cannot be written to record it")
            $rc = 40
        }
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
    Write-LabPendingWarning
    foreach ($l in $out) { Write-LabLine $l }
    if (@($out | Where-Object { ($_ -split ' ', 3)[1] -eq 'fail' }).Count -gt 0) { exit 30 }
    exit 0
}

try {
    Read-LabArgument $script:Arguments
    $words = $script:Words
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
            [Console]::Error.WriteLine("Usage: $Self <command> [<phase> | <run>] [options]")
            [Console]::Error.WriteLine("Commands: $($Commands -join ', ')")
            [Console]::Error.WriteLine("Try '$Self help' for more information.")
            exit 40
        }
        'help' {
            if ($rest.Count -gt 1) { Exit-LabUsage "unexpected word '$($rest[1])' after 'help $($rest[0])'" 'help' }
            $topic = ''
            if ($rest.Count -eq 1) { $topic = $rest[0].ToLowerInvariant() }
            if ($topic -ne '' -and $Commands -cnotcontains $topic) {
                $hint = Get-LabSuggestion $topic $Commands
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
            if ($cmd -ceq 'plan') { $used = @('profile') } else { $used = @('profile', 'break-glass', 'confirm-group') }
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
