# Security policy

Labyrinth runs as root or Administrator on machines people are defending, so a weakness in it matters. A weakness someone could use today goes through private reporting; other security work is tracked in public issues, like any bug.

## Supported versions

Fixes go to `main`. Once Labyrinth has releases, the latest release gets them too, in the next release.

## Private or public

**Report privately** a weakness a person could use today against a host running Labyrinth: something the current `main` or the latest release does, on a path a run, an undo or the revert timer actually takes, that would let someone break a scored service, lock out its operators or officials, read a secret from a log, manifest or backup, gain root or Administrator, or make Labyrinth change something outside its explicit lists, against what `AGENTS.md` and the specs promise.

**Open a public issue** (labeled `type: security`) for:

- A hardening gap: Labyrinth works as specified, but could check more, such as a race or a missing ownership check with no way to use it yet.
- A flaw in code that nothing reaches yet, such as a core helper no module calls. Say in the issue why it is not reachable today, and which planned work would make it reachable.
- A gap in the software Labyrinth hardens that is already public knowledge, such as a published CVE.

If you are not sure which it is, report it privately; a maintainer moves it to a public issue if it can be.

## Reporting a weakness

Use **[Report a vulnerability](https://github.com/dotnetdork/Labyrinth/security/advisories/new)** on the repository's Security tab. Only the maintainers see the report. Please do not open a public issue, pull request or discussion about a weakness that goes private.

Say what you found, where (file and line, or the command and its output), and what someone could do with it. Keep it to what a fix needs: no working attack against anyone's systems.

## What counts

Labyrinth itself: the runners, `core/`, the modules, the release and install scripts, and the CI workflows.

Not in scope: weaknesses in the software Labyrinth hardens (report those to its vendor), and findings that need an attacker who is already root on the host.

## Good-faith research

Testing your own copy of Labyrinth on machines you own or are allowed to test, such as your own lab, is welcome. A report made in good faith under this policy will not be held against the person who makes it. This covers Labyrinth only, never testing other people's systems.

## What happens next

A maintainer replies within a few days, agrees the fix and its timing with you, and credits you in the advisory unless you would rather not be named. The fix goes to `main`, and the advisory is published once it is there, or, once Labyrinth has releases, once the release with the fix is out.
