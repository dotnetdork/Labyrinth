# Contributing to Labyrinth

Thanks for helping. Labyrinth is public, and every line of it is shared with every competing team. Read [`AGENTS.md`](AGENTS.md) first: its hard rules and its public boundary apply to every change, whoever or whatever writes it.

## Ways to contribute

- **Report a bug** in Labyrinth's behavior: open an issue from the Bug template.
- **Fix or improve the documentation:** open an issue, or a small pull request on a `docs/<name>` branch.
- **Build a Roadmap item:** pick an open issue in the current milestone ([`docs/Roadmap.md`](docs/Roadmap.md)) and follow the workflow below. `good first issue` marks a small, self-contained place to start.
- **Propose something beyond the Roadmap:** open an issue from the Feature template.
- **Report a weakness in Labyrinth itself:** never in a public issue. Use [private reporting](SECURITY.md).

## The public boundary

Generic, reusable defense logic only. Never add team strategy, schedules, deadlines, event values, real topology, hostnames, addresses, credentials or details about team members. Events differ, so every event value is supplied at run time from a `*.example` template, never committed.

## The workflow: one issue, one person, one branch, one small pull request

1. **Pick an issue.** Work starts from a GitHub issue. Assign it to yourself before you start, so two people never build the same thing. If there is no issue for what you want to do, open one first.
2. **Branch from the latest `main`.** Use the branch name the issue and [`docs/Roadmap.md`](docs/Roadmap.md) give, such as `phase-4/ssh` for code, or `docs/<name>` for documentation only.
3. **Read first.** Open every link in the issue's **Read first** section, then the spec. The specs in [`docs/design/`](docs/design/README.md) are the source of truth. If the spec is wrong or vague, fix it on the same branch before writing code, and say why in the commit message.
4. **Tests first.** Write them from the spec's acceptance-test list, in bats for bash and Pester 5 for PowerShell, including the negative test that protected accounts and scored services are untouched. Make the change in both runners where the spec covers both platforms.
5. **Keep it small.** One component per pull request. A follow-up step stays on the same branch; an unrelated problem you find becomes a new issue, not part of this change.
6. **Open the pull request** with the template filled in and `Closes #<issue>` in its description.
7. **Merge** once CI is green and someone other than the author approves it. The branch must be up to date with `main`.

Never push to `main`, force-push, rewrite published history, or delete a branch you did not create.

## Tests

CI runs on every push: ShellCheck, the guard (`tests/lint/guard.sh`), bats, PSScriptAnalyzer, Pester under Windows PowerShell 5.1, and the manual build. All must pass. A branch that changes only documentation (outside `docs/manual/`) skips these tests, and they show as skipped, which counts as passing. You may run the suites locally if you already have the tools, but nobody needs to install anything: pushing the branch and reading the CI results is enough.

## Issues, labels and milestones

Open an issue from a template. Write it so someone new, or their AI assistant, can pick it up without asking you anything. Each issue has these parts, in this order:

1. **Read first:** links to the exact spec sections, the Roadmap row, the Conventions sections and the `AGENTS.md` rules the work needs, then the line "Read these before starting. If this issue and the spec disagree, the spec wins; say so in the pull request."
2. **Summary:** two to four plain sentences: what it is and why it matters.
3. **Depends on:** the issues it is blocked by and the ones it blocks, matching GitHub's links.
4. **Location & Context:** the branch, the module ID, and the real files and functions.
5. **Current Behavior:** what Labyrinth does today, and why that falls short.
6. **Plan:** short numbered steps.
7. **Acceptance tests:** a checklist, written first, including the negative test that protected accounts and scored services are untouched.
8. **Done when:** a checklist, such as both platforms passing CI, the manual and help pages written, and the lab tests passing.
9. **Out of scope:** nearby work that belongs to another issue, with its number.

A bug or a cleanup can leave out the parts that do not apply. The title is a short action with no prefix, such as `Add the imap probe`; the labels carry the type.

| Label group | Use |
|---|---|
| `type:` | One per issue: `build` (a planned Roadmap item), `feature` (a new capability beyond the Roadmap), `bug`, `tech-debt`, `docs`, or `security` (only for a hardening gap that is public knowledge; a weakness in Labyrinth itself goes through [private reporting](SECURITY.md)) |
| `phase:` | The run phase it belongs to: `lockout`, `harden`, `observe`, `deceive`, `sustain` |
| `area:` | The part of the code it touches, such as `firewall`, `accounts` or `command-line` |
| `platform:` | `linux`, `windows`, both, or `appliance` |
| `cve` | It concerns a published CVE. The CVE ID goes in the title, for example `Mitigate CVE-2024-6387 in sshd` |
| `good first issue` | Small and self-contained, a good place to start |

Each label group has its own color: the phase labels use the phase colors of the docs site, and the `type:` labels are pale except `bug` and `security`.

The **milestone** says when an issue is built: the first usable release, then the later milestones in the order of [`docs/Roadmap.md`](docs/Roadmap.md). There are no priority labels; the milestone and the Roadmap's order are the priority. When one issue cannot start until another is done, mark it with GitHub's **blocked by** relationship; a Roadmap row split into steps becomes a parent issue with **sub-issues**.

## Using an AI assistant

Any assistant, or none, works. The rules in [`AGENTS.md`](AGENTS.md) apply either way; most assistants read that file on their own, `CLAUDE.md` pulls it in for Claude Code, and `.github/copilot-instructions.md` points Copilot to it.

### With Claude Code

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

### Without Claude Code

Copilot, another assistant or plain hands all work. The shared commands in `.claude/commands/` are checklists you can follow yourself:

1. **Claim the issue** (`/start-issue`): check nobody is assigned and no pull request covers it, assign yourself, update `main`, create the branch, and read every link in the issue's **Read first** section.
2. **Build a module** (`/new-module`): create the folder and `module.yml` from the module contract (design 00), and write the tests from the spec's acceptance-test list first.
3. **Before the pull request** (`/pre-pr`): read your own diff against the public boundary and the hard rules in `AGENTS.md`, tick every box in the pull request template, and push the branch so CI runs.

## Ownership and license

Jay Sausa is the sole owner of Labyrinth. By contributing you agree to the terms in [`LICENSE`](LICENSE), and contributing gives you no ownership of Labyrinth. A contributor whose contributions are substantial may ask to discuss co-ownership; the license explains how that works.
