# 11. Windows and Active Directory Hardening

**Status:** Draft · reviewed 2026-10-02 · Phase: 🟥 Lock out · Priority: P0 (credentials, firewall), P1 (the rest)

## 1. Goal

Give the `windows-member` and `windows-dc` profiles (Blueprint §6.3) the same guarded treatment the Linux profiles get. Windows hosts and the AD (Active Directory) domain controller carry some of the highest-impact weaknesses in a typical competition network, and the domain controller is also the most dangerous host to change: a mistake there can break every logon and every DNS (Domain Name System) lookup at once.

So this spec splits the work by blast radius. A change that affects one host is automated with the panic button's guard rails (design 01). A change that affects the whole domain is a printed checklist.

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Administrator-class passwords are not used for scoring and may be changed freely; other user passwords follow the notification process (Midwest Collegiate Cyber Defense Competition [MWCCDC], 2025, Rule 13; *Provisional*). | Automation rotates only the built-in and administrator-class accounts. |
| Scored services have used AD users, for example for POP3 (Post Office Protocol 3) mail logins (MWCCDC, 2025, Functional Services section; *Provisional*). | Domain-wide resets, domain account changes and domain policy changes are done by a person from a checklist (section 5). |
| Tools must not deliberately break expected functionality (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.5). | Every change comes from an explicit list and skips the protected set. |
| Officials must be given access on request (NCCDC, 2025, Rule 4.1). | When an official asks, the captain gives them a working login (design 05, section 5). Remote Desktop and firewall restrictions still allow the admin source and any official sources named in the event packet. |
| Scoring is based partly on controlling and preventing unauthorized access (NCCDC, 2025, Scoring section), and scored services are a primary Red Team target. | Where RDP or WinRM is itself scored, the restriction also allows the scoring engine, and the service is hardened rather than closed (section 3). |
| Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | DNS on the domain controller is treated as scored and changed by hand only (Blueprint §4.6). |

## 3. Blast radius decides the tier

| Tier | Member servers and workstations | Domain controller |
|---|---|---|
| **0. Observe** | Local admins, services, scheduled tasks, autoruns, listeners (design 04); SMBv1, LLMNR, NBT-NS, RDP and WinRM state | All of the left, plus: privileged group membership (Domain Admins, Enterprise Admins, Schema Admins, Administrators), accounts with a service principal name, linked Group Policy objects, Print Spooler state |
| **1. Safe and reversible** | Rotate the built-in Administrator and other local admin-class passwords that nothing logs on with (design 05, section 2); turn on the audit policy (design 10) | Audit policy (design 10). No password is rotated automatically: every account on a domain controller is a domain account (section 7) |
| **2. Service-affecting, per host with a revert timer** | Default-deny inbound firewall (design 01); require NLA (Network Level Authentication) for RDP; allow RDP and WinRM only from the admin source, plus the scoring engine where either is scored; turn off SMBv1 server; turn off LLMNR and NBT-NS in local policy; the protocol settings below; stop and disable Print Spooler where nothing prints; remove unexpected local Administrators members that nothing depends on (design 05, section 6) | Firewall as on the left, applied last, after the member servers pass, and always allowing domain traffic from member hosts (below); RDP, WinRM and the protocol settings as on the left; stop and disable Print Spooler if printing is not scored |
| **3. Approve, then act** | Labyrinth acts after approval: removing a local Administrators member that might be a service dependency; protocol settings in the approval class (below) | A person acts, from the checklist in section 5: rotating the domain Administrator password; KRBTGT reset (twice, with a replication wait); creating domain honey-accounts (design 09); removing members from domain admin groups; domain password resets; disabling and deleting domain accounts; any Group Policy change; service account resets; LAPS (Local Administrator Password Solution) roll-out; any DNS server change |

**Protocol settings** (*Background*; each per host, in the registry, under the revert timer):

| Setting | Why | Class |
|---|---|---|
| NTLMv2 only; LM and NTLMv1 refused (`LmCompatibilityLevel` 5); no LM hashes stored (`NoLMHash`) | Older hash formats are cracked or relayed easily | Automatic |
| WDigest off (`UseLogonCredential` 0) | Otherwise plain-text passwords sit in memory for tools such as Mimikatz to read. Turning it back on raises an alert (design 10). | Automatic |
| No anonymous listing of accounts and shares (`RestrictAnonymous`, `RestrictAnonymousSAM`; `EveryoneIncludesAnonymous` 0) | Stops attackers listing users without a password | Automatic |
| Turn off automatic proxy discovery (WPAD) | Lets an attacker on the network pose as a proxy and collect hashes | Automatic |
| Require SMB signing on the server side | Stops relayed logons to file shares | Automatic where SMB is not scored; approval where it is, because an old scoring client may not sign |

**Domain traffic to the domain controller.** Its default-deny firewall always allows, from the member hosts' addresses: DNS (53), Kerberos (88, 464), time (123/UDP), RPC (135 and the dynamic range), LDAP (389, 636, 3268 and 3269) and SMB (445). Without these, every logon in the domain fails.


