# Working on Labyrinth

These rules bind every contributor and every coding assistant (Claude Code, Copilot, Codex, Cursor, Gemini or another). Claude Code reads them through `CLAUDE.md`, which adds only its own setup.

Labyrinth is a public, rules-bound hardening and deception tool for CCDC (Collegiate Cyber Defense Competition) defense. The design specs in `docs/design/` are the source of truth. Code implements them; it never quietly departs from them.

## Hard rules

Each rule below says where it comes from. **Rule** items restate the national CCDC rules for team-written tools (National Collegiate Cyber Defense Competition [NCCDC], 2025); breaking one can get the tool rejected or the team penalized. **Design** items are stricter choices made in the specs. They are just as binding here, but they are not the rules' wording, so never cite a rule number for them.

1. **No cloud services, no private sources.** *Rule 5.6.4:* a team tool must not use resources outside the competition environment, apart from simple DNS lookups; cloud services and cloud processing are prohibited. So no reputation or enrichment APIs, and no `git clone` of a private source. Public software and public data are not cloud processing, so *Design (02, 03):* after the first-minute lockdown, only the `packages` module and the core download helper may download or install them: software and data such as a CVE database from the host's configured repositories, an event mirror or proxy, or a release pinned by SHA-256, with offline paste as the fallback. PowerShell Gallery modules at pinned versions are allowed. Never a full upgrade, a new repository (apart from EPEL through `epel-release`, design 02), cloud processing, or a private source (Rule 5.2). Those lines carry a guard allow comment. Probes that talk to the team's *own* scored services are allowed and are marked for the guard (see `docs/Conventions.md`).
2. **No secrets or event values in the repository.** *Rules 5.6.1, 5.6.3:* the code is public and its links go to every other team. *Design (00, 16):* no passwords, keys, addresses, hostnames, seeds or per-event values; only `*.example` templates with placeholders. Configuration is supplied at run time.
3. **No blanket actions.** *Rule 5.6.5:* tools must not deliberately break expected functionality; the rules' examples are setting all user shells to `/bin/false` and indiscriminately terminating all outbound connections. *Design (03, 04, 06):* never disable accounts wholesale, change login shells, stop services outside an explicit candidate list, or reboot. Never delete a file outside Labyrinth's own temporary and state paths: remove it by quarantine (design 06, section 5). The one exception is the Linux revert timer's own two unit files, which Labyrinth wrote (`docs/Conventions.md`, section 3.1). Delete an account only in the account module, for an account a person approved, after a checkpoint shows every scored service passing and its evidence is saved (design 04, section 6.4). Every change works from an explicit list and skips the protected set.
4. **Plan by default.** *Design (00, 03):* `apply` runs only after the plan is printed, the safety gates pass, and the target group is confirmed: typed at the prompt, given with `--confirm-group` in a first-minute run whose profile the team reviewed before the event (design 03, section 6.3), or, once automatic runs are built, read from the hosts file, with `laby PHASE` as the preview (design 00, section 5.1; Conventions, section 3.3).
5. **Never mislead the scoring engine, and never impede it.** *Rule 9.3:* changing a system to make the scoring engine think a service is up when it is not can bring disqualification or penalties; nothing fakes a service state. *Rules 4.11, 9.3:* anything that interferes with scoring is the team's responsibility and lowers the score. *Design (01, 03):* every scored service is allowed from any source, and any scoring allowlist is added, before any deny rule; a scored port is never filtered by source address. Never change a host name, an address, a scored DNS name or a username.
6. **Officials get access.** *Rule 4.1:* Operations and White Team must be given access immediately when they ask. *Design (03, 04):* nothing removes the break-glass path.
7. **Reversible.** *Design (00):* back up before changing; record every change in the run manifest; `rollback` must work from that manifest.
8. **Confirm, then act.** *Design (00, 03):* an `approval` module changes only the items a person approved, at the prompt, in advance through a pre-approval rule in a category the module allows, or, once automatic runs are built, later from the queue with `laby -q -a`, with the same backups, manifest and rollback as any change. A `manual-only` module never changes anything.

## Public boundary

