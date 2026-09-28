# Labyrinth — Hardening & Deception Reference

**Project:** Labyrinth · a rapid, idempotent, multi-OS hardening + deception deployment system
**Purpose:** the base documentation — the portable doctrine and the transferable technical controls — used to design and build the automation.
**Reference implementation:** a hardened Debian server run by the author is the worked example of the **Linux server profile**; this document generalizes it to a mixed competition network.
**Secrets:** none reproduced. This document describes configuration *shape* only — no keys, env files, or credentials.

---

## 0. Executive summary

Labyrinth exists to solve one problem: **the opening minutes.** In a CCDC engagement the scoreboard goes live, the Red Team already has footholds, and every host in a heterogeneous network (Ubuntu, Fedora, Oracle Linux, Windows Server, Active Directory, a Windows workstation, a SIEM, and edge appliances) needs to be simultaneously wrestled back to a trustworthy state *without* dropping the services being graded.

You cannot do that by hand, per host, from memory. Labyrinth is:

- **A core strategy** — four phases (*Lock out → Observe → Deceive → Sustain*) and a set of OS-agnostic invariants, so the same reasoning applies to a Fedora webserver and a Windows domain controller.
- **A capability map** — each invariant expressed as a concrete control on Linux, on Windows/AD, and on the network edge, with a priority and a CCDC note.
- **A deception catalog** — traps, canaries, honey-accounts, tarpits, and sinkholes that make an attacker's recon expensive, noisy, and logged, because deception buys time that patching cannot.
- **An architecture** — Ansible roles and *phase* playbooks so a team can run the lockout across every reachable box in one command, then layer observation and deception.

The transferable technicals come from a real hardened box. What follows is that box's controls, generalized into a system you can point at an empty network.

**How to read this document**
- §1 is the doctrine you execute live (the clock).
- §2 is the portable "why" (the invariants).
- §3 is the "how, per OS" (the capability map — the heart of the reference).
- §4 is the trap catalog.
- §5 is the proven Linux build (the reference implementation).
- §6 is how Labyrinth itself is structured (Ansible).
- §7 is the priority scorecard; §8 is verify/rollback.

---

## 1. Operating doctrine — the order of work

The competition reality: **assume breach from the start.** Credentials are default or already known, implants may be pre-seeded, and you are graded on *service uptime* — so every change must be reversible and must not take a scored service down. Work the phases in order; do the cheap, high-impact things first.

### Phase 0 — Establish trust
The attacker's power comes from credentials and existing sessions. Remove both.
- **Rotate every credential you were handed or that ships by default** — local admins, service accounts, DB users, appliance web logins, SNMP strings. This is the single highest-impact action; do it first, everywhere.
- **Inventory and lock accounts** — disable/expire everything that is not a known operator or a required service account. Kill unexpected sessions.
- **Capture a baseline** — users, listening ports, running processes, scheduled tasks/cron, startup items, firewall state. You cannot spot anomalies later without it.

### Phase 1 — Shrink the surface
- **Default-deny ingress** on every host firewall and at the edge; allow only the scored services and your own admin path.
- **Move or hide admin** — get SSH/RDP off the obvious port; consider port-knocking on hosts that support it (§4.6).
- **Disable services you are not graded on.** Every listener is a vector.
- **Patch the obvious** — the known-exploited, internet-facing things only; do not start a 40-minute `dist-upgrade` mid-round.

### Phase 2 — See everything
- **Ship logs to the SIEM** (Splunk in the reference topology) — auth, firewall, process creation. Centralized logs survive a wiped host.
- **Turn on high-signal host logging** — `auditd` on Linux, **Sysmon + Windows Security auditing** on Windows.
- **Watch authentication** in real time; a successful login to something you locked in Phase 0 is your first catch.

### Phase 3 — Deceive & sustain
- **Deploy the trap layer** (§4): scanner tarpits, canary tokens, honey-accounts, port traps, DNS sinkholes. Now every attacker action generates a high-confidence alert.
- **Keep scored services green** — health-check them, and use your rollback path the instant a change hurts a service.
- **Hold and triage** — work your alert queue by confidence: canary/honey-account hits first (near-certain), then anomalies.

