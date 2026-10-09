# 20. Packages and Third-Party Tools

**Status:** Draft · reviewed 2026-10-09 · Phase: All · Priority: P0

## 1. Goal

Get the tools the team needs onto each host in the minutes after the first-minute lockdown (design 01, section 6.1), from public sources only, verified, recorded and safe to undo. Labyrinth installs what the profile lists; nobody types package commands under pressure.

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Team-written tools that use resources outside the competition environment, other than simple DNS lookups, are prohibited; the rule's own example is tools that use cloud services or cloud processing (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.4). | Labyrinth never sends data to, or has anything processed by, an outside service. Installing public software through the host's own package manager is not cloud processing. The install feature is named in the tool's declaration (Rule 5.6.2), so officials approve or reject it before the event. |
| Free public resources that every team could reach are allowed; private staging areas for patches or software are prohibited (NCCDC, 2025, Rules 5.1, 5.2). | Sources are only the host's configured repositories, a mirror or proxy the event provides, and the public release pages pinned in the catalog (section 6). Never a team-controlled server, cloud drive or private repository. |
| Team tools are declared and frozen (NCCDC, 2025, Rule 5.6.2). | Every package name is in the release, and every downloaded file is pinned by version and SHA-256 in the release, so what runs at the event is what officials approved. |
| Tools must not deliberately break expected functionality (NCCDC, 2025, Rule 5.6.5). | Only listed packages, never a full upgrade, and an install that would remove or replace a package is refused (section 4). |
| Scored services may not be migrated or containerized (NCCDC, 2025, Rule 4.14). | No container runtime is ever installed, and nothing moves a scored service. |
| The 2025 qualifier packet describes a web proxy that includes the team's declared repository (Midwest Collegiate Cyber Defense Competition [MWCCDC], 2025; *Provisional*). | The proxy address is run-time configuration. When no source is reachable, installs are skipped and the lockdown still stands (section 4). |

## 3. Sources, in order

1. **Vendored in the release.** A tool whose license allows redistribution is copied into `vendor/<tool>/` with its license and a NOTICE file naming its author, version and source (design 08). It needs no network and is frozen with the release.
2. **The host's own package manager** (`apt-get` on the Debian family, `dnf` on the RHEL family), from the repositories the host is already configured with.
3. **An event mirror or proxy.** Run-time `event.conf` keys `PROXY` (for example `http://proxy.example:3128`) and `MIRROR`. Labyrinth passes the proxy to the package manager for that command only and never writes it into the host's configuration.
4. **A pinned public download**, only for a tool whose license forbids redistribution (for example the Sysinternals tools). The catalog holds the URL, the version and the SHA-256. The file goes to Labyrinth's temporary path, is checked against the hash before use, and is discarded on a mismatch.

Labyrinth never adds a repository, a signing key or a package source, so a tool that the host's repositories lack (fail2ban on a RHEL-family host without EPEL, for example) is skipped, and the module that wanted it uses its fallback (design 12, section 6).

## 4. How an install runs

The `packages` module runs in the lockout phase, straight after the first-minute bundle (design 01, section 6). It is Tier 2: automatic for the profile's list, under the revert timer, with probes before and after.

- **check** lists the profile's packages that are missing and says which source would supply each one. It changes nothing.
- **plan** prints the exact commands.
- **apply**:
  1. refuses (`20`) if the outbound lockdown does not allow the repository, mirror or proxy (design 01, section 6.1);
  2. waits up to a set time for the package manager's lock, which an unattended update often holds just after boot, then refuses (`20`) rather than breaking the lock;
  3. simulates the install first (`apt-get -s`, `dnf --assumeno`) and refuses any package whose install would remove, downgrade or replace an installed package;
  4. installs non-interactively, with no recommended extras (`--no-install-recommends`, `--setopt=install_weak_deps=False`) and a time limit per package;
  5. keeps any service the package brings stopped and disabled until its own module configures it, so fail2ban cannot start its default SSH jail before the never-ban list is in place (design 12, section 6). On the Debian family, a temporary `policy-rc.d` stops services from starting during the install and is removed afterwards;
  6. records each package and version as a `package_install` entry in the run manifest.
- **When no source answers**, the module reports each skipped package and exits `0`. The lockdown is already in place, and a module that needs a missing tool blocks (`20`) or uses its fallback.
- **rollback** stops and disables any service an installed package brought, and leaves the package installed. Removing software is a person's decision, made by hand from the manifest, because a removal can take files and dependencies with it.

Code that calls a package manager or downloads a file carries a guard allow comment naming this design (Conventions, section 8). Only the `packages` module and the core download helper may do so.

