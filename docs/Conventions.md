# Labyrinth Coding Conventions

**Status:** Draft · reviewed 2026-10-02

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

Templates live in `config/*.example` and contain placeholders only. At run time, configuration is read from `<root>/etc/` (or the directory passed with `--config`). Anything that may change between events, or with a new rules packet or topology, belongs here, not in code. The rule freezes the submitted tools and repository (NCCDC, 2025, Rule 5.6.2). Our reading is that values supplied at run time are not part of that submission and can change after the freeze. The rule does not say so directly, so the reading must be confirmed with competition officials.

**Parsing rules:** strip comments after `#`, trim whitespace, skip blank lines, and reject a line that does not match the file's format, naming the file and line number. An empty `protected-accounts` file is a safety-gate failure (exit 20).

### 2.3 Profiles

`profiles/<name>.profile` ships the default ordered module list for a host type. A file of the same name in the run-time `profiles/` directory replaces it entirely for that run.

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
| `LAB_APPROVED` | For `approval` modules only: the item ids a person approved, separated by spaces. Empty otherwise |

Entry points load the core library from `LAB_ROOT/core/` and never from a relative path: `source "$LAB_ROOT/core/lib.sh"` in bash, `. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')` in PowerShell. Loading it only defines functions. Entry points never read standard input: the runner owns the operator's prompts, so in bash an entry point's input is `/dev/null`.

**Exit codes in plan mode.** `check` and `plan` both exit `10` when a change is needed and `0` when none is, or `20` when a safety gate blocks them (design 00, section 4). The runner treats any other code as `40`. It runs `plan` only after `check` exits `10`, and for a whole run it reports the highest code any module returned, so one blocked module makes the run exit `20` and one error makes it exit `40`.

### 3.1 Commands, gates and the order of an apply

| Command (bash; PowerShell in brackets) | Does |
|---|---|
| `labyrinth.sh <phase>` | Plan: every module of the phase reports what it would change. Nothing is written, not even logs |
| `labyrinth.sh --apply <phase>` (`-Apply`) | Apply the plan, behind the gates below |
| `labyrinth.sh probe` | Probe every scored service once; exit `30` if one fails |
| `labyrinth.sh keep <run>` | Keep a run's changes: cancel its revert timer |
| `labyrinth.sh rollback <run>` | Undo what a run applied, newest module first. The revert timer runs exactly this |

Options: `--profile` (`-Profile`), `--root` (`-Root`), `--config` (`-Config`), `--breakglass NAME` (`-BreakGlass`) and `--confirm GROUP` (`-ConfirmGroup`). The last two answer the break-glass and confirmation prompts without typing. PowerShell avoids the name `-Confirm`, which it reserves.

**Profile.** `--profile` names it; otherwise it is this host's line in the `hosts` file. On apply the host must be listed (else `20`), a given `--profile` must match its line (else `40`), and a host in the `manual` group is refused (`20`).

**Modules run by priority** (`P0` first), and in profile order within a priority. A `reversible`, `service-affecting` or `approval` module must have `check`, `apply`, `verify` and `rollback`, or it is invalid (`40`).

**Apply order.** A failed step stops the run before anything changes, unless the step says otherwise:

1. Administrator or root (`20`), the host's line and profile, `event.conf`, and the protected set: missing or empty is `20`, malformed is `40`. Plan mode needs the protected set too.
2. The run lock, `<state>/lock`, holding the process id. A live holder blocks the run (`20`); a lock whose process is gone is taken over.
3. Every module is planned. Any `40` means nothing is applied. If nothing needs applying, the run ends with no prompts.
4. **Break-glass** (design 01, section 7): the operator logs in at the console with a `breakglass`-class account and types its name. It is asked once per host and kept in `<state>/breakglass` as `<timestamp><TAB><account>`.
5. **Confirmation:** the operator types the host's group name.
6. From here, changes are made and recorded: the run's manifest starts (`run_start`, `breakglass_verified`), and the scored services are probed if a `services` file exists (otherwise a warning).
7. Each module that needs a change, in order:
   - `manual-only`: never applied; its plan is the checklist.
   - `touches_scored: true`: blocked (`20`) without a non-empty `scoring-allowlist` and a `services` file; the run continues.
   - `requires`: blocked if a required module in this run did not complete.
   - `approval`: the operator types the ids of the items to approve; none means nothing changes.
   - The revert timer is (re)armed for `REVERT_MINUTES`, unless the module is `read-only`.
   - `apply`: `20` is recorded and the run continues; any other failure rolls the module back and stops the run (`40`).
   - `verify`: a failure rolls the module back and stops the run (`30`, or `40` for an exit code other than `30`).
   - Probes again: a scored service that passed before and fails now rolls the module back and stops the run (`30`). An `unknown` result is never a regression.
   - `cleanup`, if present.
