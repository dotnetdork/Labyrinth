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

**Windows** (`Get-LabFact -Name <name>`; `Get-LabFact` with no name returns every fact as an ordered table, and `Clear-LabFact` forgets the kept values):

| Fact | Values | Learned from |
|---|---|---|
| `os_caption` | For example `Microsoft Windows Server 2022 Standard` | `Win32_OperatingSystem` |
| `os_build` | The build number, for example `20348` | `Win32_OperatingSystem` |
| `role` | `workstation`, `member-server`, `standalone-server` or `domain-controller` | `ProductType` and `PartOfDomain` |
| `firewall` | `on` (every profile on), `partial`, `off` or `unknown` | `Get-NetFirewallProfile` |
| `secure_boot` | `on`, `off`, `unsupported` (no UEFI) or `unknown` (for example, without administrator rights) | `Confirm-SecureBootUEFI` |
| `ad_module` | `yes` or `no`: whether the ActiveDirectory PowerShell module is present (design 11, section 3.2) | `Get-Module -ListAvailable` |
| `splunk_forwarder` | `yes` or `no` (design 10, section 4) | Whether the `SplunkForwarder` service exists |

**Optional tools.** `lab_have <tool>` (`Test-LabTool -Name <tool>` on Windows) says whether a command is on the path, for the tools Labyrinth must not assume, such as `jq`, `python3`, `curl` and `dig`. A module that can use one has a slower path that works without it.

**Tests.** On Linux, facts read their files under `LAB_SYSROOT` when it is set (default: empty, the real root), so tests can supply a fake `/etc/os-release` and `/run/systemd/system`. Commands are replaced by stubs on the path. On Windows, the cmdlets are mocked in Pester.

### 3.1 Which firewall is active (Linux)

Each backend is checked in this order:

1. **UFW** is active when `ufw status` reports `Status: active`.
2. **firewalld** is active when `firewall-cmd --state` reports `running`.
3. **nftables** is active when the `nftables` service is active, or when `nft list tables` shows a table that `iptables-nft` or firewalld did not make. `iptables-nft`, which UFW and Docker use, makes the `filter`, `nat`, `mangle`, `raw` and `security` tables in the `ip` and `ip6` families; firewalld makes `inet firewalld`.
4. **iptables** counts only when none of the above is active: `iptables -S` shows anything but the default `ACCEPT` policies. UFW drives iptables itself, so its rules there are not a second firewall.

- One active backend gives its name.
- None gives `none`.
- More than one of UFW, firewalld and nftables gives `conflict`.
- A check that fails to run, for example `ufw status` or `nft list tables` without root rights, gives `unknown`, whatever the other checks found.

## 4. Layout

| Path | Holds |
|---|---|
| `core/platform/platform.sh`, `core/platform/Platform.ps1` | The facts, loaded with the rest of the core |
| `platform/linux/firewall/<backend>.sh` | One firewall adapter per Linux backend (section 5) |
| `platform/ubuntu/`, `platform/rhel-family/` | Adapters that differ by family, such as package ownership (`dpkg -S` or `rpm -qf`) |
| `platform/windows/Firewall.ps1` | The Windows Firewall adapter |
| `platform/appliance/` | Runbooks and templates only (design 16) |

The `hosts` file's platform `ubuntu` covers the whole Debian family, and `rhel-family` covers Fedora, RHEL, Rocky, Oracle Linux and AlmaLinux (Conventions, section 3.1).

## 5. The firewall adapter

Every backend's adapter offers the same functions, so the firewall, ban and egress modules never call a backend directly. On Linux they are called through one dispatcher, `lab_fw FUNCTION ARGS` (in `platform/linux/firewall/firewall.sh`, which a module sources). The dispatcher picks the backend from the `firewall` fact and refuses (`20`) when the fact is `none`, `conflict` or `unknown`; `restore` instead uses the backend named in the snapshot, so a rollback still works after the fact changes. A host with no active firewall is reported for a person, because the adapter never turns one on (section 6). On Windows the functions are in `platform/windows/Firewall.ps1`, and they refuse (`20`) when the `firewall` fact is `unknown`.

| Function (Linux) | Windows | Does |
|---|---|---|
| `snapshot [DIR]` | `Save-LabFirewallSnapshot [-Path DIR]` | Saves the complete current ruleset to DIR, in a form `restore` can load back exactly. DIR defaults to `<backup>/<run>/<module>/<seq>-firewall`. |
| `restore DIR` | `Restore-LabFirewallSnapshot -Path DIR` | Puts back the ruleset saved in DIR, then compares `state` with the state saved at the snapshot |
| `allow PROTO PORT SOURCE` | `Add-LabFirewallAllow -Protocol P -Port N -Source S` | Allows inbound PROTO (`tcp` or `udp`) on PORT from SOURCE (an address or CIDR, or `any`) |
| `default_deny_in` | `Enable-LabFirewallDefaultDeny` | Sets the inbound default to deny, keeping established connections, loopback and ICMP (design 01, section 2) |
| `state` | `Get-LabFirewallRuleState` | Prints the current rules, normalized so two snapshots can be compared: packet counters are removed |
| `lab_fw_rollback` | `Undo-LabFirewallChange` | Restores, newest first, every snapshot the current module took in the current run. A module's `rollback` calls it. |

