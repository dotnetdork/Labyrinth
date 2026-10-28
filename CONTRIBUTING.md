# Contributing to Labyrinth

Labyrinth is public, and every line of it is shared with every competing team. Read [`AGENTS.md`](AGENTS.md) first: its hard rules and its public boundary apply to every change, whoever or whatever writes it.

## The workflow: one issue, one person, one branch, one small pull request

1. **Pick an issue.** Work starts from a GitHub issue. Assign it to yourself before you start, so two people never build the same thing. If there is no issue for what you want to do, open one first.
2. **Branch from the latest `main`.** Name the branch after the build stage in [`docs/Roadmap.md`](docs/Roadmap.md): `phase-<n>/<name>` for code (for example `phase-4/ssh`), or `docs/<name>` for documentation only.
3. **Read the spec first.** The specs in [`docs/design/`](docs/design/README.md) are the source of truth. If the spec is wrong or vague, fix it on the same branch before writing code, and say why in the commit message.
4. **Tests first.** Write them from the spec's acceptance-test list, in bats for bash and Pester 5 for PowerShell, including the negative test that protected accounts and scored services are untouched. Make the change in both runners where the spec covers both platforms.
5. **Keep it small.** One component per pull request. A follow-up step stays on the same branch; an unrelated problem you find becomes a new issue, not part of this change.
6. **Open the pull request** with the template filled in and `Closes #<issue>` in its description.
7. **Merge** once CI is green and someone other than the author approves it. The branch must be up to date with `main`.

Never push to `main`, force-push, rewrite published history, or delete a branch you did not create.

## Issues, labels and milestones

Open an issue from a template; each asks for the same three parts: **Location & Context**, **Current Behavior** and **Remediation Plan**. Write it so someone new, or their assistant, can pick it up without asking you anything.

| Label group | Use |
|---|---|
| `type:` | One per issue: `bug`, `enhancement`, `tech-debt`, `docs`, or `security` (only for a hardening gap that is public knowledge; a weakness in Labyrinth itself goes through [private reporting](SECURITY.md)) |
| `phase:` | The run phase it belongs to: `lockout`, `harden`, `observe`, `deceive`, `sustain` |
| `area:` | The part of the code it touches, such as `firewall`, `accounts` or `command-line` |
| `platform:` | `linux`, `windows`, both, or `appliance` |
| `cve` | It concerns a published CVE. The CVE ID goes in the title, for example `[Enhancement] Mitigate CVE-2024-6387 in sshd` |
| `good first issue` | Small and self-contained, a good place to start |

The **milestone** is the build stage in [`docs/Roadmap.md`](docs/Roadmap.md), section 3. When one issue cannot start until another is done, mark it with GitHub's **blocked by** relationship; a Roadmap row split into steps becomes a parent issue with **sub-issues**.

## Without Claude Code

Copilot, another assistant or plain hands all work. The rules in [`AGENTS.md`](AGENTS.md) apply either way; most assistants read that file on their own, `CLAUDE.md` pulls it in for Claude Code, and `.github/copilot-instructions.md` points Copilot to it. The shared commands in `.claude/commands/` are checklists you can follow yourself:

1. **Claim the issue** (`/start-issue`): check nobody is assigned and no pull request covers it, assign yourself, update `main`, create the branch, and read the spec sections the issue names.
2. **Build a module** (`/new-module`): create the folder and `module.yml` from the module contract (design 00), and write the tests from the spec's acceptance-test list first.
3. **Before the pull request** (`/pre-pr`): read your own diff against the public boundary and the hard rules in `AGENTS.md`, tick every box in the pull request template, and push the branch so CI runs.

## Tests

CI runs on every push: ShellCheck, the guard (`tests/lint/guard.sh`), bats, PSScriptAnalyzer, Pester under Windows PowerShell 5.1, and the manual build. All must pass. A branch that changes only documentation (outside `docs/manual/`) skips these tests, and they show as skipped, which counts as passing. You may run the suites locally if you already have the tools, but nobody needs to install anything: pushing the branch and reading the CI results is enough.

## Working with Claude Code

The repository ships a shared setup in `.claude/`, so every contributor's assistant works the same way:

| Shared | What it is for |
|---|---|
| `AGENTS.md` | The rules every contributor and assistant follows: hard rules, the public boundary, the module contract and the workflow above |
| `CLAUDE.md` | Pulls in `AGENTS.md` for Claude Code and adds its subagents and commands |
| `.claude/agents/` | `scout` for cheap lookups, `builder` for implementing a settled spec, `verifier` for an independent review before a pull request |
| `.claude/commands/` | `/start-issue <number>` to claim an issue and branch, `/new-module <phase>/<name>` to scaffold a module from its spec, `/pre-pr` to check a branch before its pull request |
| `.claude/settings.json` | Read-only git and GitHub commands run without asking; pushes, merges and branch deletions ask first; the usual forms of force-push and push to `main` are refused. GitHub's branch protection is what enforces the rules for everyone |

Keep personal preferences out of the shared files:

- **Personal rules** go in `CLAUDE.local.md` at the repository root, and **personal settings** in `.claude/settings.local.json`. Git ignores both.
- **Decisions go in the repository**, in a spec or an issue, never only in an assistant's memory. Another contributor's assistant cannot see your memory, so a decision kept there leads to work that drifts apart.
- **Run `/pre-pr`** before opening a pull request. It has the `verifier` agent check the diff against the public boundary and the spec.

Changes to `AGENTS.md`, `CLAUDE.md` or `.claude/` go through a pull request like any other change, so everyone's setup changes together.

## The public boundary

Generic, reusable defense logic only. Never add team strategy, schedules, deadlines, event values, real topology, hostnames, addresses, credentials or details about team members. Events differ, so every event value is supplied at run time from a `*.example` template, never committed.

## Ownership

By contributing you agree to the terms in [`LICENSE`](LICENSE). Ownership is recorded in [`CONTRIBUTORS.md`](CONTRIBUTORS.md).
