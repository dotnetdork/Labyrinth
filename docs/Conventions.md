# Labyrinth Coding Conventions

**Status:** Draft · reviewed 2026-10-05

These conventions turn the design specs into code that every module writes the same way. The specs say *what* a part must do; this page says *how* the code is shaped. If the two disagree, the spec wins and this page is corrected.

## 1. Languages and targets

| Platform | Language | Minimum | Not allowed |
|---|---|---|---|
| Linux | bash | 4.2 | Assuming `jq`, `python3`, `perl`, `curl`, `dig` or `yq`. Detect optional tools with `command -v` and degrade gracefully. |
| Windows | Windows PowerShell | 5.1 | PowerShell 7-only syntax: `??`, `?.`, ternary `a ? b : c`, `&&`/`||` between commands, `ForEach-Object -Parallel`, `Clean {}` blocks |
| Appliances | none | — | Any automation that writes to an appliance (design 16) |

Team-written tools must not use resources outside the competition environment, apart from simple DNS lookups (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.4). So Labyrinth never downloads anything. Labyrinth goes further than the rule as a design choice: it never installs packages at all, not even from a mirror inside the event network (design 00, section 3; design 15, sections 5 and 7). If a module needs a tool the host lacks, it reports exit code 20 (blocked) with a clear message.

## 2. Files and data formats

All formats are line-oriented text, so bash and PowerShell 5.1 can read them without a parsing library.

### 2.1 `module.yml`: a strict flat subset of YAML

Only `key: value` lines, `key: [a, b, c]` inline lists, comments starting with `#`, and blank lines. No nesting, no multi-line values, no anchors.

```yaml
id: lockout.firewall
title: Firewall
phase: lockout
priority: P0
platforms: [ubuntu, rhel-family, windows]
risk: service-affecting
touches_scored: true
requires: [observe.inventory]
outputs: [/etc/ufw/user.rules, firewall-backup]
spec: 01
```

The fields are those of design 00, section 4, plus `spec`, the design number the module implements. A loader that meets any other YAML construct fails with exit code 40.

### 2.2 Run-time configuration

Configuration is **data, never code**. It is never `source`d in bash or dot-sourced in PowerShell, because that would let a tampered config file run commands.

| File | Format | Holds |
|---|---|---|
| `event.conf` | `KEY=value`, one per line | Single values: SIEM address, revert-timer minutes, ring size |
| `protected-accounts` | `account class` per line, optional `# reason`; class is `official`, `scoring`, `employee`, `operator`, `breakglass`, `service` or `builtin` | The protected set (design 01, section 4); the class decides what Labyrinth may do to the account |
| `scoring-allowlist` | one address or CIDR per line | Scoring engine sources, applied before any deny rule |
| `never-ban` | one address or CIDR per line | Addresses that bans must never touch (design 12) |
| `services` | `name proto host port expect` per line | Scored services and what their probe expects |
| `hosts` | `host group profile platform` per line | Which hosts exist, their ring group, profile and platform |
| `profiles/<name>.profile` | one module id per line | Optional override of a shipped profile |

Templates live in `config/*.example` and contain placeholders only. A run-time profile override may name only modules the release ships; an unknown module id is an error (`40`). At run time, configuration is read from `<root>/etc/` (or the directory passed with `--config`). Anything that may change between events, or with a new rules packet or topology, belongs here, not in code. The rule freezes the submitted tools and repository (NCCDC, 2025, Rule 5.6.2). Our reading is that values supplied at run time are not part of that submission and can change after the freeze. The rule does not say so directly, so the reading must be confirmed with competition officials.

**Parsing rules:** strip comments after `#`, trim whitespace, skip blank lines, and reject a line that does not match the file's format, naming the file and line number. An empty `protected-accounts` file is a safety-gate failure (exit 20).

### 2.3 Profiles

`profiles/<name>.profile` ships the default ordered module list for a host type. A file of the same name in the run-time `profiles/` directory replaces it entirely for that run.