This repository is public. Public knowledge is fine: published rules, vendor documentation, known CVEs, widely used software. Never add internal or strategic information: team strategy, schedules, deadlines, event dates, team member details, a real event's topology, hostnames, addresses or credentials, or anything from the private planning repository. Generic, reusable defense logic only. Never commit `PRODUCT.md` or any `.impeccable*` file. Before a branch is handed over for merge, have its diff checked against this boundary and the hard rules above (with Claude Code, the `verifier` subagent does this).

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

- **Linux:** bash 4.2 or newer and the tools present on a minimal Ubuntu, Debian or RHEL-family (RHEL, Rocky, Oracle Linux, Alma) install. Do not assume `jq`, `python3`, `curl` or `dig`; detect them and degrade gracefully. Firewalls differ: UFW on Debian and Ubuntu, firewalld on the RHEL family, behind a platform adapter (raw nftables only for the first minute on a Debian host with no front end).
- **Windows:** Windows PowerShell **5.1** (the version on Windows Server). Do not use PowerShell 7-only syntax (`??`, `?.`, ternaries, `&&`/`||` pipeline chains, `-Parallel`).
- **Appliances:** never automated. Runbooks and templates only (design 05).

## How work is done

1. Start from the issue. Read every link in its **Read first** section, then the module's spec. If the issue and the spec disagree, the spec wins; say so in the pull request. If the spec is ambiguous or wrong, raise it and update the spec in the same branch before writing code, saying why in the commit message.
2. Write tests first, from the spec's acceptance-test list: bats for bash, Pester 5 for PowerShell. Every module needs a negative test showing protected accounts and scored services are untouched.
3. Implement against `core/`, following `docs/Conventions.md`.
4. CI (`.github/workflows/ci.yml`) runs `tests/lint/guard.sh`, ShellCheck, PSScriptAnalyzer, bats and Pester under Windows PowerShell 5.1, and the manual build; all must be clean. Run them locally only where the tools are already installed and `CLAUDE.local.md` does not say otherwise; never install test tools on someone's machine without asking. Otherwise push the branch and read the CI results.
5. One issue, one person, one branch, one small pull request (`CONTRIBUTING.md`). Name the branch as the issue and `docs/Roadmap.md` give it (for example `phase-4/ssh`), or `docs/<name>` for documentation only, and keep follow-up steps on it. Push only to that branch, so CI checks it, and fix failures there. Never push to `main`, force-push, rewrite history, or delete a branch you did not create. A pull request merges once CI is green and someone other than its author approves it.

## Changing the command line

`labyrinth.sh` and `labyrinth.ps1` share one vocabulary. Before changing a command, option, prompt, exit code or console message:

- Follow `docs/Conventions.md` section 3.1 (commands, options, the order of an apply), section 3.2 (console output) and section 3.3 (the planned additions to the command line, built in the first usable release). If the change departs from them, update the spec first.
- **Update the operator manual in the same commit** (`docs/manual/labyrinth.md`). Put platform-only text between `<!-- linux -->` or `<!-- windows -->` and `<!-- end -->`, and write in the plain style of `docs/Overview.md`. `tests/manual/manual.bats` must pass.
- Make the same change in both runners, with tests in both suites.

## Lint pitfalls already met

- **PowerShell:** new functions use approved verbs and the `Lab` noun prefix. Avoid `Set-`, `New-`, `Remove-` and similar verbs, which make PSScriptAnalyzer demand `ShouldProcess`.
- **Stand-in cmdlets in Pester:** import the real module first, define the stand-in, assert its `.Module` is empty, and in `finally` remove it and run `Import-Module <module> -Force`. Otherwise later test files reach the stand-in.
- **bash 4.2:** no namerefs, and no bare `(( ))` statement that can evaluate to 0 under `set -e`.
- **The `ERR` trap does not fire under `||`, `&&`, `if` or `!`.** Check a call that must not fail silently explicitly.
- **Guard words:** strings must not contain the words the guard looks for (`tests/lint/guard.sh`), even in messages.

Docs use US spelling, no draft version numbers, no review logs or "reviewed on" dates (Git keeps the history), and APA 7 citations for rules.
