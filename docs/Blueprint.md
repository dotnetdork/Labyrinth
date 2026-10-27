# Labyrinth Implementation Blueprint

- **Project:** Labyrinth, a rapid, idempotent, multi-OS hardening and deception deployment system.
- **Purpose:** the base documentation for designing and building the automation: the portable doctrine and the transferable technical controls.
- **Secrets:** none reproduced. This document describes the *shape* of configuration only: no keys, env files, or credentials.
- **Citations:** competition rules are cited by rule number in APA 7 style (author, date, rule).
- **Detailed designs:** each part of the tool has its own spec in [`design/`](design/README.md).
- **New to the project?** The [overview](Overview.md) explains every part in plain language.

> [!IMPORTANT]
> **Rules basis and warning.** Rule numbers follow the web version of the national CCDC (Collegiate Cyber Defense Competition) rules, updated 10 December 2025 (National Collegiate Cyber Defense Competition [NCCDC], 2025). A rule number is the page's section number, then the item's place in it: Rule 4.14 is item 14 of section 4, and Rule 5.6.1 is the first point of item 6 of section 5. The page has ten sections: Rule 8.5 is in Questions, Disputes, and Disclosures, and Rules 9.3 and 9.4 are in Scoring. Each event's local competition rules and materials come first and differ from event to event (NCCDC, 2025, Local Competition Rules section), so Labyrinth reads the event's values at run time and assumes none.
>
> Every rule citation is re-checked against each event's materials and local rules. Where this document and the rules disagree, the rules win.
>
> Items marked **[RULES]** are limits the competition rules place on a control.

---

## 0. Executive summary

Labyrinth exists to solve one problem: **the opening minutes.** In a CCDC engagement the scoreboard goes live and the Red Team may already know the default credentials. Every host in a heterogeneous network (several Linux distributions, Windows Server, Active Directory (AD), Windows workstations, a SIEM (Security Information and Event Management system), and edge appliances) has to be wrestled back to a trustworthy state at the same time, *without* dropping the services being graded.

You cannot do that by hand, per host, from memory. Labyrinth is:

- **A core strategy:** five phases (*Lock out → Harden → Observe → Deceive → Sustain*) and a set of OS-agnostic invariants, so the same reasoning applies to a Fedora web server and a Windows domain controller.
- **A capability map:** each invariant expressed as a concrete control on Linux, on Windows/AD, and on the network edge, with a priority and a CCDC note.
- **A deception catalog:** traps, canaries, honey-accounts, tarpits, and sinkholes that make an attacker's reconnaissance expensive, noisy, and logged. Deception buys time that patching cannot.
- **An architecture:** native bash and PowerShell modules grouped into *phases*. A team can run a guarded lockout across the reachable hosts from one command, then layer observation and deception on top (§6, design 00).

Because Labyrinth is a team-written tool, the rules require that it:

- is public at least three months before use;
- is declared;
- is frozen;
- is shared with every team;
- uses no cloud services or private sources: public software and data are downloaded after the lockdown, with an offline fallback;
- does not deliberately break expected functionality

(NCCDC, 2025, Rules 5.6.1–5.6.5). Those five rules shape every section below.

### How to read this document