The release ships six: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc` and `appliance` (Blueprint, section 6.3). A module id is added to a shipped profile in the same commit as the module (design 00, section 8), so a shipped profile never lists a module the release lacks. `tests/profiles/` checks each shipped profile:

- every line is a module id, listed once, naming a module whose `module.yml` carries that id;
- a `windows-*` profile lists only modules whose platforms include `windows` and that have `.ps1` entry points;
- a `linux-*` profile lists only modules with a Linux platform and `.sh` entry points;
- the `appliance` profile lists only `manual-only` modules (design 16).

## 3. How a module is run

The runner (`labyrinth.sh` / `labyrinth.ps1`) calls each entry point as a separate process with these environment variables set:

| Variable | Meaning |
|---|---|
| `LAB_ROOT` | The code directory, the one holding `labyrinth.sh` and `labyrinth.ps1`: `<root>/bin` on hosts, the repository root in development. The data root (`<root>`, design 00, section 7) is set with `--root` / `-Root` |
| `LAB_CONFIG_DIR` | Run-time configuration directory |
| `LAB_STATE_DIR` | State: baselines, manifests, key registry |
| `LAB_LOG_DIR` | Log root; categories below it |
| `LAB_BACKUP_DIR` | Timestamped backups |
| `LAB_RUN_ID` | Unique ID of this run, used in logs and the manifest |
| `LAB_MODULE_ID` | The module's `id` |
| `LAB_DRY_RUN` | `1` when the run is in plan mode |
| `LAB_ENTRY` | The entry point being run (`check`, `plan`, `apply`, ...); the logger records it |
| `LAB_APPROVED` | For `approval` modules only: the items a person approved, separated by spaces, each `<id>@<fingerprint>` (section 3.1). Empty otherwise |

Entry points load the core library from `LAB_ROOT/core/` and never from a relative path: `source "$LAB_ROOT/core/lib.sh"` in bash, `. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')` in PowerShell. Loading it only defines functions. Entry points never read standard input: the runner owns the operator's prompts, so in bash an entry point's input is `/dev/null`.

**Exit codes in plan mode.** `check` and `plan` both exit `10` when a change is needed and `0` when none is, or `20` when a safety gate blocks them (design 00, section 4). The runner treats any other code as `40`. It runs `plan` only after `check` exits `10`, and for a whole run it reports the highest code any module returned, so one blocked module makes the run exit `20` and one error makes it exit `40`.

### 3.1 Commands, options, gates and the order of an apply

Both runners share one vocabulary. In this section `labyrinth` stands for the installed command, or for `labyrinth.sh` / `labyrinth.ps1` run directly (design 00, section 5).

```
labyrinth <command> [<phase> | <run>] [options]
```

| Command | Does |
|---|---|
| `plan <phase>` | Every module of the phase reports what it would change. Nothing is written, not even logs |
| `apply <phase>` | Plan, then apply behind the gates below |
| `keep [<run>]` | Keep a run's changes: cancel its revert timer, then record the keep. Without `<run>`, it takes the one run whose timer is armed; if several are armed, it lists them and keeps nothing (`40`) |
| `rollback <run>` | Undo what a run applied, newest module first. The revert timer runs exactly this. `<run>` is always needed: without it, the runs are listed (`40`) |
| `runs` | List this host's runs, oldest first: ID, phase, start time (UTC) and state, which is `armed` (with the time it rolls back), `kept`, `rolled back`, `rolled back with errors`, or `not kept, no timer`. Changes nothing; needs root or Administrator (`20`) |
| `probe` | Probe every scored service once; exit `30` if one fails. Changes nothing |
| `help [<topic>]` | Help for every command, or for one; also `-h` and `--help` (`-Help`). The topic `basics` explains the ideas in plain words, and a module ID prints that module's help page (design 00, section 4) |
| `version` | Print the version; also `-V` and `--version` (`-Version`) |

`<phase>` is `lockout`, `observe`, `deceive` or `sustain`. `<run>` is a run ID (`20261002T140301Z-4f2a`) or its last four characters (`4f2a`). A run that does not exist, or four characters that match more than one run, is an error (`40`) that points to `runs`. Commands, phases, option names and run IDs ignore case; other values do not.

