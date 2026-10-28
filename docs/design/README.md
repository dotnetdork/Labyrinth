# Labyrinth Design Specifications

These are design documents, not code. They describe what each part must do, how it stays inside the competition rules, and how it is tested. The [implementation blueprint](../Blueprint.md) is the complete overview of what the whole system needs; each spec here is the detailed design and instructions for one part of it. For a plain-language introduction to every part, read the [overview](../Overview.md) first.

> [!NOTE]
> **Rules basis.** Built on the national CCDC (Collegiate Cyber Defense Competition) rules, updated 10 December 2025. Rule numbers follow the web version of the rules (National Collegiate Cyber Defense Competition [NCCDC], 2025): a rule number is the section number, then the item's place in it, so Rule 4.14 is item 14 of section 4, and Rule 5.6.1 is the first point of item 6 of section 5. The page has ten sections; Scoring is section 9. Each event's own materials and local competition rules come first, and they differ from event to event (NCCDC, 2025, Local Competition Rules section), so every design reads the event's values at run time and assumes none.

**Verification labels.**

- *Verified*: checked against the named source.
- *Provisional*: from a text extraction or a source that could not be re-checked.
- *Background*: general knowledge, not re-checked.

## Reading order

Each spec belongs to one phase of the doctrine (five in all: lock out, harden, observe, deceive, sustain), and every document uses the same colors for them: 🟥 **Lock out** · 🟧 **Harden** · 🟦 **Observe** · 🟪 **Deceive** · 🟩 **Sustain**. In diagrams, amber marks a step a person does or decides, and a dashed red outline marks a stop or refusal.

The numbers follow the order a run uses the parts: the foundations every module needs, then the phases in run order, then reference material.

| # | Document | Phase | Question it answers |
|---|---|---|---|
| 00 | [Module contract and layout](00-Module-Contract-and-Layout.md) | All | How is Labyrinth organized so that new capabilities plug in without touching the core? |
| 01 | [Platform facts and adapters](01-Platform-Facts-and-Adapters.md) | All | How does a module learn what host it is on, and change firewalls and other parts that differ by platform? |
| 02 | [Packages and third-party tools](02-Packages-and-Third-Party-Tools.md) | 🟧 Harden | Which public tools does Labyrinth add to a host, from where, and how is each install checked and recorded? |
| 03 | [Lockout ("panic button")](03-Lockout-Panic-Button.md) | 🟥 Lock out, 🟧 Harden | How do we do the first-minutes lockout safely and inside the rules, and harden behind it? |
| 04 | [Credentials and SSH keys](04-Credentials-and-SSH-Keys.md) | 🟥 Lock out | How do we rotate credentials and deploy SSH (Secure Shell) keys without locking ourselves out? |
| 05 | [Network appliance runbooks](05-Network-Appliance-Runbooks.md) | 🟥 Lock out | How does a person lock down routers and firewall appliances safely? |
| 06 | [Persistence sweep](06-Persistence-Sweep.md) | 🟧 Harden | How do we find and remove the Red Team's footholds early, without breaking a scored service? |
| 07 | [Backup and recovery](07-Backup-and-Recovery.md) | 🟧 Harden, 🟩 Sustain | How do we restore a scored service after damage we did not cause? |
| 08 | [Baseline and integrity](08-Baseline-and-Integrity.md) | 🟧 Harden, 🟦 Observe | How do we hash critical files and learn who changed what, when, and from where? |
| 09 | [Vulnerability tracker and mitigations](09-Vulnerability-Tracker-and-Mitigations.md) | 🟧 Harden | How do we find the flaws the Red Team will look for, close them first, and keep each one tracked until it is closed? |
| 10 | [Patching and service reduction](10-Patching-and-Service-Reduction.md) | 🟧 Harden | How do we turn off unneeded services and patch the dangerous packages without breaking scoring? |
| 11 | [Service packs and config library](11-Service-Packs-and-Config-Library.md) | 🟧 Harden | How do we harden the scored apps themselves, quickly and repeatably, without breaking them? |
| 12 | [Windows and AD hardening](12-Windows-and-AD-Hardening.md) | 🟧 Harden | How do we harden Windows hosts and the domain controller without a domain-wide mistake? |
| 13 | [Service replacement and containers](13-Service-Replacement-and-Containers.md) | 🟧 Harden | Where an event allows it, how do we rebuild or containerize a scored service without losing its data, users or address? Off by default. |
| 14 | [Log forwarding and detection](14-Log-Forwarding-and-Detection.md) | 🟦 Observe | Which logs leave each host, how they reach the SIEM, and which few searches run over them? |
| 15 | [Status feed and MOTD](15-Status-Feed-and-MOTD.md) | 🟦 Observe | How does the SIEM (Security Information and Event Management system) inform every host without new trust paths? |
| 16 | [Event seed and deception config](16-Event-Seed-and-Deception-Config.md) | 🟪 Deceive | How can the code be public but the deception still be unpredictable? |
| 17 | [Deception maze and CVE decoys](17-Deception-Maze-and-CVE-Decoys.md) | 🟪 Deceive | How do we build the maze, and where are the limits? |
| 18 | [Dynamic bans](18-Dynamic-Bans.md) | 🟪 Deceive | How do trap hits become expiring bans that can never block the scoring engine? |
| 19 | [Health monitor and checkpoints](19-Health-Monitor-and-Checkpoints.md) | 🟩 Sustain | How do we notice a scored service going down, and review the whole network in one command? |
| 20 | [Incident reporting automation](20-Incident-Reporting-Automation.md) | 🟩 Sustain | How do we produce complete Red Team incident reports quickly? |
| 21 | [Cleanup and tool integrity](21-Cleanup-and-Tool-Integrity.md) | 🟩 Sustain | How do we leave nothing behind and keep our own tools tamper-evident? |
| 22 | [Ideas mined from reference repos](22-Reference-Mining.md) | All | What did the reference-only repositories teach us, turned into specs? |