8. The lock is released. The operator checks that a new login still works, then types `keep`. Anything else leaves the timer armed, and when it fires it runs `rollback <run>`. Keeping after a rollback is refused as too late (`20`).

**The revert timer** is a transient systemd timer `lab-revert-<run>-<n>` on Linux and a one-time scheduled task `\Labyrinth\lab-revert-<run>-<n>` running as SYSTEM on Windows. `rollback` waits up to two minutes for the run lock and then proceeds without it, so a hung run cannot stop the timer.

## 4. Bash style

- Start every script with `#!/usr/bin/env bash` and `set -Eeuo pipefail`. Handle expected non-zero results explicitly (`if cmd; then`), never by turning `-e` off for a whole script.
- Quote every expansion. Use `local` in functions. Use `[[ ]]` for tests and `$(...)` for substitution.
- Core functions are prefixed `lab_` (for example `lab_log_info`, `lab_manifest_record`). Module-internal functions use a short module prefix.
- Never use `eval`, never `source` configuration, never build commands from unvalidated strings.
- Write temporary files only with `mktemp`, inside a Labyrinth path, and remove them in an `EXIT` trap.
- ShellCheck must pass with no warnings. A suppression needs a comment giving the reason on the line above.

## 5. PowerShell style

- Start every script with `#Requires -Version 5.1`, `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Use approved verbs. Core functions use the `Lab` noun prefix (for example `Write-LabLog`, `Add-LabManifestEntry`).
- Never use `Invoke-Expression`, never dot-source configuration.
- Exit with the contract codes using `exit <code>`; do not let an exception escape an entry point without being mapped to `40`.
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

Logs are written to `<logs>/<category>/<YYYYMMDD>.jsonl` (UTC date); warnings and errors are also printed to standard error. Plan mode writes no log files. Extra fields may follow. **Never log a secret:** passwords, keys, the event seed and tokens are never passed to the logger, not even masked. Log categories are those in design 00, section 7.

## 7. The run manifest

Every change `apply` makes is recorded through `lab_manifest_record` / `Add-LabManifestEntry` **before** the change is made, with what is needed to undo it: the action, the target, the backup path or the previous value. `rollback` replays the manifest in reverse. `cleanup` reads the module's `outputs` and its manifest entries; it never deletes anything the manifest does not list.

The manifest is `<state>/runs/<run>/manifest.jsonl`, one JSON object per line, every value a string: `ts`, `run`, `host`, `module`, `seq`, `action`, `target`, `backup`, `prev`, `note`. Writing to it is refused in plan mode. Actions the core writes:

| Action | Meaning |
|---|---|
| `run_start`, `breakglass_verified`, `run_kept`, `run_rolled_back` | The run itself (empty `module`) |
| `apply_start` | A module's `apply` is about to run; `rollback <run>` undoes every module with one |
| `file` | A file is about to change; `backup` holds its copy, `<backup>/<run>/<module>/<seq>-<name>` |
| `file_created` | A file that did not exist is about to be created |
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

- Tests live in `tests/`, mirroring the code layout: `tests/core/`, `tests/phases/<phase>/<module>/`, `tests/lint/`.
- **bats** for bash and **Pester 5** for PowerShell. Unit tests mock system commands. Real-system tests (`tests/core/realsystem.bats`, `tests/core/RealSystem.Tests.ps1`) run only where `LAB_REALSYSTEM=1`, which CI sets on its disposable runners, and on lab VMs; never on a developer's own machine.
- Runner tests build a throwaway Labyrinth tree from the fixture modules in `tests/fixtures/modules/`, so they never touch the repository's own `phases/` or `profiles/`. The tree's core gets test doubles appended (`tests/fixtures/doubles.sh`, `tests/fixtures/Doubles.ps1`) that replace the administrator check, the revert timer and the probes.
- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request: ShellCheck, the guard and bats on Ubuntu; PSScriptAnalyzer and Pester under Windows PowerShell 5.1 on Windows. The test tools are installed on the CI runners only. A contributor may install them locally to run the same commands, but nothing in Labyrinth requires it.
- Each module's tests start from its spec's acceptance-test list and include the negative test from design 00, section 8: protected accounts and scored services are untouched.

## 10. Commits

One module or one core component per branch. Commit messages say what changed and why, in plain sentences. The spec is updated in the same branch when the code shows it needs to change, with an entry in the design review log.
