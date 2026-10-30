# Labyrinth

[![CI](https://github.com/dotnetdork/Labyrinth/actions/workflows/ci.yml/badge.svg)](https://github.com/dotnetdork/Labyrinth/actions/workflows/ci.yml)
[![Docs](https://github.com/dotnetdork/Labyrinth/actions/workflows/docs.yml/badge.svg)](https://dotnetdork.github.io/Labyrinth/)

**Labyrinth hardens the hosts a defending team is given, plants traps for attackers, and keeps the scored services working. It is fast enough to use in the first minutes of an event, and every change it makes can be undone.**

> Labyrinth is built for the Collegiate Cyber Defense Competition (CCDC). When the event starts, attackers may already be inside the network, and the team must lock them out while keeping the scored services up. Labyrinth applies one strategy to every host, one group of hosts at a time, in priority order. It checks the services after each step and keeps a way back.

## Status

Labyrinth is not ready to defend a host yet: no hardening module exists. [`docs/Roadmap.md`](docs/Roadmap.md) gives the build order, and the design specs are the blueprint the code is built against.

**Built,** for Linux and Windows, and tested on CI but not yet in a lab:

- **The core:** logging, the run manifest, the safety gates, the revert timer (which undoes a run unless someone keeps it) and scoring-style probes.
- **The command line:** preview, run (`-r`), keep (`-k`), undo (`-u`), `--history` and `--probe` ([`docs/Conventions.md`](docs/Conventions.md), section 3.1).
- **The guided installers,** `install.sh` and `install.ps1`, which add the `laby` and `labyrinth` commands (section 3.3).
- **The groundwork modules need:** platform facts, the firewall adapter, quarantine, approval items and the shipped profiles.
- **The guard,** which checks every script for outside calls and blanket actions.

**Next: the first usable release.** One command per host with no questions during the run, an approval queue, the first-minute lockout, the Harden phase and short output. It is specified, not built. Remote mode (driving many hosts from one control node) comes after it.

## Why this exists

In a live competition (or a real incident) you do not have time to remember 200 hardening steps per host across a mix of Debian, Ubuntu, RHEL-family Linux, Windows Server, AD (Active Directory), and network appliances. You need:

1. **A strategy that is the same everywhere** — the same handful of invariants applied to every OS, so you reason once and execute many.
2. **A tool that applies it fast and can undo it** — safe to run twice, checks before it changes anything, and backs up first, so you can run it under pressure without breaking a scored service.
3. **Deception baked in** — because you cannot patch fast enough to out-run a pre-seeded foothold, so you make the attacker's every move expensive, noisy, and logged.

Labyrinth is that strategy plus that tool.

### The world it is built for

A heterogeneous, contested network of the kind CCDC events use:

- more than one Linux family (Debian and Ubuntu, and the RHEL family, Red Hat Enterprise Linux and its relatives);
- Windows Server with Active Directory;
- Windows and Linux workstations;
- a SIEM;
- network edge appliances such as a router and one or more firewalls, with the inside network either flat or split into segments.

Labyrinth classifies each host into a **profile** and applies the roles that fit — doing the safe work automatically, the riskier work once a person approves it, and printing a checklist for the few actions a person must carry out.

## The core strategy — *Lock out → Harden → Observe → Deceive → Sustain*

| Phase | Goal | In one line |
|---|---|---|
| **Lock out** (`lockout`) | Take back trust | Assume the attacker is already in: reset default and known admin credentials, end intruder sessions, default-deny the firewall. |
| **Harden** (`harden`, planned) | Shrink the surface | Behind the lockdown: install the team's tools, take restore points, sweep for footholds, verify core files against the official packages, patch named packages, cut unneeded services, then reopen outbound. |
| **Observe** (`observe`) | See everything | High-signal logging to a central SIEM (Security Information and Event Management system); watch logins, files, and process starts. |
| **Deceive** (`deceive`) | Tax the attacker | Traps, canaries, honey-accounts, tarpits — every non-service touch is a tripwire. |
| **Sustain** (`sustain`) | Keep services scoring | Keep the scored services healthy; check them on a schedule, roll back cleanly, report incidents and hold the line. |

Harden is specified and arrives in the first usable release (Roadmap). Today the runner's phases are `lockout`, `observe`, `deceive` and `sustain`, and the first-minute bundle runs without the Harden phase behind it.

## Documentation

All of these documents are also published as a website with a menu and search, rebuilt from the same files whenever they change: **[dotnetdork.github.io/Labyrinth](https://dotnetdork.github.io/Labyrinth/)**.

- **New to this?** Start with [`docs/Overview.md`](docs/Overview.md), a plain-language tour of how each part of Labyrinth works, written for readers who are not security or networking experts.
- **The whole system** (the doctrine, the transferable technicals, the trap catalog, and the architecture) is the implementation blueprint: [`docs/Blueprint.md`](docs/Blueprint.md).
- **The detailed designs** for each part of the tool live in [`docs/design/`](docs/design/README.md).
- **How the code is written** (formats, style, logging, tests): [`docs/Conventions.md`](docs/Conventions.md). **The build order:** [`docs/Roadmap.md`](docs/Roadmap.md).
- **The operator manual,** one source for the Linux and Windows editions: [`docs/manual/labyrinth.md`](docs/manual/labyrinth.md).

### Repository map

```
Labyrinth/
├── labyrinth.sh / labyrinth.ps1  ← main program: preview, run, keep, undo, history, probe, help, version
├── install.sh / install.ps1      ← guided installers; laby.cmd / labyrinth.cmd are the Windows commands
├── core/ phases/ profiles/ platform/   ← code layout from design 00
├── config/                       ← *.example templates for run-time values; never real values
├── vendor/                       ← pinned third-party code, each under its own license (planned)
├── report/                       ← incident reporting (planned; empty today)
├── tests/ tools/                 ← tests and the guard; manual and release builders
├── docs/                         ← overview, blueprint, conventions, roadmap, lab, manual, design specs 00–22
├── .github/                      ← CI, issue and pull request templates, Copilot instructions
└── AGENTS.md, CLAUDE.md, .claude/  ← working rules and shared setup for contributors and AI assistants
```

Strategy, the team's reading of the rules, topology notes and the vulnerability assessment live in the team's private repository, not here.

## Install

From the unpacked release folder, the installer checks the release, shows what it will do, and asks before it changes anything (the default answer is no). It is safe to run again.

```bash
sudo ./install.sh          # Linux: as root
```

```powershell
.\install.ps1              # Windows: in a PowerShell window opened as Administrator
```

It installs the code where only root (Administrators) can change it, adds the commands `laby` and `labyrinth`, installs the manual, and copies the `config/*.example` templates into the data root without overwriting anything. Then run `sudo laby` (Linux) or `laby` (Windows). The steps are in [`docs/Conventions.md`](docs/Conventions.md#33-automatic-runs-and-the-rest-of-the-command-line-specified-planned) and the operator manual ([`docs/manual/labyrinth.md`](docs/manual/labyrinth.md)).

## The rules it follows

> [!IMPORTANT]
> Competition rules are cited by rule number from the national rules, updated 10 December 2025. Each event's own materials and local competition rules come first and differ from event to event, so every event value is supplied at run time.

Labyrinth is a team-written tool under the national CCDC rules, so it:

- is published at least three months before use;
- is declared to officials and frozen for each event;
- is shared with every competing team;
- uses no cloud services or other outside processing, and after the first-minute lockdown downloads only public software and public data, with a fallback to pasting files in (DNS, the Domain Name System, lookups aside);
- never deliberately breaks expected functionality

(National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 5.6.1–5.6.5). Strategy and event-specific values live in the team's private repository.

> [!CAUTION]
> **No secrets in this repo — ever.** Labyrinth provisions *shape*, not values: placeholder templates (`.env.example`, cert paths, token names), real values supplied at run time from the event packet and an event seed kept offline (see [`docs/design/16`](docs/design/16-Event-Seed-and-Deception-Config.md)).
> The reference documents configuration structure only; no keys, env files, or credentials are reproduced.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md): one issue, one person, one branch, one small pull request, merged after CI passes and a second person approves.

## Security

Found a weakness in Labyrinth itself? Report it privately, never in a public issue: see [`SECURITY.md`](SECURITY.md).

## License

Labyrinth is free for noncommercial use, such as personal study, labs, schools and CCDC defense, under the PolyForm Noncommercial License 1.0.0 with a few additional terms: Jay Sausa is the sole owner, and publishing a changed version needs the owner's written permission. Third-party components under `vendor/` keep their own licenses. The full terms are in [`LICENSE`](LICENSE).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from
 https://www.nationalccdc.org/rules.html
