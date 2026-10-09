# 17. Persistence Sweep

**Status:** Draft · reviewed 2026-10-05 · Phase: 🟥 Lock out · Priority: P0

## 1. Goal

Assume the attacker is already inside when the event starts. Someone who got in early leaves ways back: scheduled jobs, services, startup items, keys, sudo rules and login hooks. Rotating passwords and ending sessions (design 01) does not remove any of them, so the attacker simply returns.

This spec finds those footholds and removes them as early as is safe, without breaking a scored service. Scored services are a primary Red Team target, and successful penetrations cost points (National Collegiate Cyber Defense Competition [NCCDC], 2025, Scoring section), so the sweep covers them too.

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Scoring is based partly on controlling and preventing unauthorized access (NCCDC, 2025, Scoring section). No rule forbids removing an attacker's foothold. | Removal is part of the job, not an optional extra. |
| Tools must not deliberately break expected functionality (NCCDC, 2025, Rule 5.6.5). | Never a blanket action such as removing every cron job. Each item is judged on its own and quarantined, never deleted. |
| Anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | An item a scored service depends on is never removed automatically. Probes run before and after, under a revert timer. |
| Reports must say what happened and what was affected (NCCDC, 2025, Rule 9.4). | Quarantine keeps every item, so it can be shown as evidence in the report (design 02). |

## 3. Where it looks

| Platform | Persistence points |
|---|---|
| Linux | System and per-user crontabs, `cron.d`, anacron, `at` jobs; systemd units and timers (system and per-user); `rc.local` and init scripts; shell startup files (`/etc/profile.d`, system and user `bashrc` and `profile`); `sudoers` and `sudoers.d`; PAM configuration; `ld.so.preload`; SSH configuration and every key source (design 05, section 4); setuid files and kernel modules not owned by a package; web server and PHP modules or extensions not owned by a package (Apache and nginx modules, `php.ini` `extension=` and `auto_prepend_file` lines) |
| Windows | Services; scheduled tasks; Run and RunOnce registry keys; startup folders; WMI event subscriptions; Winlogon `Userinit` and `Shell` values; Image File Execution Options debuggers; replaced accessibility programs (`sethc.exe`, `utilman.exe`); members of the local Administrators group; unsigned DLLs in a service's own folder (report only, because DLL hijacking is hard to judge automatically); IIS modules and handlers not in the profile's known-good list |
| Both | Remote-access and tunnel tools (for example AnyDesk, TeamViewer, ScreenConnect, ngrok, chisel, rclone, plink), found as installed services, running processes or program files and matched against the release's data file (design 10, section 5) |
| SIEM host | Splunk apps, scripted inputs and alert actions (design 10, section 7) |
| Scored apps | Files in a web root or application folder that look like web shells, and CMS plugins or themes not in the app's original install (flagged only; section 4) |


## 4. Classes

Each item found is checked three ways:

- **Owned by a package?** On Linux, `dpkg -S` or `rpm -qf`, then a verify of that package's files. On Windows, signed by Microsoft, or listed in the profile's known-good list.
- **Does a scored service depend on it?** Checked through the service's unit dependencies, its process tree, its files and its run-as account (design 05, section 2).
- **Does it show a strong sign of attack?** See the list below.

| Class | Which items | What happens |
|---|---|---|
| **Known good** | Owned by a package and unmodified, or on the profile's known-good list | Left alone; baselined (design 04) |
| **High confidence** | Not owned by a package, **and** nothing scored depends on it, **and** at least one strong sign | Quarantined automatically in the first-minute bundle (design 01, section 6). Tier 2, with probes and a revert timer. |
| **Unexplained** | Any other item not owned by a package, a package file that fails verification, or an item belonging to a protected account | Listed in the plan with the reason. A person approves each item, or a whole category on one host; Labyrinth then quarantines them (Tier 3, design 01). |
| **Scored-app content** | Files inside a scored app's own folders that look like web shells | Listed with the reason. A person confirms each one, because a false positive takes the site down. Labyrinth then quarantines it. |

**Strong signs** (any one is enough):

- it runs from `/tmp`, `/var/tmp`, `/dev/shm`, a hidden folder, or a user's temporary folder on Windows;
- it opens a shell to the network (`/dev/tcp/`, `nc -e`, `socat exec:`, `bash -i` redirected to a socket);
- it decodes and runs code (`base64 -d | sh`, `powershell -enc`, `FromBase64String` piped to `Invoke-Expression`);
- it downloads and runs something (`curl … | sh`, `wget -O- … | sh`, `DownloadString`, `certutil -urlcache`, `bitsadmin /transfer`);
- it is a replaced Windows accessibility program, or an Image File Execution Options debugger on one.