**Options** may come before or after the command and its word. A value is given as `--name value`, `--name=value`, `-Name value` or `-Name:value`, and `--` ends the options. Each option has one name in both runners: bash help writes it `--break-glass`, PowerShell help writes it `-BreakGlass`, and both runners accept both spellings, because long names ignore case and dashes. The short flags `-h`, `-?` and `-V` are matched exactly, so `-v` is an error. PowerShell takes an unquoted `-?` for itself before the script runs, so the Windows help and manual offer `-h` instead.

| Option | PowerShell | Value | Used by |
|---|---|---|---|
| `--profile` | `-Profile` | NAME, `[a-z0-9-]+` | `plan`, `apply` |
| `--root` | `-Root` | absolute folder: the data root (default `/opt/labyrinth`; `C:\ProgramData\Labyrinth`) | all |
| `--config` | `-Config` | absolute folder: run-time configuration (default `<root>/etc`) | all |
| `--break-glass` | `-BreakGlass` | NAME: answers the break-glass prompt without typing | `apply` |
| `--confirm-group` | `-ConfirmGroup` | GROUP: answers the confirmation prompt without typing | `apply` |
| `--approve` | `-Approve` | LIST: approves items without the approval prompt (Approval items, below) | `apply` |
| `-h`, `-?`, `--help` | `-h`, `-Help` | none | all |
| `-V`, `--version` | `-V`, `-Version` | none | all |

PowerShell avoids the name `-Confirm`, which it reserves.

**Usage errors** exit `40`. They print one line, `labyrinth: <what is wrong>`, an optional line saying how to fix it, then `Try 'labyrinth help[ <command>]' for more information.`, all to standard error. The line names the word at fault and, for a near miss, suggests the right one (`did you mean 'observe'?`; `/?` gets `did you mean 'help'?`). The `Try` line names the command the line gives, even when the error is in an option, so `keep 4f2a --bogus` points to `help keep`. A line with no command prints `labyrinth: no command given`, three numbered steps to start with (`help basics`, `plan lockout`, `help`), then the short usage. These are errors too:

- an option given twice;
- an option whose value is missing, or looks like another option (`--profile needs a value, but got '--root'`);
- a command that conflicts with its options, such as `apply probe` or `--apply` with `keep`.

The whole line must parse before help or the version is shown. A value option that the command does not use, such as `--profile` with `probe`, gives a warning, not an error. The warning is printed once the command has passed its own checks, so it never comes before an error.

**Compatibility forms** stay accepted for good. Operators have learned them, and an armed revert timer runs its stored command line even after the runner that armed it has been replaced. They are:

- a phase alone means `plan <phase>`;
- `--apply` / `-Apply` with a phase means `apply <phase>`;
- `--breakglass`, `--confirm` and `-ProfileName`;
- the run before or after the options.

`tests/runner/compat.bats` and `tests/runner/Compat.Tests.ps1` hold every such form (section 9).

**Host checks** run for `plan`, `apply` and `probe` only:

- A `--config` folder that does not exist is an error (`40`).
- This host's line in `hosts` must name a platform the runner serves: `ubuntu` (the whole Debian family) or `rhel-family` (Fedora, RHEL, Rocky, Oracle Linux, AlmaLinux) for `labyrinth.sh`, `windows` for `labyrinth.ps1`. Otherwise the run is blocked (`20`).
- An `appliance` is never changed (design 16).

`keep`, `rollback` and `runs` skip these checks, so a stored revert-timer command still works after the configuration changes.

**Profile.** `--profile` names it; otherwise it is this host's line in the `hosts` file. On apply the host must be listed (else `20`), a given `--profile` must match its line (else `40`), and a host in the `manual` group is refused (`20`).

**Modules run by priority** (`P0` first), and in profile order within a priority. A `reversible`, `service-affecting` or `approval` module must have `check`, `apply`, `verify` and `rollback`, or it is invalid (`40`).

**Apply order.** A failed step stops the run before anything changes, unless the step says otherwise:

1. Administrator or root (`20`). On Windows the data root is then made private: only Administrators, SYSTEM and the operator's account can use it, and it does not inherit rights from its parent. A file or folder under it that another account owns is refused (`20`) and must be checked and removed by hand. Then the host's line and profile, `event.conf`, and the protected set: missing or empty is `20`, malformed is `40`. Plan mode needs the protected set too.
2. The run lock, `<state>/lock`, holding the process id. A live holder blocks the run (`20`); a lock whose process is gone is taken over.
3. Every module is planned. Any `40` means nothing is applied. If nothing needs applying, the run ends with no prompts.
4. **Break-glass** (design 01, section 7): the operator logs in at the console with a `breakglass`-class account and types its name. It is asked once per host and kept in `<state>/breakglass` as `<timestamp><TAB><account>`.
5. **Confirmation:** the operator types the host's group name.
6. From here, changes are made and recorded: the run's manifest starts (`run_start`, `breakglass_verified`), and the scored services are probed if a `services` file exists (otherwise a warning).
7. Each module that needs a change, in order:
   - `manual-only`: never applied; its plan is the checklist.
   - `touches_scored: true`: blocked (`20`) without a non-empty `scoring-allowlist` and a `services` file; the run continues.
   - `requires`: blocked if a required module in this run did not complete.
   - `approval`: the runner shows the module's items again, and the operator types the ids or categories to approve, or `--approve` gives them (Approval items, below); none means nothing changes.
   - The revert timer is (re)armed for `REVERT_MINUTES`, unless the module is `read-only`.
   - `apply_start` is recorded. If the manifest cannot be written, the module is not applied and the run stops (`40`).
   - `apply`: `20` is recorded and the run continues; any other failure rolls the module back and stops the run (`40`).
   - `verify`: a failure rolls the module back and stops the run (`30`, or `40` for an exit code other than `30`).
   - Probes again: a scored service that passed before and fails now rolls the module back and stops the run (`30`). An `unknown` result is never a regression.
   - `cleanup`, if present.
8. The lock is released. The operator checks that a new login still works, then types `keep`. Anything else leaves the timer armed, and when it fires it runs `rollback <run>`. Until then, `keep <run>` keeps the run, or `keep` alone when only one timer is armed. Keeping after a rollback is refused as too late (`20`).

**The revert timer** is a transient systemd timer `lab-revert-<run>-<n>` on Linux and a one-time scheduled task `\Labyrinth\lab-revert-<run>-<n>` running as SYSTEM on Windows. Re-arming creates the new timer first and only then removes the earlier one, so a failed re-arm leaves the run covered. `rollback` waits up to two minutes for the run lock and then proceeds without it, so a hung run cannot stop the timer.

The time a timer will fire is kept in `<state>/runs/<run>/timer-due` (UTC, `YYYY-MM-DDTHH:MM:SSZ`), for `runs` and the keep prompt. The file is advisory: if it is missing, the time is shown as unknown.

Cancelling a timer checks that it is really gone. If it is still armed, `keep` records nothing, says so, and exits `40`.

#### Approval items

Decided in the 2026-10-05 review.

- **Items.** An `approval` module's `plan` lists each item it would change, one per line on standard output: `item`, then the item id, its category, its fingerprint and the reason, separated by tabs. The core prints the line: `lab_item ID CATEGORY FINGERPRINT REASON` / `Write-LabItem`. The id is `[a-z0-9-]+`, unique within the module on this host, and derived from what the item is (for example its path), so the same item keeps its id from one run to the next. The category is `[a-z0-9-]+`. The fingerprint is the first 12 hex digits of the SHA-256 of the item's current state: its content, value or settings (`lab_item_fingerprint`, which reads the state on standard input, / `Get-LabItemFingerprint -Text`). A line that starts with `item` and a tab but is malformed, or an id listed twice, makes the module an `ERROR` (`40`), in plan and in apply.
- **Shown** under the module's result line as `Item:` lines, `<id>@<fingerprint> (<category>): <reason>`.
- **The prompt.** In apply, the runner shows the module's items again, then asks for item ids, and `category:<name>` for every item of that category in this run's plan, on this host only (design 01). A word that is neither is a `BLOCKED` (`20`); an id or category not in the plan is ignored with a line saying so. Each approved item goes to `apply` as `<id>@<fingerprint>` in `LAB_APPROVED`, with the fingerprint of this run's plan. Under the `CHANGE` line, `Approved:` lists them. A module whose plan listed no items, or with nothing approved, changes nothing (`OK`).
- **`--approve` / `-Approve`** (`apply` only) approves without the prompt, for remote mode (design 00, section 5). Its value is a comma-separated list of `<module-id>:<item-id>@<fingerprint>`, copied from a plan. It takes no categories, because a category could include items the operator never saw; an entry with a category, or any other malformed entry, is a usage error (`40`). When `--approve` is given, an `approval` module gets only the entries that name it, and the prompt is not asked. After the plan, each entry that names no item of an `approval` module in this run's plan is ignored with a line saying so.
- **Changed since the plan.** An `--approve` entry whose fingerprint differs from this run's plan is left out, recorded as `approval_refused` and shown as a `Found:` line. `apply` then recomputes each approved item's fingerprint before changing it, with `lab_approved ID FINGERPRINT` / `Test-LabApproved`: `0` approved and unchanged, `1` not approved, `2` changed since the plan, which records `approval_refused` and leaves the item alone. None of these makes the run fail.
- **Recorded.** The module's `apply_start` entry notes the approved items.
- **Never stored.** Approvals are not written into a revert timer's command line, and `rollback` never needs them.

