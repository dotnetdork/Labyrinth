# Labyrinth Design Specifications

**Status:** Draft · reviewed 2026-10-02

These are design documents, not code. They describe what each part must do, how it stays inside the competition rules, and how it is tested. The [implementation blueprint](../Blueprint.md) is the complete overview of what the whole system needs; each spec here is the detailed design and instructions for one part of it. For a plain-language introduction to every part, read the [overview](../Overview.md) first.

> [!NOTE]
> **Rules basis.** Built on the 2026 national CCDC (Collegiate Cyber Defense Competition) rules and the 2025 Midwest qualifier packet. The 2027 rules are not published yet, so every rule citation here must be re-checked when they arrive. Rule numbers follow the web version of the rules (National Collegiate Cyber Defense Competition [NCCDC], 2025). That page numbers its sections but letters the items within them, so Rule 4.14 appears as item 4(n) and Rule 5.6.1 as 5(f)(i).

**Verification labels.**

- *Verified*: checked against the named source on the date given.
- *Provisional*: from a text extraction or a source that could not be re-checked.
- *Background*: general knowledge, not re-checked.

## Reading order

Each spec belongs to one phase of the doctrine, and every document uses the same colors for them: 🟥 **Lock out** · 🟦 **Observe** · 🟪 **Deceive** · 🟩 **Sustain**. In diagrams, amber marks a step a person does or decides, and a dashed red outline marks a stop or refusal.

| # | Document | Phase | Question it answers |
|---|---|---|---|
| 00 | [Module contract and layout](00-Module-Contract-and-Layout.md) | All | How is Labyrinth organized so that new capabilities plug in without touching the core? |
| 01 | [Lockout ("panic button")](01-Lockout-Panic-Button.md) | 🟥 Lock out | How do we do the first-minutes lockout safely and inside the rules? |
| 02 | [Incident reporting automation](02-Incident-Reporting-Automation.md) | 🟩 Sustain | How do we produce complete Red Team incident reports quickly? |
| 03 | [Event seed and deception config](03-Event-Seed-and-Deception-Config.md) | 🟪 Deceive | How can the code be public but the deception still be unpredictable? |
| 04 | [Baseline and integrity](04-Baseline-and-Integrity.md) | 🟦 Observe | How do we hash critical files and learn who changed what, when, and from where? |
| 05 | [Credentials and SSH keys](05-Credentials-and-SSH-Keys.md) | 🟥 Lock out | How do we rotate credentials and deploy SSH (Secure Shell) keys without locking ourselves out? |
| 06 | [Status feed and MOTD](06-Status-Feed-and-MOTD.md) | 🟦 Observe | How does the SIEM (Security Information and Event Management system) inform every host without new trust paths? |
| 07 | [Cleanup and tool integrity](07-Cleanup-and-Tool-Integrity.md) | 🟩 Sustain | How do we leave nothing behind and keep our own tools tamper-evident? |
| 08 | [Ideas mined from reference repos](08-Reference-Mining.md) | All | What did the reference-only repositories teach us, turned into specs? |
| 09 | [Deception maze and CVE decoys](09-Deception-Maze-and-CVE-Decoys.md) | 🟪 Deceive | How do we build the maze, and where are the limits? |
| 10 | [Log forwarding and detection](10-Log-Forwarding-and-Detection.md) | 🟦 Observe | Which logs leave each host, how they reach the SIEM, and which few searches run over them? |
| 11 | [Windows and AD hardening](11-Windows-and-AD-Hardening.md) | 🟥 Lock out | How do we harden Windows hosts and the domain controller without a domain-wide mistake? |
| 12 | [Dynamic bans](12-Dynamic-Bans.md) | 🟪 Deceive | How do trap hits become expiring bans that can never block the scoring engine? |
| 13 | [Health monitor and checkpoints](13-Health-Monitor-and-Checkpoints.md) | 🟩 Sustain | How do we notice a scored service going down, and review the whole network in one command? |
| 14 | [Backup and recovery](14-Backup-and-Recovery.md) | 🟩 Sustain | How do we restore a scored service after damage we did not cause? |
| 15 | [Patching and service reduction](15-Patching-and-Service-Reduction.md) | 🟥 Lock out | How do we turn off unneeded services and patch the dangerous packages without breaking scoring? |
| 16 | [Network appliance runbooks](16-Network-Appliance-Runbooks.md) | 🟥 Lock out | How does a person lock down routers and firewall appliances safely? |

## Diagrams

Each diagram is a Mermaid block inside the document it illustrates, with a one-sentence caption beneath it.

