# Labyrinth

**A fast, idempotent deployment system that drives any box it can reach into a known-good hardened, deceptive posture — fast enough to matter in the first minutes of an engagement.**

> Built for CCDC-style defense: the flag drops, the network is already contested, and you have to lock attackers out *now* while keeping scored services alive. Labyrinth is the muscle memory — one repo, one core strategy, applied to every host at once, in priority order.

---

## Why this exists

In a live competition (or a real incident) you do not have time to remember 200 hardening steps per host across a mix of Ubuntu, Fedora, Oracle Linux, Windows Server, AD, and network appliances. You need:

1. **A strategy that is the same everywhere** — the same handful of invariants applied to every OS, so you reason once and execute many.
2. **A tool that applies it fast and reversibly** — idempotent, re-runnable, check-before-change, timestamped backups, so you can hit *go* under pressure without bricking a scored service.
3. **Deception baked in** — because you cannot patch fast enough to out-run a pre-seeded foothold, so you make the attacker's every move expensive, noisy, and logged.

Labyrinth is that strategy plus that tool. The **Linux profile** is modelled on a hardened server the author runs; this documentation generalizes it into a portable system.

## The core strategy — *Lock out → Observe → Deceive → Sustain*

| Phase | Goal | In one line |
|---|---|---|
| **Lock out** | Take back trust | Reset every default/known credential, allowlist admins, default-deny the firewall. |
| **Observe** | See everything | High-signal logging to a central SIEM; watch auth, files, and process starts. |
| **Deceive** | Tax the attacker | Traps, canaries, honey-accounts, tarpits — every non-service touch is a tripwire. |
| **Sustain** | Stay scored-green | Keep the graded services healthy; patch and roll back cleanly; hold the line. |

The whole doctrine, the transferable technicals, the trap catalog, and the architecture live in:

### → [`docs/Hardening-Reference.md`](docs/Hardening-Reference.md)

## The world Labyrinth is built for

A heterogeneous, contested network of the kind CCDC events use: more than one Linux family, Windows Server with Active Directory, workstations, a SIEM, and network edge appliances such as a router and firewalls. Labyrinth classifies each host into a **profile** and applies the roles that fit — locking the easy 80% automatically and flagging the manual 20%.

## Repository map

```
Labyrinth/
├── README.md                     ← you are here
├── docs/
│   ├── Hardening-Reference.md     ← doctrine, capability map, trap catalog (rules-aware, Draft 2)
│   └── design/                    ← design specs 00–09 (module contract, panic button,
│                                    incident reporting, event seed, baseline, credentials,
│                                    status feed, cleanup, reference mining, deception maze)
└── (future) core/ phases/ profiles/ platform/ config/ vendor/ tests/   ← see design/00
```

Strategy, rules baseline, topology notes and the vulnerability assessment live in the private CCDC-2027 repository, not here.

## Status

Planning and design phase (Draft 2). The design specs are the blueprint the code is built against. Competition rules are cited by rule number; all citations must be re-checked when the 2027 rules are published.

## Ground rule

**No secrets in this repo — ever.** Labyrinth provisions *shape*, not values: placeholder templates
(`.env.example`, cert paths, token names), real values supplied at run time from the event packet and a paper-only event seed (see `docs/design/03`).
The reference documents configuration structure only; no keys, env files, or credentials are reproduced.
