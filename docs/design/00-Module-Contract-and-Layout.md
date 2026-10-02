# 00. Module Contract and Repository Layout

**Status:** Draft · reviewed 2026-10-02

## 1. Goal

One main Labyrinth program enables each phase. Each phase is an entry script that calls small, single-purpose modules. Adding a capability means adding a folder, not editing the core, which is how the design stays scalable.

## 2. Naming: phases, not "hardening"

"Hardening" is the umbrella word in the documents, but it covers more than one moment: a credential reset at minute zero is a different job from patching at hour two. Folders are therefore named after the doctrine phases, which are also the order the phases run in:

| Folder | Phase | Contains |
|---|---|---|
| `lockout` | 🟥 Lock out | Credentials, accounts, firewall, remote-admin hardening, service reduction |
| `observe` | 🟦 Observe | Log forwarding, auditing, integrity baseline, status feed |
| `deceive` | 🟪 Deceive | Canaries, honey-accounts, trap ports, tarpits, decoy services |
| `sustain` | 🟩 Sustain | Health checks, backups, rollback, patching, reporting |

```mermaid
flowchart LR
    L["<b>1. Lock out</b><br/>credentials · accounts<br/>firewall · remote admin<br/>service reduction"]
    O["<b>2. Observe</b><br/>log forwarding · auditing<br/>integrity baseline<br/>status feed"]
    D["<b>3. Deceive</b><br/>canaries · honey-accounts<br/>trap ports · tarpits<br/>decoy services"]
    S["<b>4. Sustain</b><br/>health checks · backups<br/>rollback · patching<br/>reporting"]
    L --> O --> D --> S
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef deceive fill:#efe7fb,stroke:#7c3aed,color:#351465
    classDef sustain fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    class L lockout
    class O observe
    class D deceive
    class S sustain
```

*Figure: the four phases run in order, left to right, and each box lists the kinds of module its folder contains. Colors follow the phase key: red is lock out, blue is observe, purple is deceive and green is sustain.*

## 3. Repository layout

```
Labyrinth/
├── labyrinth.sh                 # main program for Linux hosts and control nodes (bash)
├── labyrinth.ps1                # main program for Windows hosts and control nodes (PowerShell)
├── core/                        # shared library used by every module
│   ├── lib.sh                   # loads the bash core (entry points source it)
│   ├── Lab.ps1                  # loads the PowerShell core (entry points dot-source it)
│   ├── config/                  # run-time configuration readers (data only, never sourced)
│   ├── log/                     # structured logging (JSON lines)
│   ├── manifest/                # run manifest: what was changed, for rollback and cleanup
│   ├── safety/                  # protected set, gates, dead-man revert timers
│   ├── seed/                    # event seed derivation (design 03)
│   └── probe/                   # scoring-style health probes
├── phases/
│   ├── lockout/
│   │   ├── run-lockout.sh       # phase entry script
│   │   ├── run-lockout.ps1
│   │   └── modules/
│   │       ├── credentials/     # one folder per module (contract below)
│   │       ├── accounts/
│   │       ├── firewall/
│   │       ├── ssh/
│   │       └── services/
│   ├── observe/  (same shape)
│   ├── deceive/  (same shape)
│   └── sustain/  (same shape)
├── report/                      # incident report builder (design 02); cross-phase
├── profiles/                    # host profile → ordered module list
├── platform/                    # per-OS adapters: ubuntu, rhel-family, windows, appliance runbooks
├── config/                      # templates only: *.example, never values
├── vendor/                      # pinned third-party code, each with LICENSE and NOTICE
├── tests/                       # lab tests and negative tests
└── docs/                        # design specs and the implementation blueprint
```

Notes:

- **Profiles** map hosts to modules, for example `linux-web`, `linux-siem`, `windows-dc`, `windows-member`, `appliance`. A profile is a list, not code.
- **Appliances** (VyOS, Palo Alto, Cisco FTD (Firepower Threat Defense)) are handled by templated configuration and a manual runbook, not remote-execution modules.
- **Language:** bash on Linux, Windows PowerShell 5.1 on Windows. No interpreter or package has to be installed at run time (section 9).

