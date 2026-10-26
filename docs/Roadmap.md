# Labyrinth Roadmap

This is the build order for the rest of Labyrinth, highest priority first. The design specs in `docs/design/` say *what* each part does; this page says *in what order* the parts are built and what each branch must deliver. It holds no dates or event details.

## Priority order

Work goes top to bottom. A stage starts when the one above it is merged, except where a row says otherwise.

| # | Work | Why it comes here |
|---|---|---|
| 1 | **P0 lockout modules** (stage 4) | They take control back in the first minutes. Everything else assumes the attacker has been locked out. |
| 2 | **Remote checks** (stage 5) | Read-only `remote plan` shows every host's plan from one hardened control node without changing anything. Changes still run locally on each host; `remote apply` follows once the read-only part has run safely in the lab. |
| 3 | **Observe and checkpoints** (stage 6) | Without logging, the later traps and checks cannot be seen. Checkpoints guard the scored services from here on. |
| 4 | **Sustain and hardening** (stage 7) | Service packs, patching and the flaw tracker keep scored services up and close known holes. |
| 5 | **Reporting and cleanup** (stage 8) | Incident reports earn points, and cleanup must work before the tool is used at an event. |
| 6 | **Deceive and extras** (stage 9) | Traps need the logging from priority 3 to be worth anything. |
| — | **Appliance runbooks** | Templates only, with no code dependency. Done whenever a person has time. |

## 1. Where it stands

**Built:**
- the core library in bash and PowerShell: logging, the run manifest with backup and restore, safety gates, the protected set, break-glass, the run lock, revert timers, the release check, and the http, dns and banner probes;
- both runners, with `plan`, `apply`, `keep`, `rollback`, `runs`, `probe`, `help` and `version`;
- from stage 3: platform facts, the firewall adapter, the quarantine helper, approval items with `--approve` / `-Approve` and pre-approval rules (`pre-approved`), the six shipped profiles (empty until their modules are built), and new passwords shown once for the offline record;
- the operator manual, the compatibility suite and CI.

**Merged since stage 3:** the framework hardening (pull request 38), which keeps changes that only take access away once they verify, checks Labyrinth's own files against the release before running them, and makes configuration errors and recovery hints say exactly what to do; and the Linux revert timer that survives a restart (pull request 40).

**Not built:**
- real modules (`phases/*/modules` holds only placeholders);
- `report/`, `core/seed/` and `vendor/`;
- the planned commands: `seal`, `reseal`, `checkpoint`, `backup`, `restore` and `remote`.

## 2. Rules for every branch

- One component per branch, named `phase-<n>/<name>`, or `docs/<name>` for documentation only.
- Re-read the spec first. If it is wrong or vague, fix it in the same branch before writing code, and say why in the commit message.
- Write tests first, from the spec's acceptance-test list. Every module gets the negative test: protected accounts and scored services are untouched.
- Make the change in bash and PowerShell together wherever the spec covers both platforms.
- `tests/lint/guard.sh` and CI must be clean. A real-host acceptance test names where it runs: a CI runner or the lab (`docs/lab/README.md`).
- A new command or option goes into both runners, the manual and both test suites in one commit. The compatibility suite is never edited to make a change pass.

## 3. Build stages

The build stages are numbered on from the stages already done: 0 (foundations), 1 (the core) and 2 (the command line). Branches are named `phase-<stage>/<name>`. A build stage is not a run phase: the run phases are lockout, observe, deceive and sustain, the word in `labyrinth plan <phase>`, and modules of one run phase are built across several stages.

### Stage 3: groundwork that modules need (done)

Built on one branch, `phase-3/groundwork`, one commit per part, and hardened on `phase-3/framework-hardening`. The parts are listed by the branch name each would have had.

