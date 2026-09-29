# 08. Ideas Mined from Reference Repositories

**Status:** Draft 1 · 2026-09-29

## 1. Purpose

Some repositories are kept as **reference only**: we read them, learn from them, and write our own original code. This avoids licence obligations and avoids running code we have not vetted. This document turns what we learned into design specs for Labyrinth modules. No code from them is copied.

## 2. Licence question

Team-written tools must be public and shared with all teams (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 5.6.1, 5.6.3). Third-party code you include remains under its own licence. Permissive licences (MIT, Apache-2.0) allow use with notice. Copyleft licences (GPL-3.0) require anything derived from them to be released under the same licence. Code with no licence file gives no permission to reuse. Ideas and techniques are not covered by copyright, which is why writing from a specification is the safe route. See the final summary for the direct answer.

## 3. Sources and what we take from each

| Source (reference only) | Idea | Labyrinth spec it feeds |
|---|---|---|
| CCDCScripts25 (UMass Cybersecurity) | Per-OS script layout; quick inventory of users, ports, services; baseline before hardening | Profiles and the observe inventory module (designs 00, 04) |
| BYU CCDC scripts (GPL-3.0) | Ordering of a first-hour checklist; separate Linux and Windows tracks | Stage plan and phase order (Strategic Plan) |
| SwiftOnSecurity sysmon-config (stale since 2021; no licence file) | Which Windows events carry high signal | Logging baseline for design 04 (event list only, written by us) |
| ansible-lockdown (MIT, active) | Benchmark-style control lists with IDs and a check/apply split | The module contract, one control per module or per module section (design 00) |
| UAC, Fenrir (from the reading list) | Dependency-free live collection with native tools | Collection step in the incident report pipeline (design 02) |

## 4. Specs distilled from the mining

### 4.1 Inventory module (observe, P0)
- Output: users and groups, sudoers, authorised keys, listeners with process, services, scheduled execution, startup items, firewall state, installed packages.
- Native tools only. One JSON-lines output file. Read-only.
- Runs before any lockout change and again after.

### 4.2 Control catalogue (all phases)
- Each hardening step gets a stable ID, a check, an apply, a verify and a rollback (matches the module contract).
- Controls are tagged with risk tier (design 01) so the panic button picks only the safe ones.
- Benchmark control text is paraphrased, never copied.

### 4.3 Windows event baseline (observe, P1)
- A short list of event IDs to forward: logons, failed logons, privilege use, process creation with command line, service and task creation, account changes, log clearing.
- Chosen by ourselves from the Windows documentation and the reading list, sized for a small SIEM.

### 4.4 Collection module (sustain, P2)
- Live triage collector for a suspected compromised host: process tree, network connections, recent file changes, persistence locations.
- Read-only, output to the `report` log category, feeds design 02.

### 4.5 Lint checks for our own scripts (tests)
- Static checks that no module calls the network, disables accounts wholesale, or changes shells, enforcing rules 5.6.4 and 5.6.5 automatically in the test suite.

## 5. What we will not copy

- Any script that restarts or removes services without an allowlist.
- Any code that deletes users or changes shells wholesale.
- Any download-and-run pattern.
- Anything with an unclear licence.

## 6. Re-check

Reference repositories change. Re-read them before each release and note the commit read. Vetting details for candidate repositories live in the CCDC-2027 docs.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