```mermaid
flowchart TD
    MAIN["labyrinth.sh / labyrinth.ps1<br/>(main program)"]
    subgraph inputs["What the main program reads"]
        PROF["profiles/<br/>host profile → module list"]
        CFG["config/<br/>*.example templates only"]
    end
    subgraph work["What it runs"]
        PH["phases/<br/>lockout · observe · deceive · sustain"]
        MOD["phases/{phase}/modules/{name}/<br/>module.yml + entry points"]
        REP["report/<br/>incident report builder"]
    end
    subgraph shared["What modules share"]
        CORE["core/<br/>log · manifest · safety · seed · probe"]
        PLAT["platform/<br/>per-OS adapters"]
        VEN["vendor/<br/>pinned third-party code"]
    end
    MAIN -->|reads| PROF
    MAIN -->|runs| PH
    PH -->|calls| MOD
    MOD -->|uses| CORE
    MOD -->|uses| PLAT
    MOD -.->|may use| VEN
    MAIN -.->|run-time values shaped like| CFG
    MAIN -->|cross-phase| REP
```

*Figure: the main program reads a profile, runs the phase entry scripts, and each phase calls its modules, which share the core library and per-OS adapters; dashed lines are optional or run-time-only links.*

## 4. The module contract

Every module is a folder containing a metadata file and up to six entry points.

`module.yml` fields:

| Field | Meaning |
|---|---|
| `id` | Unique name, for example `lockout.firewall` |
| `phase` | `lockout`, `observe`, `deceive` or `sustain` |
| `priority` | P0 to P3 (P0 runs first, P3 last) |
| `platforms` | `ubuntu`, `rhel-family`, `windows`, `appliance` |
| `risk` | `read-only`, `reversible`, `service-affecting`, `approval` or `manual-only` |
| `touches_scored` | `true` if it can affect a scored service or account |
| `requires` | Other modules or facts that must exist first |
| `outputs` | Files and state it creates, so cleanup can find them |

Entry points:

| Entry point | Purpose | Must be |
|---|---|---|
| `check` | Is a change needed? | Read-only. Exits `10` if a change is needed and `0` if not |
| `plan` | Show exactly what `apply` would do | Read-only. This is the default mode. Exits like `check`: `10` when it lists changes, `0` when it lists none |
| `apply` | Make the change | Idempotent; backs up first; writes to the run manifest |
| `verify` | Confirm the change worked and nothing scored broke | Read-only |
| `rollback` | Undo `apply` from the manifest | Safe to run repeatedly |
| `cleanup` | Remove temporary files this module created | Safe to run repeatedly |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Nothing to do, or success |
| `10` | Change needed |
| `20` | Blocked by a safety gate |
| `30` | Verify failed |
| `40` | Error |

```mermaid
flowchart TD
    C["check<br/>(read-only)"] -->|"exit 0: nothing to do"| DONE(["done"])
    C -->|"exit 10: change needed"| P["plan<br/>(read-only, default mode)"]
    P --> G{"safety gates pass<br/>and human confirms?"}
    G -->|"no: exit 20"| BLOCK(["blocked, nothing changed"])
    G -->|yes| A["apply<br/>backup first, write run manifest"]
    A --> V{"verify<br/>(scoring-style probes)"}
    V -->|"pass: exit 0"| CL["cleanup<br/>temporary files"]
    V -->|"fail: exit 30"| RB["rollback<br/>from the run manifest"]
    RB --> CL
    CL --> DONE
    subgraph anystep["At any step"]
        ERR(["any step fails unexpectedly:<br/>exit 40, stop"])
    end
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class DONE,CL ok
    class G,RB human
    class BLOCK,ERR stop
```

*Figure: one module run moves from check to plan to a human-confirmed apply, then verify decides between cleanup and rollback; each arrow shows its exit code, and exit 40 can end the run at any step. Green marks a clean finish, amber a human decision or an undo, and a dashed red outline a stop.*

Rules for module authors:

1. `touches_scored: true` modules run only after the scoring allowlist and the protected set are loaded.
2. An `approval` module lists each item it would change, with the reason, and changes only the items a person approves, per item or per category on one host. Approved items go through the same backup, manifest, verify and rollback as any other change.
3. A `manual-only` module never changes anything. It prints a checklist for a human. This is kept for actions too broad or too hard to undo for Labyrinth to carry out even with approval: KRBTGT resets, Group Policy and DNS server changes, domain controller restores, rescuing an unbootable host, patching and appliance changes.
4. No module downloads anything or calls outside services (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.4).
5. No module deliberately breaks expected functionality (NCCDC, 2025, Rule 5.6.5).
6. No module deletes a file. Anything removed is quarantined (design 17, section 5). An account is deleted only by the account module, after approval (design 05, section 6).

## 5. Execution model

Labyrinth runs in two modes that share the same modules:

- **Local mode.** `labyrinth.sh` or `labyrinth.ps1` runs on the host it changes. This is the base: it needs nothing but the host itself, and it is the fallback when remote access is lost.
- **Remote mode.** `labyrinth remote --targets <group> <phase>` runs on a control node. For each target it copies the release, checks it (design 07, section 5), runs the *same* local command over SSH (Linux) or PowerShell remoting or OpenSSH (Windows), and brings back the logs and the run manifest. It must cope with being cut off, because the lockout rotates the very credentials and SSH settings it connects with.

Either way, one run does this:

```
labyrinth <phase> --profile <name> --targets <group>   # plan mode by default
   1. load profile → ordered module list
   2. safety gates (protected set loaded, break-glass verified; the scoring allowlist
      for modules that touch scored services)
   3. plan all modules and print the combined plan
   4. human confirms (typed confirmation) → apply in rings (design 01)
   5. verify each module with scoring-style probes; auto-rollback a module on regression
   6. write run manifest; run cleanup
```

The local commands are `labyrinth.sh <phase>` (plan), `--apply <phase>`, `probe`, `keep <run>` and `rollback <run>`, with the same commands in `labyrinth.ps1`. `docs/Conventions.md` section 3.1 gives their options and the exact order of the gates and steps in an apply.

## 6. Code and configuration are separate

The released code is frozen for each event (NCCDC, 2025, Rule 5.6.2). Everything that changes per event is configuration: the scoring engine addresses, the protected accounts, the event seed and the host lists. Configuration is supplied at run time and never committed; the `config/*.example` files show its shape only.

Our reading is that values supplied at run time are not part of the frozen submission, so they can change after the freeze. The rule does not say so directly, so this reading must be confirmed with competition officials before relying on it.

## 7. Standard paths on every host

Every host uses the same tree, and everything Labyrinth keeps is under one root. The root is configurable, so the location is not a fixed, publicly known path, and cleanup has one place to look.

| Purpose | Linux | Windows |
|---|---|---|
| Code (read-only) | `<root>/bin` | `<root>\bin` |
| Run-time configuration | `<root>/etc` | `<root>\etc\` |
| State: baselines, manifests, key registry | `<root>/state` | `<root>\state\` |
| Logs, one folder per category | `<root>/logs/<category>` | `<root>\logs\<category>\` |
| Backups, timestamped | `<root>/backup` | `<root>\backup\` |

- **Default root:** `/opt/labyrinth` on Linux, `C:\ProgramData\Labyrinth` on Windows.
- **Ownership.** The whole tree is owned by root (SYSTEM and Administrators on Windows). `etc`, `state` and `backup` are readable by them only, because backups can hold copies of configuration files that contain secrets and the state shows where the traps are.
- **Log categories:** `run`, `auth`, `integrity`, `network`, `deception`, `report`, `health` (design 13).

## 8. Adding a capability

1. Create `phases/<phase>/modules/<name>/` with `module.yml` and the entry points.
2. Add the module id to the relevant profile.
3. Add lab tests, including a negative test that shows protected accounts and scored services are untouched.

Nothing else changes.

## 9. Decisions

- **Ansible or native scripts.** Resolved: native scripts. They work in local mode with nothing installed, and the remote mode (section 5) gives the reach Ansible would have given.
- **Windows log shipping method.** Pinned between the Splunk forwarder installer, a script posting to Splunk's HTTP Event Collector, or another method. See designs 08 and 10.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
