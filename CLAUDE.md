@AGENTS.md

## Claude Code

The `scout`, `builder` and `verifier` agents and the project's commands (`/start-issue`, `/new-module`, `/pre-pr`) live in `.claude/`, shared by everyone. Personal rules go in `CLAUDE.local.md` and personal settings in `.claude/settings.local.json`; git ignores both. Decisions go in the specs or in issues, never only in an assistant's memory, so every contributor sees them.

`.claude/settings.json` blocks running the runners, `bats`, Pester and the guard, so nothing an assistant does can change the machine it runs on; CI runs them instead. For a local syntax check, which only parses and never runs anything, use `bash -n <file>` and `pwsh -NoProfile -File tools/lint/syntax.ps1`.

Before a branch is handed over for merge, run `/pre-pr`: the `verifier` subagent checks its diff against the public boundary and the hard rules in `AGENTS.md`.
