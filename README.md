# Labyrinth

**Labyrinth hardens the hosts a defending team is given, plants traps for attackers, and keeps the scored services working. It is fast enough to use in the first minutes of an event, and every change it makes can be undone.**

> Labyrinth is built for the Collegiate Cyber Defense Competition (CCDC). When the event starts, attackers may already be inside the network, and the team must lock them out while keeping the scored services up. Labyrinth applies one strategy to every host, one group of hosts at a time, in priority order. It checks the services after each step and keeps a way back.

---

## Why this exists

In a live competition (or a real incident) you do not have time to remember 200 hardening steps per host across a mix of Ubuntu, Fedora, Oracle Linux, Windows Server, AD (Active Directory), and network appliances. You need:

1. **A strategy that is the same everywhere** — the same handful of invariants applied to every OS, so you reason once and execute many.
2. **A tool that applies it fast and can undo it** — safe to run twice, checks before it changes anything, and backs up first, so you can run it under pressure without breaking a scored service.
3. **Deception baked in** — because you cannot patch fast enough to out-run a pre-seeded foothold, so you make the attacker's every move expensive, noisy, and logged.

Labyrinth is that strategy plus that tool.

## The core strategy — *Lock out → Observe → Deceive → Sustain*

| Phase | Goal | In one line |
|---|---|---|
| **Lock out** (`lockout`) | Take back trust | Assume the attacker is already in: reset default and known admin credentials, end intruder sessions, sweep for footholds, default-deny the firewall. |
| **Observe** (`observe`) | See everything | High-signal logging to a central SIEM (Security Information and Event Management system); watch logins, files, and process starts. |
| **Deceive** (`deceive`) | Tax the attacker | Traps, canaries, honey-accounts, tarpits — every non-service touch is a tripwire. |
| **Sustain** (`sustain`) | Keep services scoring | Keep the scored services healthy; patch and roll back cleanly; hold the line. |

**New to this?** Start with [`docs/Overview.md`](docs/Overview.md), a plain-language tour of how each part of Labyrinth works, written for readers who are not security or networking experts.

The complete overview of the system (the whole doctrine, the transferable technicals, the trap catalog, and the architecture) is the implementation blueprint:

### → [`docs/Blueprint.md`](docs/Blueprint.md)

The detailed designs for each part of the tool live in [`docs/design/`](docs/design/README.md).

## The world Labyrinth is built for

A heterogeneous, contested network of the kind CCDC events use:

- more than one Linux family (Debian and RHEL, Red Hat Enterprise Linux);
- Windows Server with Active Directory;
- Windows and Linux workstations;
- a SIEM;
- network edge appliances such as a router and one or more firewalls, often split into segments.

Labyrinth classifies each host into a **profile** and applies the roles that fit — doing the safe work automatically, the riskier work once a person approves it, and printing a checklist for the few actions a person must carry out.

## Repository map

```
Labyrinth/
├── README.md                     ← you are here
├── CLAUDE.md                     ← working rules for contributors and AI assistants
├── labyrinth.sh / labyrinth.ps1  ← main program: plan, apply, keep, rollback, runs, probe
├── core/ phases/ profiles/ platform/ report/   ← code layout from design 00
├── config/                       ← *.example templates for run-time values; never real values
├── vendor/                       ← pinned third-party code, each under its own license (planned)
├── tests/                        ← bats and Pester tests, the guard and fixtures
├── tools/manual/                 ← builds the Linux and Windows manuals (CI only)
├── docs/
│   ├── Overview.md                ← plain-language tour; start here
│   ├── Blueprint.md               ← doctrine, capability map, trap catalog (rules-aware)
│   ├── Conventions.md             ← how the code is written: formats, style, logging, tests
│   ├── Roadmap.md                 ← build order: milestones, branches, settled decisions
│   ├── lab/README.md              ← the test lab: machines, how to run a pass, results
│   ├── manual/labyrinth.md        ← operator manual: one source, Linux and Windows editions
│   └── design/                    ← design specs 00–21 (module contract, panic button,
│                                    incident reporting, event seed, baseline, credentials,
│                                    status feed, cleanup, reference mining, deception maze,
│                                    log forwarding, Windows/AD, bans, health monitor,
│                                    backups, patching, appliance runbooks, persistence
│                                    sweep, service packs, platform adapters, packages,
│                                    vulnerability tracker)
└── .github/workflows/ci.yml       ← lint, guard and tests on Linux and Windows
```

Strategy, the team's reading of the rules, topology notes and the vulnerability assessment live in the team's private repository, not here.

## Status

Groundwork stage (reviewed 2026-10-09). The design specs are the blueprint the code is built against, and [`docs/Roadmap.md`](docs/Roadmap.md) gives the order they are built in. The core is built for Linux and Windows: logging, the run manifest, the safety gates, the revert timer (which undoes a run unless someone keeps it), scoring-style probes, and the main program's plan, apply, keep, rollback, runs and probe commands (docs/Conventions.md, section 3.1). The groundwork modules need is built too: platform facts, the firewall adapter, quarantine, approval items and the shipped profiles. It is tested on CI, but not yet in a lab. The guard checks every script for outside calls and blanket actions. No hardening module exists yet, and remote mode (driving many hosts from one control node) is not built.


> [!IMPORTANT]
> Competition rules are cited by rule number; all citations must be re-checked when the 2027 rules are published.

Labyrinth is a team-written tool under the national CCDC rules, so it:

- is published at least three months before use;
- is declared to officials and frozen for each event;
- is shared with every competing team;
- uses no outside resources other than DNS (the Domain Name System);
- never deliberately breaks expected functionality

(National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 5.6.1–5.6.5). Strategy and event-specific values live in the team's private repository.

## Ground rule

> [!CAUTION]
> **No secrets in this repo — ever.** Labyrinth provisions *shape*, not values: placeholder templates (`.env.example`, cert paths, token names), real values supplied at run time from the event packet and an event seed kept offline (see [`docs/design/03`](docs/design/03-Event-Seed-and-Deception-Config.md)).
> The reference documents configuration structure only; no keys, env files, or credentials are reproduced.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from
 https://www.nationalccdc.org/rules.html
