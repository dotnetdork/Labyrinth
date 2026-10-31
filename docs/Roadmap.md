# Labyrinth Roadmap

This is the build order for the rest of Labyrinth, highest priority first. The design specs in `docs/design/` say *what* each part does; this page says *in what order* the parts are built and what each branch must deliver. It holds no dates or event details.

## Milestones

Work goes top to bottom. Each milestone is a GitHub milestone of the same name, and every open issue belongs to exactly one. The first usable release comes first; everything after it builds on a tool a team can already run.

| # | Milestone | What it holds | Why it comes here |
|---|---|---|---|
| 1 | **First usable release** (section 3) | The installer, automatic runs with the queue, the first-minute lockout, the Harden phase, checkpoints, the read-only checks and probes, the operator helpers, and the manual and help | With it, each host's operator can install Labyrinth, lock the host down in the first minutes, close known weaknesses, and check that scored services still pass, on Linux and Windows. |
| 2 | **Remote mode** (section 4.1) | Read-only `remote plan`, then `remote apply` | Local mode already works on every host. Remote mode lets one hardened control node check every host, read-only first. |
| 3 | **Observe and checkpoints** (section 4.2) | Seal and integrity findings, the outside probe, the health monitor, audit logging and log forwarding | Without logging, the later traps and checks cannot be seen. The sealed baseline gives checkpoints their integrity section. |
| 4 | **Sustain and hardening** (section 4.3) | SIEM hardening, service reduction, the flaw tracker, service replacement | Keeps scored services up and closes the remaining known holes. |
| 5 | **Reporting and cleanup** (section 4.4) | The incident report builder, cleanup, JSON output | Incident reports earn points, and cleanup must work before the tool is used at an event. |
| 6 | **Deceive and extras** (section 4.5) | Canaries, the maze, dynamic bans, the status feed, the DNS sinkhole | Traps need the logging from milestone 3 to be worth anything. |
| — | **Appliance runbooks** (section 4.6) | Runbook templates a person follows | Templates only, with no code dependency. Done whenever a person has time. |

## 1. Where it stands

**Built:**
- the core library in bash and PowerShell: logging, the run manifest with backup and restore, safety gates, the protected set, break-glass, the run lock, revert timers, the release check, and the http, dns and banner probes;
- both runners, with the flag-style command line: preview (`laby PHASE`), run (`-r`), keep (`-k`), undo (`-u`), `--history`, `--probe`, `-h`, `-V` and `-P` (Conventions section 3.1);
- the guided install (`install.sh`, `install.ps1`), which puts `labyrinth`, `laby` and the manual where the system finds them and sets up the data root;
- the groundwork below: platform facts, the firewall adapter, the quarantine helper, approval items with `--approve` / `-Approve` and pre-approval rules (`pre-approved`), the six shipped profiles (empty until their modules are built), and new passwords shown once for the offline record;
- the framework hardening, which keeps changes that only take access away once they verify, checks Labyrinth's own files against the release before running them, and makes configuration errors and recovery hints say exactly what to do, and the Linux revert timer that survives a restart;
- the operator manual and CI.

**Not built:**
- real modules (`phases/*/modules` holds only placeholders);
- `report/`, `core/seed/` and `vendor/`;
- the planned commands: `seal`, `reseal`, `checkpoint`, `backup`, `restore` and `remote`, which take the flag style, with names decided when each is built (Conventions section 3.3);
- the Harden phase, the rest of the command line (bare `laby` status, `--manual`, `-y`, `--no-revert`, the queue, the login check), automatic runs and the short output (Conventions section 3.3).

The groundwork that modules need was built on one branch, `phase-3/groundwork`, one commit per part, and hardened on `phase-3/framework-hardening`. The parts are listed by the branch name each would have had.

