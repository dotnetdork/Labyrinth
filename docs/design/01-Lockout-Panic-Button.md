# 01. Lockout ("Panic Button") Design

**Status:** Draft · reviewed 2026-10-05 · Phase: 🟥 Lock out · Priority: P0

## 1. What it is

One command that carries out the first-minutes lockout across the reachable hosts: fast, but only within the limits the rules allow.

The original idea ran against every reachable host in one pass, resetting credentials, locking accounts and applying default-deny in a single sweep. The rules prohibit that "indiscriminate" version, so this design keeps the speed and adds guard rails.

## 2. The rules that shape it

| Rule | Effect on the design |
|---|---|
| Tools must not deliberately break expected functionality. The examples are setting all user shells on Linux to `/bin/false` and indiscriminately terminating all outbound connections after 30 seconds (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.5). | No blanket actions. Every destructive action works from an explicit allowlist and skips the protected set. |
| Operations and White Team must be given access immediately on request (NCCDC, 2025, Rule 4.1). | A confirmed break-glass path is a precondition. Nothing removes it. |
| Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | The scoring engine allowlist is applied first. Verification uses scoring-style probes. |
| Do not mislead the scoring engine (NCCDC, 2025, Rule 11.3). | The panic button never fakes a service state. |
| Administrator-class passwords are not used for scoring and may be changed freely. Other user passwords follow the notification process (Midwest Collegiate Cyber Defense Competition [MWCCDC], 2025, Rule 13). | Only admin-class credentials are rotated automatically. User-level rotation is manual-only. |
| Scored services may not be migrated or containerized (NCCDC, 2025, Rule 4.14). | The panic button contains no container actions. |
| Blue Teams should keep ICMP working on all competition devices (MWCCDC, 2025, Rule 14; *Provisional*). | Default-deny always allows ICMP, inbound and outbound, unless the run-time configuration says the event packet allows otherwise. |
| Points can be lost for failed employee access (Northeast Collegiate Cyber Defense Competition [NECCDC], 2026, Scoring Overview; *Provisional*, another region's packet). | Accounts that simulated employees use are treated like scoring accounts: never locked, rotated or switched to key-only by automation (design 05). |
| Team tools may not use outside resources (NCCDC, 2025, Rule 5.6.4). | Everything runs from the vendored repository. |

## 3. Design principles

1. **Protect first.** Load the protected set before doing anything else. If it is missing or empty, stop.
2. **Plan before apply.** Plan mode is the default. Apply needs a typed confirmation naming the target group.
3. **Small blast radius.** Apply in rings, one canary host first.
4. **Reversible.** Every change is backed up and recorded in the run manifest.
5. **Verify like the scoring engine.** After each module, run probes and compare with the probes taken before.
6. **Fail toward access.** On any doubt, abort and leave the host as it was.
7. **Assume breach.** The Red Team may already be inside when the event starts, so the first minute removes the ways back in, not just the passwords (section 6).
8. **Defend scored services, don't avoid them.** Scored services are a primary Red Team target, and successful penetrations cost points (NCCDC, 2025, Scoring section). Leaving them untouched is not safe; changing them carefully, with probes and a revert timer, is.
9. **Confirm, then act.** When a person confirms that something may be changed or removed, Labyrinth carries it out, with the same backups, probes and records. Only the actions on Tier 3's person-run list are left to a person's hands.

## 4. The protected set

The protected set is a list the operator supplies at run time, from the event packet. It is never committed. It contains:

| Class | Examples | Treatment |
|---|---|---|
| Official accounts | Accounts the White or Operations Team use | Never changed without the White Team's permission; logons alerted on (design 05, section 5) |
| Scoring accounts | Mailbox users and other accounts the scoring engine logs in with | Never touched by automation |
| Employee accounts | Accounts that simulated employees (for example the Orange Team) use, as named in the event packet | Never touched by automation; treated like scoring accounts |
| Operator accounts | Named team accounts | Never locked or removed |
| Break-glass account | An existing admin-class account whose rotated password is kept in the team's offline record; no new account or key (design 05, section 5) | Never locked or removed; password rotated only in design 05's order; confirmed at the console by the operator (section 7) |
| Service accounts for scored services | Database and application accounts a scored service depends on | Never touched until the dependency map is known |
| Built-in and machine accounts | System, machine and domain-trust accounts | Never touched |

## 5. Actions, by risk tier

| Tier | Nature | Actions | How run |
|---|---|---|---|
| **0. Observe only** | Read-only | Inventory of users, groups, listeners, processes, sessions, scheduled tasks, startup items, keys and sudoers; baseline (design 04) | Automatic |
| **1. Safe and reversible** | Cannot stop a scored service | Rotate admin-class passwords (root, Administrator and equivalents) that no service or scheduled task logs on with (design 05, section 2); back up, then clear, authorized keys that are not in the key registry, on accounts outside the protected set; end remote sessions after rotation (section 6.2) | Automatic after plan review |
| **2. Service-affecting** | Could interrupt a scored service | SSH (Secure Shell) configuration check and key-only drop-in (design 05, section 4); high-confidence persistence quarantine (design 17); default-deny inbound firewall with the scored ports, the scoring engine, any official sources named in the event packet, ICMP and the admin path allowed; remove admin rights from unexpected *local* accounts and lock them (design 05, section 6); Windows protocol settings (design 11); rules for new passwords (design 05, section 2.2); automatic service-pack settings (design 18); disable services from a per-profile candidate list (design 15); a log-only outbound firewall rule (design 10, section 5); re-applying the sealed firewall rules when they drift (design 13, section 4.1) | Applied per ring with verify and a revert timer |
| **3. Approve, then act** | High consequence, or not provably safe | **Labyrinth acts after a person approves:** unexplained persistence items (design 17); deleting a locked account once services are confirmed working (design 05, section 6); approval-class service-pack settings (design 18); lockout settings and PAM stack changes (design 05, section 2.2); approval-class Windows and domain controller settings (design 11); rotating an admin-class password that a service or scheduled task logs on with, once its dependents are listed; rotating application admin credentials (design 05, section 2.1); restoring a service from its restore point (design 14); filtering a host's outbound traffic (design 10, section 5); ending a SYSTEM process on Windows (design 11). **A person acts, from a printed checklist:** user-level password changes (notification required); domain account and group changes; KRBTGT reset; Group Policy changes; DNS changes on a domain controller; domain controller restores and rescuing an unbootable host (design 14); patching (design 15); appliance changes (design 16)
 | Shown in the plan; approved per item, or per category on one host |

```mermaid
flowchart LR
    T0["<b>Tier 0</b><br/>Observe only<br/>read-only"] --> R0["Runs automatically"]
    T1["<b>Tier 1</b><br/>Safe and reversible<br/>admin passwords, keys, sessions"] --> R1["Runs automatically<br/>after plan review"]
    T2["<b>Tier 2</b><br/>Service-affecting<br/>SSH, persistence, firewall, local admins"] --> R2["Runs per ring with verify<br/>and a revert timer"]
    T3["<b>Tier 3</b><br/>Approve, then act<br/>unexplained items, deletions, domain"] --> R3["Labyrinth acts after approval;<br/>a few items a person runs"]
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    class T0 observe
    class T1 ok
    class T2 human
    class T3 lockout
```

*Figure: each risk tier, from read-only Tier 0 to Tier 3, which waits for a person's approval, and who or what carries out its actions. Colors rise with risk: blue is read-only, green safe, amber service-affecting and red approval-only.*

## 6. Sequence

1. Load protected set and configuration.
2. Safety gates (section 7).
3. Tier 0 on all targets.
4. **The first-minute bundle** (section 6.1) on the canary ring with a revert timer, verify, then the remaining rings.
5. The rest of Tier 2 on the canary ring with revert timers, verify, then the remaining rings.
6. Show the Tier 3 items for approval, carry out what is approved, and print the person-run checklist.
7. Seal the baseline (design 04, section 6).

**Rings.** Ring 0 holds one low-impact host per platform, for example one Linux host and one Windows workstation, because a change that works on one platform proves little about another. Ring 1 is the next group. Later rings follow, never more than a set share of hosts at once. A failed verify stops the run. The bundle takes seconds on the canary, so the rings delay the rest of the network very little.

**Hosts with no canary.** A host that is the only one of its kind, such as the domain controller or the only mail server, has no canary that tested the change on the same software first. It goes in the last ring, and its Tier 2 changes rely on the revert timer and the before-and-after probes alone.

### 6.1 The first-minute bundle

An attacker who got in before the event can come back through a password, a key, an open session, a persistence item or an open port. Closing only some of these leaves the rest, so each host gets all of them, in this order, as one step:

1. **Rotate** admin-class passwords (Tier 1; design 05, section 2).
2. **Remove** unregistered SSH keys and **check** the SSH configuration for planted settings (Tiers 1 and 2; design 05, section 4).
3. **End** intruder sessions (Tier 1; section 6.2).
4. **Quarantine** high-confidence persistence (Tier 2; design 17).
5. **Default-deny** the firewall (Tier 2).

The order matters. Sessions are ended after passwords and keys change, so the attacker cannot simply log back in. Persistence is quarantined before the firewall closes, so a planted job has no chance to reopen a port afterwards. One revert timer covers the whole bundle on each host.

### 6.2 Ending sessions

Changing a password does not end the sessions already logged in with it. So, right after rotation, Labyrinth ends every remote session on the host (SSH, RDP and remote shells) **except**:

- console sessions (`tty1` and other local terminals on Linux; the `console` session on Windows), which is how the virtualization platform's console reaches the host;
- the operator's own session;
- sessions from the admin source;
- sessions of accounts in the protected set.

This is not "terminating all connections" (NCCDC, 2025, Rule 5.6.5). It ends only interactive logins, after a credential change, and never touches service traffic or the excepted sessions. On Linux it uses `loginctl terminate-session`; on Windows, `logoff <session id>`. Each ended session is logged with its user, source and start time for the incident record (design 02).

```mermaid
flowchart TD
    PS["Load protected set<br/>and configuration"] --> GATES{"All safety gates pass?<br/>(section 7)"}
    GATES -->|no| STOP(["Stop: nothing changed"])
    GATES -->|yes| T0["Tier 0 on all targets<br/>(read-only inventory and baseline)"]
    subgraph fm["First-minute bundle, ring by ring (section 6.1)"]
        ARM["Arm revert timer"] --> B1["Rotate admin passwords"] --> B2["Remove unregistered keys;<br/>check SSH configuration"] --> B3["End intruder sessions"] --> B4["Quarantine high-confidence<br/>persistence"] --> B5["Default-deny firewall"] --> V1{"Verify passes?"}
        V1 -->|"no, or no one cancels"| REV(["Timer reverts; stop run"])
    end
    subgraph tier2["Rest of Tier 2, ring by ring"]
        T2C["Arm, apply, verify, cancel"]
    end
    T0 --> ARM
    V1 -->|"yes: cancel timer"| T2C
    T2C --> T3["Tier 3: a person approves;<br/>Labyrinth acts"] --> SEAL(["Seal the baseline;<br/>print person-run checklist"])
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class GATES,T3 human
    class STOP,REV stop
    style fm fill:#fde8e8,stroke:#c0392b,color:#4a1111
    style tier2 fill:#fff4d6,stroke:#b7791f,color:#4a3108
```

*Figure: once every safety gate passes, each ring gets the first-minute bundle under one revert timer, then the rest of Tier 2, then the Tier 3 items a person approves, and finally the baseline is sealed. The red box is the first-minute bundle, amber marks service-affecting work and a person's approval, and dashed red outlines mark where the run stops.*

## 7. Safety gates (all must pass)

| Gate | Check |
|---|---|
| Protected set loaded | Non-empty and parsed |
| Scoring allowlist present | In the firewall plan for every host that filters traffic. The runner blocks any module with `touches_scored: true` while the run-time `scoring-allowlist` is missing or empty |
| Break-glass confirmed | The operator has confirmed, by typing, that the break-glass credential worked at this host's console. This is the operator's word, not proof: a script cannot reach the console, so it is asked once per host. The account must be in the protected set with class `breakglass`, the answer is kept in Labyrinth's state for later runs on that host, and every run records it in its manifest. When the answer is given, Labyrinth looks for a session of that account at the console (`loginctl` or `who` on Linux, `query user` on Windows) and records the session it found. If it finds none, or cannot look, it warns and goes on: the gate stays a confirmation, and the manifest says what backed it. |
| Backup taken | Every file is copied before it changes, and the copy is recorded in the run manifest (`docs/Conventions.md`, section 7) |
| Plan reviewed | Operator confirmed the plan by typing the group name |
| Revert timer armed | Before every change that is not `read-only`, re-armed before each module (section 8) |

## 8. Preventing self-lockout

- **Two-session rule.** Keep one session open while testing from a fresh one.
- **Dead-man revert.** Before any change that is not `read-only`, such as a firewall or SSH change, arm a timer that rolls the whole run back unless the operator keeps it after verify. It runs `labyrinth rollback <run>` (`docs/Conventions.md`, section 3.1).
  - Linux: a transient systemd timer, `lab-revert-<run>-<n>` (`systemd-run --on-active=<minutes>m --unit=lab-revert-<run>-<n> ...`), cancelled with `systemctl stop lab-revert-<run>-<n>.timer`.
  - Windows: a one-time scheduled task, `\Labyrinth\lab-revert-<run>-<n>`, running as SYSTEM, unregistered when the run is kept.
  - `labyrinth runs` shows which runs still have a timer armed, and when each one fires.
  - VyOS: `commit-confirm <minutes>` followed by `confirm`. Read the VyOS warning below first.
- **Passwords shown once.** New credentials are displayed once, on the operator's screen, for the team's offline record (design 05, section 2). Labyrinth never writes them to disk or logs and never echoes them over an unencrypted channel. Use a cryptographic random source (`/dev/urandom` or .NET `RandomNumberGenerator`), not `Get-Random`.
- **Acknowledge before continuing.** The operator confirms the credential is recorded before the old one is invalidated.

> [!WARNING]
> **VyOS reboots by default.** On VyOS 1.4 the default action when a commit is not confirmed is to *reboot* to the saved configuration, which drops routing for every host behind the router (VyOS, n.d.). First set, commit and save `set system config-management commit-confirm action reload`. If the installed version does not offer that option, do not rely on the timer: make the change by hand with a second session open.

## 9. Verification

After each module, probe as the scoring engine would:

| Service | Probe | Pass condition |
|---|---|---|
| HTTP and HTTPS | Fetch the page | Expected status and expected content string |
| DNS | Query a known record | Expected answer |
| SMTP (Simple Mail Transfer Protocol) | Connect and read the banner; optionally send a test message | Expected response |
| POP3 (Post Office Protocol 3) | Connect and read the banner (no scoring-account logins) | Expected response |
| FTP (File Transfer Protocol) | Connect and read the banner | Expected response |

Take probes before and after. A regression triggers automatic rollback of that module and stops the run. Between runs, the health monitor repeats these probes on a schedule (design 13).

## 10. What the panic button will never do

- Disable accounts wholesale.
- Change shells.
- End all connections, or end a console session, the operator's own session, an admin-source session or a protected account's session.
- Delete a file. Persistence items are quarantined (design 17).
- Delete an account without a person's approval, or before a checkpoint shows every scored service passing (design 05, section 6).
- Stop services outside the candidate list.
- Reboot.
- Move a service into a container.
- Change scoring accounts.
- Act on a host with no break-glass path.

## 11. Acceptance tests (in the lab)

- Protected accounts are unchanged before and after.
- A mailbox user can still authenticate after the run.
- An admin-class account that a service or scheduled task logs on with is not rotated automatically and is listed for approval in Tier 3.
- A run on a host with no break-glass confirmation refuses to change it.
- An official source named in the event packet can still connect after default-deny.
- Every scored-service probe passes after the run, on every ring.
- The revert timer restores the firewall when verify is deliberately failed.
- A run with an empty protected set refuses to start.
- After default-deny, the host still answers ping.
- A second session stays usable throughout.
- After the bundle, an intruder's SSH and RDP sessions are gone, while the console session, the operator's session and an admin-source session remain.
- A planted reverse-shell cron job is quarantined in the bundle, and its connection does not return after the firewall closes.
- A Tier 3 item a person approves is carried out by Labyrinth and recorded in the run manifest; an item not approved is left unchanged.

## References

Midwest Collegiate Cyber Defense Competition. (2025). *2025 Midwest Collegiate Cyber Defense Competition qualifier team packet* [PDF]. https://brazil.minnesota.edu/ccdc/ccdc-2025/2025MWCCDCQTeamPack.pdf

Northeast Collegiate Cyber Defense Competition. (2026). *NECCDC 2026 season regional blue team packet* [PDF]. Retrieved October 2, 2026, from https://neccdl.org/history/2026/resources/Regional-Packet-NECCDC-2026.pdf

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html

VyOS. (n.d.). *Command line interface* [VyOS 1.4.x (sagitta) documentation]. Retrieved September 29, 2026, from https://docs.vyos.io/en/1.4/cli.html
