<#
.SYNOPSIS
    Labyrinth: preview, run, keep and undo hardening runs on this Windows
    host.

.DESCRIPTION
    One action per line ('laby' is this program, run as shown):
      .\labyrinth.ps1                  this host's status and the next step
      .\labyrinth.ps1 PHASE            preview a phase: nothing changes
      .\labyrinth.ps1 -r PHASE         run a phase: plan, confirm, then change
      .\labyrinth.ps1 -k ID            keep a run: cancel its revert timer
      .\labyrinth.ps1 -u ID [-All]     undo a run, newest change first
      .\labyrinth.ps1 -History         list this host's runs and their state
      .\labyrinth.ps1 -Probe           test every scored service once
      .\labyrinth.ps1 -NewSeed         make this host's decoy seed
      .\labyrinth.ps1 -SeedCheck       check a seed typed at a prompt
      .\labyrinth.ps1 -Manual          the full manual, one screen at a time
      .\labyrinth.ps1 -V               the version; also -Version
      .\labyrinth.ps1 -h [TOPIC]       help; also -Help and /?

    A phase is lockout, observe, deceive or sustain. ID is a run ID, or its
    last 4 characters.

    Options, before or after the action:
      -P NAME, -Profile NAME  use this profile instead of the hosts file's
      -Root DIR               the data root (default C:\ProgramData\Labyrinth)
      -Config DIR             the configuration folder (default <root>\etc)
      -BreakGlass NAME        answer the break-glass prompt (-r only)
      -ConfirmGroup GROUP     answer the group-name prompt (-r only)
      -Approve LIST           approve items without the prompt (-r only)
      -All                    with -u: also undo changes kept once verified
      -y, -Yes                with -u ID -All or -NewSeed: yes to its question
      -NoRevert               with -r: no revert timer, for test machines

    Short letters are case-sensitive: -P and -V are capitals. Long names
    ignore case, and a double dash (--root) works too. -k and -u need an ID.

    Exit codes: 0 done or nothing to do, 10 change needed, 20 blocked
    (not an Administrator, another run, or a safety check), 30 a check
    after a change failed (-Probe: a service failed), 40 error.

    New to Labyrinth? '.\labyrinth.ps1 -h basics' explains the ideas in
    plain words. '.\labyrinth.ps1 -h ACTION' explains one action, and
    '.\labyrinth.ps1 -h MODULE-ID' one module. '.\labyrinth.ps1 -Manual'
    shows the operator manual, which installed Labyrinth also has as
    Get-Help about_Labyrinth.

.EXAMPLE
    .\labyrinth.ps1 lockout

    Shows what the lockout phase would change on this host.

.EXAMPLE
    .\labyrinth.ps1 -r lockout

    Plans, asks you to confirm, then makes the changes and arms a revert
    timer that undoes them unless you keep them.

.EXAMPLE
    .\labyrinth.ps1 -History

    Lists this host's runs, with the state of each revert timer.

.EXAMPLE
    .\labyrinth.ps1 -k 4f2a

    Keeps the run whose ID ends in 4f2a: its revert timer is cancelled.

.NOTES
    -r, -k, -u, -History and -NewSeed need PowerShell opened with 'Run as
    administrator'. Use -h for help: PowerShell takes -? for itself. The
    common parameters, such as -Verbose and -ErrorAction, are not
    supported.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabVersion = '0.1.0'
