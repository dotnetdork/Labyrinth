# Working on Labyrinth

Labyrinth is a public, rules-bound hardening and deception tool for CCDC (Collegiate Cyber Defense Competition) defense. The design specs in `docs/design/` are the source of truth. Code implements them; it never quietly departs from them.

## Hard rules

Each rule below says where it comes from. **Rule** items restate the national CCDC rules for team-written tools (National Collegiate Cyber Defense Competition [NCCDC], 2025); breaking one can get the tool rejected or the team penalized. **Design** items are stricter choices made in the specs. They are just as binding here, but they are not the rules' wording, so never cite a rule number for them.

1. **No outside resources at run time.** *Rule 5.6.4:* a team tool must not use resources outside the competition environment, apart from simple DNS lookups; cloud services and cloud processing are prohibited. So no `curl`/`wget`/`Invoke-WebRequest` to the internet, no `git clone`, no reputation or enrichment APIs. *Design (00, 15):* Labyrinth also never installs packages or modules (`apt install`, `Install-Module` and the like), even from inside the event network. Probes that talk to the team's *own* scored services are allowed and are marked for the guard (see `docs/Conventions.md`).
2. **No secrets or event values in the repository.** *Rules 5.6.1, 5.6.3:* the code is public and its links go to every other team. *Design (00, 03):* no passwords, keys, addresses, hostnames, seeds or per-event values; only `*.example` templates with placeholders. Configuration is supplied at run time.
3. **No blanket actions.** *Rule 5.6.5:* tools must not deliberately break expected functionality; the rules' examples are setting all user shells to `/bin/false` and indiscriminately terminating all outbound connections. *Design (01, 05, 17):* never disable accounts wholesale, change login shells, stop services outside an explicit candidate list, or reboot. Never delete a file outside Labyrinth's own temporary and state paths: remove it by quarantine (design 17, section 5). Delete an account only in the account module, for an account a person approved, after a checkpoint shows every scored service passing and its evidence is saved (design 05, section 6.4). Every change works from an explicit list and skips the protected set.
4. **Plan by default.** *Design (00, 01):* `apply` runs only after `plan`, the safety gates, and a typed confirmation.
5. **Never mislead the scoring engine, and never impede it.** *Rule 9.3:* changing a system to make the scoring engine think a service is up when it is not can bring disqualification or penalties; nothing fakes a service state. *Rules 4.11, 9.3:* anything that interferes with scoring is the team's responsibility and lowers the score. *Design (01):* the scoring allowlist goes in before any deny rule.
6. **Officials get access.** *Rule 4.1:* Operations and White Team must be given access immediately when they ask. *Design (01, 05):* nothing removes the break-glass path.
7. **Reversible.** *Design (00):* back up before changing; record every change in the run manifest; `rollback` must work from that manifest.
8. **Confirm, then act.** *Design (00, 01):* an `approval` module changes only the items a person approved, with the same backups, manifest and rollback as any change. A `manual-only` module never changes anything.

## Public boundary

This repository is public. Never add team strategy, schedules, deadlines, event dates, real topology, hostnames, addresses, team member details, or anything from the private planning repository. Generic, reusable defense logic only. Never commit `PRODUCT.md` or any `.impeccable*` file.

## The module contract (design 00)

Each module is a folder `phases/<phase>/modules/<name>/` with `module.yml` and up to six entry points: `check`, `plan`, `apply`, `verify`, `rollback`, `cleanup` (`.sh` for Linux, `.ps1` for Windows).

| Exit code | Meaning |
|---|---|
| 0 | Nothing to do, or success |
| 10 | Change needed |
| 20 | Blocked by a safety gate |
| 30 | Verify failed |
| 40 | Error |

`check`, `plan` and `verify` are read-only. `apply` is idempotent, backs up first and writes to the run manifest. `rollback` and `cleanup` are safe to run repeatedly. Use the `core/` library for logging, the manifest, safety gates and probes; never re-implement them in a module.

