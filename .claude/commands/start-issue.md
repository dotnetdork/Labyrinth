---
description: Start work on a GitHub issue — check it is free, branch from main, read the spec, and propose a plan
argument-hint: <issue number>
---

Start work on issue #$ARGUMENTS.

1. Read it with `gh issue view $ARGUMENTS --comments`. If it is assigned to someone else, or an open pull request already covers it (`gh pr list --search "$ARGUMENTS"`), stop and say so. One issue, one person.
2. If it is unassigned, ask me before assigning it (`gh issue edit $ARGUMENTS --add-assignee @me`).
3. Make sure the working tree is clean, then update main: `git switch main` and `git pull --ff-only`.
4. Pick the branch name: the one the issue and `docs/Roadmap.md` give for code, or `docs/<name>` for documentation only. Create it with `git switch -c <branch>`.
5. Read every link in the issue's **Read first** section, and the parts of `docs/Conventions.md` they rely on. If the issue and the spec disagree, the spec wins. If the spec is ambiguous or wrong, say so now: fixing the spec is the first commit on the branch.
6. Reply with a short plan: the files you expect to touch, the acceptance tests you will write first, and any question that needs an answer before you start. Wait for my go-ahead.
