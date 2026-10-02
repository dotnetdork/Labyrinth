# Labyrinth

**A fast, idempotent deployment system that drives any box it can reach into a known-good hardened, deceptive posture — fast enough to matter in the first minutes of an engagement.**

> Built for CCDC-style defense (the Collegiate Cyber Defense Competition): the flag drops, the network is already contested, and you have to lock attackers out *now* while keeping scored services alive. Labyrinth is the muscle memory — one repo, one core strategy, applied host by host in small rings, in priority order, with a check and a way back at every step.

---

## Why this exists

In a live competition (or a real incident) you do not have time to remember 200 hardening steps per host across a mix of Ubuntu, Fedora, Oracle Linux, Windows Server, AD (Active Directory), and network appliances. You need:

1. **A strategy that is the same everywhere** — the same handful of invariants applied to every OS, so you reason once and execute many.
2. **A tool that applies it fast and reversibly** — idempotent (safe to run twice), re-runnable, check-before-change, timestamped backups, so you can hit *go* under pressure without breaking a scored service.
3. **Deception baked in** — because you cannot patch fast enough to out-run a pre-seeded foothold, so you make the attacker's every move expensive, noisy, and logged.

Labyrinth is that strategy plus that tool. The **Linux profile** is modeled on a hardened server the author runs; this documentation generalizes it into a portable system.

## The core strategy — *Lock out → Observe → Deceive → Sustain*

| Phase | Goal | In one line |
|---|---|---|
| 🟥 **Lock out** | Take back trust | Reset every default/known credential, allowlist admins, default-deny the firewall. |
| 🟦 **Observe** | See everything | High-signal logging to a central SIEM (Security Information and Event Management system); watch logins, files, and process starts. |
| 🟪 **Deceive** | Tax the attacker | Traps, canaries, honey-accounts, tarpits — every non-service touch is a tripwire. |
| 🟩 **Sustain** | Stay scored-green | Keep the graded services healthy; patch and roll back cleanly; hold the line. |

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

Labyrinth classifies each host into a **profile** and applies the roles that fit — locking the easy 80% automatically and flagging the manual 20%.

## Repository map

```
Labyrinth/
├── README.md                     ← you are here
├── docs/
│   ├── Overview.md                ← plain-language tour; start here
│   ├── Blueprint.md               ← doctrine, capability map, trap catalog (rules-aware)
│   └── design/                    ← design specs 00–16 (module contract, panic button,
│                                    incident reporting, event seed, baseline, credentials,
│                                    status feed, cleanup, reference mining, deception maze,
│                                    log forwarding, Windows/AD, bans, health monitor,
│                                    backups, patching, appliance runbooks)
└── (future) core/ phases/ profiles/ platform/ config/ vendor/ tests/   ← see design/00
```

Strategy, rules baseline, topology notes and the vulnerability assessment live in the private CCDC-2027 repository, not here.

## Status

Planning and design phase (reviewed 2026-09-29). No code yet. The design specs are the blueprint the code is built against.

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

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