### 3.2 Console output

What the runners print is part of the contract: operators read it under time pressure, many of them new to the tool, and the tests pin it. The output is written for a beginner: plain words, one idea per line, and every problem says what to do next.

- **Status words.** Every module result starts with one of `OK`, `CHANGE`, `WARN`, `BLOCKED`, `FAIL` or `ERROR`, padded to 9 characters, then the module's title and its ID in brackets: `CHANGE   Toggle setting sample (observe.toggle)`. A module whose `module.yml` cannot be read has no title, so its line shows the ID alone.
  - **In plan mode:**
    - `OK`: nothing to do (`0`);
    - `CHANGE`: a change is needed (`10`);
    - `BLOCKED`: `20`;
    - `ERROR`: `40`, or a module that cannot be loaded;
    - `WARN`: a module skipped on this platform, or a manual-only module that needs steps a person carries out (`10`). A phase with no modules in the profile is one `WARN` line, `WARN     Phase observe`, with its own Found, Fix and More lines.
  - **In apply:**
    - `OK`: applied and verified, nothing approved, no apply step (a module with only a `check` changes nothing), or rolled back;
    - `CHANGE`: a module about to apply, or about to be rolled back;
    - `WARN`: manual only, or a failed cleanup;
    - `BLOCKED`: a gate blocked the module;
    - `FAIL`: verify failed or a scored service regressed;
    - `ERROR`: apply failed, or a rollback failed.
- **Labelled lines.** Everything under a status line is a labelled line: two spaces, the label and a colon padded to 11 characters, then the text: `  Found:     password logins are on`. The labels are:
  - from modules: `Found` (what it saw), `Will do` (what apply would change), `Did` (what it changed), `Why`, `Risk`, `Problem`, `Cause`, `Fix` and `Undo`;
  - from the runner: `Item` (an approval item, section 3.1), `Approved` (the items approved), `Note` (any other module line), `Script` (the entry point that failed), `It said` (its last lines), `Log` (the run log), `Before` and `More` (`<SELF> help <module-id>`).

  Text longer than 65 characters wraps at a space onto another line with the same label, so each line makes sense alone; a word longer than that, such as a path, is never split.
- **Module output.** A module prints `key: text` lines, with a key from the module labels above, in any case: `found: password logins are on`. The runner shows each such line with its label, any other line as a `Note`, and drops blank lines. `check` and `plan` output is shown after the result line, because the result is known only when they end; the output of later entry points is shown as it comes. A `CHANGE` with no `Risk` line gets the module's risk in plain words. On screen and in `output.log`, a tab becomes a space and every other control character becomes `?`, so text from a module or a probed service cannot move the cursor or forge a status line.
- **The `problem:` line.** An entry point that exits `20`, `30` or `40` prints a `problem:` line last, saying what stopped it. The runner shows it as given. Without one, the runner says the script gave no reason, names the script, and in plan mode shows its last 10 lines as `It said` lines.
- **Blocks.** Every `WARN`, `BLOCKED`, `FAIL` or `ERROR` block says what failed (`Problem`, or `Found` for a `WARN`), how to recover (`Fix`, or the `Did: rolled back` of an automatic rollback), and ends with `More`. A `FAIL` or `ERROR` in apply also names the run log.
- **Header.** Two lines, at most 78 columns:
  - the version, the mode (`plan` or `APPLY`), the phase and the profile;
  - `run <id>`, followed in plan mode by `(plan mode: nothing is recorded)` and in apply by the host and group.

  Then, in plan mode, that nothing on the host changes and the host's group; in apply, that nothing changes until the operator confirms; and how many modules are checked.
