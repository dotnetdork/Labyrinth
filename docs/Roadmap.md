# Labyrinth Roadmap

This is the build order for the rest of Labyrinth. The design specs in `docs/design/` say *what* each part does; this page says *in what order* the parts are built and what each branch must deliver. It holds no dates or event details.

## 1. Where it stands

**Built:**
- the core library in bash and PowerShell: logging, the run manifest with backup and restore, safety gates, the protected set, break-glass, the run lock, revert timers, and the http, dns and banner probes;
- both runners, with `plan`, `apply`, `keep`, `rollback`, `runs`, `probe`, `help` and `version`;
- from stage 3: platform facts, the firewall adapter, the quarantine helper, approval items with `--approve` / `-Approve`, and the six shipped profiles (empty until their modules are built);
- the operator manual, the compatibility suite and CI.

**Not built:**
- real modules (`phases/*/modules` holds only placeholders);
- `report/`, `core/seed/` and `vendor/`;
- the planned commands: `seal`, `reseal`, `checkpoint`, `backup`, `restore` and `remote`.

## 2. Rules for every branch

- One component per branch, named `phase-<n>/<name>`.
- Re-read the spec first. If it is wrong or vague, fix it with a review-log entry before writing code.
- Write tests first, from the spec's acceptance-test list. Every module gets the negative test: protected accounts and scored services are untouched.
- Make the change in bash and PowerShell together wherever the spec covers both platforms.
- `tests/lint/guard.sh` and CI must be clean. A real-host acceptance test names where it runs: a CI runner or the lab (`docs/lab/README.md`).
- A new command or option goes into both runners, the manual and both test suites in one commit. The compatibility suite is never edited to make a change pass.

## 3. Build stages

The build stages are numbered on from the stages already done: 0 (foundations), 1 (the core) and 2 (the command line). Branches are named `phase-<stage>/<name>`. A build stage is not a run phase: the run phases are lockout, observe, deceive and sustain, the word in `labyrinth plan <phase>`, and modules of one run phase are built across several stages.

### Stage 3: groundwork that modules need

Built on one branch, `phase-3/groundwork`, one commit per part. The parts are listed by the branch name each would have had.