- **Why Group Policy is manual.** One Group Policy change reaches every machine in the domain at once. That is the "indiscriminate" pattern the rules warn about (NCCDC, 2025, Rule 5.6.5), so it stays with a person who can watch the effect.
- **Why Print Spooler.** The print spooler has had several serious remote vulnerabilities, and a domain controller rarely needs to print (*Background*). It is turned off only when printing is not a scored service on that host.
- **Why local policy for LLMNR and NBT-NS.** Both let an attacker on the network answer name lookups and collect password hashes (*Background*). The per-host setting keeps the blast radius to one host; the domain-wide setting is a Group Policy change and therefore Tier 3.

```mermaid
flowchart TD
    T0["<b>Tier 0</b> on every Windows host<br/>read-only report"] --> MEM
    subgraph MEM["Member servers and workstations, ring by ring"]
        M1["Tier 1: local admin passwords,<br/>audit policy"] --> M2["Tier 2 with revert timer:<br/>firewall · RDP · WinRM · SMBv1 · LLMNR<br/>NBT-NS · NTLM · WDigest · Print Spooler"]
    end
    MEM --> DC
    subgraph DC["Domain controller, last"]
        D1["Tier 1 and Tier 2, host-only settings,<br/>with DNS and logon probes"] --> D3["Tier 3 checklist:<br/>domain Administrator · KRBTGT · domain groups<br/>Group Policy · DNS · domain accounts · LAPS"]
    end
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    class T0 observe
    class M1 ok
    class M2,D1 human
    class D3 lockout
    style MEM fill:#f8fafc,stroke:#94a3b8,color:#1e293b
    style DC fill:#f8fafc,stroke:#94a3b8,color:#1e293b
```

*Figure: every Windows host is observed first, member servers and workstations are changed ring by ring, and the domain controller comes last, with its domain-wide changes left to a person. Colors follow the risk tiers of design 01: blue is read-only, green safe, amber service-affecting and red a person's checklist.*

## 4. Domain controller probes

A domain controller serves more than its scored ports. After each change on it, verify:

- a DNS query for a known record returns the expected answer (design 01, section 9);
- an operator account can authenticate to the domain from a member server;
- a member server can still find the domain controller.

Scoring accounts are never used to test logons (design 01, section 4).

## 5. The domain checklist

Domain-wide changes reach every machine at once, so they stay with a person even under "confirm, then act" (design 01, section 3). The `windows-dc` profile prints this checklist, filled with the run's host names, for the team to work through with the captain's approval:

1. **Domain Administrator.** Check the Tier 0 report for services and scheduled tasks that log on with it (design 05, section 2). Rotate it, update each of those, then re-run the logon probes. The new password goes in the team's offline record.
2. **Privileged groups.** Compare the Tier 0 report with the expected members. Remove unknown members by hand, one at a time, and re-run the logon probes after each.
3. **KRBTGT.** Reset the KRBTGT password, wait for replication, then reset it again (Blueprint §3.1). This invalidates forged Kerberos tickets.
4. **Service accounts.** Reset only after their dependencies are known.
5. **Unexpected domain accounts.** Disable them only after confirming they are not scoring or official accounts; re-enabling raises an alert (event 4722; design 10). Once a checkpoint shows every scored service passing (design 13), delete them, after saving their group membership and creation details for the incident record (design 02).
6. **Group Policy.** Apply domain-wide settings (for example, turning off LLMNR everywhere) one at a time, with a scoring-style probe after each.
7. **DNS.** Any change, including a sinkhole entry (Blueprint §4.6), is tested with a query before and after.
8. **Domain honey-accounts.** If the team uses them (design 09), create each one by hand with the name the module prints, disabled or with no usable password, and confirm it does not collide with a scoring or official account.

## 6. Roll back

Every Tier 1 and Tier 2 change is recorded in the run manifest with its previous value: the registry value, service start type, firewall rule or audit setting. Rollback restores that value. Tier 2 changes are also covered by the one-time scheduled task that serves as the Windows revert timer (design 01, section 8).

## 7. What it will never do

- Change Group Policy, DNS or a domain account itself, with or without approval. These stay on the checklist in section 5.
- Touch an account in the protected set.
- Remove the break-glass path or the officials' access.
- Install software from outside the environment.

## 8. Acceptance tests

- After the run, the protected accounts, the scoring accounts and every scored-service probe are unchanged.
- An operator can still log on to the domain from every member server.
- A deliberately failed verify on the domain controller is reverted by the scheduled task.
- The Tier 0 report lists a planted extra member of Domain Admins.
- No Group Policy object changes during an automated run.
- Where RDP is scored, the scoring engine's address can still connect after the firewall and RDP changes.
- After default-deny on the domain controller, a member server still logs on to the domain and resolves names.
- After the protocol settings, an NTLMv1 logon is refused, WDigest is off, and anonymous user listing fails; turning WDigest back on raises an alert.


## References

Midwest Collegiate Cyber Defense Competition. (2025). *2025 Midwest Collegiate Cyber Defense Competition qualifier team packet* [PDF]. https://brazil.minnesota.edu/ccdc/ccdc-2025/2025MWCCDCQTeamPack.pdf

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