| Branch | Spec | Delivers | Done when |
|---|---|---|---|
| `phase-3/platform-detect` | 19 | Detects the OS family, firewall backend (UFW, firewalld, nftables, iptables, Windows Firewall), init system and package manager, in `core/platform/`; works without `jq`, `python3` or `curl` | Fixture tests pass for each supported distribution and for Windows |
| `phase-3/firewall-adapter` | 19, 01 | One interface across the five backends (UFW, firewalld, nftables, iptables, Windows Firewall): snapshot, scoring allowlist first, then deny, then restore | The allowlist is in place before any deny rule; restore puts back the exact snapshot (unit tests in CI; each backend on its lab host) |
| `phase-3/profiles` | 00, Blueprint §6.3 | The shipped profiles: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc`, `appliance` | A shipped profile lists only modules the release has, fitting its platform; each module is added to its profiles in the commit that builds it (`tests/profiles/`) |
| `phase-3/quarantine` | 17 §5 | A core quarantine helper for files, cron lines, units, scheduled tasks, services, registry values and WMI subscriptions | Rollback restores each item byte for byte; nothing is deleted |
| `phase-3/approval-flow` | Conventions §3.1 | Approval items with fingerprints, `category:` approval at the prompt, and `--approve` / `-Approve` | An unapproved item and an item changed since the plan are left alone |
| `phase-3/offline-record` | 05 | Hand-over of new passwords without writing them to disk | No secret appears in logs, the manifest or backups |

### Stage 4: P0 lockout

Each module ships its read-only `check` and `plan` first. The branches are listed in the order a first-minute run uses them (design 01, section 6), so each one can be tried in the lab behind the ones before it.

| Branch | Spec | Delivers |
|---|---|---|
| `phase-4/bootstrap` | 07 §5.2 | Release archives with their SHA-256 in the release notes, and the manual's steps to fetch, check and unpack one with each host's own tools, for events with no control node |
| `phase-4/baseline-inventory` | 04, 05 §2 | Read-only inventory and the dependency map of each scored service, including the addresses each one connects out to, which later modules and the outbound allowlist rely on |
| `phase-4/vuln-check` | 21 §3 | The read-only finding and ranking of known flaws: host security data, web apps on disk, the dated known-exploited snapshot, and WES-NG on Windows. Built early so the team sees what is exposed from the first build |
| `phase-4/credentials` | 05 | Rotation from an explicit list; password and lockout policy (§2.2); the `scored-admin` class, its seed-derived password and the change list shown once (§2.4) |
| `phase-4/ssh` | 05 §4 | Remote-admin hardening and the SSH key registry |
| `phase-4/sessions` | 01 §6.2 | Ending intruder sessions outside the protected set |
| `phase-4/firewall` | 01 §6.1, 11, 19 §5 | Default-deny inbound and outbound through the adapter, under a revert timer. The adapter gains an outbound default and the `outbound-allow` list, on every backend, the gate that passes with no scoring allowlist when every scored service is allowed from any source, and the refusal of a narrower source on a scored port |
| `phase-4/packages` | 20 | Installing the profile's packages behind the lockdown: source order, lock wait, simulation check, services kept stopped, `package_install` entries; vendored tools and pinned downloads with the core download helper |
| `phase-4/restore-points` | 14 | `backup <service>` and `restore <service>`, so a restore point exists before the sweep and before any patch |
| `phase-4/persistence-sweep` | 17 | Classification, automatic quarantine of high-confidence items, and limits on who can schedule jobs |
| `phase-4/accounts` | 05 §6 | Locking accounts from a list; deletion only after approval and a passing checkpoint |
| `phase-4/win-base` | 11 §3, §3.3 | Windows protocol and credential settings, including SMBv1 and Print Spooler |
| `phase-4/ad-readonly` | 11 §3.1, §3.2 | Domain read-only checks and the printed domain checklist |
| `phase-4/first-minute` | 01 §6, §6.3 | The first-minute bundle in its order (lock down, install, sweep, reopen outbound), first-minute runs with every answer on the command line, ring order and test hosts |

### Stage 5: remote mode

Local mode is the standard, so the lockout already works on every host without this stage. Remote mode is built read-only first, from a hardened control node (Blueprint §6.1), and `remote apply` only once `remote plan` has run safely in the lab.

| Branch | Spec | Delivers |
|---|---|---|
| `phase-5/remote-plan` | 00 §5, 07 §5 | `remote plan --group <group>` over SSH and PowerShell remoting: it copies and checks the release, runs the local `plan`, and brings back the plans and logs. It changes nothing |
| `phase-5/remote-apply` | 00 §5 | `remote apply --group <group>`, after `remote plan` has run safely in the lab: it runs the local `apply` and brings back logs and manifests. It collects approval items from the plan and passes each host its own `--approve` entries. It copes with losing the connection while credentials and SSH settings rotate. It keeps a host's run only when it can still log in over the admin path and no scored service that passed before the run fails after it; otherwise the timer reverts that host, except the modules kept once they verified (design 00, section 5) |

### Stage 6: observe and checkpoints

| Branch | Spec | Delivers |
|---|---|---|
| `phase-6/seal` | 04 §6 | `seal`, `reseal --reason`, and integrity findings against the sealed baseline |
| `phase-6/checkpoint` | 13 | The read-only `checkpoint` summary; the sweep re-runs in report mode; the known-flaw section reads the tracker once stage 7 builds it |
| `phase-6/probes` | 13 §3.1 | The `http` path and the probes that log in (`imap`, `ssh`, `smb`, `sql`, `winrm`, `siem`), with a probe account typed at run time and never stored |
| `phase-6/outside-probe` | 13 §3 | `probe` from a machine outside the team's network, limited to the `own-ranges` list |
| `phase-6/health-monitor` | 13 §3–§5 | The scheduled job on the control node: probes of every scored service with state-change alerts and rollback candidates, firewall drift re-applied from the seal, and scheduled checkpoints that alert once on each new finding |
| `phase-6/linux-audit` | 10 | auditd, installed by `packages`, with the vendored rule set |
| `phase-6/win-audit` | 10 | Audit policy, script block logging, log sizes, and Sysmon from its pinned download |
| `phase-6/log-forwarding` | 10 §4 | syslog forwarding on Linux; on Windows, the forwarder already present or the HEC script; saved searches, including the outbound log rule |

### Stage 7: sustain and hardening (P1)

| Branch | Spec | Delivers |
|---|---|---|
| `phase-7/service-packs-web` | 18 | nginx, Apache and IIS; ModSecurity with the Core Rule Set in detection-only mode, and approved blocking rules for one flaw (§6.1) |
| `phase-7/service-packs-mail-dns` | 18 | Postfix, Dovecot (POP3 and IMAP), webmail, BIND, and Windows DNS on servers that are not domain controllers |
| `phase-7/service-packs-data` | 18 | MySQL or MariaDB, SQL Server, SMB shares, WinRM, vsftpd, and the host settings library, including the `pkexec` setting |
| `phase-7/siem` | 10 §7 | The SIEM's own hardening: admin password (a `scored-admin` where scored), ports by whether they are scored, and `splunkd` off root after approval |
| `phase-7/service-reduction` | 15 §3 | Stopping services from an explicit candidate list |
| `phase-7/patching` | 15 §4, 20 §5 | Applying an approved security update, one package at a time, after a restore point; the `security-update` category, which pre-approval rules may cover, so a first-minute run applies a named scored package's update; Windows patching checklist |
| `phase-7/vuln-tracker` | 21 §3.2, §4, §5 | The version scan of the team's own hosts, the tracker and its states, and the mitigation catalog, with automatic mitigations applied through the modules that own each setting |
| `phase-7/service-replacement` | 22 | Off by default: the `ALLOW_SERVICE_REPLACE` and `ALLOW_CONTAINERS` keys, the data-preservation inventory and comparison, build beside, switch under a revert timer, and the container controls. Built last in the stage, and only rehearsed where an event allows it |
| `phase-7/win-tier3` | 10 §5, 11 | LDAP signing, lockout settings, the per-host abused-tool block, the KRBTGT reset (two resets with a replication check between, §5.1), and the remaining approval items |

### Stage 8: reporting and cleanup

| Branch | Spec | Delivers |
|---|---|---|
| `phase-8/report` | 02 | The incident report builder, fed by quarantine evidence, integrity findings and the tracker's closed flaws |
| `phase-8/cleanup-integrity` | 07 | Cleanup, and the signature check on the control node. Each host's own release check (07 §5.1) is part of the framework hardening |

### Stage 9: deceive and extras (P2)

| Branch | Spec | Delivers |
|---|---|---|
| `phase-9/seed` | 03 | Event seed derivation in `core/seed/` |
| `phase-9/canaries` | 03, 09, 11 | Canary files and honey-accounts |
| `phase-9/maze` | 09 | The deception maze, CVE decoys and the web tarpit |
| `phase-9/dynamic-bans` | 12 | Bans in both directions that never touch the never-ban list or the scoring allowlist; fail2ban where installed; approved outbound bans (§6.1) |
| `phase-9/status-feed` | 06 | The status feed and login banner |
| `phase-9/dns-sinkhole` | 10 §5, Blueprint §4.6 | The DNS sinkhole (person-run on a domain controller). Outbound filtering moved to `phase-4/firewall` and the outbound log rule to `phase-6/log-forwarding` |

### Any time: appliance runbooks

`phase-x/appliance-runbooks` (design 16) holds templates and runbooks only. It depends on nothing above.

## 4. Settled decisions

### 4.1 Approvals, logs, build order and tests

| Question | Decision | Recorded in |
|---|---|---|
| How are approvals given? | Typed at the prompt by default. Each item carries a fingerprint from the plan, and `--approve` passes approvals without the prompt for remote mode. An item that changed since the plan is refused. | Conventions §3.1 |
| How do Windows hosts ship logs? | The Splunk universal forwarder where the host already has one; otherwise a PowerShell script posting to Splunk's HTTP Event Collector. No forwarder is installed. | Design 10 §4, design 00 §9 |
| How is Labyrinth run, and when is remote mode built? | Local mode is the standard: each host's operator runs it on that host. Remote mode comes after the P0 lockout works locally, read-only `remote plan` first, and `remote apply` only once that has run safely in the lab (stage 5). | Blueprint §6.1, this page, design 00 §5, §9 |
| Where do real-host tests run? | CI runners for Ubuntu, Windows Server and a single domain controller; a local lab for everything else, before each release. | Conventions §9, `docs/lab/README.md` |
| Are the Windows registry values right? | Checked against Microsoft's documentation. Netlogon enforcement is now report-only, because patched domain controllers enforce it anyway. LSA protection is offered only in a form that rollback can remove. LDAP and SMB signing defaults on Windows Server 2025 are reported. The removal of the PowerShell 2.0 engine is noted. | Design 11 §3–§3.3, design 10 |

### 4.2 Installs, the first minute and automation

| Question | Decision | Recorded in |
|---|---|---|
| May Labyrinth install software? | Yes, public software only, after the first-minute lockdown, through the `packages` module: the host's repositories, an event mirror or proxy, or a pinned public download. Rule 5.6.4's example is cloud services and cloud processing, which installing a package is not. Never a private source (Rule 5.2), a new repository (apart from EPEL, design 20 §3) or a full upgrade. | Design 20, CLAUDE.md |
| What does Labyrinth need from the network? | Only its own public release. Packages, pinned downloads such as Sysmon, EPEL and refreshed lists of known flaws are optional extras: each runs after the lockdown when its source answers, and is reported as skipped otherwise. | Blueprint §6.1, design 20 |
| What runs in the first minute? | Lock down with what the host has (rotate, keys, sessions, default-deny inbound and outbound), then install, then sweep, then reopen outbound to the normal allowlist. | Design 01 §6, §6.1 |
| How does a first-minute run avoid prompts? | The existing options answer them (`--confirm-group`, `--break-glass`, `--approve`), and pre-approval rules cover the items the team approved before the event. Revert timers, probes, the scoring allowlist and the protected set stay. No command-line change is needed. | Design 01 §6.3 |
| Can a ban block outbound traffic? | Yes. Every ban drops the address in both directions; an address from the unusual-outbound search is banned outbound only after approval. | Design 12 §6.1 |
| How are known flaws handled? | Found and ranked locally, tracked until closed, and closed by mitigation or patch. A scored service is never turned off to close a flaw. | Design 21 |
| Are design choices labeled as rules? | No longer. Watching abused tools, manual Group Policy, manual DNS on the domain controller, the candidate list and keeping login shells are design choices, and the docs now say so. | CLAUDE.md, Blueprint |
| How are items approved before the event? | `--approve` needs a fingerprint from a plan, so it could not carry them. A module declares the categories that are safe to pre-approve (`pre_approvable`), and the run-time `pre-approved` file names the items or categories the team approved. Each item is still checked against this run's plan, the probes and the revert timer. | Conventions §2.2, §3.1; design 00 §4 |
| Which more steps run without a person? | Pre-approved security updates for named scored packages, default application passwords and settings tested on the event's versions; keeping a host's run in remote mode once the admin login works and no scored service regressed; scheduled read-only checkpoints that alert on new findings; and the KRBTGT reset, now carried out by Labyrinth after approval. Deleting accounts, restores, ordinary users' passwords, Group Policy, DNS on the domain controller, appliances, medium-confidence outbound bans and app settings that change what scoring sees stay with a person. | Designs 00 §5, 05 §2.1, 11 §5.1, 13 §5, 15 §4, 18 §4 |

### 4.3 Scoring, sources and service replacement

| Question | Decision | Recorded in |
|---|---|---|
| Are admin accounts ever scored? | Events differ. None is assumed unscored. An admin account a check logs in with is a `scored-admin` account: rotated in the first minute, with its new password in a `username,password` change list shown once. | Designs 01, 05 §2.4 |
| May a scored port be limited by source? | No. Some events penalize it, and officials and simulated users come from addresses nobody can list. Scored ports are open to every source and hardened in place; a ban blocks one address on every port. | Designs 01 §6.1, 12, 19 §5 |
| Is the scoring allowlist still required? | Only where given. The gate passes when every scored service is allowed from any source. | Designs 01 §7, 19 §5 |
| Do probes log in? | Where the operator gives a probe account at run time; it is never stored. Otherwise they connect only, and the plan says so. | Design 13 §3.1 |
| May a scored service be rebuilt or containerized? | Only where an inject or the local competition rules allow it (Rule 4.14), through design 22, off by default and named in `event.conf`. | Design 22 |
| Which rule numbers apply? | The rules page has ten sections: misleading scoring is 9.3, incident reports 9.4, materials 8.5. | Blueprint, design README |

## 5. Open: questions for competition officials

Short questions, each answerable in a line. The team sends them with the tool's declaration and records each answer in the spec it affects.

1. **Configuration after the freeze.** The frozen tool reads a folder of event facts that we fill in at the event: scoring engine addresses, host names, account names and the list of hosts. The files hold no code and cannot add features. Is filling them in after the freeze allowed (NCCDC, 2025, Rule 5.6.2)? Design 00, section 6 and Conventions, section 2.2 are labeled *Provisional* until the answer arrives.
2. **Public packages.** After locking a host down, the tool installs a fixed list of free, public packages, such as auditd, from the host's own repositories or the event's mirror or proxy. Please confirm this is allowed (Rules 5.1, 5.2 and 5.6.4). The install feature is named in the declaration (design 20, section 2).
3. **A public vulnerability database.** Trivy's database and the CISA known-exploited catalog are public files that change daily, so they cannot be pinned by hash. All matching runs on the team's own hosts. May it be downloaded at the event? Until the answer arrives, Trivy stays out of the shipped profiles (design 21, section 6).
4. **Fetching the release at the event.** Where a host or a console reaches the internet, the operator downloads the declared release archive from its public release page and checks its SHA-256 against the value given with the declaration before unpacking it. Please confirm this is allowed (Rules 5.1 and 5.6.2) (design 07, section 5.2).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 9, 2026, from https://www.nationalccdc.org/rules.html