## Pick a part to build

Start here if you want to contribute. Pick a row whose status is **Next** and whose dependencies are built, open its issue (each Roadmap branch has one, and the small self-contained ones carry the `good first issue` label), and run `/start-issue` with the issue number: it reads the spec, lists the acceptance tests to write first and names the branch. The [Roadmap](../Roadmap.md) holds the exact branches and what each must deliver.

Module IDs are `phase.name`, so the ID shows where the module runs. The IDs below are the planned ones; a spec may rename a module when it is built. `harden.*` modules wait for the Harden phase in the runner (Roadmap, stage 4b).

| # | Part | Planned module IDs | Roadmap stage | Depends on | Size | Status |
|---|---|---|---|---|---|---|
| 00 | Module contract, both runners and the core | (the framework) | 1 to 3, then 4b | — | — | Built; automatic runs and short output are next (4b) |
| 01 | Platform facts and the firewall adapter | (core) | 3, 4 | 00 | — | Built; the outbound default comes with `lockout.firewall` |
| 02 | Packages and third-party tools | `harden.packages` | 4 | 01, 03 | M | Next |
| 03 | Lockout and the first-minute bundle | `lockout.sessions`, `lockout.firewall`, `harden.reopen_outbound` | 4, 4b | 00, 01, 04 | L | Next |
| 04 | Credentials and SSH keys | `lockout.credentials`, `lockout.ssh`, `lockout.accounts`, `harden.accounts` | 4 | 00 | L | Next; new passwords shown once are built |
| 05 | Network appliance runbooks | `lockout.appliance_runbooks` (manual-only) | Any time | — | S | Next; good first issue (templates, no code) |
| 06 | Persistence sweep | `harden.persistence_sweep` | 4 | 01, 07 | L | Next; the quarantine helper is built |
| 07 | Backup and recovery | `harden.restore_points` | 4 | 00 | M | Next |
| 08 | Baseline and integrity | `observe.inventory`, `harden.package_verify`, `observe.integrity` | 4, 4b, 6 | 00, 02 | L | Next |
| 09 | Vulnerability tracker and mitigations | `harden.vuln_check`, `harden.mitigations` | 4, 7 | 02, 08 | L | Next (the read-only check); the tracker is waiting |
| 10 | Patching and service reduction | `harden.service_reduction`, `harden.patching` | 7 | 07, 09 | M | Waiting |
| 11 | Service packs and config library | `harden.pack_web`, `harden.pack_mail_dns`, `harden.pack_data` | 7 | 07, 19 | L | Waiting |
| 12 | Windows and AD hardening | `harden.win_base`, `harden.ad_checks`, `harden.win_tier3` | 4, 7 | 01 | L | Next (the base settings and read-only domain checks) |
| 13 | Service replacement and containers | `harden.service_replace` | 7 | 02, 07, 11, 19 | L | Waiting |
| 14 | Log forwarding and detection | `observe.auditd`, `observe.win_audit`, `observe.sysmon`, `observe.forward_linux`, `observe.forward_windows`, `observe.searches`, `harden.siem` | 6, 7 | 02, 03 | M | Waiting |
| 15 | Status feed and MOTD | `observe.status_feed` | 9 | 14, 19 | S | Waiting; a good first issue once 19 is built |
| 16 | Event seed | (core: `core/seed/`), `deceive.canaries` | 9 | 00 | S | Waiting; good first issue (self-contained) |
| 17 | Deception maze and CVE decoys | `deceive.maze`, `deceive.decoys` | 9 | 14, 16 | L | Waiting |
| 18 | Dynamic bans | `deceive.bans` | 9 | 01, 14, 17 | M | Waiting |
| 19 | Health monitor and checkpoints | `sustain.health_monitor` | 6 | 00 | M | Waiting; the http, dns and banner probes are built |
| 20 | Incident reporting | (cross-phase `report/`) | 8 | 06, 08, 09 | M | Waiting |
| 21 | Cleanup and tool integrity | `sustain.cleanup` | 8 | 00 | M | Waiting; each host's release check is built |
| 22 | Ideas mined from reference repos | — | — | — | — | Reference only; nothing to build |

