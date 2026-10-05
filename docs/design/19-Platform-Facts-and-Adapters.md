# 19. Platform Facts and Adapters

**Status:** Draft · reviewed 2026-10-05 · Priority: P0

## 1. Goal

Modules must behave the same on every supported host, but the hosts differ. Ubuntu runs UFW, Fedora runs firewalld, and a minimal Debian may run bare nftables. Package ownership is answered by `dpkg` on one family and `rpm` on the other. A Windows domain controller needs care that a member server does not.

This spec gives every module one read-only way to learn what host it is on: the **platform facts**. It also gives one way to change the things that differ: the **adapters**. A module asks for a fact or calls an adapter; it never guesses a platform from a file name or a tool it happens to find.

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Team tools may not use resources outside the competition environment (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.4). | Facts come only from the host itself: files, built-in commands and the registry. Nothing is downloaded or installed to learn a fact. |
| Tools must not deliberately break expected functionality (NCCDC, 2025, Rule 5.6.5). | A fact that cannot be learned is `unknown`, and a module that needs it is blocked (`20`) rather than guessing. When two firewalls are active at once, the firewall modules are blocked, because a rule added to one could be undone or shadowed by the other. |

## 3. Facts

Reading a fact changes nothing, so facts are safe in `check` and `plan`. Each fact is worked out once per process and kept for the rest of it.

**Linux** (`lab_fact <name>`; `lab_facts` prints every fact as `name=value`, one per line):

| Fact | Values | Learned from |
|---|---|---|
| `os_id` | The `ID` field, for example `ubuntu`, `debian`, `fedora`, `rhel`, `rocky`, `ol`, `almalinux`, `centos`; else `unknown` | `/etc/os-release` |
| `os_family` | `debian` or `rhel`; else `unknown` | `ID`, then `ID_LIKE`, in `/etc/os-release` |
| `os_version` | The `VERSION_ID` field; else `unknown` | `/etc/os-release` |
| `init` | `systemd` or `other` | Whether `/run/systemd/system` exists |
| `pkg_db` | `dpkg` or `rpm`, the database that answers "which package owns this file?"; else `none` | The family, confirmed by the tool being present |
| `firewall` | `ufw`, `firewalld`, `nftables`, `iptables`, `none`, `conflict` or `unknown` | Section 3.1 |
| `selinux` | `enforcing`, `permissive`, `disabled` or `absent` | `getenforce`, if present |

**Windows** (`Get-LabFact -Name <name>`; `Get-LabFacts` returns every fact as an ordered table):

| Fact | Values | Learned from |
|---|---|---|
| `os_caption` | For example `Microsoft Windows Server 2022 Standard` | `Win32_OperatingSystem` |
| `os_build` | The build number, for example `20348` | `Win32_OperatingSystem` |
| `role` | `workstation`, `member-server`, `standalone-server` or `domain-controller` | `ProductType` and `PartOfDomain` |
| `firewall` | `on` (every profile on), `partial`, `off` or `unknown` | `Get-NetFirewallProfile` |
| `secure_boot` | `on`, `off` or `unsupported` (no UEFI) | `Confirm-SecureBootUEFI` |
| `ad_module` | `yes` or `no`: whether the ActiveDirectory PowerShell module is present (design 11, section 3.2) | `Get-Module -ListAvailable` |
| `splunk_forwarder` | `yes` or `no` (design 10, section 4) | Whether the `SplunkForwarder` service exists |

**Optional tools.** `lab_have <tool>` (`Test-LabTool -Name <tool>` on Windows) says whether a command is on the path, for the tools Labyrinth must not assume, such as `jq`, `python3`, `curl` and `dig`. A module that can use one has a slower path that works without it.

**Tests.** On Linux, facts read their files under `LAB_SYSROOT` when it is set (default: empty, the real root), so tests can supply a fake `/etc/os-release` and `/run/systemd/system`. Commands are replaced by stubs on the path. On Windows, the cmdlets are mocked in Pester.

### 3.1 Which firewall is active (Linux)

Each backend is checked in this order:

1. **UFW** is active when `ufw status` reports `Status: active`.
2. **firewalld** is active when `firewall-cmd --state` reports `running`.
3. **nftables** is active when the nftables service is active, or `nft list ruleset` shows a table that neither UFW nor firewalld made.
4. **iptables** (legacy, without nftables) is active when `iptables -S` shows a rule or a policy other than `ACCEPT`.

- One active backend gives its name.
- None gives `none`.
- More than one gives `conflict`. UFW and firewalld both work through nftables or iptables underneath, and their own tables do not count as a second backend.
- A check that fails to run, for example without root rights, gives `unknown`.

## 4. Layout

| Path | Holds |
|---|---|
| `core/platform/platform.sh`, `core/platform/Platform.ps1` | The facts, loaded with the rest of the core |
| `platform/linux/firewall/<backend>.sh` | One firewall adapter per Linux backend (section 5) |
| `platform/ubuntu/`, `platform/rhel-family/` | Adapters that differ by family, such as package ownership (`dpkg -S` or `rpm -qf`) |
| `platform/windows/` | The Windows Firewall adapter |
| `platform/appliance/` | Runbooks and templates only (design 16) |

The `hosts` file's platform `ubuntu` covers the whole Debian family, and `rhel-family` covers Fedora, RHEL, Rocky, Oracle Linux and AlmaLinux (Conventions, section 3.1).

## 5. The firewall adapter

Every backend's adapter offers the same functions, so the firewall, ban and egress modules never call a backend directly:

| Function | Does |
|---|---|
| `snapshot DIR` | Saves the complete current ruleset to DIR, in a form `restore` can load back exactly |
| `restore DIR` | Puts back the ruleset saved in DIR |
| `allow PROTO PORT SOURCE` | Allows inbound PROTO/PORT from SOURCE (an address or CIDR, or `any`) |
| `default_deny_in` | Sets the inbound default to deny, keeping established connections and loopback |
| `state` | Prints the current rules, normalized so two snapshots can be compared |

The order is fixed. The caller takes a snapshot, adds the scoring allowlist and the admin source, then the rest of the allows, then calls `default_deny_in` (design 01). The adapter refuses `default_deny_in` (`20`) when no allow for the scoring allowlist has been added in the same run. Every call is recorded in the run manifest, and rollback calls `restore` on the snapshot.

## 6. What it will never do

- Install, enable or switch to a firewall backend that the host is not already using.
- Guess a fact. An unknown fact blocks the module that needs it.
- Change anything while reading a fact.

## 7. Acceptance tests

- Each supported Linux family is recognized from its `/etc/os-release`, including through `ID_LIKE`. An unknown `ID` gives `unknown` for the family.
- With UFW active, the firewall fact is `ufw`, even though nftables shows UFW's own tables.
- With UFW and firewalld both active, the fact is `conflict`, and the firewall module exits `20` without changing anything.
- With no root rights, the firewall fact is `unknown`, not `none`.
- A Windows domain controller, member server and workstation each report the right `role`, and a host without UEFI reports `secure_boot` as `unsupported`.
- Reading every fact leaves the host unchanged: on Linux, no file under `/etc` changes; on Windows, no registry value changes.
- For each adapter on its lab host: `snapshot`, then changes, then `restore` gives the same `state` as before.
- `default_deny_in` with no scoring allowlist added is refused, and the ruleset is unchanged.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
