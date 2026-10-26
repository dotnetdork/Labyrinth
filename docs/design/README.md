# Labyrinth Design Specifications

These are design documents, not code. They describe what each part must do, how it stays inside the competition rules, and how it is tested. The [implementation blueprint](../Blueprint.md) is the complete overview of what the whole system needs; each spec here is the detailed design and instructions for one part of it. For a plain-language introduction to every part, read the [overview](../Overview.md) first.

> [!NOTE]
> **Rules basis.** Built on the national CCDC (Collegiate Cyber Defense Competition) rules, updated 10 December 2025. Rule numbers follow the web version of the rules (National Collegiate Cyber Defense Competition [NCCDC], 2025): a rule number is the section number, then the item's place in it, so Rule 4.14 is item 14 of section 4, and Rule 5.6.1 is the first point of item 6 of section 5. The page has ten sections; Scoring is section 9. Each event's own materials and local competition rules come first, and they differ from event to event (NCCDC, 2025, Local Competition Rules section), so every design reads the event's values at run time and assumes none.

**Verification labels.**

- *Verified*: checked against the named source.
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
| 17 | [Persistence sweep](17-Persistence-Sweep.md) | 🟥 Lock out | How do we find and remove the Red Team's footholds early, without breaking a scored service? |
| 18 | [Service packs and config library](18-Service-Packs-and-Config-Library.md) | 🟥 Lock out | How do we harden the scored apps themselves, quickly and repeatably, without breaking them? |
| 19 | [Platform facts and adapters](19-Platform-Facts-and-Adapters.md) | All | How does a module learn what host it is on, and change firewalls and other parts that differ by platform? |
| 20 | [Packages and third-party tools](20-Packages-and-Third-Party-Tools.md) | All | Which public tools does Labyrinth add to a host, from where, and how is each install checked and recorded? |
| 21 | [Vulnerability tracker and mitigations](21-Vulnerability-Tracker-and-Mitigations.md) | 🟥 Lock out | How do we find the flaws the Red Team will look for, close them first, and keep each one tracked until it is closed? |
| 22 | [Service replacement and containers](22-Service-Replacement-and-Containers.md) | 🟩 Sustain | Where an event allows it, how do we rebuild or containerize a scored service without losing its data, users or address? Off by default. |

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
| Panic button: gates, the first-minute bundle, rings, approval and seal | [01, section 6](01-Lockout-Panic-Button.md#6-sequence) |
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
| Persistence item: package, dependency and sign checks decide automatic quarantine or approval | [17, section 4](17-Persistence-Sweep.md#4-classes) |
| Known flaw: find, rank, track, and close a scored service in place | [21, section 5.2](21-Vulnerability-Tracker-and-Mitigations.md#52-the-mitigation-catalog) |
| Service replacement: allowed, inventory, build beside, copy data, compare, switch, keep or revert | [22, section 6](22-Service-Replacement-and-Containers.md#6-sequence) |

## Where things live

- **This repository (Labyrinth):** design, code, reference. It becomes public because Rule 5.6.1 requires team-written tools to be public before use (NCCDC, 2025, Rule 5.6.1).
- **CCDC-2027 (private):** strategy, rules baseline, topology notes, decision log.

> [!CAUTION]
> Never put strategy, per-event values, real hostnames, addresses or credentials in this repository.

## Design constraints that apply to every document

1. Public and frozen: code must be safe for rivals and the Red Team to read (NCCDC, 2025, Rules 5.6.2, 5.6.3).
2. No outside resources at run time other than DNS (Domain Name System) lookups; the rule's example is cloud services and cloud processing (NCCDC, 2025, Rule 5.6.4). Public software from the host's repositories, an event mirror or a pinned download is installed only after the lockdown (design 20).
3. No deliberate breakage of expected functionality (NCCDC, 2025, Rule 5.6.5).
4. Never impede the scoring engine: anything that interferes with it is the team's responsibility and lowers the score (NCCDC, 2025, Rules 4.11, 9.3). Never mislead it: that can bring disqualification or penalties (NCCDC, 2025, Rule 9.3).
5. Officials must be given access immediately when they ask (NCCDC, 2025, Rule 4.1).
6. No new devices (NCCDC, 2025, Rule 4.2). No migrating or containerizing a scored service unless an inject or the local competition rules allow it (NCCDC, 2025, Rule 4.14); where they do, design 22 governs it, off by default.
7. Assume breach, and defend scored services rather than avoid them. Scoring rewards controlling and preventing unauthorized access, and successful Red Team penetrations cost points (NCCDC, 2025, Scoring section). Scored services are a primary Red Team target, so leaving them as found is not the safe choice; changing them with probes, backups and a revert timer is.
8. Confirm, then act. What a person approves, at the prompt or before the event with a pre-approval rule, Labyrinth carries out with the same backups, records and rollback. Only actions too broad or too hard to undo (Group Policy, DNS changes on a domain controller, domain controller restores, rescuing an unbootable host, Windows patching, appliances) stay in a person's hands.
9. Keep every name and address. No host name, address, scored DNS name or username is changed, and no scored port is filtered by source address: scoring, officials and simulated users reach it from addresses nobody can list (design 01, section 6.1).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026,
 from https://www.nationalccdc.org/rules.html