Size is a rough guide: **S** is a day or two of work, **M** about a week, **L** several branches.

## Old design numbers

The specs were renumbered into run order. Commit messages, closed issues and pull requests from before then use the old numbers; this table translates them.

| Old | New | Spec | Old | New | Spec |
|---|---|---|---|---|---|
| 00 | 00 | Module contract | 12 | 18 | Dynamic bans |
| 01 | 03 | Lockout | 13 | 19 | Health monitor |
| 02 | 20 | Incident reporting | 14 | 07 | Backup and recovery |
| 03 | 16 | Event seed | 15 | 10 | Patching and service reduction |
| 04 | 08 | Baseline and integrity | 16 | 05 | Appliance runbooks |
| 05 | 04 | Credentials and SSH keys | 17 | 06 | Persistence sweep |
| 06 | 15 | Status feed | 18 | 11 | Service packs |
| 07 | 21 | Cleanup and tool integrity | 19 | 01 | Platform facts and adapters |
| 08 | 22 | Reference mining | 20 | 02 | Packages and third-party tools |
| 09 | 17 | Deception maze | 21 | 09 | Vulnerability tracker |
| 10 | 14 | Log forwarding | 22 | 13 | Service replacement and containers |
| 11 | 12 | Windows and AD hardening | | | |

## Diagrams

Each diagram is a Mermaid block inside the document it illustrates, with a one-sentence caption beneath it.