| Section | What it covers |
|---|---|
| [§1](#1-operating-doctrine--the-order-of-work) | The doctrine you execute live: the order of work. |
| [§2](#2-the-core-strategy--portable-invariants) | The portable "why": the invariants. |
| [§3](#3-capability-map--transferable-technicals-per-platform) | The "how, per OS": the capability map, the heart of this reference. |
| [§4](#4-deception--trap-catalog) | The trap catalog. |
| [§5](#5-event-settings--what-differs-from-event-to-event) | The settings that differ from event to event, and how Labyrinth handles each. |
| [§6](#6-labyrinth-architecture) | How Labyrinth itself is structured. |
| [§7](#7-priority-scorecard) | The priority scorecard. |
| [§8](#8-verification--rollback) | Verification and rollback. |

---

## 1. Operating doctrine — the order of work

The competition reality: **assume breach from the start.** Credentials are default or already known, implants may be pre-seeded, and you are graded on *service uptime*. So every change must be reversible and must not take a scored service down.

Work the phases in order, and do the cheap, high-impact things first. The timing of each step belongs to the team's own plan, not to this public document.

```mermaid
flowchart LR
    A["<b>Lock out</b><br/><i>Take back trust</i><br/>• rotate admin credentials<br/>• lock unexpected accounts<br/>• end intruder sessions<br/>• default-deny in and out"]
    B["<b>Harden</b><br/><i>Shrink the surface</i><br/>• install tools, take restore points<br/>• sweep, verify against official packages<br/>• patch, cut services, service packs<br/>• then reopen outbound"]
    C["<b>Observe</b><br/><i>See everything</i><br/>• ship logs to the SIEM<br/>• high-signal host logging<br/>• watch authentication"]
    D["<b>Deceive and sustain</b><br/>• deploy the trap layer<br/>• keep scored services green<br/>• hold and triage"]
    A --> B --> C --> D
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    classDef harden fill:#fdeedc,stroke:#c2410c,color:#4a1d06
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    classDef deceive fill:#efe7fb,stroke:#7c3aed,color:#351465
    class A lockout
    class B harden
    class C observe
    class D deceive
    style D stroke:#15803d,stroke-width:3px
```

*Figure: the order of work in this section, from taking back trust through hardening, observation, deception and sustainment, with the main steps of each stage. Colors follow the phase key: red is lock out, orange is harden, blue is observe, purple is deceive and green is sustain. The last box covers both deceive and sustain, so it is purple with a green border.*

### Lock out — Establish trust

The attacker's power comes from credentials, existing sessions and footholds left before the event. The first-minute bundle takes the first two away on each host in one step: it rotates admin passwords, removes unregistered keys and checks the SSH configuration, ends intruder sessions, then applies default-deny inbound and outbound. It installs nothing: installing is slow, and the lockdown must be in place before outbound opens again, so it uses only what the host already has (design 03, section 6.1). That is a matter of speed and order, not of a rule. On a Debian host with no firewall front end (nftables installed but not running, shipped rules that accept everything, UFW not installed), the lockdown uses raw nftables, and UFW takes over in the Harden phase with the same rules. Scored services are a primary Red Team target, so they are defended, with probes and revert timers, rather than left as found.

- **Rotate administrator-class credentials you were handed or that ship by default:** local admins, appliance web logins, SNMP (Simple Network Management Protocol) strings, and service or database accounts once the dependency map is known. Do it first, everywhere.

  **[RULES]** Events differ on whether scoring logs in with admin accounts (§5), so none is assumed unscored. An admin account a check logs in with is a `scored-admin` account: it is rotated, and its new password goes to the event's change process (design 04, section 2.4). Automation never rotates user-level or scoring accounts.

- **Inventory and lock unexpected accounts:** an account is expected if it is protected, named in the packet or owns a scored service. Unexpected *local* accounts with admin rights or hidden-admin signs lose those rights and are locked automatically; other unexpected local accounts are locked after approval. Once a checkpoint shows every scored service passing, a person may approve deleting them, with evidence saved first (design 04, section 6). Domain accounts are handled by hand from a checklist (design 12). End intruder sessions after rotation, but never a console session, the operator's own, an admin-source session or an official's (design 03, section 6.2).

  **[RULES]** Never change every shell or end connections indiscriminately; the rules give those as examples of tools that break expected functionality (NCCDC, 2025, Rule 5.6.5). Disabling accounts wholesale is the same kind of blanket action. Officials must be able to get in on request (NCCDC, 2025, Rule 4.1), so a verified break-glass path comes first.

- **Default-deny** inbound and outbound on every host firewall and at the edge. Allow only the scored services and your own admin path inbound, and only what the host and its scored services need outbound.

### Harden — Shrink the surface

With the network closed around each host, the Harden phase installs the team's tools, takes restore points, and does the slower cleanup, then reopens outbound traffic to the host's normal list.

- **Install the team's tools** from public sources (design 02), and **take restore points** of the scored services before the first risky change (design 07).
- **Sweep for persistence:** scheduled jobs, services, startup items, SSH and PAM changes, and web shells. Clear attacker footholds are quarantined automatically; anything a scored service might depend on waits for approval. Nothing is deleted (design 06).
- **Verify against the official packages, then baseline** (last in the Harden phase, after patching, so it checks the packages as they are left; design 03, section 6): users, listening ports, processes, scheduled tasks/cron, startup items, firewall state. The package database on a host can be edited by root, so for a core set of packages (OpenSSH server, sudo, PAM, coreutils, util-linux, systemd, the shadow tools) and any package a local check flags, Labyrinth downloads the package from the host's configured repositories, checks its signature and compares its files' hashes with the files on disk. A mismatch is a finding for a person, never an automatic fix. Windows keeps Authenticode signer checks and `sfc /verifyonly`. Verify before hashing files, so a compromised state is not recorded as normal. Once the lockout and sweep are verified, seal the baseline, so later checks compare against the cleaned host (design 08, section 6).
- **Move or hide admin:** where SSH (Secure Shell) or RDP (Remote Desktop Protocol) is not scored, get it off the obvious port, and consider port-knocking on hosts that support it (§3.4, §4.7). A scored admin service is never moved or hidden; it stays open to every source and is hardened in place.
- **Disable services you are not graded on.** Every listener is a vector.

  **[RULES]** Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). As a design choice, services are disabled only from a per-profile candidate list, and only after the scored-service list is known (design 10).

- **Patch the obvious:** the known-exploited, internet-facing things only, package by named package. Do not start a 40-minute `dist-upgrade` mid-round. Apply the service packs for the scored services (design 11) and the Windows and AD settings (design 12), and, only where an inject or the local rules allow it, replace or containerize a service (design 13).

### Observe — See everything

- **Ship logs to the SIEM** (for example Splunk): authentication, firewall, process creation. Centralized logs survive a wiped host. On a flat network every host reaches the SIEM directly; where hosts sit in different segments, open only the minimum flows needed for log forwarding and the admin path (§5).
- **Turn on high-signal host logging:** `auditd` on Linux, **Sysmon + Windows Security auditing** on Windows.
- **Watch authentication** in real time. A successful login to something you locked earlier is your first catch.

### Deceive and sustain

- **Deploy the trap layer** (§4): scanner tarpits, canary tokens, honey-accounts, port traps, DNS (Domain Name System) sinkholes. Now every attacker action generates a high-confidence alert.

  **[RULES]** No decoy on a scored port, and no decoy that misleads the scoring engine (NCCDC, 2025, Rule 9.3).

- **Keep scored services green:** health-check them (design 19), and use your rollback path the instant a change hurts a service. Read-only checkpoints also run on a schedule and alert once on each new finding.
- **Hold and triage:** work your alert queue by confidence. Canary and honey-account hits come first (near-certain), then anomalies.

> [!TIP]
> **Rule of thumb:** *lock-out before hardening, hardening before observation, observation before deception, deception before comfort.* A trap is worthless if the attacker still has valid credentials and an open admin port.

---

## 2. The core strategy — portable invariants

These hold on every OS. The capability map (§3) is just these seven, made concrete.

1. **Identity:** no shared, default, or unrotated credentials; least privilege; an explicit admin allowlist; keys or MFA (multi-factor authentication) over passwords wherever the platform allows.
2. **Surface:** default-deny ingress; expose only scored services; move or hide administration.
3. **Segmentation & egress:** enforce trust boundaries: between segments where the network has them, and in each host's own firewall on a flat network. Treat unexpected *outbound* traffic as hostile (the signature of C2, command and control), not just inbound.
4. **Observability:** high-signal logging to a central SIEM; watch authentication, sensitive files, and process starts.
5. **Deception:** anything that is not a real service is a tripwire, and every trip lands in one place.
6. **Recoverability:** baselines, backups, tagged rollback points, and a documented break-glass path.
7. **Change discipline:** idempotent, reversible, timestamped. Never make a change you cannot undo in ten seconds.

---

## 3. Capability map — transferable technicals, per platform

This is the core of the reference. Each capability gives:

- the portable **principle**;
- the concrete implementation on **Linux**, **Windows / AD**, and the **network edge**;
- a **priority** (P0 = do in the first minutes);
- a CCDC note.

### 3.1 Credential reset & account control — **P0**

- **Principle:** no attacker keeps access through a credential you have rotated.
- **Linux:** use `passwd` / `chpasswd` for root and administrator-class accounts only, `scored-admin` accounts included with their change list (design 04, section 2.4). Use `usermod -L` to lock unexpected local accounts outside the protected set. Audit `sudoers` and group membership. Back up, then empty, unexpected `~/.ssh/authorized_keys`. After rotation, end remote sessions with `loginctl terminate-session`, except console, operator, admin-source and protected sessions (design 03, section 6.2). Automation never rotates or locks ordinary user accounts (for example, mailbox users).
- **Windows/AD:** rotate the built-in local Administrator and other local administrator-class accounts, except any that a service or scheduled task logs on with (changing those breaks the service at its next start). Review `Domain Admins`, `Enterprise Admins` and local Administrators membership. By hand only, after confirming with the captain:
  - rotate the domain Administrator, and any admin account a service or task logs on with, updating each dependent service;
  - reset service accounts once their dependencies are known;
  - disable accounts confirmed as unused.
- **KRBTGT:** reset its password twice, with a replication check between, to invalidate golden tickets. This is a Tier 3 item: after approval, Labyrinth carries out both resets (design 12, section 5.1).
- **Never rename** an account, and never change a host name, address or scored DNS name: scoring and the event's change process know each by name (design 03, section 3).
- **Applications:** inventory each scored app's own admin accounts (CMS administrator, database root, phpMyAdmin) and the configuration files that store an app password. Rotating one is Tier 3: after approval, Labyrinth sets the new password, updates every listed file and runs the probes; never automatically, because scoring may log in to the app (design 04, section 2.1).
- **Edge:** change the appliance admin, web, SSH and SNMP credentials immediately. Routers and firewalls often ship with well-known defaults.
- **CCDC note:** the number-one foothold is a credential the Red Team already knows. Rotate administrator-class credentials first, everywhere, before anything clever.

  **[RULES]** Events differ on which accounts scoring logs in with (§5), so none is assumed unscored. An admin account a check logs in with is a `scored-admin` account: it is rotated, and its new password goes into a `username,password` change list shown once for the event's change process (design 04, section 2.4). Domain-wide or user-level resets are manual-only by default: scored mail checks have logged in with Active Directory users (*Background*), so a mass reset can zero a scored service. As a design choice, the KRBTGT reset is an approval item that Labyrinth carries out: it is one account with a known procedure, and the first reset breaks nothing. Design: 03, 04, 12.

### 3.2 Remote-admin hardening (SSH / RDP / WinRM) — **P0/P1**

- **Principle:** shrink and strengthen the way *you* get in; deny every other way.
- **Linux:** key-only (`PasswordAuthentication no`), `PermitRootLogin no`, an `AllowUsers` allowlist, `MaxAuthTries 3`, no X11 or agent forwarding, weak ciphers and MACs removed, `LogLevel VERBOSE` (needed for the planted-key canary). All of it in a drop-in file named to load first, with the base config untouched; planted add-on files and `Match` blocks are quarantined, and `sshd -T` confirms the settings in effect (design 04, section 4.1). Where SSH is scored, the scoring and `scored-admin` accounts keep password login through a `Match User` block, and every other account is key-only; root keeps it only when it is itself a `scored-admin` account (design 04, section 4.2).
- **Windows/AD:** restrict RDP to an admin jump source where RDP is not scored, and harden it in place where it is; enable NLA (Network Level Authentication); disable RDP where it is not needed; restrict WinRM (Windows Remote Management) where it is not scored, and harden its accounts in place where it is; remove `Everyone` and `Authenticated Users` from remote-logon rights; use LAPS (Local Administrator Password Solution) for the local admin.
- **Edge:** bind the management plane to an inside interface only; no WAN admin.
- **CCDC note:** pair this with §3.4 (move/hide). Hardening the login is worth more once it is not on port 22/3389.

  **[RULES]** Officials must be given access immediately when they ask (NCCDC, 2025, Rule 4.1). Use a drop-in file, test with `sshd -t`, arm a revert timer, and keep the two-session rule (design 03, 04). Prefer per-role ed25519 keys with `from=`, `restrict` and forced commands (design 04).

### 3.3 Host firewall / default-deny — **P0**

- **Principle:** deny inbound by default; permit scored services from every source, plus your admin path and any official sources named in the event packet; log denials (that log feeds the honeypot in §4.1). A scored port is never filtered by source: some events penalize it, and officials and simulated users come from addresses nobody can list. On a flat network the host firewall is the only boundary between servers (design 03, section 6.1).
- **Linux:** UFW (Uncomplicated Firewall) on Debian and Ubuntu (installed on a Debian host that has no front end) and firewalld on the RHEL family, default-deny in, allow out, with explicit allows per service. Raw nftables is used only for the first minute on a Debian host with no front end, until UFW takes over in the Harden phase with the same rules (design 01). Each run's summary shows the host's firewall in one format. Use **medium logging** so every drop is logged as `[UFW BLOCK] … DPT=…`. On container hosts, also filter `DOCKER-USER`: Docker's published ports **bypass** the host `INPUT` chain, so bans and egress rules must live there too.
- **Windows:** Windows Defender Firewall, default-deny inbound per profile; allow only graded ports; enable connection logging.
- **Edge:** default-deny WAN; an explicit allow per service; log denies to the SIEM.
- **CCDC note:**

  **[RULES]** Every scored service is allowed from any source before any deny rule, and a scoring allowlist, where given, goes first too (NCCDC, 2025, Rule 4.11). The firewall adapter refuses a narrower allow, or a deny, on a scored port (design 01, section 5).

  "Docker bypasses the host firewall" is the classic way a "locked-down" web host is still wide open. Verify with the actual ingress path, not just `ufw status`.

  **Drift.** Once sealed, the rule set is compared on a schedule. If it has drifted (for example, flushed by an attacker), the sealed rules are re-applied automatically with probes and a revert timer, and an alert is raised; repeated drift is flagged for a person (design 19, section 4.1).

### 3.4 Move / hide administration — **P1**

- **Principle:** make the admin service invisible to a mass scan, so it is not the first thing hit.
- **Linux:** where SSH is not scored, move it off port 22 (a tarpit can then sit *on* 22; see §4.2). A scored admin service is never moved, knocked or hidden; it is hardened in place (design 04, section 4.2). Optionally add **port-knocking** (`knockd`), so the real port stays filtered until a knock sequence opens it for the knocking source IP.
- **Windows:** where RDP is not scored, put it behind the firewall or a jump host rather than on a non-standard port (changing the port is weak on Windows), and prefer allowlisting the source. Where RDP is scored, it stays open to every source (§5).
- **CCDC note:** port-knocking (§4.7) makes SSH appear *closed* to Nmap, which saves real time. The trade-off is one more moving part on a box you also need to log into fast.

  **[RULES]** Officials must be able to get in on request (NCCDC, 2025, Rule 4.1), so knocking is optional and never the only path. The knock sequence is documented only in the team's offline record (design 04, section 2).

### 3.5 Dynamic banning / auto-response — **P2**

- **Principle:** turn repeated hostile touches into automatic, expiring blocks, and make the blocking scale.
- **Linux:** `fail2ban` backed by an **ipset** (one kernel hash-set and one match rule per chain) instead of one iptables rule per IP, so thousands of bans stay flat. Jails cover SSH where it is not scored, the trap-port honeypot, the planted-key canary, and repeat offenders. Failed logins on a scored service only alert: manual scoring checks and simulated users come from addresses that are not the scoring engine's (design 18). Bans apply on **both** `INPUT` and `DOCKER-USER`.
- **Labyrinth:** a small native watcher in bash feeds the same kernel set. fail2ban is installed after the lockdown where the host's repositories offer it (on RHEL-family hosts it needs EPEL, which Labyrinth adds only as an optional extra where EPEL can be reached), and starts only once the never-ban list is in its `ignoreip` (designs 02, 18).
- **Windows:** there is no fail2ban. Approximate it with a scheduled task or a WinLogbeat → SIEM alert that drives a firewall block, or with an IDS (intrusion detection system) at the edge. This is usually better handled at the perimeter.
- **CCDC note:** ipset matters when a tarpit is feeding you thousands of IPs; a per-IP ruleset will bloat and slow the box.

  **[RULES]** Bans act only on your own host's traffic, inbound and outbound. Dropping traffic to or from a hostile address is not offensive activity; scanning, attacking or contacting it is, and offensive activity outside the team's network is prohibited (NCCDC, 2025, Rule 4.10). Active response such as TCP resets is allowed, but anything that interferes with scoring is the team's responsibility (NCCDC, 2025, Rule 4.11). The scoring engine, officials, operators and the host's outbound dependencies are always on the ignore list. A ban on one address is targeted, not the indiscriminate blocking the rules give as an example (NCCDC, 2025, Rule 5.6.5). Design: 18.

> [!WARNING]
> If traffic from outside reaches the host through NAT (network address translation) on the router, the scoring engine and the Red Team can appear to come from the same last-hop address, and banning that address would block scoring. Confirm what source addresses the host actually sees before enabling automatic bans.

### 3.6 Service minimization & patching — **P1**

- **Principle:** fewer listeners, fewer known-exploited packages.
- **Linux:** disable or mask unneeded units. Patch internet-facing, known-exploited packages surgically, not with a blind full upgrade mid-round. Assess fixable CVEs (Common Vulnerabilities and Exposures), report only, narrowed to what is *actually* upgradable today. Built-in tools come first:
  - `debsecan` on Debian;
  - `pro security-status` on Ubuntu;
  - `dnf updateinfo list --security` on RHEL-family (Red Hat Enterprise Linux) hosts;
  - the installed updates on Windows.

  Then Lynis (from the distribution's repositories, EPEL on the RHEL family) and Trivy (a pinned release checked against its SHA-256; it downloads its public CVE database, which is allowed after the lockdown). OpenVAS and Greenbone are not used: their feed sync takes hours. Patching is an approval item that updates only the named packages, never a full upgrade.
- **Windows:** stop unneeded services and features; apply the specific KBs (Microsoft Knowledge Base updates) for known-exploited CVEs; disable SMBv1 (Server Message Block version 1), LLMNR (Link-Local Multicast Name Resolution) and NBT-NS (NetBIOS Name Service).
- **CCDC note:**

  **[RULES]** Do not migrate or containerize scored services unless an inject or the local competition rules allow it (NCCDC, 2025, Rule 4.14). Where they do, rebuilding a service is design 13, off by default, and only with full proof that its users, mailboxes, pages, database contents and address are preserved and its scored check passes on a staging port before cutover (§3.7).

  A scored service you break costs points immediately; an unpatched, non-exploited CVE probably does not. Prioritize by exploitability plus exposure, not by count. Known-exploited domain controller flaws (for example ZeroLogon, CVE-2020-1472) rank above everything else. Web apps and their plugins are inventoried from the files on disk and ranked the same way; an unused vulnerable plugin can be deactivated after approval. A scored service with a flaw is never turned off to close it: it is mitigated in place (a setting or a web application firewall rule), then patched in place. Each finding is tracked from open to closed and shown at every checkpoint. Matching is done locally, never by sending versions to an outside service (NCCDC, 2025, Rule 5.6.4). Designs: 09, 10.

### 3.7 Application / container least-privilege — **P1** (Linux app hosts, where the event allows containers)

- **Principle:** if an app is compromised, the blast radius is one unprivileged process with no capabilities.
- **Linux:** the RHEL family uses Podman and Debian and Ubuntu use Docker (`docker.io`), both from the distribution's own repositories, with no new repository. Every container runs as a non-root user by default, drops **ALL** capabilities and adds back only what the service needs, sets `no-new-privileges`, and uses a read-only root file system where the service allows. An admission check refuses `privileged`, host namespaces, a mounted container-engine socket and bind mounts that are not allowlisted, *before* deploy. Services built to start as root and drop privileges themselves (Postfix, Dovecot) are on a named exception list; any other container running as root is refused. Ports below 1024 are published from a high port inside the container.
- **Windows:** run app pools and services as least-privileged service accounts (gMSA, group Managed Service Accounts), not `LocalSystem`. Constrain them with Just-Enough-Admin where practical.
- **CCDC note:** WordPress and other web apps are prime targets. Once de-privileged, a webshell lands in a box that can barely do anything.

  **[RULES]** Containerizing a scored service is not allowed unless an inject or the local competition rules allow it (NCCDC, 2025, Rule 4.14). Local rules can allow it on the same host, and then the service keeps the same public address, DNS name and usernames, and its scored check passes before cutover (design 13, `ALLOW_CONTAINERS=yes:<reference>`). Without that permission, the existing installation is hardened with service accounts, systemd sandboxing and file permissions.

### 3.8 Web edge — **P1** (web hosts)

- **Principle:** terminate and filter at a reverse proxy. Only real clients reach the app; scanners get punished (§4.3).
- **Linux:** an nginx reverse proxy with:
  - the real client IP restored from a front end such as a load balancer, where one exists, so logs, rate limits and traps see the true IP;
  - TLS (Transport Layer Security) and security headers;
  - per-site logging;
  - a request-time resolver, so one bad upstream returns 502s for one site instead of crashing nginx.

  Where a front end such as a load balancer exists, the origin is locked to it.
- **CCDC note:** the scanner tarpit (§4.3) lives here. It is one of the highest-value, lowest-risk traps you can deploy on a graded web host.

### 3.9 Centralized logging & detection — **P1**

- **Principle:** logs on the box die with the box. Get them off-host and make them high-signal.
- **Linux:** `auditd` with rule keys for privileged commands, identity and sudoers, SSH keys, cron, systemd units, `/usr/local`, and **canary reads**; forward to Splunk.
- **Windows/AD:** **Sysmon** (process creation, network, image loads) plus Windows Security auditing (4624/4625/4688/4720/4728…); forward to Splunk through the universal forwarder. Hosts of both kinds install the Splunk Universal Forwarder from Splunk's public download site, pinned by version and SHA-256 in the run-time configuration and checked against the checksum file published beside it; the forwarder is never newer than the indexer. Receiving on 9997 stays off on the indexer until enabled, and the HEC script is the fallback (design 14).
- **SIEM:** Splunk is the aggregation point. A few high-value saved searches (new local admin, canary hit, authentication to a locked account, boot-critical file changes, ZeroLogon and DCSync signs, unusual outbound traffic) beat a hundred noisy dashboards. The SIEM host is itself hardened: its admin password rotated, users and roles audited, its web and management ports open only to the admin source unless they are scored (then open to every source), its inputs only to managed hosts, `splunkd` moved off root after approval, and unknown apps and scripted inputs quarantined (design 14, section 7).
- **CCDC note:** stand this up in the Observe phase, *before* deception, so the traps have somewhere to report. Design: 14.

### 3.10 Egress control — **P2**

- **Principle:** unexpected *outbound* traffic is the C2 signature. Watch it even if you cannot block it.
- **Linux:** containers normally reach out only to DNS, HTTP, HTTPS and NTP (Network Time Protocol). A new outbound SYN to any other external port is logged with a container-outbound log prefix. The rule is rate-limited, scoped to the external interface, placed above Docker's `RETURN`, and re-installed after Docker restarts.
- **Windows:** Windows Firewall outbound logging; alert on beaconing patterns through Sysmon network events.
- **Every host:** a rate-limited, log-only rule for new outbound connections (Tier 2; blocks nothing) feeds an unusual-outbound search, such as NTP or DNS to a server not in the run-time configuration. Outbound default-deny is part of the first-minute bundle, from the services file and the run-time `outbound-allow` list (design 03, section 6.1).
- **CCDC note:** combine with DNS sinkholing (§4.5): see the beacon, then dead-end it without tipping off the attacker.

### 3.11 Backups, rollback & break-glass — **P1**

- **Principle:** every change is reversible, every service is restorable, and there is always a way back in.
- **Linux:** timestamped config backups before each change (`*.bak-<ts>`), database dumps before patching, the previous image, tagged before each update, for instant rollback, and the virtual machine console as break-glass.
- **Windows/AD:** system state and AD backups; VSS (Volume Shadow Copy Service) snapshots; a documented DC (domain controller) recovery path.
- **Off-host copies are required:** an attacker with root or SYSTEM can delete on-host backups, so each restore point is copied to the control node, or another team host named as the backup peer, and hash-checked before it counts as complete (design 07, section 5). Snapshots of the virtual machines may not be available; Labyrinth never relies on them.
- **Restore:** `labyrinth restore <service>` (with `--database` or `--start`) runs after a person confirms the restore point predates the damage (Tier 3); the damaged state is kept as evidence. Domain controller restores and rescuing an unbootable host (for example, a deleted `/etc/fstab`) are person-run, from printed runbooks (design 07, section 6).
- **CCDC note:** the team that can *revert* a bad change in seconds outscores the team that is afraid to make changes. Design: 07.

---

## 4. Deception & trap catalog

**Design principle:** *make reconnaissance expensive and noisy for the attacker, while every trip is logged for the defender.*

Route every tripwire to **one** place (a central trip log or SIEM index), so a single rate-limited notifier can watch it. Deception comes after Observe, because it multiplies the value of the logging you set up there.

### 4.1 Trap ports / port-trap honeypot

Trap ports are ports you run **nothing** on, so a single inbound packet is hostile.

- **Log-driven (preferred):** UFW already logs every denied packet. A `fail2ban` filter matches `[UFW BLOCK] … DPT=<trap port>` and bans the source instantly through ipset (all ports, for weeks). There is no extra listener and no daemon to crash. Labyrinth's native watcher does the same job (§3.5, design 18). The trap set excludes real services, and the never-ban list (operators, the scoring engine where known, officials) is never banned.
- **Listener-based:** a `nc -l` loop on, for example, 1433/3389 that logs every hit. It is simpler, but it needs one process per port and it *accepts* connections. Prefer the log-driven approach where you already have firewall logging.
- **Portability:** on Windows, a firewall "block + log" rule on unused ports, feeding a Sysmon or Security alert.

### 4.2 SSH tarpit (endlessh)

A tarpit on the port every bot targets (22). It dribbles an endless SSH banner, so scanners hang for minutes. Real admin access is elsewhere (§3.4). The tarpit's own output names the offenders.

In a competition, only put a tarpit on port 22 if SSH is not scored and the officials have been told the real admin path (NCCDC, 2025, Rule 4.1). The tarpit program (endlessh) comes from the distribution's repositories after the lockdown, from EPEL on the RHEL family, and is not vendored (design 02).

**[RULES]** Offenders are never reported to an outside reputation service: a team tool may not use outside resources apart from DNS (NCCDC, 2025, Rule 5.6.4). Offenders go to the local trip log only.

**Value:** it wastes attacker and bot time for free and turns the noisiest port into a sensor.

### 4.3 Web scanner tarpit

Two implementations of one idea: punish tools like Gobuster, Dirb and Nikto that crawl for `/wp-login`, `.env`, `/phpmyadmin` and similar paths.

- **Slow-drip (used):** an nginx regex `location` matches attack paths that no real visitor requests. It returns a **rate-limited** decoy (`limit_rate`), capped per real client IP (`limit_conn`, keyed on the binary remote address so a flood cannot exhaust workers), and logs the real IP to a scanner log. It never matches real app routes, APIs or assets. There is no automatic ban wired from host to container (that would be fragile coupling): the tarpit *is* the punishment, and the log drives a manual block.
- **Recursive loop (not used):** a `trap.php` that returns `200 OK` with a link to a fresh random folder, so recursive crawlers loop forever and bloat memory until they crash.

  **[RULES]** Not recommended: an always-`200` responder can look like a live page to the scoring engine and mislead it (NCCDC, 2025, Rule 9.3), and it risks load on a scored host. Use the slow-drip approach on paths the scoring engine never requests.

- **CCDC note:** this is the highest-value, lowest-risk trap on a graded web host, because real users never hit these paths.

### 4.4 Canary tokens & files

Passive bait that raises an alert the instant it is touched: the highest-confidence signal you can plant.

- **Host-native:** two layers, one for *finding* the bait and one for *using* it.
  - Decoy files (a fake cloud-credentials file, a fake database dump) are watched by `auditd` (`canary_read` key), so a **read** raises an alert. You catch a snooper who merely *finds* the bait.
  - A **planted SSH key** is authorized on no account. Because sshd logs at VERBOSE, any *use* of the key logs its fingerprint, which a `fail2ban` jail matches and bans for a year (in Labyrinth, the native watcher, design 18).
- **Cross-platform:** `Passwords_2026.docx` on Windows shares and desktops; host-native audited bait files.

  **[RULES]** Hosted tracking URLs and web bugs (CanaryTokens and similar) call an outside service, so they are out (NCCDC, 2025, Rule 5.6.4). Use audited files and honey-accounts only. Names and paths derive from the event seed (design 16).

- **Portability:** on Windows, a decoy file plus a Security "object access" audit ACL (event 4663), host-native only. Place bait wherever an attacker looks for credentials: shares, home directories, repositories, backups, wikis.

### 4.5 Honey-accounts

A decoy admin (`backup_admin`, `svc-sql-backup`, …) that no real person uses and that **cannot log in at all**, wired to alert on **any logon attempt**. False positives are near zero, and an attacker who guesses or cracks its password still gains nothing.

- **Linux:** the account has no usable password and no login shell. The authentication log records every attempt with its source IP; the watcher writes it to the local trip log, and the log forwarder carries it to the SIEM.

  **[RULES]** The hook never posts to an outside service (NCCDC, 2025, Rule 5.6.4).

- **Windows/AD:** a disabled account with a tempting name, whose failed logon events (4625, and 4771 or 4776 on the domain controller) fire a high-priority SIEM alert. Domain honey-accounts are created by hand (design 12). A well-known variant is a Kerberoast-bait service account with an SPN (service principal name).
- **CCDC note:** treat any honey-account hit as a confirmed intrusion. It is the cleanest alert you will get.

### 4.6 DNS sinkholing (C2 dead-ending)

When you identify a C2 domain, **redirect** its resolution to loopback or a capture host instead of blocking it at the firewall. A block *tells* the attacker they are caught; a sinkhole silently strands the implant.

- **Per-host:** append the domain → `127.0.0.1` in `/etc/hosts`.
- **Network-wide:** RPZ (Response Policy Zone) or conditional forwarding on the AD DNS server, or DNS host overrides on the perimeter firewall, to sinkhole across all assets at once.

  **[RULES]** DNS is a scored service, and anything that interferes with scoring is the team's responsibility (NCCDC, 2025, Rule 4.11). The rule does not require changes by hand; keeping changes to the domain controller's DNS manual, tested with a scoring-style query before and after, is a design choice (design 12).

### 4.7 Port knocking (stealth admin) — see §3.4

The firewall drops all inbound traffic to the admin port until a secret knock sequence opens it for the sender's IP. Under an Nmap sweep the port reads **closed/filtered**, which denies the attacker an easy vector. The trade-off is noted in §3.4.

### Trip-log pattern

Every trap above writes one line to a **central trip log** (for example `/var/log/security-trip.log`, with tight permissions and rotation) or to a dedicated SIEM index. With one place to tail, one rate-limited notifier can cover every trap without spamming you.

```mermaid
flowchart LR
    subgraph traps["Traps"]
        TP["Trap ports (§4.1)"]
        ST["SSH tarpit (§4.2)"]
        WT["Web scanner tarpit (§4.3)"]
        CF["Canary files and<br/>planted SSH key (§4.4)"]
        HA["Honey-accounts (§4.5)"]
    end
    TL[("Central trip log<br/>or SIEM index")]
    NT["One rate-limited notifier"]
    TP --> TL
    ST --> TL
    WT --> TL
    CF --> TL
    HA --> TL
    TL --> NT
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    classDef observe fill:#e3eefc,stroke:#2563eb,color:#0f2a5c
    class TL store
    class NT observe
    style traps fill:#efe7fb,stroke:#7c3aed,color:#351465
```

*Figure: every trap writes to one central trip log, so a single rate-limited notifier can watch all of them. Purple is the deception layer, gray the trip log and blue the alerting that watches it.*

---

## 5. Event settings — what differs from event to event

The national rules are the same at every event. Each event's own materials and local rules add settings of their own, and these change between regions, and between one region's invitational and its qualifier (NCCDC, 2025, Local Competition Rules section). Labyrinth assumes none of them: each is a run-time value or a decision a person makes at the event. This table is the one list of them; other sections and the designs link here.

| Setting | What events have done (*Background*) | What Labyrinth does |
|---|---|---|
| Which accounts scoring logs in with | Some events said administrator-class accounts are never used for scoring. Others score logins with admin accounts too, and take new passwords only through their own change list | No account is assumed unscored. The operator marks each account a check logs in with as `scoring`, or `scored-admin` when it is also an admin account; a `scored-admin` password is rotated and goes into a `username,password` change list shown once (design 04, section 2.4) |
| Filtering a scored port by source | Some events penalize filtering a public service by source address, or letting only the scoring engine reach it. Officials' manual checks, simulated users and traffic generators come from addresses nobody can list | Scored ports stay open to every source and are hardened in place. One hostile address at a time can be banned (design 18); the firewall adapter refuses a narrower allow on a scored port (design 01, section 5) |
| Scoring engine addresses | Some events publish them; many do not, and some say they vary | The scoring allowlist is optional. Where given, it goes first (design 03, section 7) |
| ICMP (ping) | Events commonly require ping to keep working on every device, sometimes with one exception | ICMP stays on every device unless officials direct otherwise (design 03) |
| Internet access | Open internet, a web proxy that allows only listed sites (such as the team's declared repository), or none | After the lockdown, Labyrinth downloads public software and public data from the host's repositories, an event mirror or proxy, or a pinned release checked against its SHA-256. Offline paste is the fallback, and a download that cannot be reached is reported as skipped (§6.1, design 02) |
| Recovery | Some events offer a scrub or revert of a VM, at a penalty; others offer no snapshots, only a power cycle or a fresh lab | Labyrinth never relies on VM snapshots. It makes its own restore points and copies them off the host (design 07) |
| Moving or containerizing a scored service | Not allowed unless an inject or the local rules allow it (NCCDC, 2025, Rule 4.14). Some events allow containerizing on the same platform with the same address | Off by default; design 13, turned on with `ALLOW_CONTAINERS=yes:<reference>` in `event.conf`, naming the rule or inject |
| Replacing a scored service | Not allowed unless an inject or the local rules allow it (NCCDC, 2025, Rule 4.14) | Off by default; design 13, turned on with `ALLOW_SERVICE_REPLACE` in `event.conf`. It needs full proof: same users, mailboxes and message counts, same pages (hash-compared), same database contents, and the scored check passing on a staging port before cutover; otherwise it refuses |
| How officials reach the hosts | Some events give officials a console on every VM through the event's lab system; others may name official source addresses | The break-glass login is the access path. Official sources named at run time are allowed through default-deny (design 03, section 2) |
| Network shape | One flat inside network behind a single edge firewall, or several segments behind separate firewalls | On a flat network each host's own firewall is the only boundary between servers (design 03, section 6.1). Where there are segments, only the log-forwarding and admin flows are opened between them (design 15, section 3) |

---

## 6. Labyrinth architecture

### 6.1 Tooling

**Native scripts, run locally or remotely.**

**[RULES]** Team tools may not use outside resources such as cloud services or cloud processing (NCCDC, 2025, Rule 5.6.4), while free public software sources are allowed (NCCDC, 2025, Rules 5.1, 5.2). Events differ on what the hosts can reach (§5). So **Labyrinth itself needs only its own public release**: fetched from its release page where a host or console reaches it, or pasted in or carried in where nothing does (design 21, section 5.2). After the first-minute lockdown, it **downloads first and falls back to offline paste**: public software and public data come from the host's configured repositories, an event mirror or proxy, or a pinned release checked against its SHA-256. It never calls a cloud service, a reputation or enrichment API or a private source, and never runs a full upgrade. A download that cannot be reached is reported as skipped, and the lockdown stands (design 02).

Labyrinth is therefore bash on Linux and PowerShell on Windows, in one repository; third-party tools come from public sources after the lockdown, or are vendored where their license allows (design 02). **Local mode is the standard:** each host's operator runs it on that host, so nothing holds access to every host at once. **Remote mode** comes later: a control node sends the same command over SSH or PowerShell remoting, starting with read-only `remote plan` across every host, and `remote apply` only once that has proven itself. A control node holds access to every host, so it is a prime target: it should be a hardened server, with keys made fresh at the event, which hosts accept only from the control node's address, and it keeps the revert safeguards and the scored-service probes. In remote mode, the control node keeps a host's run only when it can still log in over the admin path and no scored service that passed before the run fails after it; otherwise the host's revert timer undoes it, except the changes kept once they verified. Ansible was considered and not adopted. Network appliances use templated configuration and a manual runbook. See design 00.

### 6.2 Layout

The repository layout is defined in design 00 (`core/`, `phases/<phase>/modules/`, `profiles/`, `platform/`, `config/`). The role names below (`ssh`, `firewall`, `nginx_edge` …) are the module names.

### 6.3 Profiles

Classify each host and apply only the roles that fit:

| Profile | Example host | Roles |
|---|---|---|
| `linux-server` | Any Linux server without a web role | identity, ssh, firewall, bans, deception, egress_log, audit_motd, patching |
| `linux-web` | Linux web or webmail server | + nginx_edge (the scanner tarpit is P1 here). Containers only where an inject or the local rules allow it (NCCDC, 2025, Rule 4.14), through design 13. |
| `windows-member` | Windows member servers and workstations | win_base, win_firewall, win_audit, honey-account, canary (design 12) |
| `windows-dc` | Domain controller with DNS | + AD hardening checklist (design 12); the KRBTGT reset is an approval item and the DNS sinkhole is manual-only (§3.1, §4.6) |
| `linux-siem` | SIEM server | identity, ssh, firewall + ingest config (the destination, hardened but light) |
| `appliance` | Router or firewall appliance | Templated config + manual runbook (credentials, default-deny, management-plane lockdown; design 05) |

Every host profile also runs the persistence sweep (design 06) and the service packs that match its scored services (design 11).


### 6.4 Phase playbooks = the doctrine, executable

The lockout phase is the panic button; the Harden phase follows behind it on the same host.

**[RULES]** A single pass that resets every credential, locks every account and default-denies every host would break expected functionality, which the rules prohibit (NCCDC, 2025, Rule 5.6.5).

The design keeps the speed and adds guard rails:

- a protected set;
- plan-before-apply;
- host groups (rings), with one test host per platform first;
- a confirmed break-glass path;
- dead-man revert timers;
- scoring-style probes after each module.

Tier 3 actions wait for a person's approval; Labyrinth then carries them out, except a short person-run list (Group Policy, DNS changes on a domain controller, domain controller restores, rescuing an unbootable host, Windows patching and appliances). Items the team decided on before the event, such as security updates for named scored packages, can be pre-approved, so a first-minute run applies them without a prompt (Conventions, section 3.1). Nothing is deleted without approval: files are quarantined, and accounts are deleted only after approval once services pass. See designs 03 and 06. After the lockout, seal the baseline and layer `observe → deceive → sustain`.


### 6.5 Secret handling

Ship **placeholder templates** only (`.env.example`, cert paths, token *names*). Real values are supplied at run time from the event packet and the event seed, which is kept offline (design 16).

**[RULES]** The code is public (NCCDC, 2025, Rule 5.6.1), so decoy values are derived from a secret event seed kept offline (design 16) rather than stored in an encrypted repository file.

Labyrinth provisions the *shape*; the operator supplies the values. **No real credential, key, or env file ever enters the repo.**

### 6.6 Speed & safety discipline

- **Idempotent, and plan mode first:** every module runs in `plan` mode (a dry run) before `apply`, especially near scored services (design 00).
- **Reversible:** every role backs up what it changes (timestamped) and documents its rollback.
- **Tested on throwaway VMs** (or the CCDC practice image) before you trust it live.
- **Fail-safe ordering:** never lock your own admin path before the new one is proven, and keep the break-glass path.

  **[RULES]** A dead-man revert timer is armed before any firewall or SSH change (design 03).

### 6.7 One command per host — specified, built later

The runner does not do this yet; today `plan` and `apply` are separate steps. The intended change is that `apply` prints a compact plan and carries it out, and `plan` stays as a read-only command. Every existing command form keeps working. It is switched on with `AUTO_APPLY=yes` in `event.conf`; unset means today's behavior (design 03). When on:

- **The group comes from the hosts file,** matched on the host's name and address. A mismatch or an ambiguity blocks the run (exit 20). `--confirm-group` is still accepted but no longer required.
- **The break-glass account is the `breakglass`-class account from the protected set that exists on the host;** with none, or more than one, the run blocks (20). Labyrinth checks for a console session itself and warns if it finds none, rather than prompting.
- **It never prompts mid-run.** Approval items that no pre-approval rule covers go to a queue under the state path. `labyrinth queue` lists them, and `labyrinth approve <ids>` applies the chosen ones in a new run with the same backups, manifest, timer and probes. Always queued: deleting an account, changing a scored service that has no probe, replacing or containerizing a service, and any Tier 3 item.
- **Each module is kept automatically** once its verify and probes pass, except firewall and SSH changes, which stay under the revert timer until one `keep` per host run.
- **Output is short:** one line per module (`OK`, `CHANGED`, `ROLLED BACK`, `QUEUED`, `BLOCKED`, `FAIL`). Full Found/Fix/More blocks appear only for failures and blocks; details go to the run log, and `--detail` shows the full blocks.

---

## 7. Priority scorecard

Triage under a clock. Do P0 everywhere before P1 anywhere. The **When** column is color-coded from 🔴 P0 (first) through 🟠 P1 and 🟡 P2 to ⚪ P3 (last).

| Control | Impact | Effort | When |
|---|---|---|---|
| Rotate admin-class creds / lock unexpected local accounts (§3.1) | ★★★★★ | Low | 🔴 P0 |
| End intruder sessions + persistence sweep (§1, design 06) | ★★★★★ | Med | 🔴 P0 |
| Default-deny firewall (§3.3) | ★★★★★ | Low | 🔴 P0 |
| Remote-admin hardening (§3.2) | ★★★★ | Low | 🔴 P0/P1 |
| Move/hide admin (§3.4) | ★★★ | Med | 🟠 P1 |
| Central logging + auditd/Sysmon (§3.9) | ★★★★ | Med | 🟠 P1 |
| Service minimization + targeted patch (§3.6) | ★★★ | Med | 🟠 P1 |
| Service packs for scored apps (design 11) | ★★★★ | Med | 🟠 P1 |
| Web edge + scanner tarpit (§3.8, §4.3) | ★★★★ | Low | 🟠 P1 |
| Backups / rollback / break-glass (§3.11) | ★★★★ | Low | 🟠 P1 |
| Container least-privilege, where allowed (§3.7) | ★★★ | Med | 🟠 P1 |
| Replacing a service, where allowed (design 13) | ★★★ | High | 🟠 P1 |
| Canary tokens & honey-accounts (§4.4–4.5) | ★★★★★ | Low | 🟡 P2 |
| Dynamic banning / ipset (§3.5) | ★★★ | Med | 🟡 P2 |
| Egress logging + DNS sinkhole (§3.10, §4.6) | ★★★ | Med | 🟡 P2 |
| Port knocking (§4.7) | ★★ | Med | ⚪ P3 |

*The Rule 5.6 items (public, declared, frozen, no cloud processing, no breakage) apply to every row.*

*Canaries and honey-accounts are P2 by sequence, because they need §3.9's logging first. They are still the highest-confidence detections you will deploy, so get to them.*

---

## 8. Verification & rollback

A portable runbook: confirm that each control actually took, and know how to undo it.

| Control | Verify (Linux example) | Rollback |
|---|---|---|
| SSH posture | `sudo sshd -T \| grep -Ei 'port\|permitroot\|password\|allowusers\|loglevel'` | Remove the drop-in, `sshd -t`, reload |
| Firewall | `ufw status verbose`; **test the real ingress path**, including `DOCKER-USER` | Disable the rule / restore the ruleset backup |
| Dynamic bans | `fail2ban-client status`; `ipset list -n`; `iptables -S DOCKER-USER \| grep match-set` | Stop the jail; flush the set |
| Trap ports | Fire a packet at a trap port from a non-allowlisted IP → expect a ban | Remove the filter/jail |
| Canary (files+key) | Read a decoy → expect an audit event; offer the planted key → expect a fingerprint match + ban | Remove the audit rule / jail |
| Scanner tarpit | `curl -m5 https://host/.env` → should hang and log the IP | Remove the `location` block, validate, reload |
| Egress logging | Make an odd outbound connection from a container → expect the container-outbound log line | Remove the LOG rules / disable the unit |
| Central logging | Confirm events are arriving in Splunk from each host | n/a |
| Service health | curl/health-check every scored service after each change | Revert the change; restore the previous image / config backup |

*Always validate config that fronts a scored service before reloading (for example, `nginx -t` before `nginx -s reload`), and keep a break-glass path open until the new access path is proven.*

---

## Appendix — CCDC notes & glossary

**Rule numbers used in this document** (web rules, 10 December 2025). Verify against each event's materials.

| Rule | Subject |
|---|---|
| 4.1 | Official access |
| 4.10 | Offensive activity |
| 4.11 | Active response and scoring interference |
| 4.14 | No migrating or containerizing scored services, unless an inject or local rules allow it |
| Local rules | Each event's own rules, unique to that event |
| 5.1 | Free public internet resources only, nothing behind a fee or membership |
| 5.6.1–5.6.5 | Team-written tools |
| 9.3 | Misleading the scoring engine; incident reports are 9.4 |

**Notes and terms**

- **Assume breach from the start:** known default credentials may already be in use, so §1 "Establish trust" is non-negotiable.
- **Scored services are sacred:** a change that drops a graded service costs points now. Reversibility (§2.7, §3.11) is a scoring strategy, not just hygiene.
- **Confidence-ranked alerts:** canary and honey-account hits are near-certain; work them before anomaly noise.
- **Deception ≠ blocking:** a sinkhole or tarpit *wastes the attacker's time and watches*; blocking *warns* them. Prefer the quiet option when you want intelligence.
- **KRBTGT:** the AD account whose hash signs Kerberos tickets; rotate it twice to kill golden tickets.
- **ipset:** a kernel hash-set that lets one firewall rule match thousands of IPs; it keeps a tarpit-fed banlist flat.
- **RPZ:** DNS Response Policy Zone; server-side sinkholing across every client at once.

---
## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html

---
*Base documentation for Labyrinth. No secrets, environment values, or private keys are reproduced.*