| Diagram | Where |
|---|---|
| The four phases in order (plain-language version) | [Overview, section 2.1](../Overview.md#21-the-strategy-four-phases-in-order) |
| The system at a glance: control node, hosts, SIEM, trip log, reports | [Overview, section 2.3](../Overview.md#23-the-system-at-a-glance) |
| The life of one module (simplified) | [Overview, section 3.2](../Overview.md#32-the-life-of-one-module) |
| Order of work: lock out, observe, deceive and sustain | [Blueprint, §1](../Blueprint.md#1-operating-doctrine--the-order-of-work) |
| Every trap reports to one trip log | [Blueprint, §4](../Blueprint.md#trip-log-pattern) |
| The four phases and what each contains | [00, section 2](00-Module-Contract-and-Layout.md#2-naming-phases-not-hardening) |
| Repository and module layout | [00, section 3](00-Module-Contract-and-Layout.md#3-repository-layout) |
| Module lifecycle with exit codes | [00, section 4](00-Module-Contract-and-Layout.md#4-the-module-contract) |
| Risk tiers 0 to 3 and who runs each | [01, section 5](01-Lockout-Panic-Button.md#5-actions-by-risk-tier) |
| Panic button: gates, rings, verify, dead-man revert | [01, section 6](01-Lockout-Panic-Button.md#6-sequence) |
| Incident reporting pipeline | [02, section 3](02-Incident-Reporting-Automation.md#3-pipeline) |
| Event seed derivation | [03, section 3](03-Event-Seed-and-Deception-Config.md#3-derivation) |
| Baseline and integrity | [04, section 4](04-Baseline-and-Integrity.md#4-who-when-from-where) |
| Password and SSH key rotation order | [05, section 4](05-Credentials-and-SSH-Keys.md#4-ssh-key-design) |
| Status feed push | [06, section 2](06-Status-Feed-and-MOTD.md#2-design-push-from-the-control-node) |
| Cleanup and tool integrity | [07, section 5](07-Cleanup-and-Tool-Integrity.md#5-replacement-signed-manifest-and-known-commit) |
| Decoy lifecycle: seed, safety checks, trip log, cleanup | [09, section 6](09-Deception-Maze-and-CVE-Decoys.md#6-safety-checks-before-deployment) |
| Log sources, the SIEM and the saved searches | [10, section 4](10-Log-Forwarding-and-Detection.md#4-how-logs-are-shipped) |
| Windows hardening order: members first, domain controller last | [11, section 3](11-Windows-and-AD-Hardening.md#3-blast-radius-decides-the-tier) |
| Ban decision: source gate, never-ban list, threshold | [12, section 6](12-Dynamic-Bans.md#6-how-bans-are-enforced) |
| Health monitor: probe, compare, alert, human decides | [13, section 4](13-Health-Monitor-and-Checkpoints.md#4-when-a-probe-changes-state) |
| Restore point: space check, hash, store, restore | [14, section 4](14-Backup-and-Recovery.md#4-when) |
| Patching: check, rank, restore point, verify | [15, section 4](15-Patching-and-Service-Reduction.md#4-patching) |
| Appliance runbook: prepare, change, confirm or revert | [16, section 4](16-Network-Appliance-Runbooks.md#4-the-runbook-steps) |

## Where things live

- **This repository (Labyrinth):** design, code, reference. It becomes public because Rule 5.6.1 requires team-written tools to be public before use (NCCDC, 2025, Rule 5.6.1).
- **CCDC-2027 (private):** strategy, rules baseline, topology notes, decision log.

> [!CAUTION]
> Never put strategy, per-event values, real hostnames, addresses or credentials in this repository.

## Design constraints that apply to every document

1. Public and frozen: code must be safe for rivals and the Red Team to read (NCCDC, 2025, Rules 5.6.2, 5.6.3).
2. No outside resources at run time other than DNS (Domain Name System) lookups (NCCDC, 2025, Rule 5.6.4).
3. No deliberate breakage of expected functionality (NCCDC, 2025, Rule 5.6.5).
4. Never impede the scoring engine: anything that interferes with it is the team's responsibility and lowers the score (NCCDC, 2025, Rules 4.11, 9.3). Never mislead it: that can bring disqualification or penalties (NCCDC, 2025, Rule 9.3).
5. Officials must be given access immediately when they ask (NCCDC, 2025, Rule 4.1).
6. No new devices (NCCDC, 2025, Rule 4.2); no containerizing scored services (NCCDC, 2025, Rule 4.14).

## Review log

| Date | Change |
|---|---|
| 2026-09-29 | Independent review. Fixed: VyOS commit-confirm reboot default (01); account locks moved from Tier 1 to Tier 2 and domain locks to Tier 3 (01); incident-report rule wording (02); `sfc /verifyonly` (04); materials rules 4.4 and 8.5 (07); banner decoys limited to unscored services (09). Removed event-specific topology, hostnames and timings from the public documents. |
| 2026-09-29 | Formatting and readability pass, no change to facts: consistent status lines without draft numbers, GitHub alert blocks for existing warnings and caveats, long paragraphs split into lists and tables, sentences reworded for clarity, acronyms expanded on first use, US spelling. |
| 2026-09-29 | Diagrams: grouped the layout, lifecycle, lockout and incident-pipeline diagrams into labeled subgraphs with no change to nodes or edges; added diagrams for the order of work and the trip log (hardening reference), credential rotation (05) and the decoy lifecycle (09). |
| 2026-09-29 | Renamed `docs/Hardening-Reference.md` to `docs/Blueprint.md` (title: Labyrinth Implementation Blueprint), because it covers doctrine, invariants, a per-platform capability map, a trap catalog and a reference implementation. All links updated. |
| 2026-09-29 | References: VyOS entry moved into alphabetical order (01); the first citation in each document now gives the full author name with its abbreviation (00, 04, README); the README gained a reference list. |
| 2026-09-29 | Color: the four phases have one color each (🟥 lock out, 🟦 observe, 🟪 deceive, 🟩 sustain) in tables, status lines and every diagram; diagrams also use amber for steps a person does and a dashed red outline for stops; the Blueprint priority scorecard is color-coded by priority. Nodes, edges and text unchanged apart from a color sentence added to each caption. |
| 2026-09-29 | Added `docs/Overview.md`, a plain-language tour of every part of the system for non-expert readers, with three diagrams. It adds no new facts: each statement summarizes the Blueprint or a design spec. |
| 2026-09-29 | Added designs 10 to 16 to close gaps found in a coverage review: log forwarding and detection (10), Windows and AD hardening (11), dynamic bans (12), health monitor and checkpoints (13), backup and recovery (14), patching and service reduction (15) and network appliance runbooks (16). Each turns an existing Blueprint capability into a spec; tool-specific details that were not re-checked are labeled *Background*, and open questions are pinned. Cross-links added in the Blueprint and designs 00, 01, 04, 06 and 08; `health` added to the log categories (00). |
| 2026-10-02 | Rules wording audit: every rule citation re-checked against the 2026 rules web page, including list positions. Fixed: the 5.6.5 examples (all user shells; *indiscriminately* ending outbound connections) (01, Blueprint); disabling accounts wholesale no longer attributed to the rule's examples (Blueprint); Rule 4.1 is access on request, not retained access (Blueprint); Rule 4.11 permits active response such as TCP resets, so it is no longer cited for "never contact the source" (Blueprint); Rule 4.11 makes interference the team's responsibility, which is not the same as a ban, and constraint 4 now says so (README); Rule 9.4 wording (02). Design choices stricter than the rules, such as never installing packages, are now labeled as design, not rule. |
| 2026-10-02 | Break-glass and official access clarified so the break-glass path cannot become a backdoor: it is the rotated password of an existing admin-class account, sealed on paper and verified at the console; no new account, and the `breakglass` SSH key role is removed (05). Official accounts are never changed without the White Team's permission but are now watched (01, 05), with a matching saved search (10). |
| 2026-10-02 | Secrets and notes are no longer assumed to be on paper. A new term, the *offline record*, means kept out of the repository and off the competition hosts, on paper or in a local unsynced file on an operator's own machine (Rule 5.2), shared only through the official team chat or in person, with credentials rotated after the event because chat may be logged (Rule 5.5) (05, section 2). References updated in designs 01, 03, 05 and 07, the Blueprint, the Overview (with a glossary entry) and the README. |
| 2026-10-02 | Design audit of all specs; 06, 08, 14 and 16 needed no change. Fixes for real risk: an admin-class account that a service or scheduled task logs on with is not rotated automatically (01, 05); the domain Administrator is rotated by hand (11); honey-accounts cannot log in and any attempt alerts, and domain ones are created by hand (09, 10, 11, 12); decoy ports are checked against scored and listening ports, not the scoring allowlist, which holds addresses (03, 09); the report template carries every Rule 9.4 field and warns about missing ones (02); a copy or hash of each baseline is kept off the host (04); the manifest hash is in the offline record and checked on every host, while the `ssh-keygen -Y` signature is checked only on the control node, because older OpenSSH cannot (07); one canary host per platform, and hosts with no canary go last (01); the operator confirms break-glass at the console once per host, and rotation is tested with `su -` or `runas` (01, 05); default-deny also allows official sources from the event packet (01, 11). Fixes for accuracy: local and remote modes described and the Ansible question resolved as native scripts; the freeze reading marked as needing confirmation; all host paths under one root, with `etc` added and admin-only access (00); domain controller Kerberos and NTLM events, auditd `-e 2` and `-f 2` never set, and a SIEM input that is TCP and limited to managed hosts (10); fail2ban is never installed or vendored, and a host's existing fail2ban gets the never-ban list (12); Windows patches ranked by exposure only (15); the login gap in probes and an optional hand-made test mailbox (13); cleanup deletes only accounts Labyrinth created (07); Rule 4.1 effect reworded (11, constraint 5). Blueprint, Overview and `config/hosts.example` updated to match. |

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