| Diagram | Where |
|---|---|
| The five phases in order (plain-language version) | [Overview, section 2.1](../Overview.md#21-the-strategy-five-phases-in-order) |
| The system at a glance: control node, hosts, SIEM, trip log, reports | [Overview, section 2.3](../Overview.md#23-the-system-at-a-glance) |
| The life of one module (simplified) | [Overview, section 3.2](../Overview.md#32-the-life-of-one-module) |
| Order of work: lock out, harden, observe, deceive and sustain | [Blueprint, §1](../Blueprint.md#1-operating-doctrine--the-order-of-work) |
| Every trap reports to one trip log | [Blueprint, §4](../Blueprint.md#trip-log-pattern) |
| The five phases and what each contains | [00, section 2](00-Module-Contract-and-Layout.md#2-naming-phases-not-hardening) |
| Repository and module layout | [00, section 3](00-Module-Contract-and-Layout.md#3-repository-layout) |
| Module lifecycle with exit codes | [00, section 4](00-Module-Contract-and-Layout.md#4-the-module-contract) |
| Risk tiers 0 to 3 and who runs each | [03, section 5](03-Lockout-Panic-Button.md#5-actions-by-risk-tier) |
| Panic button: gates, the first-minute bundle, the Harden phase, approval and seal | [03, section 6](03-Lockout-Panic-Button.md#6-sequence) |
| Password and SSH key rotation order | [04, section 4](04-Credentials-and-SSH-Keys.md#4-ssh-key-design) |
| Appliance runbook: prepare, change, confirm or revert | [05, section 4](05-Network-Appliance-Runbooks.md#4-the-runbook-steps) |
| Persistence item: package, dependency and sign checks decide automatic quarantine or approval | [06, section 4](06-Persistence-Sweep.md#4-classes) |
| Restore point: space check, hash, store, restore | [07, section 4](07-Backup-and-Recovery.md#4-when) |
| Baseline and integrity, with verification against official packages | [08, section 4](08-Baseline-and-Integrity.md#4-who-when-from-where) |
| Known flaw: find, rank, track, and close a scored service in place | [09, section 5.2](09-Vulnerability-Tracker-and-Mitigations.md#52-the-mitigation-catalog) |
| Patching: check, rank, restore point, verify | [10, section 4](10-Patching-and-Service-Reduction.md#4-patching) |
| Windows hardening order: members first, domain controller last | [12, section 3](12-Windows-and-AD-Hardening.md#3-blast-radius-decides-the-tier) |
| Service replacement: allowed, inventory, build beside, copy data, compare, switch, keep or revert | [13, section 6](13-Service-Replacement-and-Containers.md#6-sequence) |
| Log sources, the SIEM and the saved searches | [14, section 4](14-Log-Forwarding-and-Detection.md#4-how-logs-are-shipped) |
| Status feed push | [15, section 2](15-Status-Feed-and-MOTD.md#2-design-push-from-the-control-node) |
| Event seed derivation | [16, section 3](16-Event-Seed-and-Deception-Config.md#3-derivation) |
| Decoy lifecycle: seed, safety checks, trip log, cleanup | [17, section 6](17-Deception-Maze-and-CVE-Decoys.md#6-safety-checks-before-deployment) |
| Ban decision: source gate, never-ban list, threshold | [18, section 6](18-Dynamic-Bans.md#6-how-bans-are-enforced) |
| Health monitor: probe, compare, alert, human decides | [19, section 4](19-Health-Monitor-and-Checkpoints.md#4-when-a-probe-changes-state) |
| Incident reporting pipeline | [20, section 3](20-Incident-Reporting-Automation.md#3-pipeline) |
| Cleanup and tool integrity | [21, section 5](21-Cleanup-and-Tool-Integrity.md#5-replacement-signed-manifest-and-known-commit) |

## Where things live

- **This repository (Labyrinth):** design, code, reference. It becomes public because Rule 5.6.1 requires team-written tools to be public before use (NCCDC, 2025, Rule 5.6.1).
- **The team's private configuration:** strategy, rules baseline, topology notes, decision log.

> [!CAUTION]
> Never put strategy, per-event values, real hostnames, addresses or credentials in this repository.

## Design constraints that apply to every document

1. Public and frozen: code must be safe for rivals and the Red Team to read (NCCDC, 2025, Rules 5.6.2, 5.6.3).
2. No cloud services, cloud processing or other outside resources beyond simple DNS (Domain Name System) lookups (NCCDC, 2025, Rule 5.6.4): no reputation or enrichment APIs, and no private sources (Rule 5.2). Public software from the host's repositories, an event mirror or a pinned download (checked against its SHA-256) may be downloaded and installed, only after the lockdown, with an offline fallback (design 02).
3. No deliberate breakage of expected functionality (NCCDC, 2025, Rule 5.6.5).
4. Never impede the scoring engine: anything that interferes with it is the team's responsibility and lowers the score (NCCDC, 2025, Rules 4.11, 9.3). Never mislead it: that can bring disqualification or penalties (NCCDC, 2025, Rule 9.3).
5. Officials must be given access immediately when they ask (NCCDC, 2025, Rule 4.1).
6. No new devices (NCCDC, 2025, Rule 4.2). No migrating or containerizing a scored service unless an inject or the local competition rules allow it (NCCDC, 2025, Rule 4.14); where they do, design 13 governs it, off by default.
7. Assume breach, and defend scored services rather than avoid them. Scoring rewards controlling and preventing unauthorized access, and successful Red Team penetrations cost points (NCCDC, 2025, Scoring section). Scored services are a primary Red Team target, so leaving them as found is not the safe choice; changing them with probes, backups and a revert timer is.
8. Confirm, then act. What a person approves, at the prompt or before the event with a pre-approval rule, Labyrinth carries out with the same backups, records and rollback. Only actions too broad or too hard to undo (Group Policy, DNS changes on a domain controller, domain controller restores, rescuing an unbootable host, Windows patching, appliances) stay in a person's hands.
9. Keep every name and address. No host name, address, scored DNS name or username is changed, and no scored port is filtered by source address: scoring, officials and simulated users reach it from addresses nobody can list (design 03, section 6.1).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026,
 from https://www.nationalccdc.org/rules.html