> **Rule of thumb:** *lock-out before observation, observation before deception, deception before comfort.* A trap is worthless if the attacker still has valid creds and an open admin port.

---

## 2. The core strategy — portable invariants

These hold on every OS. The capability map (§3) is just these seven, made concrete.

1. **Identity** — no shared, default, or unrotated credentials; least privilege; explicit admin allowlist; key/MFA over passwords wherever the platform allows.
2. **Surface** — default-deny ingress; expose only scored services; move/hide administration.
3. **Segmentation & egress** — enforce trust boundaries; treat unexpected *outbound* as hostile (C2 signature), not just inbound.
4. **Observability** — high-signal logging to a central SIEM; watch auth, sensitive files, and process starts.
5. **Deception** — anything that is not a real service is a tripwire; every trip lands in one place.
6. **Recoverability** — baselines, backups, tagged rollback points, and a documented break-glass path.
7. **Change discipline** — idempotent, reversible, timestamped. Never a change you cannot undo in ten seconds.

---

## 3. Capability map — transferable technicals, per platform

The core of the reference. Each capability states the portable **principle**, then the concrete implementation on **Linux** (proven on the reference box), **Windows / AD**, and the **network edge**, plus a **priority** (P0 = do in the first minutes) and a CCDC note. Linux specifics link back to §5/appendix A.

### 3.1 Credential reset & account control — **P0**
- **Principle:** no attacker keeps access through a credential you have rotated.
- **Linux:** `passwd` / `chpasswd` every interactive and service account; `usermod -L` / `--expiredate` to lock; audit `sudoers` and group membership; empty unexpected `~/.ssh/authorized_keys`; `pkill -u` stray sessions.
- **Windows/AD:** reset the KRBTGT password (twice, over the round) to invalidate golden tickets; reset Domain Admins and all service accounts; disable stale accounts; check `Domain Admins`, `Enterprise Admins`, and local Administrators membership; force logoff.
- **Edge:** change the appliance admin/web/SSH/SNMP credentials immediately (routers and firewalls often ship with well-known defaults).
- **CCDC note:** the number-one foothold is a credential the scoring engine also gave the Red Team. Rotate first, everywhere, before anything clever.

### 3.2 Remote-admin hardening (SSH / RDP / WinRM) — **P0/P1**
- **Principle:** shrink and strengthen the way *you* get in; deny every other way.
- **Linux (reference §5.2):** key-only (`PasswordAuthentication no`), `PermitRootLogin no`, `AllowUsers` allowlist, `MaxAuthTries 3`, no X11/agent forwarding, weak ciphers/MACs removed, `LogLevel VERBOSE` (needed for the planted-key canary). Drop-in file, base config untouched.
- **Windows/AD:** restrict RDP to an admin jump source; enable NLA; disable RDP where not needed; restrict WinRM; remove `Everyone`/`Authenticated Users` from remote-logon rights; LAPS for local admin.
- **Edge:** management plane bound to an inside interface only; no WAN admin.
- **CCDC note:** pair with §3.4 (move/hide) — hardening the login is worth more once it is not on port 22/3389.

### 3.3 Host firewall / default-deny — **P0**
- **Principle:** deny inbound by default; permit only scored services + your admin path; log denials (that log feeds the honeypot in §4.1).
- **Linux (reference §5.3):** UFW (or nftables) default-deny in, allow out; explicit allows per service; **medium logging** so every drop is `[UFW BLOCK] … DPT=…`. On container hosts, also filter `DOCKER-USER` — Docker's published ports **bypass** the host `INPUT` chain, so bans and egress rules must live there too.
- **Windows:** Windows Defender Firewall, default-deny inbound per profile; allow only graded ports; enable connection logging.
- **Edge:** default-deny WAN; explicit allow per service; log denies to the SIEM.
- **CCDC note:** the "Docker bypasses the host firewall" gotcha is the classic way a "locked-down" web host is still wide open. Verify with the actual ingress path, not just `ufw status`.