**Windows.** Windows Server has no package manager that Labyrinth can rely on. Windows tools are vendored (PowerShell modules are copied into Labyrinth's tool path and imported from there, never through `Install-Module`), or fetched as pinned downloads (section 3). Microsoft Defender signature updates come from Microsoft through the host's own update client.

## 5. Patching

Security updates use the same sources and the same checks. Design 21 ranks them, and Labyrinth applies each one a person approves (Tier 3), one package at a time, after a restore point. A full upgrade is never run.

## 6. Catalog

Licenses were read from each project's repository on 2026-10-09 (*Verified*), except where marked. "Use" names the design that would use the tool. A tool not yet listed in a profile is not installed.

**Linux, from the host's repositories.**

| Tool | Use | Design | License |
|---|---|---|---|
| auditd | Kernel audit of commands, file changes and logons, feeding the SIEM | 04, 10 | GPL-2.0 (*Background*) |
| fail2ban | Bans from failed logins, where the host's repositories offer it | 12 | GPL-2.0 |
| AIDE | File-integrity database for the sealed baseline | 04 | GPL-2.0 (*Background*) |
| debsums | Checks installed files against the Debian family's package hashes (`rpm -Va` does this natively on the RHEL family) | 04 | GPL-2.0 (*Background*) |
| rkhunter, chkrootkit | Rootkit and known-backdoor checks; findings go to a person | 17 | GPL-2.0 (*Background*) |
| unhide | Finds processes and ports hidden from the usual tools | 17 | GPL-3.0 (*Background*) |
| Lynis | Read-only hardening audit; its findings feed the service packs and checklists | 18 | GPL-3.0 |
| ModSecurity with the OWASP Core Rule Set | Web application firewall inside the scored Apache or nginx, never in front of it. Detection-only first; blocking only after a person approves and the probes pass | 18 | Apache-2.0 (rule set) |
| YARA | Scans web roots and temporary folders for web shells and known malware with vendored rules | 17 | BSD-3-Clause |
| nmap | Service and version scan of the team's own hosts, from the control node, with no scripts | 21 | Nmap Public Source License (*Background*) |
| debsecan | Lists Debian packages with security fixes available | 21 | GPL-2.0 (*Background*) |

**Vendored in the release.**

| Tool | Use | Design | License |
|---|---|---|---|
| Neo23x0 auditd rules | A tested, balanced rule set for auditd | 10 | Apache-2.0 |
| pspy | Watches new processes and cron runs without auditd, to catch a persistence job firing | 17 | GPL-3.0 |
| Sigma rules | Searches converted before the release (design 10, section 5) | 10 | Detection Rule License 1.1 (*Background*) |
| sysmon-modular | The Sysmon configuration for Windows hosts | 10 | MIT |
| HardeningKitty | Windows settings audit against Microsoft and CIS lists; audit mode is Tier 0, applying a finding is Tier 3 | 11 | MIT |
| PersistenceSniper | Windows persistence hunting: run keys, services, scheduled tasks, WMI and more | 17 | MIT with the Commons Clause (no commercial use) |
| Hayabusa, Chainsaw | Search Windows event logs with Sigma rules for the incident record | 02, 10 | AGPL-3.0, GPL-3.0 |
| WES-NG, with its definitions file taken at release | Matches a Windows host's `systeminfo` to the updates it is missing and the vulnerabilities they fix, offline | 21 | BSD-3-Clause |
| CISA known-exploited catalog, dated snapshot | Ranks findings | 15, 21 | Public U.S. government data (*Background*) |

**Pinned public downloads.**

| Tool | Use | Design | Why not vendored |
|---|---|---|---|
| Sysmon | Process, network and file events on Windows | 10 | The Sysinternals license does not allow redistribution (*Provisional*) |
| Autoruns (`autorunsc`) | Every Windows autostart location, for the persistence sweep | 17 | Same |
| PingCastle | Read-only Active Directory audit on the domain controller | 11 | Its license is the Non-Profit Open Software License 3.0 alongside a proprietary one, so it is fetched from its publisher, not copied |
| Trivy | Finds flawed libraries bundled inside apps, which no package manager tracks | 21 | Apache-2.0, so it could be vendored, but its binary is large. Its vulnerability database changes daily and cannot be pinned by hash; whether it may be fetched at the event is a pinned question (design 21, section 6) |

**Considered and not adopted.**

| Tool | Why not |
|---|---|
| UFW | Installing it on a host that already runs firewalld or nftables makes two firewalls, and the adapter then refuses to act (design 19, section 5). Labyrinth drives the native firewall directly. |
| Velociraptor, Wazuh | Each needs its own server and an agent on every host, and duplicates the team's Splunk. Worth a later look for hunting, not for the first minutes. |
| ansible-lockdown CIS roles | Need Ansible, which design 00 did not choose, and apply whole benchmarks at once. Mined for settings instead (design 08). |
| SwiftOnSecurity sysmon-config | No license file, so it cannot be copied into a public repository. sysmon-modular is used instead. |
| DeepBlueCLI | Not updated since 2023; Hayabusa and Chainsaw cover the same ground. |
| BloodHound | Useful for a person mapping domain attack paths, but large and slow for the first hour. |
| Grype | Covers the same ground as Trivy; one is enough. |
| nmap `vulners` script, online vulnerability APIs | Send the host's software versions to an outside service for matching, which is the cloud processing Rule 5.6.4 prohibits. |

## 7. What it will never do

- Run a full upgrade or a distribution upgrade.
- Add a repository, a signing key or a package source.
- Install a container runtime.
- Remove, downgrade or replace a package.
- Use a private server, cloud drive or private repository as a source.
- Run a downloaded file whose SHA-256 does not match the release.

## 8. Acceptance tests

- On a lab host with a reachable repository, the profile's missing packages are installed and recorded, and every probe still passes.
- fail2ban, once installed, is not running until the bans module has written the never-ban list into its `ignoreip`.
- With no repository reachable, the module lists each skipped package and exits `0`, and the firewall lockdown is unchanged.
- An install whose simulation would remove a package is refused (`20`).
- With the package manager's lock held, the module waits, then refuses (`20`) without breaking the lock.
- A pinned download with a wrong SHA-256 is discarded and not run.
- `rollback` stops and disables the services the install brought, and the packages stay installed.
- With the proxy set in `event.conf`, the install goes through it, and the host's own package configuration is unchanged afterwards.

## References

Midwest Collegiate Cyber Defense Competition. (2025). *2025 Midwest Collegiate Cyber Defense Competition qualifier team packet* [PDF]. https://brazil.minnesota.edu/ccdc/ccdc-2025/2025MWCCDCQTeamPack.pdf

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 9, 2026, from https://www.nationalccdc.org/rules.html