- **End of a run.** After a blank line:
  - `Summary:`, the number of modules and the count of each status word: `Summary: 2 modules: 1 OK, 1 CHANGE.`;
  - `Nothing on this host was changed.` after a plan, or an apply that changed nothing;
  - `Log:` and the run log's path, when there is one;
  - `Next:`, the one command to run next, when there is one. A command too long for the line goes on the next line, indented 2 spaces, so it can be copied whole;
  - `<mode> finished: exit N (<meaning>)`.
- **probe** follows the same contract: a one-line header, then one line per service, `OK` (pass), `FAIL` or `WARN` (could not be checked) with the service name in brackets, then `Summary:`, `Next:` when a service failed, and `probe finished: exit 0 (no service failed)` or `exit 30`.
- **rollback** says how many modules it undoes, gives each a `CHANGE` line and then `OK` or `ERROR`, and ends with `Summary:`, `Log:` and `rollback finished: exit 0 (rolled back)`, or `exit 40 (error)` with a `Next:` line when a module could not be undone.
- **Recaps.** Before the group-name prompt: the host, the group, one line per module (`Will change:`, `Blocked:` or `Manual:`), that a revert timer will be armed, and, when a change may interrupt a service and the operator is connected remotely, to keep a second session open. Before the keep prompt: when the revert timer rolls the run back, in UTC and in minutes from now.
- **Messages** say what failed, why, and how to recover, in one sentence each. An error that stops the runner (exit `20` or `40`) is one line on stderr, `labyrinth: <what failed>: <why>`, and, unless the fix is already in that line, a second line saying how to recover. A failure that leaves changes in place always says how to keep them and how to undo them.
- **Text.** Fixed text is at most 78 columns, plain ASCII, with no colour. A line may be longer only by the length of a path it names, and the path comes last.

For module authors: when an entry point exits `20`, `30` or `40`, its last line of output is a `problem:` line. An entry point never leaves a background process holding standard output, because the runner waits for it to close.

#### The run log