The list lives in a data file in the release, so it is reviewed and tested like code.

A remote-access or tunnel tool is never high confidence on its name alone, because the company may use it for support. It is **unexplained**, and waits for approval, unless the profile lists it as known good or it also shows a strong sign, such as running from a temporary folder.

```mermaid
flowchart TD
    F["Persistence item found"] --> PKG{"Owned by a package<br/>and unmodified?"}
    PKG -->|yes| OK(["Known good:<br/>left alone, baselined"])
    PKG -->|no| DEP{"Does a scored<br/>service depend on it?"}
    DEP -->|yes| APP["Unexplained:<br/>a person approves"]
    DEP -->|no| SIG{"Strong sign<br/>of attack?"}
    SIG -->|yes| AUTO["High confidence:<br/>quarantined in the first minute"]
    SIG -->|no| APP
    APP -->|approved| Q["Labyrinth quarantines it"]
    AUTO --> EV[("Quarantine area:<br/>kept as evidence")]
    Q --> EV
    classDef lockout fill:#fde8e8,stroke:#c0392b,color:#4a1111
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    class F,AUTO,Q lockout
    class APP human
    class OK ok
    class EV store
```

*Figure: every item found is sorted by package ownership, scored-service dependency and signs of attack; only clear, unshared attacker footholds are quarantined automatically, and everything else waits for a person's approval. Red is lock-out work, amber a person's decision, green an item left alone and gray the quarantine area.*

## 5. Quarantine, never delete

Quarantine disables the item and moves it aside, recording what is needed to put it back. The run manifest lists every step, so `rollback` restores the item exactly.

| Item | Quarantine |
|---|---|
| A file (script, unit file, startup file, web shell) | Moved to `<root>/backup/quarantine/<run>/<seq>/<original path>`, keeping its original path, owner, mode and SHA-256 |
| A cron line | Commented out with a Labyrinth marker; the original line is kept in the manifest |
| A systemd unit or timer | Disabled and stopped, its file and the drop-ins no package installed quarantined, then `systemctl daemon-reload`. A transient unit is stopped and recorded; it has no file to keep |
| A Windows scheduled task | Exported to XML, then disabled |
| A Windows service | Start type recorded, set to Disabled and stopped |
| A registry value or WMI subscription | Exported, then removed |
| A process the item started | Ended once the item is quarantined, so it cannot simply restart |

The quarantine area is readable only by root or SYSTEM (design 00, section 7). It is kept until the end of the event as evidence, and each item feeds the incident record (design 02).

### 5.1 The quarantine helper

Quarantine is a core helper (`core/quarantine/`), so every module that removes a foothold uses the same steps and the same records. The helper does not judge an item: the module decides the class (section 4) and passes the reason, which is kept in the manifest's `note`.

