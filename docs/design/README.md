# Labyrinth Design Specifications

**Status:** Draft 1 · 2026-09-29 · These are design documents, not code. They describe what each part must do, how it stays inside the competition rules, and how it is tested.

> **Rules basis.** Built on the 2026 national CCDC rules and the 2025 Midwest qualifier packet. The 2027 rules are not published yet, so every rule citation here must be re-checked when they arrive. Rule numbers follow the web version of the rules (National Collegiate Cyber Defense Competition [NCCDC], 2025).

## Reading order

| # | Document | Question it answers |
|---|---|---|
| 00 | [Module contract and layout](00-Module-Contract-and-Layout.md) | How is Labyrinth organised so that new capabilities plug in without touching the core? |
| 01 | [Lockout ("panic button")](01-Lockout-Panic-Button.md) | How do we do the first-minutes lockout safely and inside the rules? |
| 02 | [Incident reporting automation](02-Incident-Reporting-Automation.md) | How do we produce complete Red Team incident reports quickly? |
| 03 | [Event seed and deception config](03-Event-Seed-and-Deception-Config.md) | How can the code be public but the deception still be unpredictable? |
| 04 | [Baseline and integrity](04-Baseline-and-Integrity.md) | How do we hash critical files and learn who changed what, when, and from where? |
| 05 | [Credentials and SSH keys](05-Credentials-and-SSH-Keys.md) | How do we rotate credentials and deploy keys without locking ourselves out? |
| 06 | [Status feed and MOTD](06-Status-Feed-and-MOTD.md) | How does the SIEM inform every host without new trust paths? |
| 07 | [Cleanup and tool integrity](07-Cleanup-and-Tool-Integrity.md) | How do we leave nothing behind and keep our own tools tamper-evident? |
| 08 | [Ideas mined from reference repos](08-Reference-Mining.md) | What did the reference-only repositories teach us, turned into specs? |
| 09 | [Deception maze and CVE decoys](09-Deception-Maze-and-CVE-Decoys.md) | How do we build the maze, and where are the limits? |

## Where things live

- **This repository (Labyrinth):** design, code, reference. It becomes public because Rule 5.6.1 requires team-written tools to be public before use (NCCDC, 2025, Rule 5.6.1). Never put strategy, per-event values, real hostnames, addresses or credentials here.
- **CCDC-2027 (private):** strategy, rules baseline, topology notes, decision log.

## Design constraints that apply to every document

1. Public and frozen: code must be safe for rivals and the Red Team to read (NCCDC, 2025, Rules 5.6.2, 5.6.3).
2. No outside resources at run time other than DNS lookups (NCCDC, 2025, Rule 5.6.4).
3. No deliberate breakage of expected functionality (NCCDC, 2025, Rule 5.6.5).
4. Never impede the scoring engine or mislead it (NCCDC, 2025, Rules 4.11, 9.3).
5. Officials must be able to get in (NCCDC, 2025, Rule 4.1).
6. No new devices (NCCDC, 2025, Rule 4.2); no containerizing scored services (NCCDC, 2025, Rule 4.14).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
