# 18. Service Packs and Config Library

**Status:** Draft · reviewed 2026-10-02 · Phase: 🟥 Lock out · Priority: P1

## 1. Goal

Scored services are a primary Red Team target, and a successful penetration costs points (National Collegiate Cyber Defense Competition [NCCDC], 2025, Scoring section). Leaving them exactly as found protects the score from our own mistakes, but it also leaves the most-attacked software exposed.

This spec ships a **service pack** for each common scored app and a small **config library** for host settings. Each pack is a set of pre-written settings, tested in the lab, that Labyrinth can apply quickly and repeatedly without breaking the service. Settings that are safe are applied automatically; risky ones wait for a person; anything too app-specific becomes a runbook.

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | Every setting is followed by scoring-style probes, under a revert timer. |
| Do not mislead the scoring engine (NCCDC, 2025, Rule 9.3). | A pack never fakes a response or changes what a check sees to make a broken service look healthy. |
| Scored services may not be migrated or containerized (NCCDC, 2025, Rule 4.14). | Packs change settings in place. They never replace or move a service. |
| Team tools may not use outside resources apart from DNS (NCCDC, 2025, Rule 5.6.4). | Packs use only software already on the host. They never add a module or package. |
| Tools must not deliberately break expected functionality (NCCDC, 2025, Rule 5.6.5). | Settings that could change what users or the scoring engine see are never automatic (section 4). |

## 3. How a setting is applied

1. **Read the facts.** The run-time `services` file says which services are scored and what each probe expects (design 00, section 6). The pack also reads the installed version.
2. **Add, don't replace.** Each setting goes into an add-on file in the app's own include folder (for example `conf.d`). The main configuration file is backed up and not rewritten. If the app has no include folder, the change is in the approval class and edits the main file after a backup.
3. **Check with the app's own test**: `nginx -t`, `apachectl configtest`, `named-checkconf`, `postfix check`, `doveconf -n`, `vsftpd` start test, or the IIS configuration validator. A failed test stops the change.
4. **Reload gently.** A graceful reload where the app supports one, not a full restart.
5. **Probe and revert.** Probes run before and after; a revert timer undoes the change unless verify passes (design 01, section 8).
6. **Record.** Every change goes into the run manifest, so `rollback` restores it.

Re-running a pack finds nothing to change and exits 0 (design 00, section 4).

## 4. Classes of setting

| Class | Test for the class | Runs |
|---|---|---|
| **Automatic** | Does not change what users or the scoring engine see, and was tested on this app version in the lab | In the lockout phase, Tier 2 (design 01) |
| **Approval** | Could change what the scoring engine sees, or the installed version was not tested | Shown in the plan; after a person approves, Labyrinth applies it (Tier 3) |
| **Runbook** | Too specific to the event's own app or data | Printed steps for a person, kept in the release's runbook folder |

## 5. The packs

Examples per pack (*Background*; each is confirmed in the lab before release):

| App | Automatic | Approval | Runbook |
|---|---|---|---|
| nginx | Hide the version; turn off directory listing where nothing uses it; security headers that do not change page content | Minimum TLS version and ciphers; request size and rate limits | Web application settings and code |
| Apache httpd | Hide the version and OS banner; turn off directory listing and server-status where unused | Turn off modules; TLS settings | Web application settings and code |
| IIS | Remove version headers; turn off directory browsing | TLS settings; request filtering | Application pools and web application settings |
| Postfix | Hide the version banner; refuse to relay for outside senders where the packet confirms it | Authentication and TLS settings | Mailbox and alias changes |
| Dovecot | Turn off plain-text login without TLS where the probe and packet allow | Authentication mechanisms | Mailbox changes |
| BIND | Hide the version; refuse zone transfers to anyone but listed secondaries; turn off open recursion for outside clients | Rate limits | Zone contents |
| Windows DNS | Refuse zone transfers to unlisted servers | Recursion settings | Zone contents (design 11, section 5) |
| MySQL / MariaDB | Bind to the addresses the scored app uses; turn off local file loading | Remove anonymous and test accounts | Application database users and grants |
| vsftpd (FTP) | Hide the banner version | Turn off anonymous login, and lock each user into their own folder; approval because a scoring check may use either | — |
| OpenSSH | See design 05, section 4 | — | — |

## 6. Host settings (config library)

A `sysctl.d` add-on file for Linux kernel settings that rarely affect services (*Background*):

- `kernel.dmesg_restrict = 1` and `kernel.kptr_restrict = 1`;
- `fs.protected_symlinks = 1`, `fs.protected_hardlinks = 1`;
- `net.ipv4.tcp_syncookies = 1`;
- `net.ipv4.conf.all.accept_redirects = 0`, `accept_source_route = 0`;
- `kernel.yama.ptrace_scope = 1` where the module exists.

Never automatic: `net.ipv4.ip_forward` (routers and container hosts need it), `send_redirects` on a router, and reverse-path filtering (`rp_filter`), which can break traffic that returns by another route. Those are in the approval class.

## 7. Versions and testing

- Each pack lists the app versions it was tested on in the lab.
- On an untested version, every setting moves to the approval class.
- Each automatic setting has a lab test showing that the scoring-style probe still passes and that the setting took effect.

## 8. Runbooks

Whatever is not automated is written up as a runbook in the release: what to check, what to change, how to test it, and how to undo it. These double as response guides when the team sees an attack on that service.

## 9. What it will never do

- Replace a main configuration file without a backup and a person's approval.
- Restart a scored service when a graceful reload is available.
- Install, download or enable a module that is not already present.
- Make a broken service look healthy.

## 10. Acceptance tests

- Each pack, run twice on its lab host, changes nothing the second time.
- Every automatic setting leaves the scoring-style probe passing.
- A setting that fails the app's own syntax test is not applied and leaves the service unchanged.
- A forced probe failure is reverted by the timer.
- On a version not listed as tested, the pack applies nothing automatically.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
