# Instructions for coding assistants

This file is for any assistant working on Labyrinth: Copilot, Codex, Cursor, Gemini or another. The rules live in one place, [`CLAUDE.md`](CLAUDE.md), and they bind every contributor, whatever tool they use. Read it in full before changing anything.

The rules an assistant most often gets wrong:

- **The repository is public.** Never add team strategy, schedules, event values, real hostnames, addresses, credentials or anything from a team's private notes (`CLAUDE.md`, "Public boundary").
- **The specs decide.** `docs/design/` is the source of truth. Fix the spec first, on the same branch, if it is wrong.
- **Both platforms.** A change the spec covers on both platforms goes into `labyrinth.sh` and `labyrinth.ps1`, with tests in bats and Pester. PowerShell code must run on Windows PowerShell 5.1.
- **No blanket actions.** Every change works from an explicit list and skips the protected set; nothing is deleted outside Labyrinth's own paths.
- **Never edit the compatibility suite** (`tests/runner/compat.bats`, `tests/runner/Compat.Tests.ps1`) to make a change pass.
- **The workflow.** One issue, one branch, one small pull request, merged after CI passes and a second person approves (`CONTRIBUTING.md`).