**Return codes.** Each function returns `0` on success, `20` when refused, `30` when a restore does not give back the saved state, and `40` on an error, so a module can pass the code straight on as its exit code. The reason goes to standard error.

**Order and records.** The order is fixed. The caller takes a snapshot, adds the scoring allowlist and the admin source, then the rest of the allows, then calls `default_deny_in` (design 01). The adapter enforces it:

- `allow` and `default_deny_in` are refused (`20`) until the current module has taken a snapshot in the current run, and in plan mode.
- `default_deny_in` is refused (`20`) unless every address in the run-time `scoring-allowlist` has been the source of an `allow` in the current run. The adapter keeps the run's allows in `<state>/runs/<run>/firewall-allows`.
- Each change is recorded in the run manifest before it is made (Conventions, section 7): `firewall_snapshot` (target: the backend; backup: DIR) once the snapshot is saved, then `firewall_allow` and `firewall_default_deny`. Rollback restores from the `firewall_snapshot` entries; the other two are the record of what was done.
- Repeating `allow` with the same arguments in the same run changes nothing.

**Backends.**

| Backend | Snapshot and restore | `allow` | `default_deny_in` |
|---|---|---|---|
| UFW | Copies of the rules files in `/etc/ufw`, `ufw.conf` and `/etc/default/ufw`, written back in place, then `ufw reload` | `ufw prepend allow`, so the allow comes before any existing deny rule | `ufw default deny incoming`. UFW's own `before.rules` keep loopback, established connections and ICMP; the call is refused (`20`) if `before.rules` no longer accepts ICMP echo requests. |
| firewalld | A copy of `/etc/firewalld`, written back in place, then `firewall-cmd --reload`. A file added since the snapshot is moved into the snapshot folder, never deleted. | A port, or a rich rule when the source is not `any`, in every active zone, both at run time and in the permanent configuration | ICMP rich rules, then the zone target `DROP`, in every active zone; then a reload. firewalld itself keeps loopback and established connections. |
| nftables | `nft list ruleset`, loaded back with `nft -f` in one transaction that first clears the ruleset | A rule in Labyrinth's own table, `inet labyrinth`, whose `input` chain runs before the other tables' chains | Loopback, established-connection and ICMP rules, then the `input` chain's policy `drop` |
| iptables | `iptables-save` and `ip6tables-save`, loaded back with `iptables-restore` and `ip6tables-restore` | A rule in Labyrinth's own chain, `LAB-INPUT`, jumped to from the top of `INPUT`, for IPv4, IPv6 or both | Loopback, established-connection and ICMP rules in `LAB-INPUT`, then the `INPUT` policy `DROP` |
| Windows Firewall | `netsh advfirewall export`, loaded back with `netsh advfirewall import` | An inbound allow rule in the rule group `Labyrinth` | ICMPv4 and ICMPv6 allow rules, then every profile on, with inbound default `Block` and local allow rules honored |

**Known limits.** Each one is a reason for the acceptance tests on a real host (section 7):

- **firewalld:** the snapshot is of the permanent configuration. A rule that exists only at run time when the snapshot is taken is lost at the next reload. The snapshot warns when the run-time and permanent rules differ, and the restore then reports `30`.
- **nftables:** an accept in Labyrinth's table does not override a drop in another table's chain on the same hook. The firewall module's plan lists such drops for a person to review.
- **Windows Firewall:** a block rule always wins over an allow rule, and Group Policy settings win over local ones. The firewall module's plan lists enabled inbound block rules and policy-set profiles.
- **nftables and iptables:** the changes last until the ruleset is next reloaded or the host restarts. The health monitor re-applies the sealed rules when they drift (design 13, section 4.1).

## 6. What it will never do

- Install, enable or switch to a firewall backend that the host is not already using. Windows Firewall is always present on Windows, so `default_deny_in` there turns its profiles on, as part of the deny the caller asked for.
- Delete a file to restore a snapshot. A file the snapshot did not hold is moved into the snapshot folder.
- Change the firewall without a snapshot taken by the same module in the same run.
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
- `default_deny_in` with no scoring allowlist added is refused, and the ruleset is unchanged. The same holds when one scoring-allowlist address has no allow.
- `allow` and `default_deny_in` before a snapshot, or in plan mode, are refused and change nothing.
- Each change is in the run manifest before it is made, and `lab_fw_rollback` (`Undo-LabFirewallChange`) restores the snapshot.
- After `default_deny_in` on each lab host, the host still answers ping, an allowed port from an allowed source still connects, and an established session survives.
- With the firewall fact `conflict`, `none` or `unknown`, every function but `restore` is refused (`20`) and calls no firewall command.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
