---
description: Check a branch before opening its pull request — boundary, hard rules, spec, both platforms, manual
---

Check the current branch before it becomes a pull request.

1. Show what the branch changes: `git fetch origin` then `git diff --stat origin/main...HEAD` and `git log --oneline origin/main..HEAD`. If the branch mixes unrelated changes, say so: one issue, one small pull request.
2. Have the `verifier` subagent review `git diff origin/main...HEAD` against the public boundary, the hard rules in `AGENTS.md`, and the spec the branch implements.
3. Check the list in `.github/pull_request_template.md` item by item and report each as done, not needed, or missing:
   - the spec was read, and any spec change is on this branch with its reason in the commit message;
   - tests in both suites where the spec covers both platforms, including the negative test;
   - a command-line change is in both runners and in `docs/manual/labyrinth.md`;
   - lines that install or download carry the guard's allow comment;
   - no secrets, event values, real hostnames, addresses or team details.
4. If the branch is not pushed yet, ask me before pushing it. Then give me the `gh pr create` command with a title and a body filled from the template, ending with `Closes #<issue>`. Do not merge.
