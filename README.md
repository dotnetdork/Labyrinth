# Labyrinth

**Labyrinth hardens the hosts a defending team is given, plants traps for attackers, and keeps the scored services working. It is fast enough to use in the first minutes of an event, and every change it makes can be undone.**

> Labyrinth is built for the Collegiate Cyber Defense Competition (CCDC). When the event starts, attackers may already be inside the network, and the team must lock them out while keeping the scored services up. Labyrinth applies one strategy to every host, one group of hosts at a time, in priority order. It checks the services after each step and keeps a way back.

---

## Why this exists

In a live competition (or a real incident) you do not have time to remember 200 hardening steps per host across a mix of Debian, Ubuntu, RHEL-family Linux, Windows Server, AD (Active Directory), and network appliances. You need:

1. **A strategy that is the same everywhere** — the same handful of invariants applied to every OS, so you reason once and execute many.
2. **A tool that applies it fast and can undo it** — safe to run twice, checks before it changes anything, and backs up first, so you can run it under pressure without breaking a scored service.
3. **Deception baked in** — because you cannot patch fast enough to out-run a pre-seeded foothold, so you make the attacker's every move expensive, noisy, and logged.

Labyrinth is that strategy plus that tool.

## The core strategy — *Lock out → Harden → Observe → Deceive → Sustain*

| Phase | Goal | In one line |
|---|---|---|
| **Lock out** (`lockout`) | Take back trust | Assume the attacker is already in: reset default and known admin credentials, end intruder sessions, default-deny the firewall. |
| **Harden** (`harden`, planned) | Shrink the surface | Behind the lockdown: install the team's tools, take restore points, sweep for footholds, verify core files against the official packages, patch named packages, cut unneeded services, then reopen outbound. |
| **Observe** (`observe`) | See everything | High-signal logging to a central SIEM (Security Information and Event Management system); watch logins, files, and process starts. |
| **Deceive** (`deceive`) | Tax the attacker | Traps, canaries, honey-accounts, tarpits — every non-service touch is a tripwire. |
| **Sustain** (`sustain`) | Keep services scoring | Keep the scored services healthy; check them on a schedule, roll back cleanly, report incidents and hold the line. |

Harden is specified and arrives in Roadmap stage 4b. Today the runner's phases are `lockout`, `observe`, `deceive` and `sustain`, and the first-minute bundle runs without the Harden phase behind it.

**New to this?** Start with [`docs/Overview.md`](docs/Overview.md), a plain-language tour of how each part of Labyrinth works, written for readers who are not security or networking experts.

The complete overview of the system (the whole doctrine, the transferable technicals, the trap catalog, and the architecture) is the implementation blueprint:

### → [`docs/Blueprint.md`](docs/Blueprint.md)

The detailed designs for each part of the tool live in [`docs/design/`](docs/design/README.md).

