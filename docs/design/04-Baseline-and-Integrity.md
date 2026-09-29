# 04. Baseline and Integrity

**Status:** Draft 1 · 2026-09-29 · Phase: Observe · Priority: P0 (first baseline), P1 (continuous)

## 1. Goal

Know what a host looks like, then learn quickly what changed, who changed it, when, and from where. This feeds incident reports (design 02) and the decoy and status systems.

## 2. The trap in "hash everything at minute zero"

A hash baseline taken after the Red Team already has a foothold records the compromised state as normal. So the first step is to verify against a trusted source, then baseline.

| Step | Linux | Windows |
|---|---|---|
| Verify against the package or OS database | `dpkg --verify` (Debian family), `rpm -Va` (RHEL family) | Authenticode signature checks, `sfc /verifynow` |
| Record unexplained differences | As findings, not as baseline | As findings, not as baseline |
| Baseline the rest | SHA-256 of critical files, permissions, owners | Same, plus registry autoruns and services |

Config files legitimately differ from packages, so differences in `/etc` are reviewed by a human, not auto-accepted.

## 3. What is baselined

- Critical files: authentication configuration, SSH configuration, sudoers, cron and timer definitions, service unit files, web server configuration, startup items.
- Accounts, groups, authorised keys, listening ports, running services, scheduled tasks.
- Firewall state.
- Windows: local administrators, autoruns, services, WMI subscriptions, scheduled tasks.

The baseline is stored under the state path (design 00) with a signed manifest (design 07). Baselines are compared, never silently overwritten.

## 4. Who, when, from where

| Question | Linux | Windows |
|---|---|---|
| What changed | Hash mismatch, plus auditd file watches on the critical set | Event 4663 object access, Sysmon file events |
| Who | auditd `auid` (login identity that survives `sudo`) | Security event account fields |
| When | Event timestamp | Event timestamp |
| From where | Join `ses` to the `USER_START` record, which holds the source address | Join event 4663 to logon event 4624 by logon ID |

**Caveat.** The address is the last hop the host saw. Through NAT or a proxy it may not be the true origin. Reports say so (design 02).

## 5. Logging that makes this possible

- Linux: auditd rules for the critical set, kept small to avoid log floods.
- Windows: object access auditing on the critical set, process creation with command line, and Sysmon if it is available inside the environment. Only tools available to all teams and within the rules may be used (NCCDC, 2025, Rule 5.1).
- Every host forwards a small set of high-signal events first (design 06 and the Strategic Plan).

## 6. Continuous integrity

- Scheduled comparison against the baseline; results go to the `integrity` log category.
- Findings are ranked: changes to authentication, SSH, sudoers and scheduled execution rank highest.
- A change made by Labyrinth itself is recorded in the run manifest and excluded from alerts.

## 7. Rules check

Read-only observation does not affect scored services and needs no special permission. Auditing must not disable or slow a scored service. Watch lists stay small (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 4.11).

## 8. Acceptance tests

- A file modified by hand in the lab is flagged with account, time and source address.
- A binary replaced with a trojan is caught by the package verification step, not baselined.
- A change made by a Labyrinth module does not raise an alert.
- Baseline comparison completes within the target time on the lab host.
- Auditing on the critical set does not measurably slow a scored service probe.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