$LabUrl = 'https://dotnetdork.github.io/Labyrinth/'
$Phases = @('lockout', 'observe', 'deceive', 'sustain')
$ModuleKeys = @('id', 'title', 'phase', 'priority', 'platforms', 'risk', 'touches_scored', 'requires', 'outputs', 'spec', 'pre_approvable', 'keep_on_verify')
$RequiredKeys = @('id', 'title', 'phase', 'priority', 'platforms', 'risk', 'touches_scored')
$Risks = @('read-only', 'reversible', 'service-affecting', 'approval', 'manual-only')
$Platforms = @('ubuntu', 'rhel-family', 'windows', 'appliance')
$ReRunId = '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$'
$ReModuleId = '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'
# An item line from an approval module's plan, and one -Approve entry
# (docs/Conventions.md section 3.1).
$ReItem = "^item`t([a-z0-9-]+)`t([a-z0-9-]+)`t([0-9a-f]{12})`t(.*)$"
$ReApprove = '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+:[a-z0-9-]+@[0-9a-f]{12}$'
# A word that looks like one entry of a list option's value: here an
# -Approve entry, well formed or not. A phase word or a run ID never does.
$ReListItem = '^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+@[A-Za-z0-9]+$'
# How the operator started this program, so a hint can be pasted and run
# (docs/Conventions.md section 3.2): .\labyrinth.ps1 from its own folder,
# else its full path, after & and in quotes when the path needs them.
# $SelfName is the name alone, for the start of a usage error.
$SelfName = '.\labyrinth.ps1'
if ((Get-Location).ProviderPath.TrimEnd('\') -ne $PSScriptRoot.TrimEnd('\')) {
    $SelfName = $PSCommandPath
}
# Started through the installed launcher (laby.cmd or labyrinth.cmd), which
# sets LAB_SELF to its own name: show that name, as the operator types it.
if ($env:LAB_SELF -ceq 'laby' -or $env:LAB_SELF -ceq 'labyrinth') { $SelfName = $env:LAB_SELF }
$Self = $SelfName
if ($Self -notmatch '^[A-Za-z0-9_.:\\/~-]+$') { $Self = "& '" + $Self.Replace("'", "''") + "'" }

# The options, one row each (docs/Conventions.md section 3.3): the canonical
# name, how a message shows it, its long form, the key its long name is
# matched by (lower case, no dashes), its short letter if it has one (case
# matters), whether it takes a value, and whether it is an action. The same
# table as labyrinth.sh, which shows the long forms as --name.
$script:LabOptions = @(
    @{ Name = 'run'; Show = '-r'; Long = '-Run'; Key = 'run'; Short = 'r'; Value = $false; Action = $true }
    @{ Name = 'keep'; Show = '-k'; Long = '-Keep'; Key = 'keep'; Short = 'k'; Value = $true; Action = $true }
    @{ Name = 'undo'; Show = '-u'; Long = '-Undo'; Key = 'undo'; Short = 'u'; Value = $true; Action = $true }
    @{ Name = 'probe'; Show = '-Probe'; Long = '-Probe'; Key = 'probe'; Short = ''; Value = $false; Action = $true }
    @{ Name = 'history'; Show = '-History'; Long = '-History'; Key = 'history'; Short = ''; Value = $false; Action = $true }
    @{ Name = 'new-seed'; Show = '-NewSeed'; Long = '-NewSeed'; Key = 'newseed'; Short = ''; Value = $false; Action = $true }
    @{ Name = 'seed-check'; Show = '-SeedCheck'; Long = '-SeedCheck'; Key = 'seedcheck'; Short = ''; Value = $false; Action = $true }
    @{ Name = 'version'; Show = '-V'; Long = '-Version'; Key = 'version'; Short = 'V'; Value = $false; Action = $true }
    @{ Name = 'manual'; Show = '-Manual'; Long = '-Manual'; Key = 'manual'; Short = ''; Value = $false; Action = $true }
    @{ Name = 'all'; Show = '-All'; Long = '-All'; Key = 'all'; Short = ''; Value = $false; Action = $false }
    @{ Name = 'profile'; Show = '-Profile'; Long = '-Profile'; Key = 'profile'; Short = 'P'; Value = $true; Action = $false }
    @{ Name = 'root'; Show = '-Root'; Long = '-Root'; Key = 'root'; Short = ''; Value = $true; Action = $false }
    @{ Name = 'config'; Show = '-Config'; Long = '-Config'; Key = 'config'; Short = ''; Value = $true; Action = $false }
    @{ Name = 'break-glass'; Show = '-BreakGlass'; Long = '-BreakGlass'; Key = 'breakglass'; Short = ''; Value = $true; Action = $false }
    @{ Name = 'confirm-group'; Show = '-ConfirmGroup'; Long = '-ConfirmGroup'; Key = 'confirmgroup'; Short = ''; Value = $true; Action = $false }
    @{ Name = 'approve'; Show = '-Approve'; Long = '-Approve'; Key = 'approve'; Short = ''; Value = $true; Action = $false }
    @{ Name = 'yes'; Show = '-y'; Long = '-Yes'; Key = 'yes'; Short = 'y'; Value = $false; Action = $false }
    @{ Name = 'no-revert'; Show = '-NoRevert'; Long = '-NoRevert'; Key = 'norevert'; Short = ''; Value = $false; Action = $false }
    @{ Name = 'help'; Show = '-h'; Long = '-Help'; Key = 'help'; Short = 'h'; Value = $false; Action = $false }
)
# The flags that docs/Conventions.md section 3.3 plans and nothing builds yet:
# the short letter, the long name's match key ('' when the name is already an
# option) and how a message shows it. Typing one is a usage error that says
# so; building one means moving its row up into LabOptions.
$script:LabPlanned = @(
    @{ Short = 'q'; Key = 'queue'; Show = '-Queue' }
    @{ Short = 'a'; Key = ''; Show = '-Approve, with -Queue' }
    @{ Short = 'd'; Key = 'decline'; Show = '-Decline, with -Queue' }
    @{ Short = 'v'; Key = 'verbose'; Show = '-Verbose' }
)
$script:Arguments = @($args)     # the words, before any function runs
$script:ArgPos = 0               # the next word of Arguments to read
$script:Given = @{}              # canonical option name -> value given
$script:Actions = @()            # the actions given, in the order typed
$script:Words = @()              # the words that are not options, in order
$script:HelpAsked = $false       # true when -h, -Help, -? or /? came before '--'
$script:TryTopic = ''            # what the Try line puts before -h
$script:ParseError = ''          # the first option error, reported by main
$script:ErrorCount = 0           # ERROR lines in the Summary, for the Next line

$script:Mod = @{}
$script:ProfileIds = @()
$script:PendingWarnings = @()
$script:EntryRc = 0
$script:Approved = ''            # items approved for the module being applied
$script:Refused = @()            # approved items that changed since the plan
$script:Pre = @()                # those approved items a pre-approval rule approved
$script:PreRules = @()           # the pre-approval rules (pre-approved)
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
$script:HostEntry = $null        # this host's line in hosts, for plan's Next line
$script:BreakGlassAccount = ''
$script:BreakGlassNote = 'confirmed earlier'   # what the console check found
$script:BreakGlassNew = $false   # true when this run asked, so the answer is recorded
$script:GivenBreakGlass = ''     # -BreakGlass, read inside functions
$script:GivenGroup = ''          # -ConfirmGroup, read inside functions
$script:DataRoot = ''            # the data root (-Root)
$script:Answer = ''
$script:Command = ''             # the command being run, for the last catch
$script:RunRef = ''              # the run keep or rollback acts on
$script:RunOpen = $false         # true once an apply has recorded run_start
$script:NoRevert = $false        # -NoRevert: no revert timer, no keep question
$script:GaveReason = $false      # did the last entry point end with a 'problem:' line?
$script:EntryLast = ''           # the last line an entry point printed that was not blank
$script:Titles = @{}             # module ID -> title, for the status lines
$script:LogFile = ''             # the run's output.log, once it is open
$script:LogOn = $false           # keep lines for the run log before it opens
$script:LogBuf = New-Object Collections.Generic.List[string]
$script:NoLog = $false           # true while a line is shown but not logged
$LogCap = 500                    # the most lines of one entry point in the log
$Labels = @('found', 'will do', 'did', 'why', 'risk', 'problem', 'cause', 'fix', 'undo')

# Show-LabHelp [TOPIC]: the main help, or one topic's, on stdout. A topic is
# an action, an option, a phase or 'basics', by its canonical name. The text
# is the same as labyrinth.sh's. It writes the program's name as @CMD@, and
# the name as started ($Self) is put in: 'laby' or 'labyrinth' when started
# through the installed launcher.
# The main page is at most 24 lines and each topic at most 18 (basics 24), of
# at most 78 columns with the name '.\labyrinth.ps1', with an Exit line, an
# Example line and a See also line (docs/Conventions.md section 3.2).
# -Lines N prints only the first N lines.
function Show-LabHelp {
    param([string] $Topic = '', [int] $Lines = 0)
    $text = switch ($Topic) {
        '' { @'
Usage: @CMD@ PHASE                preview a phase: nothing changes
       @CMD@ -r PHASE             run a phase for real
       @CMD@                      this host's status and next step
       @CMD@ ACTION [OPTIONS]

Actions (one per line):
  -r, --run               run a phase: plan, confirm, change
  -k, --keep ID           keep a run: cancel its revert timer
  -u, --undo ID [--all]   undo a run, newest change first
      --history           list this host's runs  --probe   test every service
      --new-seed          make a decoy seed      --seed-check   check a seed
  -V, --version           print the version      --manual   the full manual

Options:
  -P, --profile NAME      profile to use, if not this host's line in hosts
  --root DIR              data root         --config DIR   configuration
  -y, --yes               yes to the question before -u ID --all or --new-seed
  --no-revert             with -r: no revert timer, for test machines
  --break-glass NAME, --confirm-group GROUP, --approve LIST: see -h run
  -h, --help [TOPIC]      help; TOPIC: an action, option, phase or basics

Phases: lockout, observe, deceive, sustain. ID: a run ID or its last 4.
Exit: 0 ok, 10 change needed, 20 blocked, 30 check failed, 40 error.
Full manual: @CMD@ --manual   (Linux also: man laby)
'@ }
        'run' { @'
Usage: @CMD@ -r PHASE [-P NAME] [--root DIR] [--config DIR]

Plan, then ask you to name the break-glass account (first run only)
and to type this host's group name. Then change, checking each change;
a revert timer undoes the run unless you keep it. Needs root or an
Administrator. -r may come before or after PHASE.

Options:
  -P, --profile NAME     must match this host's line in the hosts file
  --break-glass NAME     answer the break-glass prompt
  --confirm-group GROUP  answer the group-name prompt
  --approve LIST         approve without asking: module:item@fingerprint,...
  --no-revert            no revert timer and no keep question: test machines

Exit: 0 done, 10 manual steps left, 20 blocked, 30 check failed, 40 error.
Blocked: not an Administrator, another run, host not in hosts, or a gate.
Example: @CMD@ -r lockout
See also: @CMD@ -h lockout, -h keep, -h basics
'@ }
        'keep' { @'
Usage: @CMD@ -k ID [--root DIR] [--config DIR]

Keep a run's changes: cancel its revert timer, then record the keep.
ID is always needed: a run ID or its last 4 characters. Without it,
the armed runs are listed and nothing is kept. Needs root or an
Administrator.

Options: --root DIR (data root), --config DIR (configuration folder)

Exit: 0 kept, 20 blocked, 40 error.
Blocked: not an Administrator, a file another account can change, or too late
(the run was already undone).
Example: @CMD@ -k 4f2a
See also: @CMD@ --history, @CMD@ -h undo
'@ }
        'undo' { @'
Usage: @CMD@ -u ID [--all [-y]] [--root DIR] [--config DIR]

Undo what the run changed, newest change first. This is what the
revert timer runs. Safe to run twice. ID is always needed: a run ID or
its last 4 characters; '@CMD@ --history' lists them. Needs root or
an Administrator.

Options:
  --all                  also undo changes kept once they verified
  -y, --yes              with --all: yes to its question, asked first
  --root DIR, --config DIR   data root, configuration folder

Exit: 0 undone or not confirmed, 20 blocked, 40 error.
Blocked: not an Administrator, or a file another account can change.
Example: @CMD@ -u 4f2a
See also: @CMD@ --history, @CMD@ -h keep
'@ }
        'history' { @'
Usage: @CMD@ --history [--root DIR] [--config DIR]

List this host's runs, oldest first: run ID, phase, start time (UTC)
and state: armed (and when it is undone), kept, undone,
undone with errors, no revert (run with --no-revert), or
not kept, no timer. 'armed: timer lost'
means the timer's files are gone and nothing will undo the run by
itself: keep it or undo it. Changes nothing; needs root or an
Administrator.

Exit: 0 listed, 20 not root, 40 error.
Example: @CMD@ --history
See also: @CMD@ -h keep, @CMD@ -h undo
'@ }
        'probe' { @'
Usage: @CMD@ --probe [--root DIR] [--config DIR]

Test every scored service once, the way the scoring engine would,
and print one line per service. Changes nothing. Needs root or an
Administrator to read the configuration.

Exit: 0 all pass, 20 no service list, 30 a service failed, 40 error.
Example: @CMD@ --probe
See also: @CMD@ -h basics, @CMD@ --history
'@ }
        'new-seed' { @'
Usage: @CMD@ --new-seed [-y] [--root DIR] [--config DIR]

Make this host's decoy seed: the code its decoys are worked out from.
It is saved in seed.conf, in the configuration folder, for root only,
and shown once on the terminal until you type 'recorded'; then the
screen is cleared. Put it in the offline record, and post it in the
team chat with this host's name. If the host already has one, it asks
before replacing it; -y answers yes. Needs root or an Administrator
and a terminal.

Exit: 0 saved or not replaced, 20 blocked, 40 error.
Blocked: not root, no terminal, or the terminal went before 'recorded'
(the new seed is then not saved).
Example: @CMD@ --new-seed
See also: @CMD@ -h seed-check, @CMD@ -h yes
'@ }
        'seed-check' { @'
Usage: @CMD@ --seed-check

Ask for a seed at a prompt on the terminal and say whether it is a
valid seed: its last group must match the rest, which catches a typo.
Case, spaces and dashes do not matter. The seed is typed, never given
on the command line, and is not saved or logged. Reads no
configuration and needs no root, so it works on any machine with
Labyrinth.

Exit: 0 valid, 20 no terminal, 30 not valid.
Example: @CMD@ --seed-check
See also: @CMD@ -h new-seed
'@ }
        'version' { @'
Usage: @CMD@ -V

Print the version of Labyrinth, which program printed it, and the
release hash. --version does the same.

Exit: 0 printed.
Example: @CMD@ -V
See also: @CMD@ -h
'@ }
        'manual' { @'
Usage: @CMD@ --manual

Open the full manual, one screen at a time: the help topic
about_Labyrinth from this release's manual folder or the installed
copy. When the output is not a console, the manual is printed.
Changes nothing and needs no Administrator.

Exit: 0 shown, 40 no manual in this copy.
Example: @CMD@ --manual
See also: @CMD@ -h, @CMD@ -h basics
'@ }
        'yes' { @'
Usage: @CMD@ -u ID --all -y
       @CMD@ --new-seed -y

Answer yes to the question asked before -u ID --all, which also
undoes changes kept once verified, such as a new password. Without a
terminal to ask on, -u ID --all is refused unless -y is given.
--new-seed -y replaces this host's decoy seed without asking.
-y never keeps a run: the login check after -r is always yours.
Used by: -u with --all, and --new-seed.

Exit: 40 if given with anything else.
Example: @CMD@ -u 4f2a --all -y
See also: @CMD@ -h all, @CMD@ -h undo
'@ }
        'no-revert' { @'
Usage: @CMD@ -r PHASE --no-revert

Arm no revert timer and ask nothing at the end: the changes stay
until you undo them with -u. For test machines only: a change that
locks you out is not undone by itself. The run records it, and
--history shows the run as 'no revert'.
Used by: -r only.

Exit: 40 if given with anything else.
Example: @CMD@ -r observe --no-revert
See also: @CMD@ -h run, @CMD@ -h undo
'@ }
        'profile' { @'
Usage: @CMD@ [-r] PHASE -P NAME

Use this profile, not the one in the hosts file. NAME is lower-case
letters, digits and '-'. For a run it must match this host's line in
the hosts file. A preview shows what that profile would do.
Used by: a preview and -r.

Exit: 40 if NAME is not a valid profile name.
Example: @CMD@ observe --profile linux-web
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'root' { @'
Usage: @CMD@ ACTION --root DIR

The data root: where Labyrinth keeps its configuration (etc), run
records (state), logs and backups. DIR must be a full path. The
default is the platform's own folder; the manual names it.
Used by: every action.

Exit: 40 if DIR is not a full path.
Example: @CMD@ --history --root /srv/labyrinth
See also: @CMD@ -h config
'@ }
        'config' { @'
Usage: @CMD@ ACTION --config DIR

The configuration folder, if it is not <root>/etc: the hosts file, the
protected set and the event's other files. DIR must be a full path.
For a preview, -r, --probe and --new-seed it must exist.
Used by: every action.

Exit: 40 if DIR is not a full path or does not exist.
Example: @CMD@ observe --config /srv/event-etc
See also: @CMD@ -h root
'@ }
        'break-glass' { @'
Usage: @CMD@ -r PHASE --break-glass NAME

Answer the break-glass prompt without typing: NAME is the emergency
account you are logged in with at the console. It must be listed with
the class breakglass in the protected set.
Used by: -r only.

Exit: 20 if NAME is not that account.
Example: @CMD@ -r lockout --break-glass admin
See also: @CMD@ -h run, @CMD@ -h confirm-group
'@ }
        'confirm-group' { @'
Usage: @CMD@ -r PHASE --confirm-group GROUP

Answer the group-name prompt without typing: GROUP is this host's group
from the hosts file. A different name stops the run before anything
changes.
Used by: -r only.

Exit: 20 if GROUP is not this host's group.
Example: @CMD@ -r lockout --confirm-group ring1
See also: @CMD@ -h run, @CMD@ -h break-glass
'@ }
        'approve' { @'
Usage: @CMD@ -r PHASE --approve LIST

Approve items without the approval prompt. LIST is comma-separated
entries, module-id:item-id@fingerprint, pasted from a preview. A
category is not accepted: it could include items you never saw.
Used by: -r only.

Exit: 40 if an entry is malformed.
Example: @CMD@ -r harden --approve module-id:item-id@2a2c17aaaf66
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'all' { @'
Usage: @CMD@ -u ID --all

Also undo the changes that were kept once they verified, such as a
new admin password. Undoing those can give an intruder their access
back: if a password changes back, rotate it again.
Used by: -u only.

Exit: as for -u.
Example: @CMD@ -u 4f2a --all
See also: @CMD@ -h undo
'@ }
        'lockout' { @'
Usage: @CMD@ lockout [-P NAME]
       @CMD@ -r lockout

The first phase: take control back from the attacker. Its modules
change the host quickly, behind a revert timer.
@CMD@ lockout only previews: nothing changes and nothing is written.

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: @CMD@ lockout
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'observe' { @'
Usage: @CMD@ observe [-P NAME]
       @CMD@ -r observe

The phase that shows what is happening on the host. Its modules
look, and change only what a person approves.
@CMD@ observe only previews: nothing changes and nothing is written.

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: @CMD@ observe
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'deceive' { @'
Usage: @CMD@ deceive [-P NAME]
       @CMD@ -r deceive

The phase that plants traps to give an attacker away.
@CMD@ deceive only previews: nothing changes and nothing is written.

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: @CMD@ deceive
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'sustain' { @'
Usage: @CMD@ sustain [-P NAME]
       @CMD@ -r sustain

The phase that keeps everything running and lets you undo mistakes.
@CMD@ sustain only previews: nothing changes and nothing is written.

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: @CMD@ sustain
See also: @CMD@ -h run, @CMD@ -h basics
'@ }
        'basics' { @'
Usage: @CMD@ -h basics

Labyrinth makes this host harder to break into in five phases, in order:
lockout, harden (later), observe, deceive, sustain. Each phase is a list of
modules. A module does one small job, such as turning off password
logins. '@CMD@ -h MODULE-ID' explains any module.

1. Preview: '@CMD@ lockout' shows what each module would change.
   It changes nothing, so run it as often as you like.
2. Run: '@CMD@ -r lockout' plans again, has you name the break-glass
   account the first time, asks you to type this host's group name,
   then makes the changes and checks each one.
3. Keep: a run is named by an ID; its last 4 characters are enough.
   A revert timer undoes the run after a few minutes unless you keep
   it, so a change that locks you out undoes itself. Log in from a
   new session, and if that works, run '@CMD@ -k ID'.

To undo a run: @CMD@ -u ID; to list runs: @CMD@ --history.
Scored services are the ones the scoring engine tests. Labyrinth tests
them before and after each change, and undoes a change that breaks one.
To test them now: '@CMD@ --probe'.

Exit: 0 printed.
Example: @CMD@ -h basics
'@ }
    }
    $all = @($text -split "`r?`n")
    if ($Lines -gt 0 -and $Lines -lt $all.Count) { $all = $all[0..($Lines - 1)] }
    foreach ($l in $all) { [Console]::Out.WriteLine($l.Replace('@CMD@', $Self)) }
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
        $hint = Get-LabSuggestion $Id @(Get-LabModuleId)
        Show-LabHelpUnknown $Id $hint
        return
    }
    $file = Join-Path $dir 'module.yml'
    $script:YmlErr = @()
    if (-not (Read-LabModuleYml $file) -or -not (Test-LabModule $file $Id $phase)) {
        # Each error is "FILE: message" or "FILE:LINE: message", and the
        # message may hold ': ' itself, so the known file name comes off first.
        $err = $script:YmlErr[0]
        $where = $file
        if ($err.StartsWith($file)) { $err = $err.Substring($file.Length) }
        if ($err -match '^:([0-9]+):') { $where = "${file}:$($Matches[1])"; $err = $err.Substring($Matches[1].Length + 1) }
        if ($err.StartsWith(': ')) { $err = $err.Substring(2) }
        [Console]::Error.WriteLine("labyrinth: the module.yml of $Id is not valid: $err")
        [Console]::Error.WriteLine("Report the module to its author, or correct $where")
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
    if ($m.ContainsKey('keep_on_verify') -and $m['keep_on_verify'] -ceq 'true') {
        Write-LabLine 'Kept once it verifies and no scored service got worse; the revert'
        Write-LabLine 'timer then leaves it alone.'
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

# Exit-LabUsage MESSAGE [FIX]: a usage error: the name as typed and one line,
# the fix if there is one, a pointer to help, exit 40 (docs/Conventions.md
# section 3.3).
function Exit-LabUsage {
    param([string] $Message, [string] $Fix = '')
    $topic = ''
    if ($script:TryTopic -ne '') { $topic = " $($script:TryTopic)" }
    [Console]::Error.WriteLine("${SelfName}: $Message")
    if ($Fix -ne '') { [Console]::Error.WriteLine($Fix) }
    [Console]::Error.WriteLine("Try '$Self$topic -h'.")
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
# of 2, or of 1 for a word of 3 letters or fewer. Returns '' when there is
# none.
function Get-LabSuggestion {
    param([string] $Word, [string[]] $Candidates)
    if ($Word -eq '') { return '' }
    $prefix = @($Candidates | Where-Object { $_.StartsWith($Word, [StringComparison]::Ordinal) })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    $best = ''
    $bestd = 3
    if ($Word.Length -lt 4) { $bestd = 2 }
    foreach ($c in $Candidates) {
        $d = Measure-LabEditDistance $Word $c
        if ($d -lt $bestd) { $bestd = $d; $best = $c }
    }
    return $best
}

# Find-LabOption KEY: the row of the option whose long name is matched by KEY
# (lower case, no dashes), or $null.
function Find-LabOption {
    param([string] $Key)
    foreach ($o in $script:LabOptions) {
        if ($o.Key -ceq $Key) { return $o }
    }
    return $null
}

# Find-LabShort LETTER: the row of the option with this short letter (case
# matters), or $null.
function Find-LabShort {
    param([string] $Letter)
    foreach ($o in $script:LabOptions) {
        if ($o.Short -ne '' -and $o.Short -ceq $Letter) { return $o }
    }
    return $null
}

# Get-LabShow NAME: how a message writes an option: the short letter of the
# actions and of help, and -Name for the rest.
function Get-LabShow {
    param([string] $Name)
    foreach ($o in $script:LabOptions) {
        if ($o.Name -ceq $Name) { return $o.Show }
    }
    return "-$Name"
}

# Add-LabParseError MESSAGE: note the first option error; main reports it
# once the action is known, so the pointer to help names that action.
function Add-LabParseError {
    param([string] $Message)
    if ($script:ParseError -eq '') { $script:ParseError = $Message }
}

# Get-LabOptionKey: the match key of every option, for a near miss.
function Get-LabOptionKey {
    return @($script:LabOptions | ForEach-Object { $_.Key })
}

# Find-LabPlanned SHORT KEY: the row of the planned flag with this short
# letter or this long-name key (pass '' for the one not asked), or $null.
function Find-LabPlanned {
    param([string] $Letter, [string] $Key)
    foreach ($p in $script:LabPlanned) {
        if ($Letter -ne '' -and $p.Short -ne '' -and $p.Short -ceq $Letter) { return $p }
        if ($Key -ne '' -and $p.Key -ne '' -and $p.Key -ceq $Key) { return $p }
    }
    return $null
}

# Add-LabPlannedError TYPED ROW: note that a planned flag is not built. A
# short letter is shown with its long name.
function Add-LabPlannedError {
    param([string] $Typed, $Row)
    $more = ''
    if ($Typed.Length -eq 2) { $more = " ($($Row.Show))" }
    Add-LabParseError "'$Typed'$more is planned and not built yet"
}

# Add-LabUnknownOption WORD KEY: note an unknown long option: a planned one,
# or with a near miss.
function Add-LabUnknownOption {
    param([string] $Word, [string] $Key)
    $shown = ($Word -split '[=:]', 2)[0]
    $planned = Find-LabPlanned '' $Key
    if ($null -ne $planned) { Add-LabPlannedError $shown $planned; return }
    $hint = Get-LabSuggestion $Key (Get-LabOptionKey)
    if ($hint -ne '') {
        $h = Find-LabOption $hint
        Add-LabParseError "unknown option '$shown' (did you mean '$($h.Long)'?)"
        return
    }
    Add-LabParseError "unknown option '$shown'"
}

# Add-LabStackError WORD KEY BAD: note why a single-dash word is neither a
# long name nor a stack of short letters. KEY is the word without its dash,
# and BAD its first letter that is not a short flag.
function Add-LabStackError {
    param([string] $Word, [string] $Key, [string] $Bad)
    $shown = ($Word -split '[=:]', 2)[0]
    if ($Key.Length -gt 1) {
        $planned = Find-LabPlanned '' $Key.ToLowerInvariant().Replace('-', '')
        if ($null -ne $planned) { Add-LabPlannedError $shown $planned; return }
    }
    $planned = Find-LabPlanned $Bad ''
    if ($null -ne $planned) { Add-LabPlannedError "-$Bad" $planned; return }
    if ($Key.Length -eq 1) {
        # A lone letter of the wrong case is the commonest slip: -P for -p.
        $other = $Bad.ToUpperInvariant()
        if ($other -ceq $Bad) { $other = $Bad.ToLowerInvariant() }
        if ($null -ne (Find-LabShort $other)) {
            $what = ''
            if ($other -ceq 'V') { $what = ', the version' } elseif ($other -ceq 'P') { $what = ', the profile' }
            Add-LabParseError "unknown option '$shown' (did you mean '-$($other)'$($what)?)"
            return
        }
        Add-LabParseError "unknown option '$shown'"
        return
    }
    $lk = $Key.ToLowerInvariant().Replace('-', '')
    $hint = Get-LabSuggestion $lk (Get-LabOptionKey)
    if ($hint -ne '') {
        $h = Find-LabOption $hint
        Add-LabParseError "unknown option '$shown' (did you mean '$($h.Long)'?)"
        return
    }
    Add-LabParseError "unknown option '-$Bad' in '$shown'"
}

# Join-LabListWord FIRST: the value of a list option, FIRST, with the words
# that follow it joined on by commas while each one looks like a list item.
# The installed launcher is a .cmd file, and PowerShell hands a native
# command an unquoted a,b as the two words a and b, so a comma list reaches
# the runner in pieces. A phase word or a run ID never looks like an item, so
# the words after the list keep their meaning. Later list options (queue
# numbers and ranges) add their own kind of item here.
function Join-LabListWord {
    param([string] $First)
    $list = $First
    while ($script:ArgPos -lt $script:Arguments.Count) {
        $next = $script:Arguments[$script:ArgPos]
        if ($next -isnot [string] -or $next -cnotmatch $ReListItem) { break }
        $list += ',' + $next
        $script:ArgPos++
    }
    return $list
}

# Add-LabOption ROW SEP VAL: record the option in row ROW. SEP is the
# separator typed before VAL ('' when none); an option that takes a value and
# has none there takes the next word, unless that word looks like an option.
# -k and -u go without a value, and main lists the runs.
function Add-LabOption {
    param($Row, [string] $Sep, [string] $Val)
    $name = $Row.Name
    $show = $Row.Show
    if ($name -ceq 'help') {
        if ($Sep -ne '') { Add-LabParseError "$show takes no value"; return }
        $script:HelpAsked = $true
        return
    }
    $optional = ($name -ceq 'keep' -or $name -ceq 'undo')
    if ($Row.Value) {
        # '-Name value', or a session's '-Name:' with the value as the next word.
        if ($Sep -eq '' -or ($Sep -eq ':' -and $Val -eq '')) {
            $have = $script:ArgPos -lt $script:Arguments.Count
            $next = $null
            if ($have) { $next = $script:Arguments[$script:ArgPos] }
            if (-not $have -or ($next -is [string] -and $next -like '-?*')) {
                if (-not $optional) {
                    if (-not $have) { Add-LabParseError "$show needs a value" } else { Add-LabParseError "$show needs a value, but got '$next'" }
                    return
                }
            } else {
                $script:ArgPos++
                if ($next -is [Collections.IList]) {
                    # In a PowerShell session, a,b arrives as an array: it
                    # means the comma-separated list it was typed as.
                    $Val = (@($next) | ForEach-Object { [string] $_ }) -join ','
                } elseif ($optional -and $next -isnot [string]) {
                    # In a PowerShell session, 0123 arrives as the number 123,
                    # and the zeros cannot be told from a shorter ID. Only a
                    # number of four digits is surely what was typed.
                    $text = [string] $next
                    if ($next -is [int] -and $text.Length -eq 4) {
                        $Val = $text
                    } else {
                        Add-LabParseError "'$text' was read as a number: put it in quotes, like '0123'"
                        return
                    }
                } else {
                    $Val = [string] $next
                }
            }
        }
        if ($Val -eq '' -and -not $optional) { Add-LabParseError "$show needs a value"; return }
        if ($name -ceq 'approve') { $Val = Join-LabListWord $Val }
    } elseif ($Sep -ne '') {
        Add-LabParseError "$show takes no value"; return
    }
    if ($script:Given.ContainsKey($name)) { Add-LabParseError "$show is given twice"; return }
    $script:Given[$name] = $Val
    if ($Row.Action) { $script:Actions += $name }
}

# Read-LabArgument: sort the words into options ($script:Given,
# $script:Actions), requests for help ($script:HelpAsked) and the rest
# ($script:Words). Options may come anywhere; '--' ends them. A single dash
# before a long name (-Undo) is that name, and before anything else it is a
# stack of short letters, where a letter that takes a value comes last
# (docs/Conventions.md section 3.3).
function Read-LabArgument {
    $words = New-Object System.Collections.Generic.List[string]
    $ended = $false
    $script:ArgPos = 0
    while ($script:ArgPos -lt $script:Arguments.Count) {
        $a = $script:Arguments[$script:ArgPos]
        $script:ArgPos++
        if ($a -isnot [string]) {
            # In a PowerShell session, 0123 arrives as the number 123.
            # Reported with the rest, so the Try line names the action.
            Add-LabParseError "'$a' was read as a number: put it in quotes, like '0123'"
            continue
        }
        $w = [string] $a
        if ($ended) { $words.Add($w); continue }
        if ($w -ceq '--') { $ended = $true; continue }
        if ($w -ceq '-?' -or $w -ceq '/?') { $script:HelpAsked = $true; continue }
        if ($w -notlike '-?*') { $words.Add($w); continue }
        $key = $w.Substring(1)
        $long = $false
        if ($key.StartsWith('-')) { $long = $true; $key = $key.Substring(1) }
        $sep = ''
        $val = ''
        if ($key -match '^([^=:]*)([=:])(.*)$') {
            $key = $Matches[1]; $sep = $Matches[2]; $val = $Matches[3]
        }
        $lk = $key.ToLowerInvariant().Replace('-', '')
        $o = Find-LabOption $lk
        if ($long -or $null -ne $o) {
            if ($null -ne $o) { Add-LabOption $o $sep $val } else { Add-LabUnknownOption $w $lk }
            continue
        }
        # A stack of short letters. Check every letter before using any.
        $rows = @()
        $bad = ''
        foreach ($ch in $key.ToCharArray()) {
            $so = Find-LabShort ([string] $ch)
            if ($null -eq $so) { $bad = [string] $ch; break }
            $rows += $so
        }
        if ($key -eq '') { $bad = '-' }
        if ($bad -ne '') { Add-LabStackError $w $key $bad; continue }
        $last = $rows.Count - 1
        $early = $null
        for ($c = 0; $c -lt $last; $c++) {
            if ($rows[$c].Value) { $early = $rows[$c]; break }
        }
        if ($null -ne $early) {
            Add-LabParseError "$($early.Show) takes a value, so it must come last in '-$key'"
            continue
        }
        for ($c = 0; $c -lt $last; $c++) { Add-LabOption $rows[$c] '' '' }
        Add-LabOption $rows[$last] $sep $val
    }
    $script:Words = @($words)
}

# Show-LabHelpUnknown WORD HINT: a help topic that does not exist: one line,
# with a near miss if there is one, then the main help. Still exit 0.
function Show-LabHelpUnknown {
    param([string] $Word, [string] $Hint)
    $text = "No help for '$Word'"
    if ($Hint -ne '') { $text += " (did you mean '$Hint'?)" }
    [Console]::Out.WriteLine($text + '. Here is the main help.')
    Show-LabHelp ''
}

# Show-LabAskedHelp: the help the line asks for, and nothing else
# (docs/Conventions.md section 3.3). The topic is the first action typed,
# else the first word (a phase, 'basics', a module ID, or the long name of an
# action or option), else the first option that has a page. Called before
# anything is read.
function Show-LabAskedHelp {
    $topic = ''
    if ($script:Actions.Count -gt 0) {
        $topic = $script:Actions[0]
    } elseif ($script:Words.Count -gt 0) {
        $w = $script:Words[0].ToLowerInvariant()
        $lk = $w.Replace('-', '')
        if ($w.Contains('.')) { Show-LabModuleHelp $w; return }
        if ($lk -ceq 'basics' -or $Phases -ccontains $lk) {
            $topic = $lk
        } elseif ($lk -ceq 'help') {
            $topic = ''
        } else {
            $o = Find-LabOption $lk
            if ($null -ne $o) {
                $topic = $o.Name
            } else {
                $hint = Get-LabSuggestion $lk (@('basics') + $Phases + (Get-LabOptionKey))
                if ($hint -ne '') {
                    $h = Find-LabOption $hint
                    if ($null -ne $h) { $hint = $h.Name }
                }
                Show-LabHelpUnknown $script:Words[0] $hint
                return
            }
        }
    } else {
        foreach ($name in @('all', 'yes', 'no-revert', 'profile', 'root', 'config', 'break-glass', 'confirm-group', 'approve')) {
            if ($script:Given.ContainsKey($name)) { $topic = $name; break }
        }
    }
    Show-LabHelp $topic
}

# Select-LabTryTopic: what the Try line of a usage error puts before -h: the
# first action typed, else the phase typed.
function Select-LabTryTopic {
    $script:TryTopic = ''
    if ($script:Actions.Count -gt 0) { $script:TryTopic = Get-LabShow $script:Actions[0]; return }
    if ($script:Words.Count -gt 0) {
        $w = $script:Words[0].ToLowerInvariant()
        if ($Phases -ccontains $w) { $script:TryTopic = $w }
    }
}

# Exit-LabBadWord WORD: the usage error for a word that is not a phase. The
# long name of an action gets the real form; a near miss of a phase gets that.
function Exit-LabBadWord {
    param([string] $Word)
    $lc = $Word.ToLowerInvariant().Replace('-', '')
    $hint = ''
    if ($lc -ceq 'run') { $hint = "$Self -r PHASE" }
    elseif ($lc -ceq 'keep') { $hint = "$Self -k ID" }
    elseif ($lc -ceq 'undo') { $hint = "$Self -u ID" }
    elseif ($lc -ceq 'history') { $hint = "$Self -History" }
    elseif ($lc -ceq 'probe') { $hint = "$Self -Probe" }
    elseif ($lc -ceq 'newseed') { $hint = "$Self -NewSeed" }
    elseif ($lc -ceq 'seedcheck') { $hint = "$Self -SeedCheck" }
    elseif ($lc -ceq 'version') { $hint = "$Self -V" }
    elseif ($lc -ceq 'manual') { $hint = "$Self -Manual" }
    else { $hint = Get-LabSuggestion $Word.ToLowerInvariant() $Phases }
    $text = "'$Word' is not a phase."
    if ($hint -ne '') { $text += " Did you mean '$hint'?" }
    Exit-LabUsage $text 'The phases are lockout, observe, deceive and sustain.'
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

# Write-LabVersion: the version, the runner, and the release hash to
# compare with the team's offline record (design 21, section 5).
function Write-LabVersion {
    Write-LabLine "Labyrinth version $LabVersion ($LabUrl)"
    Write-LabLine "Runner:   PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-LabReleaseLine
}

# Write-LabReleaseLine: the release hash, as two lines of eight groups of
# four, or that it was not checked.
function Write-LabReleaseLine {
    if ($script:Release.Status -eq 'ok') {
        $groups = Get-LabReleaseGroup -Sha $script:Release.Hash
        Write-LabLine "SHA-256:  $($groups[0])"
        Write-LabLine "          $($groups[1])"
    } else {
        Write-LabLine 'SHA-256:  not checked (no release.sha256)'
    }
}

# Test-LabUndoAsked: does the line ask for -u? Read from the raw words, as
# nothing is parsed yet: -u alone or in a stack of letters, or the long name
# in any case, with one dash or two, with or without a value after = or :.
function Test-LabUndoAsked {
    foreach ($a in $script:Arguments) {
        if ($a -isnot [string]) { continue }
        if ($a -cmatch '^-[rkuVPhy]*u[rkuVPhy]*$' -or $a -match '^--?undo([=:].*)?$') { return $true }
    }
    return $false
}

# Exit-LabRelease: a file differs from the release list. A refused
# rollback leaves the changes in place, so whoever is logged in learns
# that, as from the revert timer (best effort); the core, which has
# Send-LabNotice, is not loaded, because it may be the file that differs.
function Exit-LabRelease {
    if (Test-LabUndoAsked) {
        $exe = Join-Path $env:SystemRoot 'System32\msg.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            try { $null = & $exe '*' '/TIME:900' "Labyrinth did not undo the changes on ${env:COMPUTERNAME}: its files differ from the release, so they are still in place." 2>$null } catch { $null = $_ }
        }
    }
    Exit-Lab "$($script:Release.Problem), so Labyrinth will not run" 20 "Copy Labyrinth here again from the team's copy, as manual section 11 says."
}

# How to get the rights a command needs, and how to mend a bad line.
$FixAdmin = "Run it again in PowerShell opened with 'Run as administrator'."
$FixLine = 'Correct that line, then run the same command again.'
$FixData = 'Check that the data folder is not full or read-only, then run the same command again.'
$FixServices = 'List the scored services there, one "name proto host port expect" per line.'

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
# It is a command to paste, so it is never wrapped, however long the path
# to the runner (docs/Conventions.md section 3.2).
function Write-LabMore {
    param([string] $Id)
    Write-LabLine ('  ' + 'More:'.PadRight(11) + "$Self -h $Id")
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

# Get-LabShortId RUN: the last 4 characters of a run ID, in quotes. PowerShell
# reads an unquoted 4e12 as a number, so a pasted command needs the quotes.
function Get-LabShortId {
    param([string] $RunId)
    return "'" + $RunId.Substring($RunId.Length - 4) + "'"
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
    $short = Get-LabShortId $env:LAB_RUN_ID
    if ($Mode -ceq 'apply' -and $script:Stopped -and $script:NoRevert) {
        Write-LabLine 'Next: undo the earlier changes with the command above, unless they should stay.'
    } elseif ($Mode -ceq 'apply' -and $script:Stopped) {
        Write-LabLine 'Next: undo the earlier changes, or keep them, with the commands above.'
    } elseif ($Mode -ceq 'apply' -and $script:Applied -and (Test-LabRevertTimer -RunId $env:LAB_RUN_ID)) {
        Write-LabLine "Next: check you can log in from a NEW session, then $Self -k $short."
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
        $hostsFile = Join-Path $env:LAB_CONFIG_DIR 'hosts'
        if ($other -eq 0) {
            Write-LabLine 'Next: a person carries out the manual steps above; -r changes nothing.'
        } elseif ($null -eq $script:HostEntry) {
            Write-LabLine 'Next: list this host in the hosts file, with its group and profile;'
            Write-LabLine "  -r needs it there: $hostsFile"
        } elseif ($script:Given.ContainsKey('profile') -and $script:Given['profile'] -cne $script:HostEntry.Profile) {
            Write-LabLine "Next: -r uses this host's profile in the hosts file, $($script:HostEntry.Profile)."
            Write-LabLine "  To run $($script:Given['profile']), change that line first: $hostsFile"
        } else {
            $opts = ''
            if ($script:Given.ContainsKey('profile')) { $opts += " -Profile $($script:Given['profile'])" }
            $opts += Get-LabDataOption
            # A command too long for one line goes on a line of its own.
            if (("$Self -r $Phase$opts").Length + 6 -gt 78) {
                Write-LabLine 'Next:'
                Write-LabLine "  $Self -r $Phase$opts"
            } else {
                Write-LabLine "Next: $Self -r $Phase$opts"
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
    elseif ($Code -eq 30) { $what = 'a check failed; that change was undone' }
    Write-LabLine ''
    if ($Mode -ceq 'plan' -or -not $script:Applied) {
        Write-LabSummary 'plan'
        Write-LabLine 'Nothing on this host was changed.'
    } else {
        Write-LabSummary 'apply'
        $problems = $script:Stopped -or @($script:Run | Where-Object { $_.State -ceq 'failed' -or $_.State -ceq 'error' }).Count -gt 0
        if ($problems) { Add-LabProblemMark }
        if ($script:NoRevert) { Write-LabLine 'Revert timer: none (-NoRevert).' }
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
    if ($script:NoRevert) {
        'The run stopped. Earlier changes stay: there is no revert timer (-NoRevert).'
        "To undo them now: $Self -u $(Get-LabShortId $env:LAB_RUN_ID)"
        return
    }
    'The run stopped. Earlier changes stay until the revert timer undoes them.'
    $when = Get-LabDueWord $env:LAB_RUN_ID
    if ($when -ne '') { "The revert timer undoes this run $when." }
    $short = Get-LabShortId $env:LAB_RUN_ID
    "To undo them now: $Self -u $short"
    "To keep them now: $Self -k $short"
    'If in doubt, undo them.'
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
            "To undo it: $Self -u $(Get-LabShortId $env:LAB_RUN_ID)")
    }
    $short = ''
    if ($script:RunRef -ne '') { $short = Get-LabShortId $script:RunRef }
    switch ($script:Command) {
        'rollback' {
            if ($short -ne '') { return @('The undo did not finish, and it is safe to repeat.', "Retry: $Self -u $short") }
            return 'Nothing was undone.'
        }
        'keep' {
            if ($short -ne '') { return @("The run may not be kept; '$Self -History' shows its state.", "Retry: $Self -k $short") }
            return 'Nothing was kept.'
        }
        'newseed' { return 'The decoy seed may or may not be saved; run -NewSeed again to be sure.' }
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
    if ($m.ContainsKey('pre_approvable')) {
        $cats = Get-LabListItem $m['pre_approvable']
        if ($null -eq $cats) { Write-YmlError $File 'pre_approvable must be a list'; return $false }
        if ($m['risk'] -cne 'approval') { Write-YmlError $File 'pre_approvable is only for approval modules'; return $false }
        foreach ($c in $cats) {
            if ($c -cnotmatch '^[a-z0-9-]+$') { Write-YmlError $File "not a category: $c"; return $false }
        }
    }
    if ($m.ContainsKey('keep_on_verify')) {
        if (@('true', 'false') -cnotcontains $m['keep_on_verify']) { Write-YmlError $File 'keep_on_verify must be true or false'; return $false }
        if ($m['keep_on_verify'] -ceq 'true' -and @('reversible', 'service-affecting', 'approval') -cnotcontains $m['risk']) {
            Write-YmlError $File 'keep_on_verify is only for a module that changes something'; return $false
        }
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
        if ($line -cnotmatch $ReModuleId) { Exit-Lab "${file}:${n}: not a module id: $line" 40 'Each line is one module ID, such as lockout.ssh-config. Correct it, then run the same command again.' }
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
        # function that called this one. Nothing is piped in: an entry point
        # never reads standard input (design 00), so it cannot take the
        # operator's answers.
        $file = Join-Path $Dir "$Entry.ps1"
        if ($Capture) {
            $script:EntryOut = @($null | & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 |
                    ForEach-Object { (ConvertTo-LabOutputText $_) -split "`r?`n" })
            $script:EntryRc = $LASTEXITCODE
            foreach ($l in $script:EntryOut) { if ($l.Trim() -ne '') { $script:EntryLast = $l } }
        } else {
            Add-LabLogLine "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Id $Entry started"
            $n = 0
            $null | & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | ForEach-Object {
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
        $preOk = @()
        if ($script:Mod.ContainsKey('pre_approvable')) { $preOk = Get-LabListItem $script:Mod['pre_approvable'] }
        $found += [pscustomobject]@{
            Id = $id; Dir = $dir; Risk = $script:Mod['risk']; Scored = ($script:Mod['touches_scored'] -eq 'true')
            Requires = $requires; Priority = $script:Mod['priority']; Rc = 0; State = 'planned'; Items = @()
            PreOk = $preOk; Keep = ($script:Mod.ContainsKey('keep_on_verify') -and $script:Mod['keep_on_verify'] -ceq 'true')
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
        if ($M.Risk -eq 'approval') {
            $preWords = @(Get-LabPreItem $M)
            if ($preWords.Count -gt 0) { Write-LabDetail 'Note' "pre-approved, so applied without asking: $(Get-LabItemList $preWords)" }
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

# Get-LabPreItem M: the items of approval module M that a pre-approval
# rule approves, as 'id@fingerprint' words, with this run's fingerprints.
# A rule counts only for a category the module's pre_approvable lists
# (docs/Conventions.md section 3.1).
function Get-LabPreItem {
    param($M)
    $words = @()
    foreach ($r in @($script:PreRules)) {
        if ($r.Module -cne $M.Id -or @($M.PreOk) -cnotcontains $r.Category) { continue }
        foreach ($i in @($M.Items)) {
            if ($i.Category -cne $r.Category) { continue }
            if ($r.Item -cne '*' -and $r.Item -cne $i.Id) { continue }
            if (@($words | Where-Object { $_.StartsWith("$($i.Id)@") }).Count -eq 0) { $words += "$($i.Id)@$($i.Fingerprint)" }
        }
    }
    return $words
}

# Get-LabItemList WORDS: the ids of 'id@fingerprint' words, comma-separated.
function Get-LabItemList {
    param([string[]] $Words)
    return (@($Words | ForEach-Object { $_.Substring(0, $_.LastIndexOf('@')) }) -join ', ')
}

# Write-LabPreUnmatched: after the plan, each pre-approval rule for a module
# in this run whose module.yml does not let that category be pre-approved is
# ignored, with a line saying so. Rules for other modules are for other
# hosts, and are passed over in silence.
function Write-LabPreUnmatched {
    $said = $false
    foreach ($r in @($script:PreRules)) {
        foreach ($m in $script:Run) {
            if ($m.Id -cne $r.Module -or @($m.PreOk) -ccontains $r.Category) { continue }
            if (-not $said) { Write-LabLine ''; $said = $true }
            Write-LabLine "Pre-approval ignored: $($r.Module) does not let category $($r.Category) be pre-approved: $($r.Module) $($r.Category) $($r.Item)"
        }
    }
}

# Read-LabPreRule: the pre-approval rules; a malformed file is an error,
# and a missing one approves nothing in advance.
function Read-LabPreRule {
    $rules = $null
    try { $rules = Read-LabPreApproved } catch { Exit-Lab "pre-approved is malformed: $($_.Exception.Message)" 40 $FixLine }
    $script:PreRules = @()
    if ($null -ne $rules) { $script:PreRules = @($rules) }
}

# Load and plan the phase's modules; return the worst code.
function Invoke-LabPlanAll {
    param([string] $Phase)
    $worst = Import-LabRunModule $Phase
    foreach ($m in $script:Run) {
        Invoke-LabPlanOne $m
        if ($m.Rc -gt $worst) { $worst = $m.Rc }
    }
    Write-LabPreUnmatched
    if ($script:PhaseCount -eq 0) {
        Write-LabStatus 'WARN' "Phase $Phase"
        Write-LabDetail 'Found' "profile $($script:ProfileName) lists no $Phase modules: nothing to check"
        Write-LabDetail 'Fix' "add $Phase modules to the profile, or preview another phase"
        Write-LabDetail 'More' "$Self -h basics"
    }
    return $worst
}

# Only administrators may be able to change Labyrinth's code, its
# configuration and its data root, because they run as SYSTEM, later too,
# by the revert timer (design 21, section 5).
function Assert-LabTrustedTree {
    if ($script:Release.Status -eq 'missing') {
        $script:PendingWarnings += "no release.sha256, so Labyrinth's files were not checked"
    }
    $bad = Find-LabUntrustedItem -Path @($env:LAB_ROOT, $env:LAB_CONFIG_DIR, $script:DataRoot)
    if ($null -ne $bad) {
        Exit-Lab "$bad can be changed by an account that is not an administrator, so Labyrinth will not run as SYSTEM from it" 20 `
            "Keep Labyrinth's folders owned by Administrators, with no other account allowed to change them, as under C:\ProgramData\Labyrinth."
    }
}

# The protected set must load and hold at least one account (design 03,
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
            Write-LabLine 'Before any change, check you can still get in if remote logins break.'
            Write-LabLine "Break-glass check: log in at this host's console with the break-glass"
            Write-LabLine 'account, then type its name here.'
            if (-not (Read-LabAnswer 'Break-glass account name: ')) {
                Exit-Lab 'no answer: break-glass not confirmed; nothing was changed' 20 'Run the same command again and answer the prompt, or name the account with -BreakGlass NAME.'
            }
            $account = $script:Answer
        }
        if (-not $script:Protected.ContainsKey($account) -or $script:Protected[$account] -cne 'breakglass') {
            Exit-Lab "break-glass not confirmed: '$(Get-LabSafeText $account)' is not listed with class breakglass in $(Join-Path $env:LAB_CONFIG_DIR 'protected-accounts'); nothing was changed" 20 'Name the account you logged in with at the console; that file lists it as "NAME breakglass".'
        }
        # Recorded only once the plan is confirmed (Assert-LabPlanConfirmed),
        # so a run that stops at the group prompt leaves nothing behind.
        $script:BreakGlassNew = $true
        Write-LabLine "Break-glass account ${account}: confirmed."
        # The answer is the operator's word. A session for the account at
        # the console backs it up; without one, the run goes on with a
        # warning, and the manifest says which it was.
        $session = Get-LabConsoleSession -Account $account
        if ($null -eq $session) {
            $script:BreakGlassNote = 'no console session found'
            Write-LabWarning "no session for $account was found at this host's console; check that the break-glass login works before relying on it"
        } elseif ($session -eq 'unknown') {
            $script:BreakGlassNote = 'console sessions could not be listed'
            Write-LabWarning 'this host cannot list console sessions, so the break-glass answer was not checked against one'
        } else {
            $script:BreakGlassNote = "console session $session"
        }
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
    if ($typed -cne $Group) {
        if ($typed -eq '') { $what = 'no group name was typed' } else { $what = "'$(Get-LabSafeText $typed)' was typed, not $Group" }
        Exit-Lab "the plan was not confirmed: $what; nothing was changed" 20 "Run the same command again and type $Group at the prompt, or give it with -ConfirmGroup $Group."
    }
    if ($script:BreakGlassNew) {
        try { Save-LabBreakGlass -Protected $script:Protected -Account $script:BreakGlassAccount }
        catch { Write-LabErrorLine $_.Exception.Message; Exit-Lab 'the break-glass answer could not be recorded; nothing was changed' 40 $FixData }
    }
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
    $run = Get-LabShortId $env:LAB_RUN_ID
    if ($rc -eq 0) {
        try {
            Add-LabEntryFor $Id 'rolled_back'
        } catch {
            Write-LabStatus 'ERROR' $name
            Write-LabDetail 'Problem' 'undone, but the manifest cannot be written'
            Write-LabDetail 'Found' 'the manifest still lists the change; undoing it again is safe'
            Write-LabDetail 'Fix' "run $Self -u $run again"
            Write-LabLogPath; Write-LabMore $Id
            return 40
        }
        if (-not $Inline) { Write-LabStatus 'OK' $name }
        Write-LabDetail 'Did' 'undone'
        Write-LabLogFor $Id 'warn' 'rolled_back' 'rolled back'
        return 0
    }
    Write-LabStatus 'ERROR' $name
    Write-LabDetail 'Problem' "its undo stopped with exit code $rc; the change may still be in place"
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
# section 3.1): those a pre-approval rule approves, then the -Approve
# entries that name the module when it was given, otherwise the ids and
# categories typed at the prompt, which is not asked when every item is
# pre-approved. An -Approve entry
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
    $script:Pre = @()
    $list = @()
    if (@($M.Items).Count -eq 0) {
        Write-LabStatus 'OK' $name
        Write-LabDetail 'Did' 'its plan listed no items to approve, so nothing changed'
        return 1
    }
    $script:Pre = @(Get-LabPreItem $M)
    $list += $script:Pre
    $rest = @()
    foreach ($i in $M.Items) {
        if (@($list | Where-Object { $_.StartsWith("$($i.Id)@") }).Count -eq 0) { $rest += $i }
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
    } elseif ($rest.Count -gt 0) {
        Write-LabLine "$name changes only the items you approve:"
        if ($script:Pre.Count -gt 0) { Write-LabDetail 'Approved' "$(Get-LabItemList $script:Pre) (pre-approved)" }
        foreach ($i in $rest) { Write-LabDetail 'Item' (Get-LabItemWord $i.Id $i.Category $i.Fingerprint $i.Reason) }
        Write-LabLine 'Type the ids of the items to approve, separated by spaces. To approve'
        Write-LabLine 'every item of a category, type category: and its name.'
        if (-not (Read-LabAnswer 'Items to approve (Enter for none): ')) { $script:Answer = '' }
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

# Write-LabChoice: under a module's status line, the items approved, each
# one a pre-approval rule approved marked so, and those left alone because
# they changed since the plan.
function Write-LabChoice {
    $ids = @($script:Approved -split ' ' | Where-Object { $_ -ne '' } | ForEach-Object {
            $word = $_.Substring(0, $_.LastIndexOf('@'))
            if (@($script:Pre) -ccontains $_) { $word += ' (pre-approved)' }
            $word
        })
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
        if ($tok -like '*:category:*') { Exit-LabUsage "-Approve takes no categories, only items: '$tok'" $fix }
        if ($tok -cnotmatch $ReApprove) { Exit-LabUsage "-Approve: not <module-id>:<item-id>@<fingerprint>: '$tok'" $fix }
    }
}

# Invoke-LabRecordPass: the recording pass of a run (design 00, section 4).
# Before the first change, each read-only module's check runs once more, with
# LAB_DRY_RUN=0, so that a module that only observes can write its own files
# under the state folder (the inventory, design 08, section 3.1). A preview
# never gets here. A module that fails is reported like any other and, with
# its state set, blocks only the modules that require it. Returns the worst
# exit code.
function Invoke-LabRecordPass {
    $worst = 0
    foreach ($m in $script:Run) {
        if ($m.Risk -ne 'read-only') { continue }
        if ($m.Rc -ne 0 -and $m.Rc -ne 10) { continue }
        $id = $m.Id
        $name = Get-LabModuleName $id
        try {
            Add-LabEntryFor $id 'record_start' '' 'read-only check, run with LAB_DRY_RUN=0'
        } catch {
            Write-LabStatus 'ERROR' $name
            Write-LabDetail 'Problem' 'not recorded: the run manifest cannot be written'
            Write-LabDetail 'Fix' "check that $($env:LAB_STATE_DIR) can be written, then run the same command again"
            Write-LabMore $id
            $m.State = 'error'; $worst = 40; continue
        }
        Invoke-LabEntry $m.Dir 'check' $id '0' -Capture
        $rc = $script:EntryRc
        if ($rc -eq 0 -or $rc -eq 10) {
            Write-LabStatus 'OK' $name
            if (@($script:EntryOut | Where-Object { $_.Trim() -ne '' }).Count -gt 0) { Show-LabOutput } else { Write-LabDetail 'Found' 'recorded nothing' }
            $m.State = 'done'
            try { Add-LabEntryFor $id 'recorded' '' 'wrote only under the state folder' } catch { $null = $_ }
        } elseif ($rc -eq 20) {
            Write-LabStatus 'BLOCKED' $name
            Write-LabExplain 'check' 20 (Join-Path $m.Dir 'check.ps1')
            Write-LabDetail 'Fix' 'clear what blocked it, then run the same command again'
            Write-LabMore $id
            $m.State = 'blocked'; $worst = [Math]::Max($worst, 20)
        } else {
            Write-LabStatus 'ERROR' $name
            Write-LabExplain 'check' $rc (Join-Path $m.Dir 'check.ps1')
            Write-LabDetail 'Fix' 'report the module to its author; the others still ran'
            Write-LabMore $id
            $m.State = 'error'; $worst = 40
        }
    }
    return $worst
}

function Invoke-LabApplyOne {
    param($M)
    $id = $M.Id
    $name = Get-LabModuleName $id
    $script:Approved = ''
    $script:Pre = @()
    if ($M.Risk -eq 'manual-only') {
        Write-LabStatus 'WARN' $name
        Write-LabDetail 'Found' 'this needs a person; Labyrinth changed nothing'
        Write-LabDetail 'Fix' 'carry out the steps its plan listed above'
        Write-LabMore $id
        $M.State = 'manual'; return 0
    }
    if ($M.Scored) {
        # A missing or empty list does not block: the list is optional (design 03,
        # section 7), and the firewall adapter checks that scored ports stay reachable.
        try { $null = Read-LabAddressList 'scoring-allowlist' }
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
    if ($M.Risk -ne 'read-only' -and -not $script:NoRevert) {
        try {
            $exe = (Get-Process -Id $PID).Path
            $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -u {1} -Root {2} -Config {3}' -f `
                (ConvertTo-LabCommandLineArgument (Join-Path $env:LAB_ROOT 'labyrinth.ps1')), $env:LAB_RUN_ID,
                (ConvertTo-LabCommandLineArgument $script:DataRoot), (ConvertTo-LabCommandLineArgument $env:LAB_CONFIG_DIR)
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
        if (@($script:Pre).Count -gt 0) { $note += ", pre-approved $($script:Pre -join ' ')" }
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
    # With no revert timer there is nothing for a module to be kept from.
    if ($M.Keep -and -not $script:NoRevert) { Save-LabModuleKept $id }
    $M.State = 'done'
    return 0
}

# Save-LabModuleKept ID: keep a keep_on_verify module that verified, so the
# revert timer leaves it alone (docs\Conventions.md section 3.1). Only when
# the scored services were tested, so that none is known to have got worse.
# A failure leaves the module under the timer, which is the safe side.
function Save-LabModuleKept {
    param([string] $Id)
    if (-not $script:HaveServices) {
        Write-LabDetail 'Note' 'not kept yet: with no service list, nothing shows that no scored service got worse, so the revert timer still covers it'
        return
    }
    try {
        Add-LabEntryFor $Id 'module_kept' '' 'verified; no scored service got worse'
    } catch {
        Write-LabDetail 'Note' 'not kept yet: the manifest cannot be written, so the revert timer still covers it'
        return
    }
    Write-LabDetail 'Did' 'kept: it verified and no scored service got worse, so the revert timer leaves it alone'
    Write-LabLogFor $Id 'info' 'module_kept' 'kept once verified'
}

# Get-LabUnkeptModule: the modules of the current run that a rollback
# started by the revert timer would still undo.
function Get-LabUnkeptModule {
    # The manifest readers return their list as one array, so it is taken
    # as it comes: @() around the call would wrap it in a second array.
    $kept = Get-LabKeptModule -RunId $env:LAB_RUN_ID
    $applied = Get-LabAppliedModule -RunId $env:LAB_RUN_ID
    return @($applied | Where-Object { $kept -cnotcontains $_ })
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
    Assert-LabConfigReadable
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

# Assert-LabConfigReadable: the configuration folder must exist, and it and
# every file in it must be readable. Without rights, Test-Path calls a file
# missing, which would make a gate look unset instead of unread.
function Assert-LabConfigReadable {
    $dir = $env:LAB_CONFIG_DIR
    $entries = $null
    try { $entries = [IO.Directory]::GetFileSystemEntries($dir) }
    catch [IO.DirectoryNotFoundException] {
        Exit-Lab "the configuration folder does not exist: $dir" 40 'Check -Root, or give the folder with the hosts file with -Config.'
    } catch {
        Exit-Lab "needs an elevated Administrator session to read $dir" 20 $FixAdmin
    }
    $profiles = Join-Path $dir 'profiles'
    if ([IO.Directory]::Exists($profiles)) {
        try { $entries = @($entries) + @([IO.Directory]::GetFileSystemEntries($profiles)) }
        catch { Exit-Lab "needs an elevated Administrator session to read $profiles" 20 $FixAdmin }
    }
    foreach ($f in @($entries)) {
        if ([IO.Directory]::Exists($f)) { continue }
        try { [IO.File]::OpenRead($f).Dispose() }
        catch { Exit-Lab "needs an elevated Administrator session to read $f" 20 $FixAdmin }
    }
}

function Find-LabThisHost {
    try { return Find-LabHost -Name (Get-LabHostName) } catch { Exit-Lab "the hosts file is malformed: $($_.Exception.Message)" 40 'Each line is: host group profile platform. Correct it, then run the same command again.' }
}

# Get-LabServiceMissing: why there is no service list, for a message.
function Get-LabServiceMissing {
    $file = Join-Path $env:LAB_CONFIG_DIR 'services'
    if (Test-Path -LiteralPath $file -PathType Leaf) { return "$file lists no service" }
    return "no service list at $file"
}

# Assert-LabServiceList: a malformed service list is an error before
# anything is asked, in plan and apply alike; a missing or empty one is not.
function Assert-LabServiceList {
    try { [void](Read-LabServiceList) } catch { Exit-Lab "the service list is malformed: $($_.Exception.Message)" 40 $FixLine }
}

function Invoke-LabPlanCommand {
    param([string] $Phase)
    $script:DryRun = '1'; $env:LAB_DRY_RUN = '1'
    $entry = Find-LabThisHost
    if ($script:ProfileName -eq '') {
        if ($null -eq $entry) { Exit-Lab "no profile: give -Profile, or list this host ($(Get-LabHostName)) in $(Join-Path $env:LAB_CONFIG_DIR 'hosts')" }
        $script:ProfileName = $entry.Profile
    }
    $script:HostEntry = $entry
    Read-LabProfile $script:ProfileName
    Read-LabSetting
    Read-LabPreRule
    Assert-LabServiceList
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
            Write-LabLine "Host $hostName is not in the hosts file; -r needs it there."
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
    $kept = $false
    Write-LabLine ''
    Write-LabLine "About to apply on host $HostName, group ${Group}:"
    Write-LabReleaseLine
    foreach ($m in $script:Run) {
        $what = ''
        if ($m.Rc -eq 10 -and $m.Risk -eq 'manual-only') { $what = 'Manual:' }
        elseif ($m.Rc -eq 10) {
            $what = 'Will change:'
            if ($m.Risk -eq 'service-affecting') { $remote = $true }
            if ($m.Keep) { $kept = $true }
        }
        elseif ($m.Rc -eq 20) { $what = 'Blocked:' }
        if ($what -ne '') { Write-LabLine ('  {0}{1}' -f $what.PadRight(13), (Get-LabModuleName $m.Id)) }
    }
    if ($script:NoRevert) {
        Write-LabLine 'No revert timer (-NoRevert): the changes stay until you undo them.'
    } else {
        Write-LabLine "A revert timer undoes this run in $($script:Settings['REVERT_MINUTES']) minutes unless you keep it."
    }
    if ($kept -and -not $script:NoRevert) {
        Write-LabLine 'A change that only takes access away is kept once it verifies; the timer'
        Write-LabLine 'then leaves it alone.'
    }
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
    if (-not (Test-LabAdmin)) { Exit-Lab '-r needs an elevated Administrator session' 20 $FixAdmin }
    # Before any configuration under the root is trusted.
    try { Protect-LabDataRoot -Path $script:DataRoot } catch { Exit-Lab "$($_.Exception.Message); nothing was changed" 20 }
    Assert-LabTrustedTree
    $entry = Find-LabThisHost
    if ($null -eq $entry) { Exit-Lab 'this host is not in the hosts file, so its group is unknown' 20 "Add the line '$hostName <group> <profile> <platform>' to $(Join-Path $env:LAB_CONFIG_DIR 'hosts')" }
    $group = $entry.Group
    if ($group -eq 'manual') { Exit-Lab 'this host is in the manual group: Labyrinth never changes it' 20 'Configure it by hand, from its runbook.' }
    if ($script:ProfileName -ne '' -and $script:ProfileName -cne $entry.Profile) {
        Exit-Lab "the hosts file gives this host profile $($entry.Profile), not $($script:ProfileName)" 40 "Leave out -Profile, or change this host's line in $(Join-Path $env:LAB_CONFIG_DIR 'hosts')."
    }
    $script:HostEntry = $entry
    $script:ProfileName = $entry.Profile
    Read-LabProfile $script:ProfileName
    Read-LabSetting
    Read-LabPreRule
    Assert-LabServiceList
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
        if ($worst -ge 40) {
            Write-LabLine ''
            Write-LabLine 'The plan has errors, so the run stops here.'
            Exit-LabRun 'apply' $worst $Phase
        }
        if ($script:Given.ContainsKey('approve')) { Write-LabApproveUnmatched }
        $todo = @($script:Run | Where-Object { $_.Rc -eq 10 -and $_.Risk -ne 'manual-only' }).Count
        $record = @($script:Run | Where-Object { $_.Risk -eq 'read-only' -and ($_.Rc -eq 0 -or $_.Rc -eq 10) }).Count
        if ($todo -eq 0 -and $record -eq 0) {
            Write-LabLine ''
            Write-LabLine 'There is nothing to apply: no module needs a change Labyrinth can make.'
            Exit-LabRun 'apply' $worst $Phase
        }

        # With changes to make the operator confirms them. A run that only
        # records (read-only modules writing under the state folder) asks nothing.
        if ($todo -gt 0) {
            Assert-LabBreakGlass
            Write-LabRecap $hostName $group
            Assert-LabPlanConfirmed $group
        }

        # From here on, files are written: everything is recorded first.
        $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
        try {
            New-Item -ItemType Directory -Force -Path (Get-LabRunDir $env:LAB_RUN_ID) | Out-Null
            if ($todo -gt 0) { New-Item -ItemType Directory -Force -Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) | Out-Null }
        } catch { Exit-Lab 'the run and backup folders cannot be created; nothing was changed' 40 }
        try {
            Add-LabEntryFor '' 'run_start' $hostName "phase $Phase, profile $($script:ProfileName), group $group"
            if ($todo -gt 0) { Add-LabEntryFor '' 'breakglass_verified' $script:BreakGlassAccount $script:BreakGlassNote }
            if ($script:NoRevert -and $todo -gt 0) { Add-LabEntryFor '' 'run_no_revert' '' 'no revert timer: -NoRevert' }
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Exit-Lab 'the run manifest cannot be written; nothing was changed' 40 $FixData
        }
        $script:RunOpen = $true
        if ($todo -gt 0) { $script:Applied = $true }
        Open-LabRunLog "apply $Phase, run $env:LAB_RUN_ID, host $hostName"
        Write-LabLog -Level info -EventName run_start -Message "apply $Phase, profile $($script:ProfileName), group $group"

        # The recording pass runs before the first change (design 00, section 4).
        Write-LabLine ''
        $recordWorst = Invoke-LabRecordPass
        if ($recordWorst -gt $worst) { $worst = $recordWorst }
        if ($todo -eq 0) {
            Write-LabLine ''
            Write-LabLine 'There is nothing to apply: no module needs a change Labyrinth can make.'
            if ($recordWorst -ge 40) { Add-LabProblemMark }
            Exit-LabRun 'apply' $worst $Phase
        }
        $services = $null
        try { $services = Read-LabServiceList } catch { Exit-Lab "the service list is malformed; nothing was changed: $($_.Exception.Message)" 40 $FixLine }
        Write-LabLine ''
        if ($null -ne $services) {
            $script:HaveServices = $true
            $script:Before = Get-LabProbeNow
            [IO.File]::WriteAllText((Join-Path (Get-LabRunDir $env:LAB_RUN_ID) 'probes-before'), (($script:Before -join "`n") + "`n"))
            Write-LabLine 'Scored services before any change:'
            Write-LabProbeLine $script:Before
        } else {
            Write-LabLine "No scored service is tested: $(Get-LabServiceMissing)"
        }
        Write-LabLine ''

        $worst = $recordWorst
        $stopped = $false
        foreach ($m in $script:Run) {
            if ($m.Rc -eq 20) { $worst = [Math]::Max($worst, 20); $m.State = 'blocked'; continue }
            if ($m.Rc -ne 10) {
                if ($m.State -ceq 'planned') { $m.State = 'done' }
                continue
            }
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
    } elseif ($script:NoRevert) {
        Write-LabLine 'All changes are applied and verified. There is no revert timer (-NoRevert),'
        Write-LabLine "so they stay. To undo them: $Self -u $(Get-LabShortId $env:LAB_RUN_ID)"
    } elseif ((Test-LabRevertTimer -RunId $env:LAB_RUN_ID) -and @(Get-LabUnkeptModule).Count -eq 0) {
        # Every change was kept once verified: the timer has nothing to undo.
        Write-LabLine 'All changes are applied, verified and kept.'
        $rc = Invoke-LabKeep
        if ($rc -gt $worst) { $worst = $rc }
    } elseif (Test-LabRevertTimer -RunId $env:LAB_RUN_ID) {
        Write-LabLine 'All changes are applied and verified.'
        Write-LabLine 'From a NEW session, check that you can still log in.'
        $when = Get-LabDueWord $env:LAB_RUN_ID
        if ($when -ne '') { Write-LabLine "The revert timer undoes this run $when." }
        $ok = Read-LabAnswer 'Type keep to keep the changes, or press Enter to leave them to the timer: '
        if ($ok -and $script:Answer -ceq 'keep') {
            $rc = Invoke-LabKeep
            if ($rc -gt $worst) { $worst = $rc }
        } else {
            $short = Get-LabShortId $env:LAB_RUN_ID
            Write-LabLine "Not kept. To keep later: $Self -k $short"
            Write-LabLine "To undo now: $Self -u $short"
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
            Write-LabErrorLine "labyrinth: too late: run $env:LAB_RUN_ID was already undone"
            Write-LabErrorLine 'Its changes are gone. Preview and run it again if you still want them.'
            return 20
        }
        # A -NoRevert run has no timer to cancel, and stays 'no revert'.
        if (@(Get-LabManifestEntry | Where-Object { $_.action -ceq 'run_no_revert' }).Count -gt 0) {
            Write-LabLine "nothing to keep: run $env:LAB_RUN_ID has no revert timer (-NoRevert), so its changes stay"
            return 0
        }
        try {
            Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
        } catch {
            Write-LabErrorLine $_.Exception.Message
            $when = Get-LabDueWord $env:LAB_RUN_ID
            if ($when -ne '') { $when = " $when" }
            Write-LabErrorLine "labyrinth: the revert timer for run $env:LAB_RUN_ID could not be cancelled"
            Write-LabErrorLine "The run is not kept, and the timer still undoes it$when."
            Write-LabErrorLine "Retry: $Self -k $(Get-LabShortId $env:LAB_RUN_ID)"
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
# back, kept, no revert (run with -NoRevert), armed (with when the timer
# fires), or not kept, no timer.
function Get-LabRunState {
    param([string] $RunId)
    $entries = @(Get-LabManifestEntry -RunId $RunId)
    $rolled = @($entries | Where-Object { $_.action -ceq 'run_rolled_back' })
    if ($rolled.Count -gt 0) {
        if ($rolled[-1].note -ceq 'exit 0') { return 'undone' }
        return 'undone with errors'
    }
    if (@($entries | Where-Object { $_.action -ceq 'run_kept' }).Count -gt 0) { return 'kept' }
    if (@($entries | Where-Object { $_.action -ceq 'run_no_revert' }).Count -gt 0) { return 'no revert' }
    if (Test-LabRevertTimer -RunId $RunId) {
        $due = Get-LabRevertTimerDue -RunId $RunId
        if ($due -eq '') { return 'armed: undo time unknown' }
        # The times are UTC in one fixed format, so they compare as strings.
        $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        if ([string]::CompareOrdinal($due, $now) -gt 0) { return "armed: undo at $($due.Substring(11, 5)) UTC" }
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
    if (-not (Test-LabAdmin)) { Exit-Lab '-History needs an elevated Administrator session' 20 $FixAdmin }
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
    Write-LabLine "Name a run by its last 4 characters, in quotes, like $Self -k $(Get-LabShortId $example)."
    $problems = @($runs | Where-Object { Test-Path -LiteralPath (Join-Path (Get-LabRunDir $_) 'problems') -PathType Leaf })
    if ($problems.Count -gt 0) {
        Write-LabLine ''
        Write-LabLine 'These runs had problems; their logs say what happened:'
        foreach ($id in $problems) {
            Write-LabLine ('  {0}  {1}' -f (Get-LabShortId $id), (Join-Path (Get-LabRunDir $id) 'output.log'))
        }
    }
    exit 0
}

# Resolve-LabRunId REF: the full run ID REF names. REF is a full ID, or its
# last 4 characters if they match exactly one run.
function Resolve-LabRunId {
    param([string] $Ref)
    if ($Ref -cmatch $ReRunId) {
        $manifest = Join-Path (Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $Ref) 'manifest.jsonl'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Exit-LabUsage "no run $Ref on this host" "'$Self -History' lists them." }
        return $Ref
    }
    $suffix = $Ref.ToLowerInvariant()
    $hits = @(Get-LabRunList | Where-Object { $_.EndsWith("-$suffix", [StringComparison]::Ordinal) })
    if ($hits.Count -eq 0) { Exit-LabUsage "no run ending in '$Ref' on this host" "'$Self -History' lists them." }
    if ($hits.Count -gt 1) { Exit-LabUsage "'$Ref' ends more than one run; give the full ID" "'$Self -History' lists them." }
    Write-LabLine "using run $($hits[0])"
    return $hits[0]
}

function Invoke-LabKeepCommand {
    param([string] $Ref)
    $script:DryRun = '0'; $env:LAB_DRY_RUN = '0'
    if ($Ref -eq '') {
        # -k always needs a run (section 3.3): list the armed ones, keep none.
        $need = '-k needs a run ID, or its last 4 characters'
        if (-not (Test-LabAdmin)) { Exit-LabUsage $need "As Administrator, '$Self -History' lists them." }
        Assert-LabTrustedTree
        $armed = @(Get-LabArmedRun)
        if ($armed.Count -eq 0) { Exit-LabUsage $need 'No run on this host has an armed revert timer.' }
        foreach ($l in (Get-LabRunTable $armed)) { [Console]::Error.WriteLine($l) }
        Exit-LabUsage $need 'These runs have an armed revert timer; pick one from the list above.'
    }
    if (-not (Test-LabAdmin)) { Exit-Lab '-k needs an elevated Administrator session' 20 $FixAdmin }
    Assert-LabTrustedTree
    $env:LAB_RUN_ID = Resolve-LabRunId $Ref
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" 40 "'$Self -History' lists them." }
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
        # -u always needs a run (decision D3): list them, change nothing.
        $need = '-u needs a run ID, or its last 4 characters'
        if (-not (Test-LabAdmin)) { Exit-LabUsage $need "As Administrator, '$Self -History' lists them." }
        Assert-LabTrustedTree
        $runs = @(Get-LabRunList)
        if ($runs.Count -eq 0) { Exit-LabUsage $need 'There are no runs on this host.' }
        foreach ($l in (Get-LabRunTable $runs)) { [Console]::Error.WriteLine($l) }
        Exit-LabUsage $need 'Pick one from the list above.'
    }
    if (-not (Test-LabAdmin)) { Exit-Lab '-u needs an elevated Administrator session' 20 $FixAdmin }
    Assert-LabTrustedTree
    $env:LAB_RUN_ID = Resolve-LabRunId $Ref
    $script:RunRef = $env:LAB_RUN_ID
    if (-not (Test-Path -LiteralPath (Get-LabManifestPath) -PathType Leaf)) { Exit-Lab "no run $env:LAB_RUN_ID on this host" 40 "'$Self -History' lists them." }
    Write-LabPendingWarning
    # -All asks only when it would undo more than -u alone: a module kept
    # once verified.
    if ($script:Given.ContainsKey('all') -and (Get-LabKeptModule -RunId $env:LAB_RUN_ID).Count -gt 0) { Confirm-LabUndoAll }
    # The revert timer must work even if a run still holds the lock, hung or
    # waiting at a prompt. That run is stopped first: rolling back beside it
    # would undo changes while it goes on making them and reports success.
    $locked = Enter-LabLock -WaitSeconds 10
    if (-not $locked) {
        [void](Close-LabLockHolder -WaitSeconds 30)
        $locked = Enter-LabLock -WaitSeconds 10
    }
    if (-not $locked) { [Console]::Error.WriteLine('labyrinth: warning: undoing without the run lock') }
    try {
        $rc = 0
        $ok = 0
        $bad = 0
        $mods = Get-LabAppliedModule -RunId $env:LAB_RUN_ID
        # Modules kept once verified stay, unless -All (section 3.1).
        $left = @()
        if (-not $script:Given.ContainsKey('all')) {
            $kept = Get-LabKeptModule -RunId $env:LAB_RUN_ID
            $left = @($mods | Where-Object { $kept -ccontains $_ })
            $mods = @($mods | Where-Object { $kept -cnotcontains $_ })
        }
        # A rollback started by the revert timer is logged too, though no
        # one watches it.
        Open-LabRunLog "undo run $env:LAB_RUN_ID"
        Write-LabLine "labyrinth ${LabVersion}: undo run $env:LAB_RUN_ID"
        if ($left.Count -gt 0) {
            Write-LabLine 'Kept once verified, so left in place (add -All to undo these too):'
            foreach ($id in $left) {
                Import-LabModuleTitle $id
                Write-LabLine "  $(Get-LabModuleName $id)"
            }
        }
        if ($mods.Count -eq 0 -and $left.Count -gt 0) { Write-LabLine 'Nothing else needs undoing.' }
        elseif ($mods.Count -eq 0) { Write-LabLine 'This run changed nothing that needs undoing.' }
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
            Write-LabErrorLine "labyrinth: warning: the revert timer for run $env:LAB_RUN_ID could not be removed"
            Write-LabErrorLine 'When it fires, it repeats this undo, which is safe.'
        }
        try {
            Add-LabEntryFor '' 'run_rolled_back' '' "exit $rc"
        } catch {
            Write-LabErrorLine $_.Exception.Message
            Write-LabErrorLine 'labyrinth: the changes are undone, but the manifest cannot be written to record it'
            $rc = 40
        }
        Write-LabLogFor '' 'warn' 'run_rolled_back' "run rolled back, exit $rc"
        if ($ok + $bad -gt 0) {
            # Whoever is logged in learns that changes were undone; best effort.
            [void](Send-LabNotice -Message "Labyrinth undid run $env:LAB_RUN_ID on $(Get-LabHostName): its changes are undone. See '$Self -History'.")
        }
        Write-LabLine ''
        $parts = @()
        if ($ok -gt 0) { $parts += "$ok OK" }
        if ($bad -gt 0) { $parts += "$bad ERROR" }
        if ($ok + $bad -eq 0) { Write-LabLine 'Summary: no changes to undo.' }
        elseif ($ok + $bad -eq 1) { Write-LabLine "Summary: 1 module: $($parts -join ', ')." }
        else { Write-LabLine "Summary: $($ok + $bad) modules: $($parts -join ', ')." }
        if ($script:LogFile -ne '') { Write-LabLine "Log: $($script:LogFile)" }
        if ($rc -eq 0) {
            Write-LabLine 'undo finished: exit 0 (undone)'
        } else {
            Add-LabProblemMark
            Write-LabLine 'Next: fix what is listed above, then undo it again; it is safe:'
            Write-LabLine "  $Self -u $(Get-LabShortId $env:LAB_RUN_ID)"
            Write-LabLine "undo finished: exit $rc (error)"
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
    Assert-LabServiceList
    if ($null -eq (Read-LabServiceList)) { Exit-Lab (Get-LabServiceMissing) 20 $FixServices }
    $out = Get-LabProbeResult -Timeout $script:Settings['PROBE_TIMEOUT']
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
        Write-LabLine "Next: bring the failed service back, then run '$Self -Probe' again."
        Write-LabLine 'probe finished: exit 30 (a service failed)'
        exit 30
    }
    if ($n['FAIL'] -gt 1) {
        Write-LabLine "Next: bring the failed services back, then run '$Self -Probe' again."
        Write-LabLine "probe finished: exit 30 ($($n['FAIL']) services failed)"
        exit 30
    }
    Write-LabLine 'probe finished: exit 0 (no service failed)'
    exit 0
}

# Get-LabDataOption: the -Root and -Config the line gave, for a command to
# paste.
function Get-LabDataOption {
    $opts = ''
    if ($script:Given.ContainsKey('root')) { $opts += " -Root $(ConvertTo-LabShellWord $script:Given['root'])" }
    if ($script:Given.ContainsKey('config')) { $opts += " -Config $(ConvertTo-LabShellWord $script:Given['config'])" }
    return $opts
}

# Invoke-LabStatusCommand: what typing the name alone shows
# (docs/Conventions.md section 3.1): the host, its group and profile, the
# latest run of each phase, any armed revert timer, and the one command to
# run next. It only reads, and always exits 0, even on a host with no
# configuration yet.
function Invoke-LabStatusCommand {
    if (-not (Test-LabAdmin)) {
        Show-LabHelp '' 4
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('The status of this host needs an elevated Administrator session:')
        [Console]::Out.WriteLine("open PowerShell with 'Run as administrator', then run $Self.")
        [Console]::Out.WriteLine("'$Self -h' lists every action.")
        exit 0
    }
    $opts = Get-LabDataOption
    $hostName = Get-LabHostName
    $hostsFile = Join-Path $env:LAB_CONFIG_DIR 'hosts'
    $why = ''
    $entry = $null
    [Console]::Out.WriteLine("labyrinth ${LabVersion}: status of host $hostName")
    if (-not (Test-Path -LiteralPath $hostsFile -PathType Leaf)) {
        $why = 'missing'
        [Console]::Out.WriteLine("Group:    unknown: there is no $hostsFile yet")
    } else {
        try { $entry = Find-LabHost -Name $hostName } catch { $why = 'malformed' }
        if ($why -ceq 'malformed') {
            [Console]::Out.WriteLine("Group:    unknown: $hostsFile is malformed")
        } elseif ($null -eq $entry) {
            $why = 'unlisted'
            [Console]::Out.WriteLine("Group:    unknown: this host is not in $hostsFile")
        } else {
            [Console]::Out.WriteLine("Group:    $($entry.Group), profile $($entry.Profile)")
        }
    }
    $latest = @{}
    foreach ($id in @(Get-LabRunList)) { $latest[(Get-LabRunPhase $id)] = $id }
    foreach ($p in $Phases) {
        if ($latest.ContainsKey($p)) {
            $id = $latest[$p]
            $start = '{0}-{1}-{2} {3}:{4}' -f $id.Substring(0, 4), $id.Substring(4, 2), $id.Substring(6, 2), $id.Substring(9, 2), $id.Substring(11, 2)
            [Console]::Out.WriteLine(('{0,-9} {1} (run {2}, {3} UTC)' -f $p, (Get-LabRunState $id), $id.Substring($id.Length - 4), $start))
        } else {
            [Console]::Out.WriteLine(('{0,-9} not run' -f $p))
        }
    }
    $armed = @(Get-LabArmedRun)
    if ($armed.Count -eq 0) { [Console]::Out.WriteLine('Timer:    none armed') }
    foreach ($id in $armed) {
        $when = Get-LabDueWord $id
        if ($when -eq '') { $when = 'at a time not known' }
        [Console]::Out.WriteLine("Timer:    run $($id.Substring($id.Length - 4)) is undone $when")
    }
    # The next step: the first that applies.
    $next = ''
    if ($why -ceq 'missing' -or $why -ceq 'unlisted') { $next = "list this host in $hostsFile, then run $Self$opts again." }
    elseif ($why -ceq 'malformed') { $next = "correct $hostsFile, then run $Self$opts again." }
    if ($next -eq '' -and $armed.Count -gt 0) {
        $next = "check you can log in from a NEW session, then $Self -k $(Get-LabShortId $armed[-1])$opts."
    }
    if ($next -eq '' -and $null -ne $entry -and $entry.Group -ceq 'manual') {
        $next = 'none: this host is in the manual group; configure it by hand, from its runbook.'
    }
    if ($next -eq '') {
        foreach ($p in $Phases) {
            if (-not $latest.ContainsKey($p) -or (Get-LabRunState $latest[$p]) -like 'undone*') {
                $next = "preview ${p}: $Self $p$opts"
                break
            }
        }
    }
    if ($next -eq '') { $next = "test the scored services: $Self -Probe$opts" }
    [Console]::Out.WriteLine("Next: $next")
    exit 0
}

# ConvertFrom-LabManualSource LINES: the Windows text of the manual's
# Markdown source, as tools/manual/split.sh makes it: Linux blocks and
# comment blocks dropped, the placeholders filled in.
function ConvertFrom-LabManualSource {
    param([string[]] $Lines)
    $block = ''
    $note = $false
    foreach ($l in $Lines) {
        if ($note) { if ($l -ceq '-->') { $note = $false }; continue }
        if ($l -ceq '<!--') { $note = $true; continue }
        if ($l -cmatch '^<!-- (linux|windows) -->$') { $block = $Matches[1]; continue }
        if ($l -ceq '<!-- end -->') { $block = ''; continue }
        if ($block -ceq 'linux') { continue }
        $l.Replace('@CMD@', '.\labyrinth.ps1').Replace('@ROOT@', 'C:\ProgramData\Labyrinth').Replace('@ADMIN@', 'an Administrator').Replace('@MANUAL@', 'for Windows')
    }
}

# Show-LabManual: the full manual, one screen at a time (docs/Conventions.md
# section 3.1): the help topic from this copy's manual folder, else the
# installed one, else the Markdown source; printed when the output is not a
# console. It changes nothing and needs no Administrator; it exits 0, or 40
# when this copy has no manual at all.
function Show-LabManual {
    $candidates = @(Join-Path $PSScriptRoot 'manual\about_Labyrinth.help.txt')
    if ("$env:ProgramFiles" -ne '') {
        $candidates += Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Labyrinth\en-US\about_Labyrinth.help.txt'
    }
    $candidates += Join-Path $PSScriptRoot 'docs\manual\labyrinth.md'
    $file = ''
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $file = $c; break }
    }
    if ($file -eq '') { Exit-Lab "this copy has no manual: there is no $($candidates[0])" 40 "Copy Labyrinth here again from the team's copy, which has it." }
    $lines = [IO.File]::ReadAllLines($file)
    if ($file -like '*.md') { $lines = ConvertFrom-LabManualSource $lines }
    if (-not [Console]::IsOutputRedirected) {
        # A host with no paging, such as the ISE, prints the manual instead;
        # quitting the pager part way ends here, without printing it again.
        try {
            $lines | Out-Host -Paging
        } catch [System.Management.Automation.PipelineStoppedException], [System.Management.Automation.HaltCommandException] {
            exit 0
        } catch {
            foreach ($l in $lines) { [Console]::Out.WriteLine($l) }
        }
        exit 0
    }
    foreach ($l in $lines) { [Console]::Out.WriteLine($l) }
    exit 0
}

# Invoke-LabNewSeedCommand: make this host's decoy seed (design 16, section
# 4.1). It needs an Administrator and a console, and checks both before it
# makes or saves anything. The seed is saved as DECOY_SEED in seed.conf, then
# shown once on the console until the operator types 'recorded'. If the
# console goes first, nobody recorded it, so the file goes back as it was.
# The seed reaches only the console and the file: never standard output or
# the log.
function Invoke-LabNewSeedCommand {
    if (-not (Test-LabAdmin)) { Exit-Lab '-NewSeed needs an elevated Administrator session' 20 $FixAdmin }
    if (-not (Test-LabTerminal)) {
        Exit-Lab '-NewSeed needs a terminal to show the seed on' 20 'Run it from a terminal, such as the console or a remote session.'
    }
    if (-not (Test-Path -LiteralPath $env:LAB_CONFIG_DIR -PathType Container)) {
        Exit-Lab "the configuration folder does not exist: $env:LAB_CONFIG_DIR" 40 'Check -Root, or give the folder with -Config.'
    }
    Write-LabPendingWarning
    $file = Get-LabSeedFile
    $old = $null
    try {
        $old = Read-LabSeed -Key 'DECOY_SEED'
    } catch {
        Exit-Lab "$file cannot be read, or its DECOY_SEED is not a valid seed" 40 'Correct or remove that file, then run the same command again.'
    }
    if ($old -and -not $script:Given.ContainsKey('yes')) {
        Write-LabTerminal "This host already has a decoy seed. Replace it? The decoys made from the`n"
        Write-LabTerminal 'old one must be made again. [y/N] '
        $answer = Read-LabTerminal
        if ($null -eq $answer -or $answer.Trim() -notmatch '^(y|yes)$') {
            [Console]::Out.WriteLine('Nothing was changed.')
            exit 0
        }
    }
    $hostName = Get-LabHostName
    $seed = Get-LabRandomSeed
    try {
        Save-LabSeed -Key 'DECOY_SEED' -Seed (ConvertTo-LabSeed $seed)
    } catch {
        $seed = $null
        Exit-Lab "the seed could not be saved in $file" 40 $FixData
    }
    # Ctrl+C or a dropped session before 'recorded' undoes the save as well,
    # through the finally block: nobody recorded that seed.
    $recorded = $false
    try {
        $recorded = ((Show-LabSeed -Label $hostName -Seed $seed) -eq 0)
    } finally {
        $seed = $null
        if (-not $recorded) {
            try {
                Save-LabSeed -Key 'DECOY_SEED' -Seed $(if ($old) { $old } else { '' })
            } catch {
                [Console]::Error.WriteLine("labyrinth: $file could not be put back as it was; check its DECOY_SEED")
            }
            $old = $null
        }
    }
    if (-not $recorded) {
        Exit-Lab 'the seed was not recorded, so it was not saved' 20 'Run the same command again from a terminal.'
    }
    $old = $null
    [Console]::Out.WriteLine("Saved this host's decoy seed in $file.")
    [Console]::Out.WriteLine("Post it in the team chat with this host's name: $hostName.")
}

# Invoke-LabSeedCheckCommand: say whether a seed typed at a visible prompt is
# valid. It reads no configuration and needs no Administrator, so it works on
# any machine with Labyrinth. The seed is never taken from the command line
# or standard input, and the message about a bad one never repeats it.
function Invoke-LabSeedCheckCommand {
    if (-not (Test-LabTerminal)) {
        Exit-Lab '-SeedCheck needs a terminal to type the seed at' 20 'Run it from a terminal, such as the console or a remote session.'
    }
    Write-LabTerminal 'Seed to check: '
    $typed = Read-LabTerminal
    if ($null -eq $typed) {
        Write-LabTerminal "`n"
        Exit-Lab 'the terminal went before a seed was typed' 20
    }
    try {
        [void](ConvertTo-LabSeed $typed)
    } catch {
        $typed = $null
        [Console]::Out.WriteLine($_.Exception.Message)
        [Console]::Out.WriteLine('Check it against the offline record and type it again.')
        exit 30
    }
    $typed = $null
    [Console]::Out.WriteLine('Valid seed: the check group matches.')
    exit 0
}

# Confirm-LabUndoAll: the question before -u ID -All, which also undoes
# changes kept once verified (docs/Conventions.md section 3.1). The default
# is no; -y answers yes. Without a terminal and without -y, nothing is
# undone (40).
function Confirm-LabUndoAll {
    if ($script:Given.ContainsKey('yes')) { return }
    $short = Get-LabShortId $env:LAB_RUN_ID
    if (-not (Test-LabTerminal)) {
        Write-LabErrorLine 'labyrinth: -u -All asks first, and there is no terminal to ask on'
        Write-LabErrorLine "Nothing was undone. To answer yes, add -y: $Self -u $short -All -y"
        exit 40
    }
    Write-LabTerminal "Undo run $($env:LAB_RUN_ID.Substring($env:LAB_RUN_ID.Length - 4)) with -All? It also undoes changes kept once verified,`n"
    Write-LabTerminal 'such as a new password, which can give an intruder access back. [y/N] '
    $answer = Read-LabTerminal
    if ($null -eq $answer -or $answer.Trim() -notmatch '^(y|yes)$') {
        [Console]::Out.WriteLine('Nothing was undone.')
        exit 0
    }
}

try {
    # The release check (design 21, section 5) comes before any of the
    # core is loaded, so a changed core file never runs. A file that
    # differs from release.sha256 stops every command, the revert timer's
    # rollback included; with no release.sha256, apply, keep and rollback
    # warn.
    . (Join-Path $PSScriptRoot 'core\safety\Release.ps1')
    $script:Release = Test-LabRelease -Root $PSScriptRoot
    if ($script:Release.Status -eq 'problem') { Exit-LabRelease }
    Read-LabArgument
    # Help never runs anything: it comes before every other check and read,
    # whatever else the line says.
    if ($script:HelpAsked) { Show-LabAskedHelp; exit 0 }
    Select-LabTryTopic
    if ($script:ParseError -ne '') { Exit-LabUsage $script:ParseError }
    if ($script:Actions.Count -gt 1) {
        Exit-LabUsage "two actions on one line: $(Get-LabShow $script:Actions[0]) and $(Get-LabShow $script:Actions[1])" 'Give one action at a time.'
    }
    $action = ''
    if ($script:Actions.Count -gt 0) { $action = $script:Actions[0] }
    $words = @($script:Words)
    # No action and no phase is the status (docs/Conventions.md section
    # 3.1), unless the line gives an option only a preview or -r uses.
    if ($action -ceq '' -and $words.Count -eq 0 -and
        @('profile', 'break-glass', 'confirm-group', 'approve' | Where-Object { $script:Given.ContainsKey($_) }).Count -eq 0) {
        $action = 'status'
    }
    $label = Get-LabShow $action
    if ($action -ceq '') { $label = 'a preview' } elseif ($action -ceq 'status') { $label = 'the status' }
    if ($script:Given.ContainsKey('all') -and $action -cne 'undo') {
        Exit-LabUsage "-All is only for -u, not $label"
    }
    # -y and -NoRevert are refused where they would do nothing, so no one
    # believes they took effect.
    if ($script:Given.ContainsKey('yes') -and $action -ceq 'undo' -and -not $script:Given.ContainsKey('all')) {
        Exit-LabUsage '-y is only for -u ID -All: add -All, or leave out -y'
    } elseif ($script:Given.ContainsKey('yes') -and $action -cne 'undo' -and $action -cne 'new-seed') {
        Exit-LabUsage "-y is only for -u ID -All or -NewSeed, not $label"
    }
    if ($script:Given.ContainsKey('no-revert') -and $action -cne 'run') {
        Exit-LabUsage "-NoRevert is only for -r, not $label"
    }

    $used = @()
    $phase = ''
    $word = ''
    if ($action -ceq 'status') {
        # Nothing more to check: the status takes no word.
    } elseif ($action -ceq '' -or $action -ceq 'run') {
        if ($words.Count -eq 0) {
            if ($action -ceq '') {
                Exit-LabUsage 'no phase or action given' 'Give a phase to preview, such as observe, or an action such as -r PHASE.'
            }
            Exit-LabUsage '-r needs a phase: lockout, observe, deceive or sustain'
        }
        $phase = $words[0].ToLowerInvariant()
        if ($Phases -cnotcontains $phase) { Exit-LabBadWord $words[0] }
        $shown = $phase
        if ($action -ceq 'run') { $shown = "-r $phase" }
        if ($words.Count -gt 1) { Exit-LabUsage "unexpected word '$($words[1])' after '$shown'" }
        if ($action -ceq '') {
            $label = 'a preview'
            $used = @('profile')
        } else {
            $label = '-r'
            $used = @('profile', 'break-glass', 'confirm-group', 'approve')
        }
    } elseif ($action -ceq 'keep' -or $action -ceq 'undo') {
        $word = [string] $script:Given[$action]
        $after = Get-LabShow $action
        if ($word -ne '') { $after += " $word" }
        if ($words.Count -gt 0) { Exit-LabUsage "unexpected word '$($words[0])' after '$after'" }
        # A full run ID is accepted in any case, like its last 4 characters.
        if ($word -match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$') {
            $low = $word.ToLowerInvariant()
            $word = $low.Substring(0, 8) + 'T' + $low.Substring(9, 6) + 'Z' + $low.Substring(16)
        }
        if ($word -ne '' -and $word -cnotmatch $ReRunId -and $word -notmatch '^[0-9a-fA-F]{4}$') {
            Exit-LabUsage "not a run ID: '$word' (give the ID or its last 4 characters)"
        }
        $label = Get-LabShow $action
    } elseif ($action -ceq 'new-seed' -or $action -ceq 'seed-check') {
        # A word here may be a seed: never repeat it.
        if ($words.Count -gt 0) {
            Exit-LabUsage "$(Get-LabShow $action) takes no seed on the command line: it asks for one" 'A seed typed on a command line stays in the shell history; clear it there.'
        }
        $label = Get-LabShow $action
    } else {
        if ($words.Count -gt 0) { Exit-LabUsage "unexpected word '$($words[0])' after '$(Get-LabShow $action)'" }
        $label = Get-LabShow $action
    }
    if ($action -ceq 'version') { Write-LabVersion; exit 0 }
    # Like help and -V, the manual reads no configuration and needs no
    # Administrator.
    if ($action -ceq 'manual') { Show-LabManual }
    # So does -SeedCheck: it asks for a seed and reads nothing else.
    if ($action -ceq 'seed-check') {
        $env:LAB_ROOT = $PSScriptRoot
        . (Join-Path $PSScriptRoot 'core\Lab.ps1')
        Invoke-LabSeedCheckCommand
    }
    $script:NoRevert = ($action -ceq 'run' -and $script:Given.ContainsKey('no-revert'))

    $profileName = ''
    if ($script:Given.ContainsKey('profile')) { $profileName = $script:Given['profile'] }
    $script:DataRoot = 'C:\ProgramData\Labyrinth'
    if ($script:Given.ContainsKey('root')) { $script:DataRoot = $script:Given['root'] }
    $config = ''
    if ($script:Given.ContainsKey('config')) { $config = $script:Given['config'] }
    if ($script:Given.ContainsKey('break-glass')) { $script:GivenBreakGlass = $script:Given['break-glass'] }
    if ($script:Given.ContainsKey('confirm-group')) { $script:GivenGroup = $script:Given['confirm-group'] }
    if ($profileName -ne '' -and $profileName -cnotmatch '^[a-z0-9-]+$') {
        Exit-LabUsage "invalid profile name '$profileName' (lower-case letters, digits and -)"
    }
    # Windows takes / as well as \ in a path, so C:/x is accepted as C:\x.
    $script:DataRoot = $script:DataRoot.Replace('/', '\')
    $config = $config.Replace('/', '\')
    if ($script:DataRoot -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-LabUsage "-Root must be a full path, not '$($script:DataRoot)'" }
    if ($config -ne '' -and $config -notmatch '^([A-Za-z]:\\|\\\\)') { Exit-LabUsage "-Config must be a full path, not '$config'" }
    if ($action -ceq 'run' -and $script:Given.ContainsKey('approve')) { Assert-LabApprove }
    # Noted now, printed by each action once its own checks pass.
    Test-LabOptionUse $label $used
    $script:ProfileName = $profileName
    $script:DryRun = '1'

    $env:LAB_ROOT = $PSScriptRoot
    if ($config -ne '') { $env:LAB_CONFIG_DIR = $config } else { $env:LAB_CONFIG_DIR = Join-Path $script:DataRoot 'etc' }
    $env:LAB_STATE_DIR = Join-Path $script:DataRoot 'state'
    $env:LAB_LOG_DIR = Join-Path $script:DataRoot 'logs'
    $env:LAB_BACKUP_DIR = Join-Path $script:DataRoot 'backup'
    $env:LAB_RUN_ID = Get-LabRunId
    . (Join-Path $PSScriptRoot 'core\Lab.ps1')

    # The actions keep their internal names: a preview is plan, -r is apply,
    # -u is rollback and -History is runs.
    $cmd = $action
    if ($action -ceq '') { $cmd = 'plan' }
    elseif ($action -ceq 'run') { $cmd = 'apply' }
    elseif ($action -ceq 'undo') { $cmd = 'rollback' }
    elseif ($action -ceq 'history') { $cmd = 'runs' }
    elseif ($action -ceq 'new-seed') { $cmd = 'newseed' }
    $script:Command = $cmd
    if ($cmd -in 'plan', 'apply', 'probe') { Assert-LabThisHost $config }
    switch ($cmd) {
        'status' { Invoke-LabStatusCommand }
        'plan' { Invoke-LabPlanCommand $phase }
        'apply' { Invoke-LabApplyCommand $phase }
        'keep' { Invoke-LabKeepCommand $word }
        'rollback' { Invoke-LabRollbackCommand $word }
        'probe' { Invoke-LabProbeCommand }
        'runs' { Invoke-LabRunsCommand }
        'newseed' { Invoke-LabNewSeedCommand }
    }
} catch {
    # An unexpected failure (docs/Conventions.md section 4): say what is
    # known about the run instead of only the exception.
    $what = $_.Exception.Message
    if ($what.Length -gt 60) { $what = $what.Substring(0, 57) + '...' }
    $at = Split-Path -Leaf ([string] $_.InvocationInfo.ScriptName)
    if ($at -eq '') { $at = 'labyrinth.ps1' }
    [Console]::Error.WriteLine("labyrinth: internal error at ${at}:$($_.InvocationInfo.ScriptLineNumber) ($what), exit 40")
    try {
        foreach ($l in (Get-LabRecovery)) { [Console]::Error.WriteLine($l) }
    } catch {
        [Console]::Error.WriteLine("The state of the run is unknown; check it with '$Self -History'.")
    }
    exit 40
}
