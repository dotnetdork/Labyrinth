# How Labyrinth Works

This is the plain-language tour of Labyrinth. It explains what each part of the system is for and how the parts fit together, without assuming you already know networking or security tooling. The [implementation blueprint](Blueprint.md) and the [design specs](design/README.md) hold the precise details. Each section below links to the one that goes deeper.

**Who this is for:** someone who knows what a server, an operating system and a network are, and can read a script, but who has not memorized commands or security terms. Every term is explained the first time it appears, and the [glossary](#glossary) at the end collects them.

> [!NOTE]
> Labyrinth is being built: the core and the main program exist, and the modules do not yet. This page describes how the system is *intended* to work.

**Color key.** The same five colors mark the five phases everywhere in the Labyrinth docs:

| Color | Phase | In one line |
|---|---|---|
| 🟥 | **Lock out** | Take control back from the attacker. |
| 🟧 | **Harden** | Install the tools, set aside footholds, patch and shrink what is exposed. |
| 🟦 | **Observe** | See what is happening on every machine. |
| 🟪 | **Deceive** | Plant traps that give the attacker away. |
| 🟩 | **Sustain** | Keep everything running and be able to undo mistakes. |

---

## 1. The problem Labyrinth solves

Labyrinth is built for the **Collegiate Cyber Defense Competition (CCDC)**. In CCDC, a team of students is handed a small company network that it has never seen before. The network has several **hosts** (individual computers or servers), usually a mix of Linux and Windows machines plus network devices such as a router and firewalls.

Three groups matter during the event:

- **The scoring engine** is an automated checker. Throughout the event it tests the network's **scored services**, the things the company needs working, such as a website, email or DNS (the Domain Name System, which turns names into addresses). A working service earns points; a broken one loses them.
- **The Red Team** is a group of attackers. They try to break in, stay in and cause damage. They may already know the default passwords before the event starts.
- **The White Team and the Operations Team** are the officials. They run the event and must always be able to get into the machines when they ask.

The hardest moment is **the opening minutes**. When the event starts, every host needs to be secured at once, but any mistake that breaks a scored service costs points. Doing hundreds of careful steps by hand, per machine, from memory, under time pressure, does not work.

Labyrinth is the answer: **one strategy that applies to every machine, and one tool that carries it out quickly, safely and reversibly.**

---

## 2. The big picture

### 2.1 The strategy: five phases, in order

Labyrinth works in five phases. Each one depends on the one before it.

```mermaid
flowchart LR
    L["<b>1. Lock out</b><br/>change default passwords<br/>block incoming and outgoing<br/>keep a way back in"]
    H["<b>2. Harden</b><br/>install the team's tools<br/>set aside footholds<br/>patch and cut services"]
    O["<b>3. Observe</b><br/>collect logs centrally<br/>record what 'normal' looks like<br/>spot changes"]
    D["<b>4. Deceive</b><br/>plant fake files, accounts<br/>and ports as tripwires"]
    S["<b>5. Sustain</b><br/>keep scored services up<br/>undo bad changes<br/>write incident reports"]
    L --> H --> O --> D --> S
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    classDef harden fill:#fdeedc,stroke:#c2410c,color:#4a1d06
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef deceive fill:#efe7fb,stroke:#7c3aed,color:#351465
    classDef sustain fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    class L lockout
    class H harden
    class O observe
    class D deceive
    class S sustain
```

*Figure: the five phases in the order they run, with the main jobs of each. Colors follow the phase key.*

Why this order? A trap is worthless if the attacker still has a valid password and an open way in, so locking out comes first. Hardening comes next, because the host should be closed to the network before anything is installed on it. Traps are only useful if their alarms land somewhere you are watching, so observing comes before deceiving. The blueprint sums it up as *lock-out before hardening, hardening before observation, observation before deception, deception before comfort* ([Blueprint §1](Blueprint.md#1-operating-doctrine--the-order-of-work)).

### 2.2 The seven rules of thumb behind every phase

The blueprint calls these the **invariants**: ideas that hold on every operating system, so the team reasons about them once and applies them everywhere ([Blueprint §2](Blueprint.md#2-the-core-strategy--portable-invariants)).

1. **Identity:** no shared, default or unchanged passwords; give each account only the access it needs.
2. **Surface:** block all incoming connections by default and allow only what is scored, plus the team's own admin access.
3. **Segmentation and egress:** keep parts of the network separated (on a flat network, each host's own firewall is the boundary), and treat unexpected *outgoing* traffic as a sign that an attacker's program is calling home.
4. **Observability:** send important logs to one central place and watch logins, sensitive files and new programs starting.
5. **Deception:** anything that is not a real service is a tripwire, and every trip is recorded in one place.
6. **Recoverability:** keep backups and restore points of its own, and an emergency way back in. Snapshots of the virtual machines may not be available, so Labyrinth never relies on them.
7. **Change discipline:** every change can be run twice safely, can be undone, and is timestamped. Never make a change you cannot undo in ten seconds.

### 2.3 The system at a glance

```mermaid
flowchart TD
    OP(["Operator<br/>(a team member)"])
    subgraph hosts["Managed hosts (Linux and Windows)"]
        H["Each host runs Labyrinth itself:<br/>hardened settings,<br/>traps, login banner"]
    end
    CN["Control node (optional)<br/>read-only checks,<br/>health monitor"]
    SIEM[("SIEM<br/>central log store")]
    TL[("Trip log<br/>every trap alarm")]
    REP["Incident report drafts"]
    WT(["White Team<br/>(officials)"])
    OP -->|"reviews the plan,<br/>types to confirm"| H
    CN -.->|"read-only checks over<br/>the admin connection"| H
    H -->|"forward logs"| SIEM
    H -->|"a trap is touched"| TL
    TL --> REP
    CN -->|"reads saved searches"| SIEM
    CN -->|"pushes a short status file"| H
    H -->|"copies of restore points"| CN
    REP -->|"a person edits,<br/>approves and submits"| WT
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef deceive fill:#efe7fb,stroke:#7c3aed,color:#351465
    classDef sustain fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    class OP,WT human
    class SIEM store
    class CN observe
    class TL deceive
    class REP sustain
    style hosts fill:#f8fafc,stroke:#94a3b8,color:#1e293b
```

*Figure: an operator runs Labyrinth on each host, and an optional control node runs the jobs that look across hosts, such as checks and the health monitor; hosts send logs to the SIEM and trap alarms to the trip log, and reports go to officials only after a person approves them. Amber marks people and gray the log store.*

- **Each host runs Labyrinth itself** (local mode). This is the standard way to use it: nothing holds access to every host at once, and it keeps working if the network between hosts is cut.
- The **control node** is an optional, hardened machine for the jobs that look across hosts: read-only checks, the health monitor, the status feed and copies of restore points kept off each host. Making changes from it (remote mode) comes later, once the read-only checks have run safely.
- The **SIEM** (Security Information and Event Management system; for example Splunk) collects logs from every host, so the evidence survives even if a host is wiped.
- Nothing in the diagram sends data to an outside service. The competition rules forbid team tools from using outside resources other than DNS lookups, and give cloud services as the example (see [section 5](#5-the-competition-rules-that-shape-everything)). Labyrinth itself needs only its own public release. Everything else that leaves the network happens after the lockdown, and is only public software and public data: from the hosts' own software sources, a mirror or proxy the event provides, or a download pinned by its SHA-256 (a fingerprint of the exact file), such as Sysmon or the Splunk forwarder. Labyrinth tries the download first and falls back to a person pasting the file in when nothing answers ([design 02](design/02-Packages-and-Third-Party-Tools.md)).

---

## 3. How one Labyrinth run works

### 3.1 Profiles, phases and modules

Labyrinth is organized so that new abilities can be added without rewriting the core ([design 00](design/00-Module-Contract-and-Layout.md)).

- A **module** is one small, single-purpose piece of automation, for example "set up the firewall" or "change the admin passwords". Each module is a folder.
- A **phase** is a group of modules that belong together: 🟥 lockout, 🟧 harden, 🟦 observe, 🟪 deceive or 🟩 sustain.
- A **profile** describes a kind of host, such as a Linux web server, a Windows domain controller or a network appliance, and lists which modules apply to it. A profile is a list, not code.

When you point Labyrinth at a group of hosts, it looks up each host's profile, works out the modules to run, and runs them phase by phase.

It is written in **bash** for Linux and **PowerShell** for Windows, because both are already installed on those systems. Nothing extra has to be downloaded for Labyrinth itself to run. Once the hosts are locked down, it downloads public software and public data the team chose, from public sources only, and falls back to pasting the files in by hand if no source answers ([design 02](design/02-Packages-and-Third-Party-Tools.md)). Labyrinth runs directly on the host it changes; this local mode is the standard way to use it. A remote mode, which sends the same commands to many hosts from a control node and collects the results, comes later and starts read-only. Network appliances (routers and firewall boxes) are handled with prepared configuration templates and a written checklist for a person to follow, not by remote automation.

### 3.2 The life of one module

Every module offers the same six actions, so every module behaves the same way:

| Action | Plain meaning | Changes anything? |
|---|---|---|
| `check` | "Is a change needed here?" | No |
| `plan` | "Show me exactly what you would change." This is the default. | No |
| `apply` | Make the change. Back up first, and record what changed. | Yes |
| `verify` | "Did it work, and is every scored service still up?" | No |
| `rollback` | Undo the change, using the record `apply` wrote. | Yes, restores the old state |
| `cleanup` | Remove temporary files the module created. | Removes only its own files |

```mermaid
flowchart LR
    C["check:<br/>change needed?"] -->|no| DONE(["done"])
    C -->|yes| P["plan:<br/>show the change"]
    P --> H{"a person<br/>confirms the run?"}
    H -->|no| STOP(["nothing changes"])
    H -->|yes| A["apply:<br/>back up, change,<br/>record it"]
    A --> V{"verify:<br/>services still up?"}
    V -->|yes| DONE
    V -->|no| RB["rollback:<br/>undo it"]
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class DONE ok
    class H,RB human
    class STOP stop
```

*Figure: a simplified module run; design 00 has the full version with exit codes and cleanup. A person confirms once for the whole run, after reading the plan for every module, not once per module. Green is a clean finish, amber a person's decision or an undo, and the dashed red outline a stop.*

Two words you will see often:

- **Idempotent** means running something twice gives the same result as running it once. If `apply` has already been done, running it again changes nothing. This makes it safe to re-run Labyrinth under pressure.
- The **run manifest** is the record of every change a run made. `rollback` uses it to undo changes, and `cleanup` uses it to know exactly what to remove.

### 3.3 Where things live on each host

Every host uses the same folder layout, so the team always knows where to look: the Labyrinth code (read-only), its run-time settings, its state (baselines and records), its logs (one folder per category, such as `auth`, `integrity` or `deception`) and its timestamped backups. All of it sits under one top-level folder that only administrators can use. That location can be changed, so it is not a fixed, publicly known path ([design 00, section 7](design/00-Module-Contract-and-Layout.md#7-standard-paths-on-every-host)).

### 3.4 One command per host (planned)

Today a run has a separate plan step and apply step, with questions to answer. **The runner does not do this yet**; it is specified now and built next. Every existing command form keeps working.

- **Short commands, like other security tools.** Labyrinth gets the short name `laby`, and flags with a short and a long form, the way nmap does. `laby` on its own shows where the host stands and what to run next. `laby init` shows what the first phases would change, without changing anything, and `laby -r init` (for *run*) does it: Lock out, then Harden, as one run. The later phases work the same way, for example `laby -r observe`.
- **Help is always safe.** `laby -h` fits on one screen. Adding `-h` to any command, such as `laby -u -h`, shows that command's help and never runs anything. `laby --manual`, or `man laby` on Linux, opens the full manual.
- **No questions during a run.** The group comes from the hosts file, and the emergency account is the break-glass account in the protected list that exists on that host. If either cannot be matched, the run stops. Labyrinth looks for a console session itself and warns if it finds none, rather than asking.
- **The queue.** Approval items that no pre-approval rule covers go to a **queue**. `laby -q` lists them by number, `laby -q -a 1,3` carries out the ones a person picks, in a new run with the same backups, record, timer and tests, and `laby -q -d 2` declines one. Always queued: deleting an account, changing a scored service that has no test, and replacing or containerizing a service.
- **One question at the end.** Each module is kept automatically once its checks and tests pass, except firewall and SSH changes. For those, Labyrinth asks the person to open a new login and check it works, then type `y` to keep them. With no answer, the revert timer undoes them. If the person missed the question, `laby -k` with the run's ID keeps them.
- **Output is short:** one line per module (`OK`, `CHANGED`, `ROLLED BACK`, `QUEUED`, `BLOCKED` or `FAIL`). Full explanations appear only for failures and blocked steps; the rest goes to the run log, and `-v` shows everything.

---

## 4. Each part of the system

Each subsection answers four questions: what the part does, why it exists, how it works, and what it will never do.

### 4.1 The panic button (lockout)

**What it does.** One command carries out the first-minutes lockout across the reachable hosts ([design 03](design/03-Lockout-Panic-Button.md)).

**Why it exists.** Assume the attacker is already inside when the event starts. Their power comes from passwords they already know, sessions they already have open, and ways back in they left behind. Removing all of these, fast, removes most of their ways in. The scored services are among the Red Team's main targets, so Labyrinth defends them carefully rather than leaving them as found.

**The first minute.** Each host gets one bundle of steps, in this order, installing nothing and using only what is already on it: change the admin passwords; remove unapproved SSH keys and check the SSH settings for anything planted; end the intruder's open remote sessions (never the console, the operator's own, the team's admin machine or an official's); lock unexpected accounts that have admin rights; then block all incoming traffic except the scored services, which stay open to everyone, and the team's admin path, and all outgoing traffic except what the host and its scored services need. Nothing is installed in this bundle because installing is slow and the lockdown should be in place before outgoing traffic opens again; no rule forces that. On a Debian host with no firewall program running, the lockdown uses the raw built-in firewall (nftables), and UFW, the usual front end, takes over in the Harden phase with the same rules. One revert timer covers the whole bundle. The steps that only take access away, such as the new passwords and the removed keys, are kept as soon as each checks out, so only the steps that could lock the team out are left for the timer to undo.

**The Harden phase.** With the network closed around each host, Labyrinth installs the team's extra tools, takes a backup of every scored service, sets aside the attacker's footholds, checks the core system files against the official packages (section 4.3), patches named packages, turns off unneeded services and applies the rest of the hardening, then reopens outgoing traffic to the host's normal list. Anything the attacker planted early is still on disk while this happens, but it cannot be reached or call home.

**First-minute runs.** The team reviews the plan before the event. At the start, one command per host, started on every host at once, gives all the answers up front, so nobody types a confirmation while the Red Team is moving. Once the new command line is built (section 3.4), that command is `laby -r init`, and the answers come from the team's settings files instead. Items the team approved in advance, such as a security update for a named scored program or an app's known default password, are listed in a file of pre-approvals, and are carried out without asking. A module accepts this only for kinds of item it marks as safe to approve unseen. When the run is started from the control node, the control node keeps each host's changes only if it can still log in to that host and no scored service that worked before the run fails after it; otherwise the revert timer undoes them. The revert timer, the checks before and after, and the protected set still apply.

**How it works.** The obvious version, "reset everything, lock everything, block everything, everywhere, at once", would break things the scoring engine checks, and the rules forbid breaking what the network is expected to do. So the panic button keeps the speed but adds guard rails:

- **The protected set.** Before anything else, the operator loads a list of accounts that must never be touched: the officials' accounts, the accounts the scoring engine logs in with, the team's own accounts, the emergency accounts and system accounts. If the list is missing or empty, the run stops. An admin account the scoring engine logs in with is marked **scored-admin**: it is not left alone, because the Red Team knows its default password too, so Labyrinth changes it and prints the new password in a **change list** for the team to hand in through the event's own process.
- **Safety gates.** Six checks must all pass before any change:
  1. the protected set is loaded;
  2. every scored service is reachable from anywhere in every firewall plan;
  3. the operator has confirmed that the emergency login works at the host's own console (once the new command line is built, the emergency account is read from the protected list and Labyrinth looks for its console session itself);
  4. backups exist;
  5. the operator has reviewed the plan and confirmed the target group's name (typed, or given in the command for a first-minute run; once the new command line is built, the team reviews the plan before the event and the group is read from the hosts file);
  6. a revert timer is ready for risky changes.
- **Risk tiers.** Every action is sorted by how much damage it could do, and riskier tiers get more caution:

| Tier | What it covers | Who carries it out |
|---|---|---|
| 0. Observe only | Read-only inventory: users, groups, open ports, running programs, open sessions, scheduled tasks | Runs automatically |
| 1. Safe and reversible | Change admin-class passwords, scored-admin ones included, with their change list; remove SSH keys that are not on the approved list; end intruder sessions | Runs automatically |
| 2. Service-affecting | Check and harden SSH; set aside obvious attacker footholds; block incoming and outgoing traffic except what is needed; install the team's chosen tools; back up the scored services; take admin rights from unexpected local accounts and lock them; safe settings for scored apps and Windows; turn off unneeded services | Runs host group by host group, with a check and a revert timer |
| 3. Approve, then act | Unexplained footholds, deleting locked accounts, riskier app settings and passwords, restores, Linux updates, and the other items listed below | A person approves from the queue, or the team approved it before the event, then Labyrinth does it |

Tier 3 in full: unexplained footholds; deleting locked accounts; riskier app settings; app admin passwords; restoring a service from a backup; Linux security updates; lifting the outgoing block on one host; ending a stubborn process that runs as SYSTEM on Windows; resetting the domain's ticket-signing password (KRBTGT); changing listed users' passwords where the event takes a change list; and, only where the event allows it, rebuilding a scored service (section 4.21). A short list stays with a person, as a printed checklist: ordinary users' passwords, other domain accounts and policy, DNS on the domain controller, restoring the domain controller, rescuing a host that will not boot, Windows patching and network appliances.

- **Host groups.** Each host belongs to one **group**, named in the team's hosts file, and a run acts on one group at a time. The first group holds one low-impact **test host** of each kind of system, for example one Linux host and one Windows workstation; then come the next group, and so on. (The design specs call these groups *rings*.) If a check fails, the run stops before the problem spreads. A host that is the only one of its kind, such as the domain controller, has no test host to go first; it is in the last group and relies on the revert timer and the tests.
- **Revert timer (dead-man).** Before a change that could lock the team out, such as a firewall or SSH change, Labyrinth sets a timer that will undo the run automatically unless someone keeps it after confirming everything still works. If the change locks the team out, the timer puts things back, and every logged-in screen on the host shows a notice that it did. A change that only takes access away from an intruder, such as a new admin password or a removed planted key, is kept as soon as it checks out: undoing it would hand the intruder their access back.
- **Checking like the scoring engine.** After each module, Labyrinth tests each scored service the way the scoring engine would (for example, fetching the web page and looking for the expected text) and compares the result with a test taken before the change. If a service got worse, that module is rolled back and the run stops.

**What it will never do.** Disable accounts wholesale, change login shells, cut all connections, end a console or official's session, delete a file (it sets files aside instead), delete an account without a person's approval, stop services that are not on its candidate list, reboot, move a service into a container (outside section 4.21), change scoring accounts, rename an account or host, change an address, limit a scored service to some addresses, or act on a host that has no emergency way in.

> [!TIP]
> **Break-glass** means a sealed emergency login, one per critical host, kept by the team captain in the team's **offline record**: on paper or in a local file on a team member's own machine, never in the repository or on the competition hosts. It exists so that the team, and the officials, can always get back in.

### 4.2 Passwords and SSH keys (lockout)

**What it does.** Changes passwords and manages SSH keys without locking the team out ([design 04](design/04-Credentials-and-SSH-Keys.md)).

**Background.** **SSH** (Secure Shell) is the standard way to log in to a Linux machine remotely. Instead of a password, SSH can use a **key pair**: a private key that stays with you and a public key placed on the server. A server's list of accepted public keys lives in a file called `authorized_keys`.

**How it works.**

- **Only admin-class passwords are changed automatically** (root, Administrator and similar). Events differ on which accounts the scoring engine uses, so none is assumed safe to change silently: an admin account the scoring engine logs in with is a scored-admin account, and its new password goes into the change list, shown once, for the team to submit straight away. The same name gets the same new password on every host, so one line in the list covers it. Ordinary users' passwords are changed only after approval, or by hand, following the event's own process. An admin password is also left to a person when a Windows service or scheduled task logs on with that account, because changing it would break that service the next time it starts.
- **Names never change.** Labyrinth never renames an account: scoring and the officials know each one by name.
- **New passwords are shown once**, on the operator's screen, to be copied into the offline record. Labyrinth never saves them to disk or logs, and teammates share them only through the official team chat.
- **The safe order.** Set the new password, test it from a fresh login, confirm it is written down, and only then close the old session. SSH keys follow the same pattern: add the new key next to the old one, test it, then remove the old one.
- **One SSH key per role** (for example, one for Linux admin work and one for monitoring), not one per person and not one shared key. Each key only works from the control node.
- **An approved-key list** (the registry) is kept for every host. Any key found that is not on the list is backed up and then removed.
- **Planted SSH settings.** An attacker may have added their own SSH settings file, which can quietly override the team's. Labyrinth sets aside unknown settings files and planted lines, makes sure its own settings load first, and asks SSH which settings it will actually use.
- **Key-only, aware of scoring.** Where SSH is scored, the scoring engine's accounts keep their passwords, everyone else must use a key, and the port stays open to everyone and in its usual place. Where it is not scored, everyone uses keys and only the team's admin machine can reach it.
- **Unexpected accounts.** An account is expected if it is protected, named in the event packet or runs a scored service. Labyrinth also looks for hidden admins, such as a second root account or a user in an admin group by a side door. Unexpected local accounts with admin rights are locked at once, in the first minute, and lose those rights in the Harden phase; others are locked after a person approves. Once every scored service is confirmed working, a person can approve deleting them, so they cannot be switched back on. Their details are saved first, for the incident report.

- **App admin passwords.** Apps have their own admin logins too (a website's admin page, the database's root account), and default ones are a favorite way in. Labyrinth lists them. After a person approves, it changes one, updates every settings file that stores it, and tests the app. It never does this on its own, because the scoring engine may log in to the app.

**What it will never do.** Change scoring accounts, reset domain-wide passwords automatically, or copy private keys onto managed hosts.

### 4.3 Baseline and integrity: "what changed, who, when, from where?" (observe)

**What it does.** Records what a healthy host looks like, then spots changes and works out who made them ([design 08](design/08-Baseline-and-Integrity.md)).

**Background.** A **hash** is a short fingerprint of a file. If even one byte of the file changes, the hash changes. A **baseline** is a saved set of hashes and settings that describes "normal".

**The trap it avoids.** If the Red Team is already inside when you take the baseline, you record their changes as normal. So Labyrinth first checks files against the operating system's own records of what the installed software should look like (the package database on Linux, digital signatures on Windows). Anything that does not match is reported to a person as a finding, and is never added to the baseline.

**Records an attacker could edit.** The package database lives on the host, and an administrator account can change it. So, in the Harden phase, for a core set of packages (the SSH server, sudo, the login modules, the basic command-line tools, the service manager and the password tools) and any package the local check flags, Labyrinth downloads the package from the host's own software sources, checks its signature, and compares the hash of each file inside it with the file on the disk. A mismatch is a finding for a person, never an automatic fix. Windows keeps its signature checks and `sfc /verifyonly`, the built-in system file check.

**How it works.**

1. Check files against the operating system's records.
2. Baseline the rest: hashes of critical files, plus accounts, keys, open ports, services and scheduled tasks. **Boot-critical files** (such as `/etc/fstab`, which tells Linux which disks to mount) are watched most closely, because deleting one and rebooting can leave a host unable to start. A copy, or at least its hash, is kept off the host, because an attacker with full control of a host could edit a baseline stored there.
3. Compare against the baseline on a schedule, after first checking the host's baseline against that copy.
4. When something changes, look up the audit logs to see which account made the change, when, and from which network address.

> [!IMPORTANT]
> The address a host sees is the **last hop**: the last device the connection passed through. If traffic goes through a router that rewrites addresses (NAT, network address translation) or a proxy, that address may not be the attacker's real one. Reports say "last hop observed" for this reason.

Changes made by Labyrinth itself are in the run manifest, so they do not raise false alarms.

**The sealed baseline.** The first baseline shows the host as it was found, which may include the attacker's changes. So once the lockout is finished and checked, the team **seals** a new baseline of the cleaned host, and every later check compares against that. If the team changes something on purpose later, it reseals with a written reason, and every seal is logged.

### 4.4 Status feed and login banner (observe)

**What it does.** When a team member logs in to a host, a short message shows that host's current alerts and recent changes ([design 15](design/15-Status-Feed-and-MOTD.md)). On Linux this is the **MOTD** (message of the day), the text printed at login.

**How it works.**

1. The control node asks the SIEM a small, fixed set of saved questions (for example, "how many alerts per host?").
2. It writes one short text file per host, about 15 lines at most.
3. It copies each file to its host over the admin connection it already uses.
4. The host prints the file at login.

**Why it is built this way.** The SIEM is never given access to the hosts. Giving it that access would create a new way in for an attacker who took over the SIEM. The control node already has admin access, so reusing it adds no new trust path, meaning no new way for one machine to get into another.

**Safety details.** Text taken from logs is cleaned before it is shown, because an attacker could write special control characters into a log to mess with an operator's terminal. If an update fails, the host shows the last good status marked as out of date, and logging in is never blocked. Windows has no MOTD, so the Windows version is optional.

### 4.5 The event seed: public code, secret traps (deceive)

**The problem.** The rules require Labyrinth's code to be public and shared with every team, so the Red Team can read it. If trap names and port numbers were written in the code, the Red Team would simply avoid them ([design 16](design/16-Event-Seed-and-Deception-Config.md)).

**The idea.** Think of a public recipe with a secret ingredient. The **method** for creating trap names, ports and markers is public. The **event seed**, a short random value chosen by the team just before the event, is secret. The same seed always produces the same values, so every team member and every host gets matching results without sharing a secrets file.

**How it works.**

- The seed is kept by the team captain in the offline record and typed in when Labyrinth asks for it. Labyrinth never saves it to disk, logs or command history.
- Labyrinth combines the seed with a label such as "decoy port number 3" using a **keyed hash** (HMAC-SHA256). The result looks random, cannot be reversed to reveal the seed, and is always the same for the same seed and label.
- Every result is checked. A port that clashes with a scored service, or a name that clashes with a real or protected account, is skipped and reported.
- If the seed leaks, the team picks a new one and redeploys the traps. That is designed to be a cheap, routine run.

**Why not just encrypt a secrets file?** The password for that file would itself need to be shared and typed on every host, and the encrypted file would sit in a public repository where anyone could attack it at leisure. A seed kept offline removes the stored secret entirely.

### 4.6 The deception maze: traps and decoys (deceive)

**What it does.** Makes the Red Team's work noisy, slow and visible, without ever putting scoring at risk ([design 17](design/17-Deception-Maze-and-CVE-Decoys.md), [Blueprint §4](Blueprint.md#4-deception--trap-catalog)).

**The key insight.** A trap is something no legitimate user ever touches. So when it *is* touched, you can be nearly certain it is an attacker. That makes trap alarms the most trustworthy alerts the team will get.

| Trap | What it is | How good is the signal? |
|---|---|---|
| Canary files | Tempting files, such as a fake password file, whose opening is recorded | High: nobody has a reason to open them |
| Honey-accounts | Fake admin accounts that cannot log in at all; any attempt raises an alarm | High |
| Trap ports | Network ports with no real service; any connection is recorded | High, if nothing else uses the port |
| Tarpits | Trap ports that answer extremely slowly, so scanning tools get stuck | Medium; mostly wastes the attacker's time |
| Banner decoys | Changed version text on *unscored* services only | Low; only slows the attacker's identification of software |
| CVE-mimic decoys | A fake service that *looks* like known vulnerable software (a **CVE** is a publicly listed security flaw) | High, with limits |

**How it works.**

- All trap names, ports and paths come from the event seed.
- Before a trap is installed, five safety checks must pass: its port is not scored or in use; its account name does not exist and is not protected; it runs with minimal permissions; if it crashes, no real service is affected; and the firewall lets connections reach it but lets nothing leave it.
- Every decoy writes to **one central trip log**: the time, which trap, the source address and what was attempted. The trip log feeds the incident reports and the status feed.
- At the end of the event, `cleanup` removes every trap, because the run manifest lists them all.

**What it will never do.** Put a trap on a scored port, fake a response from a scored service, attack or scan back, or contact anything outside the team's network. A CVE-mimic decoy contains no real vulnerable code; it only imitates the visible signs. It adds noise and costs the attacker time, but it never replaces actually patching the real service.

### 4.7 Incident reports (sustain)

**What it does.** Gathers the facts about an attack automatically, so a person only has to add judgment and the final wording ([design 20](design/20-Incident-Reporting-Automation.md)).

**Why it matters.** Under the rules, a thorough report that correctly identifies a successful Red Team attack may reduce the Red Team penalty for that attack. Incomplete or vague reports earn nothing.

**How it works.**

1. **Detect:** something raises an event, such as a trap being touched, a file changing, a suspicious login, a SIEM alert, or a team member typing "log this".
2. **Collect:** gather the facts already on the host: time, host, account, source address, program, file and the relevant log lines.
3. **Correlate:** group related events (same address, account or host, close in time) into one incident with a timeline.
4. **Draft:** fill in the report template, which follows what the rules ask a report to contain: what happened, with addresses and a timeline, passwords cracked, access obtained and damage done; what was affected; and a plan to fix it. Any field without evidence says `UNKNOWN`, never a guess, and the draft lists every field still missing so the team sees it before submitting.
5. **Review:** the incident lead edits the draft. The captain also approves any report about an action that affected a scored service.
6. **Submit:** a person submits it through the channel the officials specify. Labyrinth never submits anything itself.
7. **Track:** the record shows whether each report is a draft, submitted or accepted, so nothing is filed twice or forgotten.

Passwords, keys and tokens are stripped from log excerpts before they go into a report.

### 4.8 Cleanup and tool integrity (sustain)

**What it does.** Leaves nothing behind at the end, and proves that the Labyrinth code on each host is exactly the code that was released ([design 21](design/21-Cleanup-and-Tool-Integrity.md)).

**Cleanup.** Every module declares the files it creates, and every change goes into the run manifest. `cleanup` removes temporary files, timers, scheduled tasks and temporary accounts, but keeps logs and reports until they are collected. It never deletes evidence or anything the manifest does not list, and it only touches Labyrinth's own folders. The only accounts it ever deletes are ones Labyrinth created itself, such as fake trap accounts. `rollback` (undoing changes) is kept separate, so the team can tidy up without reverting its work.

**Tool integrity.** The real risk to the team's own tools is someone *changing* them, not someone *reading* them (the code is public anyway). So:

- each release is tagged in git, and its commit ID is kept in the offline record;
- a **manifest** lists every file with its hash;
- the manifest is **signed** with a team key, which proves who made it and that it has not been altered;
- before every run, the control node checks the signature, and each host checks the manifest's hash against the one in the offline record and every file's hash against the manifest. If anything does not match, the run is refused. (Older hosts cannot check this kind of signature themselves, which is why that step happens on the control node.)

### 4.9 Learning from other teams' tools

Some outside repositories are kept as **reference only** ([design 22](design/22-Reference-Mining.md)). The team reads them for ideas and then writes its own original code from a specification. This avoids software-license obligations (some licenses require anything built from the code to use the same license, and code with no license grants no permission at all) and avoids running code nobody has checked. Ideas and techniques are not covered by copyright; copied code is.

### 4.10 Getting the logs to the SIEM (observe)

**What it does.** Sends the most useful logs from every host to the one SIEM, and runs a handful of saved searches over them ([design 14](design/14-Log-Forwarding-and-Detection.md)).

**Why it exists.** A log that stays on a host disappears if an attacker wipes that host. Once a log line has reached the SIEM, deleting it locally changes nothing. The status feed, the incident reports and the traps all rely on the SIEM already holding the right events.

**How it works.**

- **Linux** hosts forward their login records, the audit log (who ran which privileged command, who touched which watched file) and firewall "blocked" messages. Where the SIEM is Splunk they use Splunk's forwarder (below); otherwise, or when the forwarder cannot be installed, the logging program that is already installed.
- **The Splunk forwarder.** Where the SIEM is Splunk, each host installs Splunk's own forwarder program, downloaded from Splunk's public download site. The exact version and file fingerprint (SHA-256) are fixed in the run-time settings, the download is checked against the fingerprint file Splunk publishes beside it, and the forwarder is never newer than the SIEM's own version. On the SIEM, receiving stays switched off until the team enables it. A small script that sends events over HTTP is the fallback.
- **Windows** hosts forward a short, fixed list of event IDs, the numbers Windows gives each kind of event: logons, failed logons, new accounts, new admin-group members, new services and scheduled tasks, and "the audit log was cleared". The domain controller also forwards its sign-in ticket events, which show password guessing and attempts to steal service passwords.
- The SIEM accepts logs only from the team's own hosts, so an attacker cannot flood it or plant false entries.
- **Appliances** send their logs by **syslog**, the standard way network devices send log lines to a collector.
- A few **saved searches** turn those logs into alerts. The ones that almost never fire by accident come first: a trap was touched, someone tried a fake account, a bait file was opened, a log was wiped.

**Protecting the SIEM itself.** An attacker who controls the SIEM can blind the team. Labyrinth changes its admin password, checks its users, lets only the team's admin machine reach its web page and only the team's hosts send it logs, and sets aside add-ons that could run commands.

**Watching outgoing traffic.** Blocking incoming traffic does not stop a program already inside from calling out. So each host blocks outgoing traffic it does not need from the first minute, and also logs new outgoing connections, and a search flags unusual ones, such as time or name lookups sent to an unknown server.

**Domain takeover signs.** Searches also look for the signs of two well-known attacks that hand over every domain password: ZeroLogon and DCSync. Either one marks the KRBTGT reset urgent, so it is offered first for approval.

**Watching, not blocking, risky tools.** Some ordinary tools are favorites for attackers (for example, ones that open network connections or download files). Blocking them everywhere could break real work, so Labyrinth raises an alert when they run instead.

**What it will never do.** Send logs anywhere outside the competition network, or let logging fill a disk.

### 4.11 Windows and the domain controller (harden)

**What it does.** Hardens Windows machines and the **domain controller** with the same guard rails as the panic button ([design 12](design/12-Windows-and-AD-Hardening.md)).

**Why it is careful.** The domain controller answers logons and DNS for the whole network. One mistake there breaks everything at once. So the rule is **blast radius**: a change that affects one machine can be automated; a change that affects the whole domain is a printed checklist.

**How it works.** Ordinary Windows machines go first, one group at a time. Labyrinth changes their admin passwords, turns on the firewall, limits remote desktop to the team's admin machine (and the scoring engine, if remote desktop is scored), and turns off old or risky features that attackers use to steal or relay passwords, such as old password formats and a setting that keeps plain-text passwords in memory. The domain controller goes last. Anything domain-wide, such as **Group Policy** (settings the domain pushes to every machine at once), domain accounts including the domain Administrator, DNS or the special KRBTGT account, is done by a person following the checklist.

**Stubborn processes.** An administrator cannot always end a process that runs as SYSTEM, the most powerful Windows account, and attackers use this to keep their tools running. After a person approves, Labyrinth ends that one process through a one-time scheduled task that runs as SYSTEM, and deletes the task afterwards. Its way of restarting is set aside first, so it does not come straight back.

### 4.12 Automatic bans (deceive)

**What it does.** When an address touches a trap, uses the planted key or keeps failing to log in, the host blocks that address for a while ([design 18](design/18-Dynamic-Bans.md)).

**The big safety catch.** If the router in front of a host rewrites every outside address into one address (NAT), the host cannot tell the scoring engine and the attacker apart. Banning that one address would block scoring. So before bans are switched on, Labyrinth checks what addresses the host really sees, and it refuses to ban if they all look the same.

**Other guard rails.** A **never-ban list** (the scoring engine, the officials, the team's own machines, the SIEM) is loaded first; a trigger from one of those raises an alert instead. Bans expire. Ban thresholds are settings the team can adjust during the event without changing the frozen code. Labyrinth uses its own small watcher; where the system's own software sources offer fail2ban, it is installed after the lockdown and given the never-ban list before it starts. Failed logins on a scored service never cause a ban, only an alert, because officials checking the service and simulated users can come from any address and may get a password wrong. Traps, the planted key and the fake accounts still ban at once.

**What it will never do.** Strike back at, scan or report the attacker to anyone. A ban only drops traffic on the team's own host: traffic coming in from that address, and traffic going out to it, so a planted program cannot call back to an attacker who is already banned. Banning an address only for outgoing traffic, when a host seems to be calling out to the attacker, waits for a person's approval.

### 4.13 Health monitor and checkpoints (sustain)

**What it does.** Re-tests every scored service on a schedule, and gives the team one command that summarizes the whole network ([design 19](design/19-Health-Monitor-and-Checkpoints.md)).

**How it works.** The control node runs the same scoring-style tests the panic button uses. When a service goes from working to broken, it records both results, names the most recent Labyrinth change on that host as the likely cause, and raises an alert. It does **not** undo a service change on its own: an hour after a change, the cause could just as easily be the attacker, so a person decides.

**Firewall drift.** The one exception is the firewall. If its rules no longer match the sealed set (for example, because an attacker flushed them), Labyrinth puts the sealed rules back at once, with the usual tests and revert timer, and raises an alert. Rules that keep changing are flagged for a person to investigate.

`labyrinth checkpoint` prints, in one screen: which services are up, new integrity findings, new accounts or open ports, open incident reports, trap hits and bans, and how long since each service was last backed up. It changes nothing. The control node also runs it on a schedule and raises one alert for each new finding, so nobody has to remember to look.

**Two caveats.** The control node tests from *inside* the network. The scoring engine may test from outside, through the edge firewall. A pass from inside is good evidence, not proof. And a plain test checks that a service answers, not that a user can log in, because the scoring engine's accounts are never used. A team closes that gap by creating its own test account by hand and typing its password at a checkpoint: the tests then log in, read the scored page, list a mailbox or share, or run a fixed query, the way the scoring engine does.

### 4.14 Backups you can restore (harden)

**What it does.** Takes **restore points** of each scored service: its settings, its website files, its database and, on the domain controller, the directory itself ([design 07](design/07-Backup-and-Recovery.md)).

**Why it exists.** Rollback only undoes Labyrinth's own changes. If an attacker defaces a website or deletes a database table, the team needs a copy from before the damage.

**How it works.** A restore point is taken before patching, before the first risky change on a host, or on request. Labyrinth first checks there is enough disk space, records a hash of each backup so tampering is caught, and stores it where only an administrator can read it. Every restore point is also copied off the host to the control node, or to another team host named as the backup peer, because an attacker with full control of a host can delete backups stored there, and Red Teams are expected to destroy things later in an event.

**Restoring.** `labyrinth restore` puts back a service's settings and files, its database, or a service that was stopped. Restoring overwrites live data, so a person first confirms the restore point is from before the damage; Labyrinth then does the restore, saves the damaged copy as evidence and tests the service. Restoring the domain controller and rescuing a host that will not boot (for example, after an attacker deleted a file it needs to start) stay with a person, following a printed procedure. None of this relies on snapshots of the virtual machines, which some events do not offer.

### 4.15 Fewer services, targeted patches (harden)

**What it does.** Turns off services the host does not need, and helps the team patch the software most likely to be attacked ([design 10](design/10-Patching-and-Service-Reduction.md)).

**Services.** Each kind of host has a list of services that may be turned off, with the reason and the conditions that keep one on, such as "it is scored". Turning a service off is easy to undo, so Labyrinth does it automatically with the usual checks.

**Patches.** Undoing a software update is often impossible, so each patch needs a person's approval. Labyrinth takes the ranked list of known flaws (section 4.19), and for each approved update takes a restore point, updates that one package and tests the service afterwards. Windows updates stay a checklist for a person. It never runs a full system upgrade in the middle of an event. Known-exploited flaws on the domain controller, such as ZeroLogon, always come first. A team can pre-approve security updates for named scored programs, so a first-minute run applies them without waiting.

**Web apps and plugins.** The system's update tools do not track most web apps, so Labyrinth also lists each scored web app's version and its plugins, read from the files on disk, and ranks them the same way. An unused plugin with a known flaw can be switched off after a person approves.


### 4.16 Routers and firewall appliances (lockout)

**What it does.** Provides a **runbook** for each type of router or firewall appliance: a tested, numbered procedure a person follows, filled in with the event's own values ([design 05](design/05-Network-Appliance-Runbooks.md)).

**Why it is manual.** Every vendor has its own commands, and a mistake on the device in front of the network can cut off every host, including the scoring engine's path. Labyrinth prints the steps; it never sends commands to an appliance.

**The steps, in order.** Prepare a way back (second session, configuration backup); change the default passwords; allow management only from the admin machines; allow the scored services from everywhere before blocking anything; block everything else from outside; note how the router rewrites addresses; send the logs to the SIEM; save, test and keep a second backup.

### 4.17 Sweeping for attacker footholds (harden)

**What it does.** Finds the ways back in that an attacker left behind, and removes them without breaking a scored service ([design 06](design/06-Persistence-Sweep.md)).

**Why it exists.** Changing passwords does not remove a scheduled job that reconnects the attacker every minute, a hidden service, or a web page that gives them a command line. Those must be found and removed too.

**How it works.** Labyrinth looks in the usual hiding places: scheduled jobs, services, startup items, login scripts, SSH and admin settings, and web folders. Each thing it finds is sorted:

- **Known good:** belongs to installed software and is unchanged. Left alone.
- **Clearly the attacker's:** does not belong to installed software, nothing scored relies on it, and it shows an unmistakable sign, such as running from a temporary folder or opening a command line to the network. Set aside automatically in the Harden phase, straight after the first-minute lockdown.
- **Unexplained:** anything else. Shown to a person with the reason; once approved, Labyrinth sets it aside.
- **Inside a scored website:** possible attacker web pages are always shown to a person first, because removing a real page would take the site down.

"Set aside" means **quarantined**: switched off and moved to a locked folder, with a record of how to put it back. Nothing is deleted, so a mistake can be undone and the item can be shown as evidence in the incident report.

### 4.18 Ready-made settings for scored apps (harden)

**What it does.** Ships tested settings packs for common scored programs: web servers, webmail and mail, DNS, databases (SQL Server included), file shares, remote management and FTP ([design 11](design/11-Service-Packs-and-Config-Library.md)).

**Why it exists.** The scored services are what the Red Team attacks most, so leaving them exactly as found is not safe. But changing them by hand under pressure is how teams break their own services.

**How it works.** Each setting is sorted in advance. Safe ones (such as hiding the software version or turning off file listings nobody uses) are applied automatically, after the program's own syntax check, with a gentle reload, a test like the scoring engine's and a revert timer. Settings that could change what the scoring engine sees wait for a person's approval. Anything too specific to the event's own app is written up as a step-by-step runbook.

### 4.19 Finding and closing known flaws (harden)

**What it does.** Finds the known flaws on the team's machines before the Red Team uses them, closes the dangerous ones first, and keeps each one on a list until it is closed ([design 09](design/09-Vulnerability-Tracker-and-Mitigations.md)).

**Why it exists.** A Red Team's first step is to check which software versions are running and attack the ones with known flaws. Labyrinth does the same check from the inside, first.

**How it works.** The assessment only reports; it changes nothing. Labyrinth starts with the tools each system already has: `dnf updateinfo list --security` on the Red Hat family, `debsecan` on Debian, `pro security-status` on Ubuntu, and the list of installed updates on Windows. It also reads the versions of scored web apps and plugins on disk, and then runs Lynis (a system audit tool) and Trivy (a scanner for known flaws). Lynis comes from the system's own software sources; Trivy is a pinned download checked against its SHA-256, and it fetches its public flaw database after the lockdown. The heavier OpenVAS/Greenbone scanner is not used, because its feed takes hours to sync. Labyrinth also scans the team's own machines (never anyone else's) for the software versions they show the network, which catches programs installed by hand. All matching happens on the team's machines; nothing is sent out to be looked up. Flaws are ranked: the domain controller first, then scored services, then anything reachable from the network that is known to be exploited.

**Closing a flaw.** An unscored service with a flaw is simply turned off. A scored service is never turned off. Instead, Labyrinth closes the flaw while the service keeps running: first with a tested setting or firewall rule from its catalog where one exists (for example, removing a dangerous permission from a helper program nothing uses), then with the security update once a person approves it. Each flaw is tracked as open, mitigated, patched or accepted, and every checkpoint shows what is still open.

### 4.20 Installing the team's tools (harden)

**What it does.** Installs the extra tools each kind of host needs, such as auditd, fail2ban and file-integrity and malware scanners, straight after the first-minute lockdown ([design 02](design/02-Packages-and-Third-Party-Tools.md)).

**Why it exists.** Typing install commands host by host under pressure is slow and error-prone, and a tool installed before the lockdown could start doing things before its settings are in place.

**How it works.** Tools come only from public sources every team can reach: the system's own software sources, a mirror or proxy the event provides, or a public download whose exact file is fixed in the release by its SHA-256. PowerShell Gallery modules on Windows are allowed at pinned versions. The SSH tarpit (endlessh) comes from the system's own sources, from EPEL on the Red Hat family, and is not bundled. Before installing, Labyrinth checks that the install would not remove or replace anything already there. New services stay switched off until their own part of Labyrinth sets them up. Every install is recorded. Labyrinth tries the download first, and a person can paste the file in by hand when no source answers. If neither works, the installs are skipped and the lockdown stands.

**What it will never do.** Upgrade the whole system, add a new software source (apart from EPEL, an optional extra on RHEL-family hosts), use a private server or a paid one, send anything to a cloud service, or install a container system unless the event allows containers (section 4.21).

### 4.21 Rebuilding a service, only where allowed (harden)

**What it does.** Where an inject or the event's own rules allow it, rebuilds one scored service that cannot be fixed where it stands: a clean install on the same host, or the same service in a container there ([design 13](design/13-Service-Replacement-and-Containers.md)). Each is off by default. Containers are turned on with `ALLOW_CONTAINERS=yes:<reference>` and replacing a service with `ALLOW_SERVICE_REPLACE`, and turning either on means naming the inject or rule that allows it.

**Why it is careful.** The national rules forbid moving or containerizing a scored service unless an inject or the local rules allow it. Even then, scoring checks the old address, the old name, the old content and the old users. So the new service is built beside the old one, every piece of data and every user is copied across and compared, and only then does the new one take over, under a revert timer. The old one is kept, stopped, until the team keeps the change.

**The proof.** A replacement needs full proof, or Labyrinth refuses: the same users, the same mailboxes and message counts, the same pages (compared by hash), the same database contents, and the scored check passing against the new service on a staging port before it takes over. The new service keeps the same host, public address, DNS name and usernames.

**Container rules.** On the Red Hat family the engine is Podman, and on Debian and Ubuntu it is Docker (`docker.io`), both from the system's own software sources. Every container runs as a non-root user by default, drops all extra privileges and adds back only what the service needs, cannot gain new privileges, uses a read-only file system where the service allows, and is never privileged. It never gets the container engine's control socket or the host's own process and network spaces, and only approved folders are mounted into it. Services built to start as root and then give it up themselves (Postfix, Dovecot) are on a named exception list; any other container running as root is refused. Ports below 1024 are published from a high port inside the container.

---

## 5. The competition rules that shape everything

Every design choice above traces back to a handful of rules. In plain words, a tool a team writes itself must:

- **be public** at least three months before it is used, **declared** to the officials, and **frozen** (no changes) for each event;
- be **shared** with every competing team;
- use **no cloud services or other outside processing**, other than DNS lookups. Free public software that every team can reach is allowed, but only from the hosts' own sources, an event mirror or a pinned download, and only after the lockdown;
- **never deliberately break** things the network is expected to do. The rules give setting every Linux login shell to `/bin/false` and ending all outbound connections after 30 seconds as examples of what not to do

(National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 5.6.1–5.6.5).

Other rules also shape the design:

| Rule in plain words | What it means for Labyrinth |
|---|---|
| Officials must be able to get in when they ask (NCCDC, 2025, Rule 4.1). | A tested emergency way in is required before any change. |
| Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | The scoring engine is allowed through firewalls first, and every change is tested like the scoring engine would test it. |
| Do not mislead the scoring engine (NCCDC, 2025, Rule 9.3). | No trap or fake service on anything scored. |
| Scored services may not be moved or put into containers unless an inject or the event's own rules allow it (NCCDC, 2025, Rule 4.14). | Off by default; where allowed, only through section 4.21, on the same host with the same address and name, and with all the data moved over. |
| Each event has its own local rules, and they differ (NCCDC, 2025, Local Competition Rules section). | Every event value is read at run time; nothing assumes one event's rules. Scored services stay open to every address, because some events penalize limiting them. |
| No new devices (NCCDC, 2025, Rule 4.2). | Everything runs on the machines already there. |
| No attacks on systems outside your own network (NCCDC, 2025, Rule 4.10). | Traps observe and record; they never strike back. |

> [!IMPORTANT]
> These rule numbers come from the national rules, updated 10 December 2025. Each event's own materials and local rules come first.

---

## 6. What Labyrinth is not

- **Not a replacement for people.** Anything high-risk is a printed checklist, and every report is approved by a person.
- **Not a store of secrets.** The repository holds templates and placeholders only. Real addresses, passwords and the event seed are supplied at run time and never committed.
- **Not an attack tool.** It defends, observes and records; it never scans, attacks or contacts outside systems.
- **Not a promise of safety.** Traps and decoys buy time and visibility. They do not replace changing passwords and patching.

---

## 7. What to do first: priorities

Controls are ranked from **P0** (do first) to **P3** (do last): 🔴 P0 · 🟠 P1 · 🟡 P2 · ⚪ P3. The rule is to do every P0 task on every host before starting any P1 task anywhere. Changing admin passwords, ending intruder sessions, sweeping for footholds and turning on the default-deny firewall are P0. Traps (canaries and honey-accounts) are P2, not because they matter less, but because they need the logging from the Observe phase to be in place first. The full table is the [priority scorecard](Blueprint.md#7-priority-scorecard).

---

## Glossary

| Term | Meaning |
|---|---|
| Active Directory (AD) | Microsoft's system for managing users and computers across a Windows network from a central server, the **domain controller**. |
| Admin-class account | An administrator account such as root or Administrator. Labyrinth changes its password in the first minute. |
| Allowlist | A list of the only things that are permitted; everything else is blocked. |
| Audit log | A log in which the operating system records who did what, such as opening a watched file. |
| Baseline | A saved record of what a healthy host looks like, used to spot changes. |
| Break-glass | A sealed emergency login kept in the offline record, used only when normal access fails. |
| Canary | A bait file whose only purpose is to raise an alarm when someone opens it. |
| Change list | The `username,password` lines Labyrinth prints once after changing scored-admin passwords, for the team to hand in through the event's own process. |
| Control node | An optional, hardened machine for the jobs that look across hosts: read-only checks, the health monitor, the status file and off-host restore copies. Hardening runs on each host itself until remote apply exists. |
| CVE | Common Vulnerabilities and Exposures: a public ID for a known security flaw. |
| Default-deny | A firewall setting that blocks every incoming connection unless a rule allows it. |
| Event seed | The secret random value, kept offline, from which all trap names and ports are derived. |
| Exit code | The number a command ends with, which says how it went: 0 done or nothing to do, 10 a change is needed, 20 blocked by a safety check, 30 a check after a change failed, 40 an error. |
| Firewall | Software or a device that decides which network connections are allowed. |
| Harden | The second phase, after the lockdown: installing the team's tools, restore points, sweeping for footholds, patching and cutting services, then reopening outgoing traffic. |
| Group | A set of hosts that receives a change together, named in the team's hosts file. The first group holds one low-impact test host of each kind of system. |
| Group Policy | Settings a Windows domain pushes to every machine at once. |
| Hash | A short fingerprint of a file that changes if the file changes. |
| Hidden admin | An account with administrator power that does not look like one, such as a second root account or a member of an admin group by a side door. |
| Persistence | A way back in that an attacker leaves behind, such as a scheduled job or a hidden service. |
| Queue | The list of approval items that wait for a person; `laby -q` shows it, and `laby -q -a` carries out chosen ones (planned). |
| Quarantine | Switching an item off and moving it to a locked folder, with a record of how to put it back, instead of deleting it. |
| Offline record | Where the team keeps passwords, the seed and the release fingerprint: on paper or in a local file on a team member's own machine, never in the repository, a cloud drive or the competition hosts. |
| Honey-account | A fake account that cannot log in; any attempt to use it is an alarm. |
| Host | Any single computer or server on the network. |
| Idempotent | Safe to run more than once: repeating it gives the same result. |
| KRBTGT | The hidden domain account whose password signs every Windows domain login ticket; resetting it cancels forged tickets. |
| Manifest | A list of files with their hashes (for tool integrity), or a record of changes made (the run manifest). |
| Module | One small, single-purpose piece of Labyrinth automation. |
| MOTD | Message of the day: the text a Linux host shows at login. |
| NAT | Network address translation: a router rewriting addresses, which can hide where traffic really came from. |
| Patch | An update that fixes a flaw in a piece of software. |
| Port | A numbered "door" on a host that a network service listens on, such as 22 for SSH. |
| Priority | How early a task runs, from P0 (first, on every host) to P3 (last). |
| Profile | A kind of host (for example, Linux web server) and the list of modules that apply to it. |
| Protected set | Accounts Labyrinth must never touch, supplied by the operator for each event. |
| Red Team | The attackers in the competition. |
| Restore | Putting a service back from a backup (a restore point) after damage. Not the same as a rollback. |
| Restore point | A backup of a service taken so it can be put back after damage. |
| Revert timer (dead-man) | A timer started before a risky change that rolls the run back automatically, unless someone keeps the run after confirming things still work. If a change locks the team out, the timer puts things back. Changes that only take access away are kept once they check out, and the timer leaves them alone. |
| Ring | The design specs' word for a host group. |
| Rollback | Undoing what a run changed, newest first, using the run manifest. The revert timer starts one automatically; a person can start one too. |
| Runbook | A tested, numbered procedure that a person follows step by step. |
| Run ID | The name of one Labyrinth run, such as `20261002T140301Z-4f2a`: the start time in UTC and four random characters. Commands also accept just the last four characters (`4f2a`). |
| Scored service | A service the scoring engine checks, such as a website, email or DNS. |
| Scored-admin account | An admin account the scoring engine logs in with. Its password is changed, and the new one goes into the change list. |
| Scoring engine | The automated checker that tests scored services and awards points. |
| Seal | Taking a new baseline of a host once it is cleaned, and using it as the reference for every later check. |
| SIEM | Security Information and Event Management system: a central place that collects and searches logs from every host. |
| SSH | Secure Shell: the standard encrypted way to log in to a Linux host remotely. |
| Syslog | The standard way servers and network devices send log lines to a collector. |
| Tarpit | A trap that answers so slowly that attack tools get stuck. |
| Tier | How risky a change is, from Tier 0 (read-only) to Tier 3 (a person approves first); it decides how carefully the change is made. |
| Trip log | The single log every trap writes its alarms to. |
| White Team | The competition officials who run the event. |

---

## Where to go next

- **The whole system in detail:** the [implementation blueprint](Blueprint.md).
- **One part in detail:** the [design specs](design/README.md), starting with [00, the module contract](design/00-Module-Contract-and-Layout.md).
- **The project summary:** the [README](../README.md).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