| Branch | Spec | Delivers | Done when |
|---|---|---|---|
| `phase-3/platform-detect` | 19 | Detects the OS family, firewall backend (UFW, firewalld, nftables, iptables, Windows Firewall), init system and package manager, in `core/platform/`; works without `jq`, `python3` or `curl` | Fixture tests pass for each supported distribution and for Windows |
| `phase-3/firewall-adapter` | 19, 01 | One interface across the five backends (UFW, firewalld, nftables, iptables, Windows Firewall): snapshot, scoring allowlist first, then deny, then restore | The allowlist is in place before any deny rule; restore puts back the exact snapshot (unit tests in CI; each backend on its lab host) |
| `phase-3/profiles` | 00, Blueprint §6.3 | The shipped profiles: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc`, `appliance` | A shipped profile lists only modules the release has, fitting its platform; each module is added to its profiles in the commit that builds it (`tests/profiles/`) |
| `phase-3/quarantine` | 17 §5 | A core quarantine helper for files, cron lines, units, scheduled tasks, services, registry values and WMI subscriptions | Rollback restores each item byte for byte; nothing is deleted |
| `phase-3/approval-flow` | Conventions §3.1 | Approval items with fingerprints, `category:` approval at the prompt, and `--approve` / `-Approve` | An unapproved item and an item changed since the plan are left alone |
| `phase-3/offline-record` | 05 | Hand-over of new passwords without writing them to disk | No secret appears in logs, the manifest or backups |

### Stage 4: P0 lockout

Each module ships its read-only `check` and `plan` first.

| Branch | Spec | Delivers |
|---|---|---|
| `phase-4/baseline-inventory` | 04, 05 §2 | Read-only inventory and the dependency map of each scored service, which later modules rely on |
| `phase-4/credentials` | 05 | Rotation from an explicit list; password and lockout policy (§2.2) |
| `phase-4/accounts` | 05 §6 | Locking accounts from a list; deletion only after approval and a passing checkpoint |
| `phase-4/sessions` | 01 §6 | Ending intruder sessions outside the protected set |
| `phase-4/persistence-sweep` | 17 | Classification, automatic quarantine of high-confidence items, and limits on who can schedule jobs |
| `phase-4/firewall` | 01, 11 | Default-deny through the adapter, under a revert timer |
| `phase-4/ssh` | 05 §4 | Remote-admin hardening and the SSH key registry |
| `phase-4/win-base` | 11 §3, §3.3 | Windows protocol and credential settings |
| `phase-4/ad-readonly` | 11 §3.1, §3.2 | Domain read-only checks and the printed domain checklist |
| `phase-4/first-minute` | 01 §6 | The first-minute bundle, ring order and canary hosts |

### Stage 5: remote mode

Built right after the P0 lockout works locally, so the lockout reaches every host quickly.

| Branch | Spec | Delivers |
|---|---|---|
| `phase-5/remote` | 00 §5, 07 §5 | `remote plan` and `remote apply --group <group>` over SSH and PowerShell remoting: it copies and checks the release, runs the local command, and brings back logs and manifests. It collects approval items from the plan and passes each host its own `--approve` entries. It copes with losing the connection while credentials and SSH settings rotate |

### Stage 6: observe and checkpoints

| Branch | Spec | Delivers |
|---|---|---|
| `phase-6/seal` | 04 §6 | `seal`, `reseal --reason`, and integrity findings against the sealed baseline |
| `phase-6/checkpoint` | 13 | The read-only `checkpoint` summary; the sweep re-runs in report mode |
| `phase-6/linux-audit` | 10 | auditd rules |
| `phase-6/win-audit` | 10 | Audit policy, script block logging and log sizes |
| `phase-6/log-forwarding` | 10 §4 | syslog forwarding on Linux; on Windows, the forwarder already present or the HEC script; saved searches |

### Stage 7: sustain and hardening (P1)

| Branch | Spec | Delivers |
|---|---|---|
| `phase-7/service-packs-web` | 18 | nginx, Apache and IIS |
| `phase-7/service-packs-mail-dns` | 18 | Postfix, Dovecot, BIND, and Windows DNS on servers that are not domain controllers |
| `phase-7/service-packs-data` | 18 | MySQL or MariaDB, vsftpd, and the sysctl library |
| `phase-7/service-reduction` | 15 | Stopping services from an explicit candidate list; patching runbooks |
| `phase-7/backup-restore` | 14 | `backup <service>` and `restore <service>` |
| `phase-7/win-tier3` | 11 | LDAP signing, lockout settings and the remaining approval items |

### Stage 8: reporting and cleanup

| Branch | Spec | Delivers |
|---|---|---|
| `phase-8/report` | 02 | The incident report builder, fed by quarantine evidence and integrity findings |
| `phase-8/cleanup-integrity` | 07 | Cleanup, and checking the release before a run |

### Stage 9: deceive and extras (P2)

| Branch | Spec | Delivers |
|---|---|---|
| `phase-9/seed` | 03 | Event seed derivation in `core/seed/` |
| `phase-9/canaries` | 03, 09, 11 | Canary files and honey-accounts |
| `phase-9/maze` | 09 | The deception maze, CVE decoys and the web tarpit |
| `phase-9/dynamic-bans` | 12 | Bans that never touch the never-ban list or the scoring allowlist |
| `phase-9/status-feed` | 06 | The status feed and login banner |
| `phase-9/egress` | 10 §5, Blueprint | Outbound logging and the DNS sinkhole (person-run on a domain controller) |

### Any time: appliance runbooks

`phase-x/appliance-runbooks` (design 16) holds templates and runbooks only. It depends on nothing above.

## 4. Decisions settled in the 2026-10-05 review

| Question | Decision | Recorded in |
|---|---|---|
| How are approvals given? | Typed at the prompt by default. Each item carries a fingerprint from the plan, and `--approve` passes approvals without the prompt for remote mode. An item that changed since the plan is refused. | Conventions §3.1 |
| How do Windows hosts ship logs? | The Splunk universal forwarder where the host already has one; otherwise a PowerShell script posting to Splunk's HTTP Event Collector. Nothing is installed. | Design 10 §4, design 00 §9 |
| When is remote mode built? | Right after the P0 lockout works locally (stage 5). | This page, design 00 §9 |
| Where do real-host tests run? | CI runners for Ubuntu, Windows Server and a single domain controller; a local lab for everything else, before each release. | Conventions §9, `docs/lab/README.md` |
| Are the Windows registry values right? | Checked against Microsoft's documentation. Netlogon enforcement is now report-only, because patched domain controllers enforce it anyway. LSA protection is offered only in a form that rollback can remove. LDAP and SMB signing defaults on Windows Server 2025 are reported. The removal of the PowerShell 2.0 engine is noted. | Design 11 §3–§3.3, design 10 |

## 5. Open: a question for competition officials

Design 00, section 6 assumes that run-time configuration is not part of the frozen submission (NCCDC, 2025, Rule 5.6.2). Labyrinth is designed so that the answer cannot change what the tool does: configuration holds only facts about the event, and a profile override can only choose among modules the release already ships. The question still needs an official answer before the event. Suggested wording:

> Our team tool is frozen and submitted before the event. At run time it reads a configuration folder that we fill in at the event with values from the team packet: scoring engine addresses, host names, account names, and the list of hosts. These files hold no code and cannot add features; they only tell the frozen tool where things are. Is filling in these values after the freeze allowed under Rule 5.6.2?

When the answer arrives, record it in the design review log and remove the *Provisional* label from design 00, section 6 and the matching sentence from Conventions, section 2.2.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