### 3.4 Move / hide administration — **P1**
- **Principle:** make the admin service invisible to a mass scan so it is not the first thing hit.
- **Linux:** move SSH off 22 (reference runs a tarpit *on* 22 — see §4.2); optional **port-knocking** (`knockd`) so the real port is filtered until a knock sequence opens it per-source-IP.
- **Windows:** RDP behind the firewall/jump host rather than a non-standard port (port-change is weak on Windows); prefer allowlisting the source.
- **CCDC note:** port-knocking (playbook §5) makes SSH appear *closed* to Nmap — real time saved. Trade-off: one more moving part on a box you also need to log into fast; document the sequence for your team.

### 3.5 Dynamic banning / auto-response — **P2**
- **Principle:** turn repeated hostile touches into automatic, expiring blocks — and make the block scale.
- **Linux (reference §5.4):** `fail2ban` backed by an **ipset** (one kernel hash-set, one match rule per chain) instead of one iptables rule per IP, so thousands of bans stay flat. Jails for SSH, the trap-port honeypot, the planted-key canary, and repeat offenders; bans applied on **both** `INPUT` and `DOCKER-USER`.
- **Windows:** there is no fail2ban; approximate with a scheduled task / WinLogbeat → SIEM alert that drives a firewall block, or an IDS at the edge. Usually better handled at the perimeter.
- **CCDC note:** ipset matters when a tarpit is feeding you thousands of IPs; a per-IP ruleset will bloat and slow the box.

### 3.6 Service minimization & patching — **P1**
- **Principle:** fewer listeners, fewer known-exploited packages.
- **Linux:** disable/mask unneeded units; patch internet-facing, known-exploited packages surgically (not a blind full upgrade mid-round). Track fixable CVEs (`debsecan`) narrowed to what is *actually* upgradable today.
- **Windows:** stop unneeded services and features; apply the specific KBs for known-exploited CVEs; disable SMBv1, LLMNR, NBT-NS.
- **CCDC note:** a scored service you break costs points immediately; an unpatched non-exploited CVE probably does not. Prioritize by exploitability + exposure, not by count.

### 3.7 Application / container least-privilege — **P2** (Linux app hosts)
- **Principle:** if an app is popped, the blast radius is one unprivileged, capability-less process.
- **Linux (reference §5.5):** every container drops **ALL** capabilities, runs as a non-root, non-sudo host UID, `no-new-privileges`, read-only root where possible. **Admission control** (`compose-guard`) refuses `privileged`, host namespaces, and un-allowlisted bind mounts *before* deploy.
- **Windows:** run app pools / services as least-privileged service accounts (gMSA), not `LocalSystem`; constrain with Just-Enough-Admin where practical.
- **CCDC note:** WordPress/Gitea/web apps are prime targets — containerized and de-privileged, a webshell lands in a box that can barely do anything.

### 3.8 Web edge — **P1** (web hosts)
- **Principle:** terminate and filter at a reverse proxy; only real clients reach the app; scanners get punished (§4.3).
- **Linux (reference §5.6):** nginx reverse proxy, real-client-IP restored from the trusted front (so logs/rate-limits/traps see the true IP), TLS, security headers, per-site logging, request-time resolver so one bad upstream 502s one site instead of crashing nginx. Origin locked to the trusted front-end where applicable.
- **CCDC note:** the scanner tarpit (§4.3) lives here and is one of the highest-value, lowest-risk traps you can deploy on a graded web host.

### 3.9 Centralized logging & detection — **P1**
- **Principle:** logs on the box die with the box; get them off-host and make them high-signal.
- **Linux:** `auditd` with rule keys for privileged commands, identity/sudoers, SSH keys, cron, systemd units, `/usr/local`, and **canary reads**; forward to Splunk.
- **Windows/AD:** **Sysmon** (process creation, network, image loads) + Windows Security auditing (4624/4625/4688/4720/4728…); forward via the universal forwarder to Splunk.
- **SIEM:** Splunk as the aggregation point; a few high-value saved searches (new local admin, canary hit, auth to a locked account) beat a hundred noisy dashboards.
- **CCDC note:** stand this up in Phase 2 *before* deception, so the traps in Phase 3 have somewhere to scream.