Every apply, keep and rollback writes `<state>/runs/<run>/output.log`, readable by root or the administrators only (mode `600` on Linux; the data root's access list on Windows). A plan writes nothing.

- The first line gives the time, the version and what wrote to the log; a keep or rollback adds its own first line to the same file, including a rollback started by the revert timer, which no one watches.
- It holds every line the operator saw, the prompts with the answers typed, and each entry point's own lines as given, as `<id> <entry>| <line>`, at most 500 per entry point, with the time each started and its exit code.
- An apply's lines are kept from the header on and written once the run folder exists, after the group is confirmed.
- A run that stopped, or had a `FAIL` or `ERROR`, is marked with a `problems` file, and `runs` lists the logs of those runs.
- A log that cannot be written never stops a run.

## 4. Bash style

- Start every script with `#!/usr/bin/env bash` and `set -Eeuo pipefail`. Handle expected non-zero results explicitly (`if cmd; then`), never by turning `-e` off for a whole script.
- The runner installs an `ERR` trap that reports an unexpected failure as an internal error (`40`), with what is known about the run: whether anything changed, and how to keep or undo it. The trap does not fire inside a function called from `if` or `||`, so failures there are checked by hand.
- Never write a bare `(( expr ))` statement that can evaluate to 0: under `set -e` it ends the script. Use `x=$(( expr ))`, or `(( expr ))` inside an `if`.
- Quote every expansion. Use `local` in functions. Use `[[ ]]` for tests and `$(...)` for substitution.
- Core functions are prefixed `lab_` (for example `lab_log_info`, `lab_manifest_record`). Module-internal functions use a short module prefix.
- Never use `eval`, never `source` configuration, never build commands from unvalidated strings.
- Write temporary files only with `mktemp`, inside a Labyrinth path, and remove them in an `EXIT` trap.
- ShellCheck must pass with no warnings. A suppression needs a comment giving the reason on the line above.

## 5. PowerShell style

- Start every script with `#Requires -Version 5.1`, `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. The one exception is `labyrinth.ps1`: its comment-based help block comes first, then a blank line, then `#Requires`, because `Get-Help` reads the help only when it is the first thing in the file.
- `labyrinth.ps1` has no `param` block. It reads `$args` with the same option table and rules as `labyrinth.sh` (section 3.1), so both runners accept the same command lines and answer every usage error with `40`.
- Use approved verbs. Core functions use the `Lab` noun prefix (for example `Write-LabLog`, `Add-LabManifestEntry`).
- Never use `Invoke-Expression`, never dot-source configuration.
- Exit with the contract codes using `exit <code>`; do not let an exception escape an entry point without being mapped to `40`. In `labyrinth.ps1` the last `catch` does this: like the bash `ERR` trap (section 4), it reports an internal error with what is known about the run. A manifest write whose failure must not end the run silently gets its own `try`.
- Use `[System.Security.Cryptography.RandomNumberGenerator]` for anything secret, never `Get-Random` (design 01, section 8).
- PSScriptAnalyzer must pass. A suppression uses `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]` with a justification.

## 6. Logging

Every log line is one JSON object on one line (JSON lines), written through the core logger only.

| Field | Example | Notes |
|---|---|---|
| `ts` | `2026-10-02T14:03:07Z` | UTC, ISO 8601 |
| `host` | `web01` | Short host name |
| `run` | `20261002T140301Z-4f2a` | `LAB_RUN_ID` |
| `module` | `lockout.firewall` | Empty for the runner itself |
| `entry` | `apply` | Entry point |
| `level` | `info` | `debug`, `info`, `warn`, `error` |
| `event` | `rule_added` | Short machine-readable name |
| `msg` | `allowed tcp/443 from scoring allowlist` | Human-readable |

Logs are written to `<logs>/<category>/<YYYYMMDD>.jsonl` (UTC date); warnings and errors are also printed to standard error. Plan mode writes no log files. Extra fields may follow. **Never log a secret:** passwords, keys, the event seed and tokens are never passed to the logger, not even masked. A module makes a new password with `lab_secret_new` / `Get-LabRandomSecret` and hands it over only with `lab_secret_show` / `Show-LabSecret`, which write to the terminal, never to standard output (design 05, section 2.3). Log categories are those in design 00, section 7.

## 7. The run manifest

Every change `apply` makes is recorded through `lab_manifest_record` / `Add-LabManifestEntry` **before** the change is made, with what is needed to undo it: the action, the target, the backup path or the previous value. `rollback` replays the manifest in reverse. `cleanup` reads the module's `outputs` and its manifest entries; it never deletes anything the manifest does not list.

The manifest is `<state>/runs/<run>/manifest.jsonl`, one JSON object per line, every value a string: `ts`, `run`, `host`, `module`, `seq`, `action`, `target`, `backup`, `prev`, `note`. Writing to it is refused in plan mode. Actions the core writes:

| Action | Meaning |
|---|---|
| `run_start`, `breakglass_verified`, `run_kept`, `run_rolled_back` | The run itself (empty `module`) |
| `apply_start` | A module's `apply` is about to run; `rollback <run>` undoes every module with one |
| `file` | A file is about to change; `backup` holds its copy, `<backup>/<run>/<module>/<seq>-<name>` |
| `file_created` | A file that did not exist is about to be created |
| `firewall_snapshot` | The firewall adapter saved the ruleset; `target` is the backend and `backup` the snapshot folder. Rollback restores it (design 19, section 5) |
| `firewall_allow`, `firewall_default_deny` | The firewall adapter is about to add an allow, or set the inbound default to deny; undone by the snapshot |
| `quarantine_file`, `quarantine_cron`, `quarantine_unit`, `quarantine_task`, `quarantine_service`, `quarantine_registry`, `quarantine_wmi`, `quarantine_process` | An item is about to be quarantined; `lab_quarantine_restore` / `Undo-LabQuarantine` put it back, except an ended process (design 17, section 5.1) |
| `approval_refused` | An approved item was left alone because it changed since the plan; `target` is the item id (section 3.1). Nothing to undo |
| `rolled_back` | The module was rolled back |

Restoring a `file` entry writes the backup over the file in place, then restores its owner and permissions (and, on Linux, its SELinux label where `restorecon` exists). A created file is never deleted: rollback moves it into the backup folder as `rolled-back-<seq>-<name>`. Restoring is safe to repeat.

## 8. Guard comments

`tests/lint/guard.sh` scans code for network calls and blanket actions. Where a match is legitimate, for example a probe connecting to the team's own scored service, mark the line:

```bash
curl -fsS --max-time 5 "$url"   # lab-guard: allow network -- probe of a scored service inside the event network
```

The comment must name the rule and give a reason after `--`. Reviewers check every allow comment.

The `delete` rule has exactly one legitimate use: the account module deleting an account a person approved (design 05, section 6.4). That line carries an allow comment naming the approval. No other module deletes an account, and no module deletes a file outside Labyrinth's own temporary and state paths; anything else is removed by quarantine (design 17, section 5).

## 9. Tests

- Tests live in `tests/`, mirroring the code layout: `tests/core/`, `tests/platform/`, `tests/phases/<phase>/<module>/`, `tests/lint/`.
- **bats** for bash and **Pester 5** for PowerShell. Unit tests mock system commands. Real-system tests (`tests/core/realsystem.bats`, `tests/core/RealSystem.Tests.ps1`) run only where `LAB_REALSYSTEM=1`, which CI sets on its disposable runners, and on lab VMs; never on a developer's own machine.
- Runner tests build a throwaway Labyrinth tree from the fixture modules in `tests/fixtures/modules/`, so they never touch the repository's own `phases/` or `profiles/`. The tree's core gets test doubles appended (`tests/fixtures/doubles.sh`, `tests/fixtures/Doubles.ps1`) that replace the administrator check, the revert timer and the probes.
- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request: ShellCheck, the guard and bats on Ubuntu; PSScriptAnalyzer and Pester under Windows PowerShell 5.1 on Windows; and the manual build, whose output is kept as a CI artifact. The test tools are installed on the CI runners only. A contributor may install them locally to run the same commands, but nothing in Labyrinth requires it.
- **The compatibility suite** (`tests/runner/compat.bats`, `tests/runner/Compat.Tests.ps1`) holds every command form operators and stored revert timers rely on (section 3.1). It is never edited to make a change pass: change the runner instead. A form leaves it only by a design decision recorded in the design review log.
- **The operator manual** (`docs/manual/labyrinth.md`) is one source for the Linux and Windows PDFs, the man page and the Windows help topic, built in CI by `tools/manual/build.sh`. Text for one platform sits between `<!-- linux -->` or `<!-- windows -->` and `<!-- end -->`. A change to a command, option, exit code or console message updates the manual in the same commit, and `tests/manual/manual.bats` checks that each platform's manual has every command, option and exit code and nothing from the other platform. The manual is written in the plain style of `docs/Overview.md`: short sentences, and every term explained the first time it appears.
- Each module's tests start from its spec's acceptance-test list and include the negative test from design 00, section 8: protected accounts and scored services are untouched.
- **Where real-host tests run** (decided in the 2026-10-05 review). Unit tests with test doubles run everywhere CI runs. Acceptance tests that change a real host run in two places:
  - **CI runners,** with `LAB_REALSYSTEM=1`: Ubuntu, and Windows Server, including a job that promotes a throwaway runner to a single domain controller for the design 11 tests. These run on every pull request that touches the module.
  - **The lab,** local virtual machines that a person runs before each release: the RHEL family (Fedora, Rocky or Oracle Linux), Debian, a domain with a member server, several hosts for rings and remote mode, a SIEM, and appliance images for the runbooks (design 16). `docs/lab/README.md` lists the machines, how to build them from public install media, and the matrix of module × platform × version. Each result is recorded there with the version tested, which is the record design 18, section 7 asks for.
  - An acceptance test says which of the two it needs. A module is not released on a platform that neither has tested.

## 10. Commits

One module or one core component per branch. Commit messages say what changed and why, in plain sentences. The spec is updated in the same branch when the code shows it needs to change, with an entry in the design review log.
