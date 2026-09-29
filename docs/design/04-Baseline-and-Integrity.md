# 04. Baseline and Integrity

**Status:** Draft · reviewed 2026-09-29 · Phase: 🟦 Observe · Priority: P0 (first baseline), P1 (continuous)

## 1. Goal

Know what a host looks like, then learn quickly what changed, who changed it, when, and from where. This information feeds the incident reports (design 02) and the decoy and status systems.

## 2. The trap in "hash everything at minute zero"

A hash baseline taken after the Red Team already has a foothold records the compromised state as normal. So the first step is to verify files against a trusted source, and only then take the baseline.

| Step | Linux | Windows |
|---|---|---|
| Verify against the package or OS database | `dpkg --verify` (Debian family), `rpm -Va` (RHEL, Red Hat Enterprise Linux, family) | Authenticode signature checks; `sfc /verifyonly` (read-only, but slow and CPU-heavy, so schedule it) |
| Record unexplained differences | As findings, not as baseline | As findings, not as baseline |
| Baseline the rest | SHA-256 of critical files, permissions, owners | Same, plus registry autoruns and services |

Configuration files legitimately differ from their packages, so differences in `/etc` are reviewed by a human, not accepted automatically.

## 3. What is baselined

- Critical files: authentication configuration, SSH (Secure Shell) configuration, sudoers, cron and timer definitions, service unit files, web server configuration, startup items.
- Accounts, groups, authorized keys, listening ports, running services, scheduled tasks.
- Firewall state.
- Windows: local administrators, autoruns, services, WMI (Windows Management Instrumentation) subscriptions, scheduled tasks.

The baseline is stored under the state path (design 00) with a signed manifest (design 07). Baselines are compared, never silently overwritten.

## 4. Who, when, from where

| Question | Linux | Windows |
|---|---|---|
| What changed | Hash mismatch, plus auditd file watches on the critical set | Event 4663 object access, Sysmon file events |
| Who | auditd `auid` (login identity that survives `sudo`) | Security event account fields |
| When | Event timestamp | Event timestamp |
| From where | Join `ses` to the `USER_START` record, which holds the source address | Join event 4663 to logon event 4624 by logon ID |

> [!IMPORTANT]
> **Caveat.** The address is the last hop the host saw. Through NAT (network address translation) or a proxy it may not be the true origin. Reports say so (design 02).

```mermaid
flowchart TD
    V["Verify files against the package or OS database<br/>(dpkg --verify · rpm -Va · signatures · sfc /verifyonly)"]
    V -->|differences| F["Findings for a human<br/>(never baselined)"]
    V -->|matches| B["Baseline: SHA-256, owners, permissions,<br/>accounts, keys, ports, services, tasks"]
    B --> CMP["Scheduled comparison"]
    CMP -->|change seen| J["Join audit records:<br/>who (auid / account) · when (timestamp)<br/>from where (last-hop address)"]
    J --> R["Integrity log and<br/>incident report (design 02)"]
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    class V,B,CMP,J observe
    class F human
    class R store
```

*Figure: files are first checked against the package database, only clean results become the baseline, and a later change is joined to audit records to show who changed it, when and from which address. Blue steps are automated observation, amber marks work handed to a person, and gray is where the results are stored.*

## 5. Logging that makes this possible

- **Linux:** auditd rules for the critical set, kept small to avoid log floods.
- **Windows:** object access auditing on the critical set, process creation with command line, and Sysmon if it is available inside the environment. Only tools available to all teams and within the rules may be used (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.1).
- **All hosts:** every host forwards a small set of high-signal events first (design 06 and the Strategic Plan).

## 6. Continuous integrity

- Scheduled comparison against the baseline; results go to the `integrity` log category.
- Findings are ranked: changes to authentication, SSH, sudoers and scheduled execution rank highest.
- A change made by Labyrinth itself is recorded in the run manifest and excluded from alerts.

## 7. Rules check

Read-only observation does not affect scored services and needs no special permission. Auditing must not disable or slow a scored service, so watch lists stay small (NCCDC, 2025, Rule 4.11).

## 8. Acceptance tests

- A file modified by hand in the lab is flagged with account, time and source address.
- A binary replaced with a trojan is caught by the package verification step, not baselined.
- A change made by a Labyrinth module does not raise an alert.
- Baseline comparison completes within the target time on the lab host.
- Auditing on the critical set does not measurably slow a scored service probe.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
