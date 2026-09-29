# Labyrinth Design Specifications

**Status:** Draft · reviewed 2026-09-29

These are design documents, not code. They describe what each part must do, how it stays inside the competition rules, and how it is tested. The [hardening reference](../Hardening-Reference.md) is the overview of the whole system; each spec here is the detailed design for one part of it.

> [!NOTE]
> **Rules basis.** Built on the 2026 national CCDC (Collegiate Cyber Defense Competition) rules and the 2025 Midwest qualifier packet. The 2027 rules are not published yet, so every rule citation here must be re-checked when they arrive. Rule numbers follow the web version of the rules (National Collegiate Cyber Defense Competition [NCCDC], 2025). That page numbers its sections but letters the items within them, so Rule 4.14 appears as item 4(n) and Rule 5.6.1 as 5(f)(i).

**Verification labels.**

- *Verified*: checked against the named source on the date given.
- *Provisional*: from a text extraction or a source that could not be re-checked.
- *Background*: general knowledge, not re-checked.

## Reading order

| # | Document | Question it answers |
|---|---|---|
| 00 | [Module contract and layout](00-Module-Contract-and-Layout.md) | How is Labyrinth organized so that new capabilities plug in without touching the core? |
| 01 | [Lockout ("panic button")](01-Lockout-Panic-Button.md) | How do we do the first-minutes lockout safely and inside the rules? |
| 02 | [Incident reporting automation](02-Incident-Reporting-Automation.md) | How do we produce complete Red Team incident reports quickly? |
| 03 | [Event seed and deception config](03-Event-Seed-and-Deception-Config.md) | How can the code be public but the deception still be unpredictable? |
| 04 | [Baseline and integrity](04-Baseline-and-Integrity.md) | How do we hash critical files and learn who changed what, when, and from where? |
| 05 | [Credentials and SSH keys](05-Credentials-and-SSH-Keys.md) | How do we rotate credentials and deploy SSH (Secure Shell) keys without locking ourselves out? |
| 06 | [Status feed and MOTD](06-Status-Feed-and-MOTD.md) | How does the SIEM (Security Information and Event Management system) inform every host without new trust paths? |
| 07 | [Cleanup and tool integrity](07-Cleanup-and-Tool-Integrity.md) | How do we leave nothing behind and keep our own tools tamper-evident? |
| 08 | [Ideas mined from reference repos](08-Reference-Mining.md) | What did the reference-only repositories teach us, turned into specs? |
| 09 | [Deception maze and CVE decoys](09-Deception-Maze-and-CVE-Decoys.md) | How do we build the maze, and where are the limits? |

## Diagrams

Each diagram is a Mermaid block inside the document it illustrates, with a one-sentence caption beneath it.

| Diagram | Where |
|---|---|
| The four phases and what each contains | [00, section 2](00-Module-Contract-and-Layout.md#2-naming-phases-not-hardening) |
| Repository and module layout | [00, section 3](00-Module-Contract-and-Layout.md#3-repository-layout) |
| Module lifecycle with exit codes | [00, section 4](00-Module-Contract-and-Layout.md#4-the-module-contract) |
| Risk tiers 0 to 3 and who runs each | [01, section 5](01-Lockout-Panic-Button.md#5-actions-by-risk-tier) |
| Panic button: gates, rings, verify, dead-man revert | [01, section 6](01-Lockout-Panic-Button.md#6-sequence) |
| Incident reporting pipeline | [02, section 3](02-Incident-Reporting-Automation.md#3-pipeline) |
| Event seed derivation | [03, section 3](03-Event-Seed-and-Deception-Config.md#3-derivation) |
| Baseline and integrity | [04, section 4](04-Baseline-and-Integrity.md#4-who-when-from-where) |
| Status feed push | [06, section 2](06-Status-Feed-and-MOTD.md#2-design-push-from-the-control-node) |
| Cleanup and tool integrity | [07, section 5](07-Cleanup-and-Tool-Integrity.md#5-replacement-signed-manifest-and-known-commit) |

## Where things live

- **This repository (Labyrinth):** design, code, reference. It becomes public because Rule 5.6.1 requires team-written tools to be public before use (NCCDC, 2025, Rule 5.6.1).
- **CCDC-2027 (private):** strategy, rules baseline, topology notes, decision log.

> [!CAUTION]
> Never put strategy, per-event values, real hostnames, addresses or credentials in this repository.

## Design constraints that apply to every document

1. Public and frozen: code must be safe for rivals and the Red Team to read (NCCDC, 2025, Rules 5.6.2, 5.6.3).
2. No outside resources at run time other than DNS (Domain Name System) lookups (NCCDC, 2025, Rule 5.6.4).
3. No deliberate breakage of expected functionality (NCCDC, 2025, Rule 5.6.5).
4. Never impede the scoring engine or mislead it (NCCDC, 2025, Rules 4.11, 9.3).
5. Officials must be able to get in (NCCDC, 2025, Rule 4.1).
6. No new devices (NCCDC, 2025, Rule 4.2); no containerizing scored services (NCCDC, 2025, Rule 4.14).

## Review log

| Date | Change |
|---|---|
| 2026-09-29 | Independent review. Fixed: VyOS commit-confirm reboot default (01); account locks moved from Tier 1 to Tier 2 and domain locks to Tier 3 (01); incident-report rule wording (02); `sfc /verifyonly` (04); materials rules 4.4 and 8.5 (07); banner decoys limited to unscored services (09). Removed event-specific topology, hostnames and timings from the public documents. |
| 2026-09-29 | Formatting and readability pass, no change to facts: consistent status lines without draft numbers, GitHub alert blocks for existing warnings and caveats, long paragraphs split into lists and tables, sentences reworded for clarity, acronyms expanded on first use, US spelling. |

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
