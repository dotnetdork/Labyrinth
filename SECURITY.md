# Security policy

Labyrinth runs as root or Administrator on machines people are defending, so a weakness in it matters. Please report one privately.

## Supported versions

Only the latest release and `main` receive fixes.

## Reporting a weakness

Use **[Report a vulnerability](https://github.com/dotnetdork/Labyrinth/security/advisories/new)** on the repository's Security tab. Only the maintainers see the report. Please do not open a public issue, pull request or discussion about it.

Say what you found, where (file and line, or the command and its output), and what someone could do with it. Keep it to what a fix needs: no working attack against anyone's systems.

## What counts

- Labyrinth itself: the runners, `core/`, the modules, the release and install scripts, and the CI workflows.
- A way Labyrinth could break a scored service, lock out its operators or officials, leak a secret into a log, manifest or backup, or change something outside its explicit lists, against what `AGENTS.md` and the specs promise.

Not in scope: weaknesses in the software Labyrinth hardens (report those to its vendor), and findings that need an attacker who is already root on the host.

## Good-faith research

Testing your own copy of Labyrinth on machines you own or are allowed to test, such as your own lab, is welcome. A report made in good faith under this policy will not be held against the person who makes it. This covers Labyrinth only, never testing other people's systems.

## What happens next

A maintainer replies within a few days, agrees the fix and its timing with you, and credits you in the advisory unless you would rather not be named. The fix ships in the next release, and the advisory is published once that release is out.