All of these documents are also published as a website with a menu and search, rebuilt from the same files whenever they change: **[dotnetdork.github.io/Labyrinth](https://dotnetdork.github.io/Labyrinth/)**.

## The world Labyrinth is built for

A heterogeneous, contested network of the kind CCDC events use:

- more than one Linux family (Debian and Ubuntu, and the RHEL family, Red Hat Enterprise Linux and its relatives);
- Windows Server with Active Directory;
- Windows and Linux workstations;
- a SIEM;
- network edge appliances such as a router and one or more firewalls, with the inside network either flat or split into segments.

Labyrinth classifies each host into a **profile** and applies the roles that fit — doing the safe work automatically, the riskier work once a person approves it, and printing a checklist for the few actions a person must carry out.

## Repository map

```
Labyrinth/
├── README.md                     ← you are here
├── AGENTS.md                     ← working rules for contributors and AI assistants
├── CLAUDE.md                     ← pulls in AGENTS.md for Claude Code, plus its own setup
├── CONTRIBUTING.md               ← how to pick up an issue and open a pull request
├── SECURITY.md                   ← how to report a weakness in Labyrinth privately
├── .claude/                      ← shared Claude Code agents, commands and settings
├── labyrinth.sh / labyrinth.ps1  ← main program: preview, run, keep, undo, history, probe, help, version
├── core/ phases/ profiles/ platform/   ← code layout from design 00
├── report/                       ← incident reporting (planned; empty today)
├── config/                       ← *.example templates for run-time values; never real values
├── vendor/                       ← pinned third-party code, each under its own license (planned)
├── tests/                        ← bats and Pester tests, the guard and fixtures
├── tools/manual/                 ← builds the Linux and Windows manuals (CI only)
├── tools/release/                ← writes the release manifest (file hashes)
├── mkdocs.yml                    ← settings for the documentation website
├── docs/
│   ├── Overview.md                ← plain-language tour; start here
│   ├── Blueprint.md               ← doctrine, capability map, trap catalog (rules-aware)
│   ├── Conventions.md             ← how the code is written: formats, style, logging, tests
│   ├── Roadmap.md                 ← build order: milestones, branches, settled decisions
│   ├── index.md                   ← home page of the documentation website
│   ├── lab/README.md              ← the test lab: machines, how to run a pass, results
│   ├── manual/labyrinth.md        ← operator manual: one source, Linux and Windows editions
│   └── design/                    ← design specs 00–22, in run order (module contract,
│                                    platform adapters, packages, panic button,
│                                    credentials, appliance runbooks, persistence sweep,
│                                    backups, baseline, vulnerability tracker, patching,
│                                    service packs, Windows/AD, service replacement,
│                                    log forwarding, status feed, event seed, deception
│                                    maze, bans, health monitor, incident reporting,
│                                    cleanup, reference mining)
└── .github/                       ← CI (lint, guard and tests on Linux and Windows),
                                     the issue templates, the pull request template
                                     and instructions for Copilot
```

Strategy, the team's reading of the rules, topology notes and the vulnerability assessment live in the team's private repository, not here.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md): one issue, one person, one branch, one small pull request, merged after CI passes and a second person approves.

## Status

Build stages 0 to 3 are done. The design specs are the blueprint the code is built against, and [`docs/Roadmap.md`](docs/Roadmap.md) gives the order they are built in. The core is built for Linux and Windows: logging, the run manifest, the safety gates, the revert timer (which undoes a run unless someone keeps it), scoring-style probes, and the main program's command line: preview, run (-r), keep (-k), undo (-u), --history and --probe (docs/Conventions.md, section 3.1). The groundwork modules need is built too: platform facts, the firewall adapter, quarantine, approval items and the shipped profiles. It is tested on CI, but not yet in a lab. The guard checks every script for outside calls and blanket actions. No hardening module exists yet, and remote mode (driving many hosts from one control node) is not built. Stage 4b is next: one command per host with no questions during the run, an approval queue, short output and the Harden phase. It is specified, not built ([`docs/Roadmap.md`](docs/Roadmap.md)).


> [!IMPORTANT]
> Competition rules are cited by rule number from the national rules, updated 10 December 2025. Each event's own materials and local competition rules come first and differ from event to event, so every event value is supplied at run time.

Labyrinth is a team-written tool under the national CCDC rules, so it:

- is published at least three months before use;
- is declared to officials and frozen for each event;
- is shared with every competing team;
- uses no cloud services or other outside processing, and after the first-minute lockdown downloads only public software and public data, with a fallback to pasting files in (DNS, the Domain Name System, lookups aside);
- never deliberately breaks expected functionality

(National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 5.6.1–5.6.5). Strategy and event-specific values live in the team's private repository.

## Ground rule

> [!CAUTION]
> **No secrets in this repo — ever.** Labyrinth provisions *shape*, not values: placeholder templates (`.env.example`, cert paths, token names), real values supplied at run time from the event packet and an event seed kept offline (see [`docs/design/16`](docs/design/16-Event-Seed-and-Deception-Config.md)).
> The reference documents configuration structure only; no keys, env files, or credentials are reproduced.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from
 https://www.nationalccdc.org/rules.html