### 3.10 Egress control — **P2**
- **Principle:** unexpected *outbound* is the C2 signature; watch it even if you cannot block it.
- **Linux (reference §5.7):** containers normally egress only to DNS/HTTP/HTTPS/NTP; a new outbound SYN to any other external port is logged `[CONTAINER OUT] …` (rate-limited, scoped to the external interface, above Docker's `RETURN`, re-installed after Docker restarts).
- **Windows:** Windows Firewall outbound logging; alert on beaconing patterns via Sysmon network events.
- **CCDC note:** combine with DNS sinkholing (§4.5) — see the beacon, then dead-end it without tipping the attacker.

### 3.11 Backups, rollback & break-glass — **P1**
- **Principle:** every change reversible; every service restorable; always a way back in.
- **Linux (reference §5.8):** timestamped config backups before each change (`*.bak-<ts>`), DB dumps before patching, previous container images tagged `:pre-update` for instant rollback, provider console as break-glass.
- **Windows/AD:** system state / AD backups; VSS snapshots; a documented DC recovery path.
- **CCDC note:** the team that can *revert* a bad change in seconds outscores the team that is afraid to make changes.

---

## 4. Deception & trap catalog

**Design principle (from the reference box and the trap playbook):** *make reconnaissance expensive and noisy for the attacker, while every trip is logged for the defender.* Route every tripwire to **one** place (a central trip log / SIEM index) so a single rate-limited notifier can watch it. Deception is Phase 3 — it multiplies the value of the observation you set up in Phase 2.

### 4.1 Trap ports / port-trap honeypot
Ports you run **nothing** on, so a single inbound packet is hostile.
- **Reference (log-driven, preferred):** UFW already logs every denied packet; a `fail2ban` filter matches `[UFW BLOCK] … DPT=<trap port>` and bans the source instantly (all-ports, weeks) via ipset. No extra listener, no daemon to crash. Trap set excludes real services and allowlists operator/front-end/mesh IPs.
- **Playbook (listener-based):** a `nc -l` loop on e.g. 1433/3389 logging every hit. Simpler, but one process per port and it *accepts* — prefer the log-driven approach where you already have firewall logging.
- **Portability:** Windows — a firewall "block + log" rule on unused ports feeding a Sysmon/Security alert.

### 4.2 SSH tarpit (endlessh)
A tarpit on the port every bot targets (22): dribbles an endless SSH banner so scanners hang for minutes. Real admin is elsewhere (§3.4). The reference box parses the tarpit and reports offenders to an external reputation service. **Value:** wastes attacker/bot time for free and turns the noisiest port into a sensor.

### 4.3 Web scanner tarpit
Two implementations of one idea — punish tools like Gobuster/Dirb/Nikto that crawl for `/wp-login`, `.env`, `/phpmyadmin`, etc.
- **Reference (slow-drip):** an nginx regex `location` matches attack paths no real visitor requests and returns a **rate-limited** decoy (`limit_rate`), capped per real-client IP (`limit_conn`, keyed on the binary remote address so a flood cannot exhaust workers); the real IP is logged to a scanner log. Never matches real app routes/APIs/assets. No auto-ban wired host→container (fragile coupling) — the tarpit *is* the punishment; the log drives a manual block.
- **Playbook (recursive loop):** a `trap.php` that returns `200 OK` with a link to a fresh random folder, so recursive crawlers loop forever and bloat memory until they crash, appending the scanner IP to a list.
- **CCDC note:** highest-value, lowest-risk trap on a graded web host — real users never hit these paths.

### 4.4 Canary tokens & files
Passive bait that screams the instant it is touched — the highest-confidence signal you can plant.
- **Reference (host-native):** decoy files (a fake cloud-credentials file, a fake database dump) watched by `auditd` (`canary_read` key) so a **read** alerts — you catch a snooper who merely *finds* the bait. Plus a **planted SSH key** authorized on no account; because sshd logs at VERBOSE, any *use* of it logs the fingerprint, which a `fail2ban` jail matches and bans for a year. Two layers: find *and* use.
- **Playbook (cross-platform):** `Passwords_2026.docx` on Windows shares/desktops; unique tracking URLs (CanaryTokens) embedded in unreferenced Gitea markdown / config files; web bugs on internal config URLs — each records the internal IP, user-agent, and timestamp on trip.
- **Portability:** Windows — a decoy file + a Security "object access" audit ACL (event 4663), or a Thinkst CanaryToken. Place bait wherever an attacker looks for creds: shares, home dirs, repos, backups, wikis.

### 4.5 Honey-accounts
A decoy admin (`backup_admin`, `svc-sql-backup`, …) that no real person uses, wired to alert on **successful authentication** — near-zero false positives.
- **Linux:** a login-triggered hook (shell profile) POSTs an alert with the source IP the millisecond someone logs in.
- **Windows/AD:** a tempting-named disabled-until-needed account (or an enabled decoy with a logon script) whose 4624 fires a high-priority SIEM alert; a Kerberoast-bait service account with an SPN is a well-known variant.
- **CCDC note:** treat any honey-account hit as a confirmed intrusion — it is the cleanest alert you will get.

### 4.6 DNS sinkholing (C2 dead-ending)
When you identify a C2 domain, **redirect** its resolution to loopback / a capture host instead of firewall-blocking it — a block *tells* the attacker they are caught; a sinkhole silently strands the implant.
- **Per-host:** append the domain → `127.0.0.1` in `/etc/hosts`.
- **Network-wide:** RPZ / conditional forwarding on the AD DNS server, or DNS host-overrides on the perimeter firewall, to sinkhole across all assets at once.

### 4.7 Port knocking (stealth admin) — see §3.4
Firewall drops all inbound to the admin port until a secret knock sequence opens it for the sender's IP. Under an Nmap sweep the port reads **closed/filtered**, denying the attacker an easy vector. Trade-off noted in §3.4.

### Trip-log pattern
Every trap above writes one line to a **central trip log** (reference: `/var/log/security-trip.log`, tight perms, rotated) — or a dedicated SIEM index. One place to tail means one rate-limited notifier can cover every trap without spamming you.

---

## 5. Reference implementation — the Linux server profile

The proven source for Labyrinth's Linux roles. Each control below is production-verified; the capability map (§3) shows how it generalizes. This is the "known-good" the automation reproduces.

| # | Control | What it is | Labyrinth role |
|---|---|---|---|
| 5.1 | Identity/SSH | key-only on a moved port, `AllowUsers` allowlist, no root login, VERBOSE logging, weak crypto removed (drop-in file) | `ssh` |
| 5.2 | Host firewall | UFW default-deny + medium logging; `DOCKER-USER` filtering for container ingress/egress | `firewall` |
| 5.3 | Dynamic bans | fail2ban backed by **ipset** (flat ruleset at scale), jails on both `INPUT` and `DOCKER-USER` | `fail2ban` |
| 5.4 | Deception | endlessh tarpit, trap-port honeypot, canary key + decoy files, central trip log | `deception` |
| 5.5 | Containers | `compose-guard` admission control; cap-drop-ALL, non-root UIDs, `no-new-privileges` | `containers` |
| 5.6 | Web edge | reverse proxy, real-client-IP, TLS + headers, per-site logs, scanner tarpit | `nginx_edge` |
| 5.7 | Egress logging | systemd-managed `DOCKER-USER` LOG rules for anomalous container egress | `egress_log` |
| 5.8 | Audit + review | auditd rule-keys incl. `canary_read`; a cached **MOTD security dashboard**; toolbox aliases | `audit_motd` |
| 5.9 | Patch/backup | monthly container patching with `:pre-update` rollback tags; timestamped config backups | `patching` |

> The MOTD dashboard (5.8) is worth stealing for every profile: a login-time, cached, at-a-glance security panel — triage summary, canary banner, fail2ban/tarpit scoreboard, watched-file changes — so an operator spots an anomaly the second they log in. See appendix A for the file inventory.

---

## 6. Labyrinth architecture

### 6.1 Tooling
**Ansible** — idempotent, agentless, check-before-change, re-runnable. Linux over SSH; Windows over WinRM (`ansible.windows` / `community.windows`); network appliances mostly via templated config + documented manual steps (vendor APIs vary — automate what is safe, document the rest).

### 6.2 Layout
```
ansible/
├── inventory/
│   ├── hosts.yml              # hosts grouped by profile
│   └── host_vars/<host>.yml   # per-host: profile, admin IPs, users, domains, trap set
├── group_vars/
│   ├── all.yml                # global invariants
│   ├── linux.yml / windows.yml
│   └── <profile>.yml          # linux_web, windows_dc, ...
├── roles/                     # one role per capability (§3 / §5)
│   ├── identity/ ssh/ firewall/ fail2ban/ deception/
│   ├── containers/ nginx_edge/ egress_log/ audit_motd/ patching/
│   └── win_base/ win_audit/ win_firewall/ ...
└── playbooks/
    ├── lockout.yml            # Phase 0–1: creds, accounts, default-deny, admin hardening
    ├── observe.yml            # Phase 2: auditd/Sysmon + SIEM forwarding
    ├── deceive.yml            # Phase 3: traps, canaries, honey-accounts, sinkholes
    └── sustain.yml            # health checks, patching, backups
```

### 6.3 Profiles
Classify each host and apply only the roles that fit:

| Profile | Example host | Roles |
|---|---|---|
| `linux_server` | Any Linux server without a web role | identity, ssh, firewall, fail2ban, deception, egress_log, audit_motd, patching |
| `linux_web` | Linux web or webmail server | + nginx_edge, containers (scanner tarpit is P1 here) |
| `windows_member` | Windows member servers and workstations | win_base, win_firewall, win_audit, honey-account, canary |
| `windows_dc` | Domain controller with DNS | + KRBTGT rotation, AD hardening, DNS-RPZ sinkhole |
| `siem` | SIEM server | identity, ssh, firewall + ingest config (the destination, hardened but light) |
| `appliance` | Router or firewall appliance | templated config + manual runbook (creds, default-deny, mgmt-plane lockdown) |

### 6.4 Phase playbooks = the doctrine, executable
`lockout.yml` is the panic button: run it against **every reachable host** to reset creds, lock accounts, and default-deny in one pass. Then layer `observe → deceive → sustain`. This is what makes the doctrine (§1) a single command instead of a memory test.

### 6.5 Secret handling
Ship **placeholder templates** only (`.env.example`, cert paths, token *names*). Real values come from **Ansible Vault** or a secrets manager at run time, supplied out-of-band. Labyrinth provisions the *shape*; the operator supplies the values. **No real credential, key, or env file ever enters the repo.**

### 6.6 Speed & safety discipline
- **Idempotent + check-mode first** — dry-run (`--check --diff`) before you commit, especially near scored services.
- **Reversible** — every role backs up what it changes (timestamped) and documents its rollback.
- **Tested on throwaway VMs** (or the CCDC practice image) before you trust it live.
- **Fail-safe ordering** — never lock your own admin path before the new one is proven; keep the provider/console break-glass.

---

## 7. Priority scorecard

Triage under a clock. Do P0 everywhere before P1 anywhere.

| Control | Impact | Effort | When |
|---|---|---|---|
| Rotate all creds / lock accounts (§3.1) | ★★★★★ | Low | P0 |
| Default-deny firewall (§3.3) | ★★★★★ | Low | P0 |
| Remote-admin hardening (§3.2) | ★★★★ | Low | P0/P1 |
| Move/hide admin (§3.4) | ★★★ | Med | P1 |
| Central logging + auditd/Sysmon (§3.9) | ★★★★ | Med | P1 |
| Service minimization + targeted patch (§3.6) | ★★★ | Med | P1 |
| Web edge + scanner tarpit (§3.8, §4.3) | ★★★★ | Low | P1 |
| Backups / rollback / break-glass (§3.11) | ★★★★ | Low | P1 |
| Canary tokens & honey-accounts (§4.4–4.5) | ★★★★★ | Low | P2 |
| Dynamic banning / ipset (§3.5) | ★★★ | Med | P2 |
| Container least-privilege (§3.7) | ★★★ | Med | P2 |
| Egress logging + DNS sinkhole (§3.10, §4.6) | ★★★ | Med | P2 |
| Port knocking (§4.7) | ★★ | Med | P3 |

*Canaries and honey-accounts are P2 by sequence (they need §3.9's logging first) but are the highest-confidence detections you will deploy — get to them.*

---

## 8. Verification & rollback

Portable runbook — confirm each control actually took, and know how to undo it.

| Control | Verify (Linux reference) | Rollback |
|---|---|---|
| SSH posture | `sudo sshd -T \| grep -Ei 'port\|permitroot\|password\|allowusers\|loglevel'` | remove drop-in, `sshd -t`, reload |
| Firewall | `ufw status verbose`; **test the real ingress path**, incl. `DOCKER-USER` | disable rule / restore ruleset backup |
| Dynamic bans | `fail2ban-client status`; `ipset list -n`; `iptables -S DOCKER-USER \| grep match-set` | stop jail; flush set |
| Trap ports | fire a packet at a trap port from a non-allowlisted IP → expect a ban | remove filter/jail |
| Canary (files+key) | read a decoy → expect an audit event; offer the planted key → expect a fingerprint match + ban | remove audit rule / jail |
| Scanner tarpit | `curl -m5 https://host/.env` → should hang, log the IP | remove `location` block, validate, reload |
| Egress logging | make an odd outbound from a container → expect `[CONTAINER OUT]` | remove LOG rules / disable unit |
| Central logging | confirm events arriving in Splunk from each host | n/a |
| Service health | curl/health-check every scored service after each change | revert the change; restore `:pre-update` image / config backup |

*Always validate config that fronts a scored service before reloading (e.g. `nginx -t` before `nginx -s reload`), and keep a break-glass path open until the new access path is proven.*

---

## Appendix A — Linux reference file inventory (the proven source)

Non-secret map of where each control lives on the reference box, for porting into the Ansible roles:

```
/etc/ssh/sshd_config.d/10-hardening.conf          SSH hardening drop-in
/etc/ufw/ (user.rules, after.rules)                host firewall + medium logging
/etc/fail2ban/jail.local                           jails + ignoreip (operator/front-end/mesh)
/etc/fail2ban/action.d/ipset-allports-2chain.conf  ipset ban action (INPUT + DOCKER-USER)
/etc/fail2ban/filter.d/{honeypot,canary-key}.conf  trap-port + planted-key filters
/etc/audit/rules.d/hardening.rules                 auditd watches (incl. canary_read)
/usr/local/sbin/compose-guard                      container admission control
/usr/local/sbin/trip-log.sh                        central tripwire logger
/usr/local/sbin/container-egress-log.sh            container egress LOG rules
/etc/systemd/system/container-egress-log.service   re-install egress rules after docker
/usr/local/bin/motd-collector.sh                   cached MOTD security snapshot (root cron)
/etc/profile.d/motd.sh                             MOTD dashboard renderer (login-time)
/var/www/nginx/{nginx.conf,default.conf}           reverse proxy, real-IP, scanner tarpit
/var/log/security-trip.log                         central trip log (tight perms, rotated)
```

## Appendix B — trap playbook → Labyrinth mapping

| Playbook technique | Labyrinth home |
|---|---|
| Directory-busting loop (`trap.php`) | `nginx_edge` scanner tarpit (§4.3) — reference uses slow-drip; loop is an alternative |
| Canary tokens / `Passwords_2026.docx` / Gitea beacons | `deception` canaries (§4.4) — host-native auditd + Thinkst tokens |
| Honey-account `.bashrc` webhook + `nc` port trap | `deception` honey-accounts (§4.5) + trap ports (§4.1, prefer log-driven) |
| DNS sinkholing (`/etc/hosts`, RPZ, firewall DNS overrides) | `deceive.yml` sinkhole tasks (§4.6) |
| Port knocking (`knockd`) | `ssh`/`firewall` optional stealth-admin (§3.4, §4.7) |

## Appendix C — CCDC notes & glossary

- **Assume breach from the start** — footholds and known creds exist before you touch anything; §1 Phase 0 is non-negotiable.
- **Scored services are sacred** — a change that drops a graded service costs points now; reversibility (§2.7, §3.11) is a scoring strategy, not just hygiene.
- **Confidence-ranked alerts** — canary/honey-account hits are near-certain; work them before anomaly noise.
- **Deception ≠ blocking** — sinkhole and tarpit *waste and watch*; blocking *warns*. Prefer the quiet option when you want intel.
- **KRBTGT** — the AD account whose hash signs Kerberos tickets; rotate twice to kill golden tickets.
- **ipset** — kernel hash-set that lets one firewall rule match thousands of IPs; keeps a tarpit-fed banlist flat.
- **RPZ** — DNS Response Policy Zone; server-side sinkholing across every client at once.

---
*Base documentation for Labyrinth. No secrets, environment values, or private keys are reproduced.*