| Item | Linux | Windows | Manifest action |
|---|---|---|---|
| File | `lab_quarantine_file PATH REASON` | `Move-LabQuarantineFile -Path P -Reason R` | `quarantine_file`: `backup` is the quarantined copy, `prev` the owner, mode and SHA-256 (on Windows, the SHA-256) |
| Cron line | `lab_quarantine_cron FILE LINE REASON` | | `quarantine_cron`: `prev` is the original line |
| systemd unit | `lab_quarantine_unit UNIT REASON` | | `quarantine_unit`: `prev` is whether it was enabled and active (`transient=yes` for a transient unit, `dropins=only` when only a package unit's added drop-ins were quarantined); its file and each drop-in get their own `quarantine_file` entry |
| Scheduled task | | `Disable-LabQuarantineTask -TaskPath P -TaskName N -Reason R` | `quarantine_task`: `backup` is the exported XML, `prev` whether it was enabled |
| Service | | `Disable-LabQuarantineService -Name N -Reason R` | `quarantine_service`: `prev` is the start mode and whether it was running |
| Registry value | | `Move-LabQuarantineRegistryValue -Path P -Name N -Reason R` | `quarantine_registry`: `backup` holds the value's name, kind and data |
| WMI subscription | | `Move-LabQuarantineWmiBinding -Filter F -Consumer C -Reason R` | `quarantine_wmi`: `backup` holds the binding, filter and consumer; only the binding is removed, which stops the subscription |
| Process | `lab_quarantine_process PID REASON` | `Invoke-LabQuarantineProcess -Id N -Reason R` | `quarantine_process`: `prev` is its command line |

- **Return codes:** `0` done (or the item is already gone, so there was nothing to do), `20` the item was left as it is (refused, or it could not be moved, such as an immutable or locked file), `40` error; the reason goes to standard error. A module treats `20` as one item for a person, lists it, and goes on with the rest: an item an attacker shaped must never stop the sweep or undo the items already quarantined.
- **Item text is kept as it is.** A file name, cron line or process command line may hold tabs or other control characters. The manifest escapes them, so they never stop a quarantine.
- **Refused:** in plan mode; a path that is not absolute, is a folder, or is inside Labyrinth's own root; a cron line that is not in the file; a unit with no unit file; a unit a package installed, asked of the package database (`dpkg-query -S` or `rpm -qf`), not read from its path, since an intruder can write a unit to `/usr/lib` or `/run` too (a package's unit file is never quarantined and its unit is only disabled after approval, in design 15, but its drop-ins that no package installed are quarantined first); a unit outside `/etc` and `/run` on a host with no package database, which cannot tell; process 1 and Labyrinth's own process and its parents.
- **Recorded first.** Each step is in the manifest before it is made (Conventions, section 7).
- **Restore.** `lab_quarantine_restore` (`Undo-LabQuarantine`) undoes the current module's quarantine entries, newest first, and a module's `rollback` calls it next to `lab_restore_files`. A file comes back to its path with its owner, mode and SELinux label, after its SHA-256 is checked against the manifest; a file now at that path is moved aside, never overwritten. A cron line is uncommented in place, leaving the rest of the file as it is. A unit is enabled and started again if it was before. A transient unit cannot be brought back, like a process: its entry is the record. A task, service, registry value or binding is put back as exported. Restoring is safe to repeat.
- **A process cannot be restored.** Ending it is recorded, and rollback restores the item that started it, which restarts it if it is a unit or service that was running.
- **Cron.** Commenting a line in a per-user crontab under the cron spool also touches the spool folder, so cron reads the change.
- **Values every logon needs.** Winlogon's `Userinit` and `Shell` are never removed, because a host without them cannot log anyone on. A planted value there is listed for approval, and a person sets it back to the Windows default.
- **Linux owner and mode; Windows ACL.** On Linux the restore puts back the owner and mode recorded in the manifest. On Windows a file moved within one volume keeps its ACL; the restore does not rewrite it.

## 6. Limiting who can schedule jobs

After the sweep, `cron.allow` and `at.allow` are set to root plus any account the dependency map shows using them. Other accounts then cannot add jobs. This is Tier 2, with probes and a revert timer.

Watching tools often abused for persistence, rather than blocking them, is covered in design 10, section 5.

## 7. When it runs

- **First minute:** the high-confidence class runs inside the first-minute bundle, right after sessions are ended (design 01, section 6).
- **Right after the bundle:** the full list of unexplained items is shown for approval.
- **At every checkpoint** (design 13): the sweep runs again in report mode. After the baseline is sealed (design 04, section 6), any new persistence item is a high-ranked integrity finding.

## 8. What it will never do

- Delete an item. Everything is quarantined and can be restored.
- Remove an item a scored service depends on without a person's approval.
- Touch a protected account's items without a person's approval.
- Act on a whole category across every host in one step.

## 9. Acceptance tests

- A planted cron job that opens a reverse shell from `/tmp` is quarantined automatically, its process is ended, and every scored probe still passes.
- An unpackaged cron job that a scored app uses is listed for approval, not quarantined.
- A planted web shell in a web root is listed with its reason and is quarantined only after approval.
- `rollback` restores every quarantined item byte for byte.
- A replaced `sethc.exe` on a lab Windows host is detected and quarantined.
- A lab install of a remote-support tool is listed for approval, not quarantined automatically; a tunnel tool running from a temporary folder is quarantined automatically.
- Each quarantined item appears in the incident record with its hash and original path.
- No item is ever deleted.
- Each quarantine step is in the run manifest before it is made, and a module's rollback restores every item it quarantined; restoring twice changes nothing.
- A file put back is checked against its recorded SHA-256 first; a quarantined copy that changed is not restored, and a file found at the original path is moved aside, not overwritten.
- A unit in `/usr/lib` or `/run` that no package owns is quarantined; a transient unit is stopped and recorded.
- Quarantine is refused in plan mode, for a folder, for a path inside Labyrinth's own tree, for a systemd unit a package installed (its added drop-ins are quarantined) or, with no package database, one outside `/etc` and `/run`, for process 1 and Labyrinth's own processes, and for Winlogon's `Userinit` and `Shell` values.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