| Branch | Spec | Delivers | Done when |
|---|---|---|---|
| `phase-3/platform-detect` | 01 | Detects the OS family, firewall backend (UFW, firewalld, nftables, iptables, Windows Firewall), init system and package manager, in `core/platform/`; works without `jq`, `python3` or `curl` | Fixture tests pass for each supported distribution and for Windows |
| `phase-3/firewall-adapter` | 01, 03 | One interface across the five backends (UFW, firewalld, nftables, iptables, Windows Firewall): snapshot, scoring allowlist first, then deny, then restore | The allowlist is in place before any deny rule; restore puts back the exact snapshot (unit tests in CI; each backend on its lab host) |
| `phase-3/profiles` | 00, Blueprint §6.3 | The shipped profiles: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc`, `appliance` | A shipped profile lists only modules the release has, fitting its platform; each module is added to its profiles in the commit that builds it (`tests/profiles/`) |
| `phase-3/quarantine` | 06 §5 | A core quarantine helper for files, cron lines, units, scheduled tasks, services, registry values and WMI subscriptions | Rollback restores each item byte for byte; nothing is deleted |
| `phase-3/approval-flow` | Conventions §3.1 | Approval items with fingerprints, `category:` approval at the prompt, and `--approve` / `-Approve` | An unapproved item and an item changed since the plan are left alone |
| `phase-3/offline-record` | 04 | Hand-over of new passwords without writing them to disk | No secret appears in logs, the manifest or backups |

## 2. Rules for every branch

- One component per branch. The branch name is the one in the tables below, such as `phase-4/firewall`, or `docs/<name>` for documentation only. The number in a name is the build stage of an earlier plan, kept so that existing branches and commits still match.
- Start from the issue: read the links in its "Read first" section, then the spec. If the spec is wrong or vague, fix it in the same branch before writing code, and say why in the commit message.
- Write tests first, from the spec's acceptance-test list. Every module gets the negative test: protected accounts and scored services are untouched.
- Make the change in bash and PowerShell together wherever the spec covers both platforms.
- `tests/lint/guard.sh` and CI must be clean. A real-host acceptance test names where it runs: a CI runner or the lab (`docs/lab/README.md`).
- A new command or option goes into both runners, the manual and both test suites in one branch.

## 3. The first usable release

Built in seven steps, in order: each step needs the ones before it. Inside a step, the rows are in build order, and the issues' "blocked by" links say what each one waits for. A module in this release is done when:

- its Linux and Windows versions both pass their tests in CI, the real-host tests included, wherever the spec covers both platforms;
- its manual entry, its `-h` page and its module help page (`laby -h MODULE`) are written;
- it passes its acceptance tests in the lab before the release (`docs/lab/README.md`).

### Step 1: install and release

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #65 | `phase-4/command-line` | Conventions §3.1, §3.3, 00 §5.1 | The rest of the command line: bare `laby` (the host's status), `--manual`, `-y` and `--no-revert`. The guided install is built |
| #71 | `phase-4/bootstrap` | 21 §5.2 | Release archives with their SHA-256 in the release notes, and the manual's steps to fetch, check and unpack one with each host's own tools, for events with no control node |

### Step 2: read-only groundwork

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #72 | `phase-4/baseline-inventory` | 08, 04 §2 | Read-only inventory and the dependency map of each scored service, including the addresses each one connects out to, which later modules and the outbound allowlist rely on |
| #74 | `phase-4/seed` | 16 | Event seed derivation in `core/seed/`, which the credentials module needs for the `scored-admin` passwords |

### Step 3: automatic runs

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #66 | `phase-4/auto-apply` | Conventions §3.3, 00, 03 | Automatic runs, with no switch: the host's group from the `hosts` file, the break-glass account taken from the protected set with a console check instead of a prompt, no mid-run prompts, pre-approval only for categories a module allows (never account deletion, an unprobed scored service or a replacement), the queue with stable numbers and `-q`, `-q -a`, `-q -d`. A module whose change only takes access away (`keep_on_verify`) is kept once it verifies; firewall and SSH changes, a stopped service and anything else that can lock the team out wait for the login check. Built in full before any lockout module, so each module is written against the final run flow |

### Step 4: the first-minute lockout

Each module ships its read-only `check` and `plan` first. The modules are built in the order the first-minute bundle runs them (design 03, section 6.1), so each one can be tried behind the ones before it. The modules that change a domain controller (#83 here, #84 and #103 later) wait for #124, the CI job that tests them on a throwaway domain controller.

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #124 | — | Conventions §9 | A CI job that promotes a throwaway Windows Server runner to a domain controller for the domain modules' real-host tests |
| #75 | `phase-4/credentials` | 04 | Rotation from an explicit list; password and lockout policy (§2.2); the `scored-admin` class, its seed-derived password and the change list shown once (§2.4) |
| #76 | `phase-4/ssh` | 04 §4 | Remote-admin hardening and the SSH key registry |
| #77 | `phase-4/sessions` | 03 §6.2 | Ending intruder sessions outside the protected set |
| #82 | `phase-4/accounts` | 04 §6 | Locking unexpected admin accounts in the bundle; removing their admin rights and the rest in Harden; deletion only after approval from the queue and a passing checkpoint |
| #78 | `phase-4/firewall` | 03 §6.1, 12, 01 §5 | Default-deny inbound and outbound through the adapter, under a revert timer. The adapter gains an outbound default and the `outbound-allow` list, on every backend |
| #83 | `phase-4/win-base` | 12 §3, §3.3 | Windows protocol and credential settings, including SMBv1 and Print Spooler |
| #85 | `phase-4/first-minute` | 03 §6, §6.3 | The first-minute bundle in its order (lock down; the install, sweep and reopening of outbound then belong to the Harden phase, step 6), first-minute runs with every answer on the command line, ring order and test hosts |

### Step 5: read-only checks and probes

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #73 | `phase-4/vuln-check` | 09 §3 | The read-only finding and ranking of known flaws: host security data, web apps on disk, the dated known-exploited snapshot, and WES-NG on Windows |
| #84 | `phase-4/ad-readonly` | 12 §3.1, §3.2 | Domain read-only checks and the printed domain checklist |
| #70 | `phase-4/baseline-verify` | 08 | In the Harden phase, the official-package check: for a core set of packages and any package the local check flags, download the package from the host's configured repositories, check its signature, and compare its files' hashes with the files on disk. Mismatches are findings for a person. Windows keeps its signer checks and `sfc /verifyonly` |
| #69 | `phase-4/hash-pack` | 08 | The reference hash pack generator. Before an event, with internet, it downloads the official packages for the core set (OpenSSH server, sudo, PAM, coreutils, util-linux, systemd, shadow tools) for chosen OS releases, every published version, checks their signatures, and records each file's hash in a pack shipped with its own SHA-256. The Harden phase uses the pack when the event is offline. Which releases get packs is a run-time choice, not kept in the repository |
| #44 (#55, #56, #57) | `phase-6/probes` | 19 §3.1 | The `http` path and the probes that log in (`imap`, `ssh`, `smb`, `sql`, `winrm`, `siem`), with a probe account given in the event configuration file or a flag at the start of the run, never typed mid-run and never stored in the repository |

### Step 6: Harden

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #68 | `phase-4/harden-phase` | 03, 10, 02, 09, 13 | The `harden` phase between `lockout` and `observe`, and `init` (Lock out then Harden as one run): the install, with outbound opened only to its exact sources for the install (02 §4), restore points, the persistence sweep, the CVE assessment, patching, service packs, Windows and AD hardening, then reopening outbound (`harden.reopen_outbound`); the shipped profiles and the first-minute run updated to match. Service replacement takes its place in the phase after this release (section 4.3) |
| #80 | `phase-4/restore-points` | 07 | `backup <service>` and `restore <service>`, so a restore point exists before the sweep and before any patch |
| #81 | `phase-4/persistence-sweep` | 06 | Classification, automatic quarantine of high-confidence items, and limits on who can schedule jobs |
| #79 | `phase-4/packages` | 02 | Installing the profile's packages behind the lockdown: source order, lock wait, simulation check, services kept stopped, `package_install` entries; vendored tools and pinned downloads with the core download helper |
| #100 | `phase-7/patching` | 10 §4, 02 §5 | Applying an approved security update, one package at a time, after a restore point; the `security-update` category, which pre-approval rules may cover, so a first-minute run applies a named scored package's update; Windows patching checklist |
| #103 | `phase-7/win-tier3` | 14 §5, 12 | LDAP signing, lockout settings, the per-host abused-tool block, the KRBTGT reset (two resets with a replication check between, §5.1), and the remaining approval items |
| #89 | `phase-6/checkpoint` | 19 | The read-only `checkpoint` summary, which the service packs and the deletion of admin accounts (#82) wait for; the sweep re-runs in report mode; the known-flaw section reads the tracker once section 4.3 builds it |
| #95 | `phase-7/service-packs-web` | 11 | nginx, Apache and IIS; ModSecurity with the Core Rule Set in detection-only mode, and approved blocking rules for one flaw (§6.1) |
| #96 | `phase-7/service-packs-mail-dns` | 11 | Postfix, Dovecot (POP3 and IMAP), webmail, BIND, and Windows DNS on servers that are not domain controllers |
| #97 | `phase-7/service-packs-data` | 11 | MySQL or MariaDB, SQL Server, SMB shares, WinRM, vsftpd, and the host settings library, including the `pkexec` setting |

### Step 7: operator helpers, output and help

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #67 | `phase-4/short-output` | Conventions §3.3 | One line per module, full blocks only for failures and blocks, `-v`, in both runners with the manual and both test suites |
| #114 | — | Conventions §3 | `laby --doctor`: a read-only check of the install and the run-time configuration |
| #115 | — | 03, Conventions §3 | A warning to logged-in sessions before the revert timer undoes a run |
| #118 | — | Conventions §3, 03 | `laby --extend ID TIME`, to push back a run's revert timer |
| #116 | — | Conventions §3, §7 | `laby --show ID`, to list what one run changed |
| #117 | — | Conventions §3 | `--only` and `--skip`, to preview or run chosen modules |
| #119 | — | Conventions §3 | Tab completion for `laby` in bash and PowerShell |
| #125 | — | 00 §4, Conventions §3, §9 | The manual and help checked as a whole: every action's `-h` page, every module's help page, and `laby -h MODULE` checked against the spec (it took over #121) |

## 4. After the first usable release

### 4.1 Remote mode

Local mode is the standard, so the lockout already works on every host without this milestone. Remote mode is built read-only first, from a hardened control node (Blueprint §6.1), and `remote apply` only once `remote plan` has run safely in the lab.

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #86 | `phase-5/remote-plan` | 00 §5, 21 §5 | `remote plan --group <group>` over SSH and PowerShell remoting: it copies and checks the release, runs the local `plan`, and brings back the plans and logs. It changes nothing |
| #87 | `phase-5/remote-apply` | 00 §5 | `remote apply --group <group>`, after `remote plan` has run safely in the lab: it runs the local `apply` and brings back logs and manifests. Each host keeps its own approval queue (Conventions section 3.3), so the control node lists a host's queue with `-q` on that host and applies the chosen items there with `-q -a`. It copes with losing the connection while credentials and SSH settings rotate. It keeps a host's run only when it can still log in over the admin path and no scored service that passed before the run fails after it; otherwise the timer reverts that host, except the modules kept once they verified (design 00, section 5) |

### 4.2 Observe and checkpoints

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #88 | `phase-6/seal` | 08 §6 | `seal`, `reseal --reason`, and integrity findings against the sealed baseline |
| #90 | `phase-6/outside-probe` | 19 §3 | `--probe` from a machine outside the team's network, limited to the `own-ranges` list |
| #91 | `phase-6/health-monitor` | 19 §3–§5 | The scheduled job on the control node: probes of every scored service with state-change alerts and rollback candidates, alerts on firewall drift (a person re-applies the sealed rules with one command, design 19), and scheduled checkpoints that alert once on each new finding |
| #92 | `phase-6/linux-audit` | 14 | auditd, installed by `packages`, with the vendored rule set |
| #93 | `phase-6/win-audit` | 14 | Audit policy, script block logging, log sizes, and Sysmon from its pinned download |
| #94 | `phase-6/log-forwarding` | 14 §4 | The Splunk Universal Forwarder on Linux and Windows, already present or from its pinned download, with syslog on Linux and the HEC script on Windows as fallbacks; saved searches, including the outbound log rule |

### 4.3 Sustain and hardening

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #98 | `phase-7/siem` | 14 §7 | The SIEM's own hardening: admin password (a `scored-admin` where scored), ports by whether they are scored, and `splunkd` off root after approval |
| #99 | `phase-7/service-reduction` | 10 §3 | Stopping services from an explicit candidate list |
| #101 | `phase-7/vuln-tracker` | 09 §3.2, §4, §5 | The version scan of the team's own hosts, the tracker and its states, and the mitigation catalog, with automatic mitigations applied through the modules that own each setting |
| #102 | `phase-7/service-replacement` | 13 | In the Harden phase, off by default: the `ALLOW_SERVICE_REPLACE` and `ALLOW_CONTAINERS` keys, the full proof (users, mailboxes, pages by hash, database contents, the scored check on a staging port), build beside, switch under a revert timer, and the container controls (non-root, named exception list, Podman and Docker). Only used where an event allows it |

### 4.4 Reporting and cleanup

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #104 | `phase-8/report` | 20 | The incident report builder, fed by quarantine evidence, integrity findings and the tracker's closed flaws |
| #105 | `phase-8/cleanup-integrity` | 21 | Cleanup, and the signature check on the control node. Each host's own release check (21 §5.1) is part of the framework hardening |
| #120 | — | Conventions §3 | `--json` output for the read-only actions, for scripts to read |

### 4.5 Deceive and extras

| Issue | Branch | Spec | Delivers |
|---|---|---|---|
| #106 | `phase-9/canaries` | 16, 17, 12 | Canary files and honey-accounts |
| #107 | `phase-9/maze` | 17 | The deception maze, CVE decoys and the web tarpit |
| #108 | `phase-9/dynamic-bans` | 18 | Bans in both directions that never touch the never-ban list or the scoring allowlist; fail2ban where installed; approved outbound bans (§6.1) |
| #109 | `phase-9/status-feed` | 15 | The status feed and login banner |
| #110 | `phase-9/dns-sinkhole` | 14 §5, Blueprint §4.6 | The DNS sinkhole (person-run on a domain controller). Outbound filtering moved to `phase-4/firewall` and the outbound log rule to `phase-6/log-forwarding` |

### 4.6 Any time: appliance runbooks

#111, `phase-x/appliance-runbooks` (design 05), holds templates and runbooks only. It depends on nothing above.

## 5. Settled decisions

### 5.1 Approvals, logs, build order and tests

| Question | Decision | Recorded in |
|---|---|---|
| How are approvals given? | Items covered by a pre-approval rule are applied; every other item goes to the host's own queue, listed by `laby -q` and approved with `laby -q -a` (planned, first usable release). Each item carries a fingerprint, and an item that changed since it was planned or queued is refused. Today the runner asks at the prompt, and `--approve` passes approvals without it. | Conventions §3.1, §3.3 |
| How do Windows hosts ship logs? | The Splunk Universal Forwarder, installed from Splunk's public download site and pinned by version and SHA-256 in the run-time configuration; the PowerShell script posting to Splunk's HTTP Event Collector is the fallback. | Design 14 §4, design 00 §9 |
| How is Labyrinth run, and when is remote mode built? | Local mode is the standard: each host's operator runs it on that host. Remote mode comes after the P0 lockout works locally, read-only `remote plan` first, and `remote apply` only once that has run safely in the lab (milestone 2). | Blueprint §6.1, this page, design 00 §5, §9 |
| Where do real-host tests run? | CI runners for Ubuntu, Windows Server and a single domain controller; a local lab for everything else, before each release. | Conventions §9, `docs/lab/README.md` |
| Are the Windows registry values right? | Checked against Microsoft's documentation. Netlogon enforcement is now report-only, because patched domain controllers enforce it anyway. LSA protection is offered only in a form that rollback can remove. LDAP and SMB signing defaults on Windows Server 2025 are reported. The removal of the PowerShell 2.0 engine is noted. | Design 12 §3–§3.3, design 14 |

### 5.2 Installs, the first minute and automation

| Question | Decision | Recorded in |
|---|---|---|
| May Labyrinth install software? | Yes, public software and public data, after the first-minute lockdown: download first, with an offline paste as the fallback, from the host's repositories, an event mirror or proxy, or a release pinned by SHA-256. PowerShell Gallery modules at pinned versions are allowed. Rule 5.6.4's example is cloud services and cloud processing, which downloading software is not. Never a private source (Rule 5.2), a new repository (apart from EPEL, design 02 §3), a reputation or enrichment service or a full upgrade. | Design 02, AGENTS.md |
| What does Labyrinth need from the network? | Only its own public release. Packages, pinned downloads such as Sysmon, EPEL and refreshed lists of known flaws are optional extras: each runs after the lockdown when its source answers, and is reported as skipped otherwise. | Blueprint §6.1, design 02 |
| What runs in the first minute? | Lock out with what the host has (rotate, keys, sessions, lock unexpected admin accounts, default-deny inbound and outbound), installing nothing, for speed and to lock down before outbound opens. Then the Harden phase: install, sweep, assess, patch, then reopen outbound to the normal allowlist. | Design 03 §6, §6.1 |
| How does a first-minute run avoid prompts? | Today the existing options answer them (`--confirm-group`, `--break-glass`, `--approve`), and pre-approval rules cover the items the team approved before the event. Planned (first usable release): automatic is the only mode, with no switch. No run prompts during the run; items without a rule go to a queue, listed by `laby -q` and approved with `laby -q -a`; the one question is the login check at the end. Revert timers, probes, the scoring allowlist and the protected set stay. | Design 03 §6.3, Conventions §3.3 |
| What does the command line look like? | Flags with short and long forms, as in nmap and pacman, under the short name `laby`: `laby init` previews, `laby -r init` runs, `-q`, `-k`, `-u`, `--probe`, `--history`. Help never runs anything, `-h` added to an action gives its help, and `laby --manual` or `man laby` opens the manual. The status, the manual and the flag forms for preview, run, keep, undo, history, probe, help and version are built; the queue is planned. | Conventions §3.1, §3.3, design 00 §5.1 |
| How do installs get out through the lockdown with no proxy? | The install opens outbound to the exact resolved addresses of the host's repositories and the pinned download hosts, for the install only, then closes them. Never all web traffic. | Design 02 §4 |
| Where are unexpected admin accounts handled? | Locked in Lock out, because locking only takes access away; their admin rights are removed in Harden; deletion always waits for a person. | Design 04 §6.3, design 03 §6.1 |
| Can a ban block outbound traffic? | Yes. Every ban drops the address in both directions; an address from the unusual-outbound search is banned outbound only after approval. | Design 18 §6.1 |
| How are known flaws handled? | Found and ranked locally, tracked until closed, and closed by mitigation or patch. A scored service is never turned off to close a flaw. | Design 09 |
| Are design choices labeled as rules? | No longer. Watching abused tools, manual Group Policy, manual DNS on the domain controller, the candidate list and keeping login shells are design choices, and the docs now say so. | AGENTS.md, Blueprint |
| How are items approved before the event? | `--approve` needs a fingerprint from a plan, so it could not carry them. A module declares the categories that are safe to pre-approve (`pre_approvable`), and the run-time `pre-approved` file names the items or categories the team approved. Each item is still checked against this run's plan, the probes and the revert timer. | Conventions §2.2, §3.1; design 00 §4 |
| Which more steps run without a person? | Pre-approved security updates for named scored packages, default application passwords and settings tested on the event's versions; keeping a host's run in remote mode once the admin login works and no scored service regressed; scheduled read-only checkpoints that alert on new findings; and the KRBTGT reset, now carried out by Labyrinth after approval. Deleting accounts, restores, ordinary users' passwords, Group Policy, DNS on the domain controller, appliances, medium-confidence outbound bans and app settings that change what scoring sees stay with a person. | Designs 00 §5, 04 §2.1, 10 §4, 11 §4, 12 §5.1, 19 §5 |

### 5.3 Scoring, sources and service replacement

| Question | Decision | Recorded in |
|---|---|---|
| Are admin accounts ever scored? | Events differ. None is assumed unscored. An admin account a check logs in with is a `scored-admin` account: rotated in the first minute, with its new password in a `username,password` change list shown once. | Designs 03, 04 §2.4 |
| May a scored port be limited by source? | No. Some events penalize it, and officials and simulated users come from addresses nobody can list. Scored ports are open to every source and hardened in place; a ban blocks one address on every port. | Designs 01 §5, 03 §6.1, 18 |
| Is the scoring allowlist still required? | Only where given. The gate passes when every scored service is allowed from any source. | Designs 01 §5, 03 §7 |
| Do probes log in? | Where the operator gives a probe account in the event configuration file or a flag at the start; it is never typed mid-run and never stored in the repository. Otherwise they connect only, and the plan says so. | Design 19 §3.1 |
| May a scored service be rebuilt or containerized? | Only where an inject or the local competition rules allow it (Rule 4.14), on the same host with the same public address and DNS name, through design 13 (P1, Harden phase), off by default and named in `event.conf`. | Design 13 |
| Which rule numbers apply? | The rules page has ten sections: misleading scoring is 9.3, incident reports 9.4, materials 8.5. | Blueprint, design README |

## 6. Open: questions for competition officials

Short questions, each answerable in a line. The team sends them with the tool's declaration and records each answer in the spec it affects.

1. **Configuration after the freeze.** The frozen tool reads a folder of event facts that we fill in at the event: scoring engine addresses, host names, account names and the list of hosts. The files hold no code and cannot add features. Is filling them in after the freeze allowed (NCCDC, 2025, Rule 5.6.2)? Design 00, section 6 and Conventions, section 2.2 are labeled *Provisional* until the answer arrives.
2. **Public packages.** After locking a host down, the tool installs a fixed list of free, public packages, such as auditd, from the host's own repositories or the event's mirror or proxy. Please confirm this is allowed (Rules 5.1, 5.2 and 5.6.4). The install feature is named in the declaration (design 02, section 2).
3. **A public vulnerability database.** Trivy's database and the CISA known-exploited catalog are public files that change daily, so they cannot be pinned by hash. All matching runs on the team's own hosts. The tool downloads them to the host after the lockdown and sends nothing out (design 09, section 3.4). Please confirm this is allowed (Rules 5.1 and 5.6.4).
4. **Fetching the release at the event.** Where a host or a console reaches the internet, the operator downloads the declared release archive from its public release page and checks its SHA-256 against the value given with the declaration before unpacking it. Please confirm this is allowed (Rules 5.1 and 5.6.2) (design 21, section 5.2).

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 9, 2026, from https://www.nationalccdc.org/rules.html