## Platform targets

- **Linux:** bash 4.2 or newer and the tools present on a minimal Ubuntu, Debian, Fedora, RHEL, Oracle Linux or Rocky install. Do not assume `jq`, `python3`, `curl` or `dig`; detect them and degrade gracefully. Firewalls differ: UFW, firewalld or nftables, behind a platform adapter.
- **Windows:** Windows PowerShell **5.1** (the version on Windows Server). Do not use PowerShell 7-only syntax (`??`, `?.`, ternaries, `&&`/`||` pipeline chains, `-Parallel`).
- **Appliances:** never automated. Runbooks and templates only (design 16).

## How work is done

1. Read the module's spec first. If the spec is ambiguous or wrong, raise it and update the spec (with a review-log entry in `docs/design/README.md`) before writing code.
2. Write tests first, from the spec's acceptance-test list: bats for bash, Pester 5 for PowerShell. Every module needs a negative test showing protected accounts and scored services are untouched.
3. Implement against `core/`, following `docs/Conventions.md`.
4. Run `tests/lint/guard.sh`. CI (`.github/workflows/ci.yml`) also runs ShellCheck, PSScriptAnalyzer, bats and Pester under Windows PowerShell 5.1; all must be clean. Never install test tools on a contributor's machine without asking; CI installs them on its own runners.
5. One component per branch, named `phase-<n>/<name>` (for example `phase-2/cli-runner`). Commit; the maintainer pushes, reviews and merges once CI is green.

## Changing the command line

`labyrinth.sh` and `labyrinth.ps1` share one vocabulary. Before changing a command, option, prompt, exit code or console message:

- Follow `docs/Conventions.md` section 3.1 (commands, options, the order of an apply) and section 3.2 (console output). If the change departs from them, update the spec first.
- **Never edit the compatibility suite to make a change pass** (`tests/runner/compat.bats`, `tests/runner/Compat.Tests.ps1`). Armed revert timers run stored command lines, so every form it holds must keep working. Change the runner instead.
- **Update the operator manual in the same commit** (`docs/manual/labyrinth.md`). Put platform-only text between `<!-- linux -->` or `<!-- windows -->` and `<!-- end -->`, and write in the plain style of `docs/Overview.md`. `tests/manual/manual.bats` must pass.
- Make the same change in both runners, with tests in both suites.

## Where the tests are

| Path | Covers |
|---|---|
| `tests/core/` | The core library (`core.bats`, `Core.Tests.ps1`); real-system timer tests (`realsystem.bats`, `RealSystem.Tests.ps1`, CI only) |
| `tests/runner/` | The runners: `apply`, `labyrinth`, `args`, `help` and `runs`, and `compat` (the compatibility suite); `args-cases.txt`, the command-line cases both suites read; helpers `lab_helper.bash` and `LabTestHelper.ps1` |
| `tests/manual/` | The manual and its splitter |
| `tests/lint/` | The guard and its fixtures |
| `tests/fixtures/` | Fixture modules and the test doubles appended to a throwaway core |

## Lint pitfalls already met

- **PowerShell:** new functions use approved verbs and the `Lab` noun prefix. Avoid `Set-`, `New-`, `Remove-` and similar verbs, which make PSScriptAnalyzer demand `ShouldProcess`.
- **Stand-in cmdlets in Pester:** import the real module first, define the stand-in, assert its `.Module` is empty, and in `finally` remove it and run `Import-Module <module> -Force`. Otherwise later test files reach the stand-in.
- **bash 4.2:** no namerefs, and no bare `(( ))` statement that can evaluate to 0 under `set -e`.
- **The `ERR` trap does not fire under `||`, `&&`, `if` or `!`.** Check a call that must not fail silently explicitly.
- **Guard words:** strings must not contain the words the guard looks for (`tests/lint/guard.sh`), even in messages.

Docs use US spelling, no draft version numbers, and APA 7 citations for rules.
