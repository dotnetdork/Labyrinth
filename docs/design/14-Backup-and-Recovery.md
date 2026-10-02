# 14. Backup and Recovery

**Status:** Draft · reviewed 2026-10-02 · Phase: 🟩 Sustain · Priority: P1

## 1. Goal

Make every scored service restorable, not just every change reversible.

The module contract already backs up each file before a module changes it (design 00), which lets `rollback` undo Labyrinth's own changes. It does not help when the damage comes from somewhere else: a defaced web root, a dropped database table, a corrupted zone file or a wrecked domain controller. Recovery from those is slow and error-prone by hand, so this spec adds **service restore points** (Blueprint §3.11).

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| Tools must not deliberately break expected functionality (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.6.5). | A backup must never fill a disk or lock a database long enough to fail a check (section 5). |
| Scored services may not be migrated or containerized (NCCDC, 2025, Rule 4.14). | A restore puts data back in place on the same host. It never moves a service. |
| Competition materials stay in the competition area (NCCDC, 2025, Rules 4.4, 8.5). | Backups never leave the event network. |
| Team tools may not use outside resources apart from DNS (NCCDC, 2025, Rule 5.6.4). | No cloud or remote backup target. |

## 3. What is backed up

| Service type | Restore point | Tool (*Background*) |
|---|---|---|
| Any scored service | Its configuration directory | Archive with owners and permissions kept |
| Web | The web root and the web server configuration | Archive |
| Database behind a scored service | A logical dump | The database's own dump tool, with its consistent-snapshot option so tables are not locked |
| Mail | Server configuration; mailboxes only if space allows | Archive |
| DNS | Zone files, or an export of each zone on Windows | Archive or the DNS server's export command |
| Domain controller | System state, which includes the AD (Active Directory) database | Windows Server Backup, only if the feature is already installed |

The list of what to back up comes from the profile. Paths are templates filled from run-time configuration.

## 4. When

- **Before patching** a service (design 15).
- **Before the first Tier 2 change** on a host (design 01).
- **On demand** through `labyrinth backup <service>`, and as a prompt in the checkpoint summary, which shows the time since each service's last backup (design 13).

How often to take further restore points is for the team's own plan.

```mermaid
flowchart LR
    TRG["Trigger:<br/>before patching · before Tier 2<br/>· on demand"] --> SPC{"Enough free disk<br/>after the backup?"}
    SPC -->|no| REF(["Refuse; tell the operator"])
    SPC -->|yes| BK["Take the restore point<br/>(archive or dump)"]
    BK --> HS["Hash it into the<br/>backup manifest"]
    HS --> ST[("Backup path,<br/>root or SYSTEM only")]
    ST -.->|"when needed"| RS["Restore: printed steps,<br/>hash checked first"]
    classDef sustain fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class TRG,SPC,BK,HS sustain
    class RS human
    class ST store
    class REF stop
```

*Figure: a restore point is taken only when the disk has room, is hashed into a manifest and stored where only an administrator can read it, and a restore checks that hash before a person follows the printed steps. Green is sustain work, amber the person's restore, gray the storage and the dashed red outline a refusal.*

## 5. Safety

- **Disk space.** Estimate the size first. Refuse if the backup would leave less than the configured free-space margin. A full disk stops services.
- **Load.** Dumps use the consistent-snapshot option and run at low priority. The health probes (design 13) run before and after.
- **Secrets.** Backups contain password hashes and application data. They are readable only by root or SYSTEM, are never copied into the repository or off the event network, and are listed in the run manifest so cleanup can remove them at the end of the event (design 07).
- **Tampering.** Each restore point's SHA-256 is recorded in a backup manifest when it is taken. A restore checks the hash first, so a backup an attacker has altered is never restored silently.
- **Copy off the host.** Optionally, a copy goes to the control node over the existing admin path (design 06), so a destroyed host does not take its backups with it.

## 6. Restoring

| What | How | Tier |
|---|---|---|
| A file Labyrinth changed | The module's own `rollback` (design 00) | Automatic |
| Service configuration or web root | Printed step list: check the hash, stop the service if needed, restore, start it, run the probes | 3, manual |
| Database | Printed step list: check the hash, restore the dump into the running database, run the probes | 3, manual |
| Domain controller | A documented recovery path following Microsoft's procedure for the installed version, practiced in the lab | 3, manual |

Restores are manual because they overwrite live data. A person must confirm that the restore point is from before the damage.

## 7. Acceptance tests

- A defaced lab web root is restored from its restore point, and the probe passes.
- A database dump is taken while the probe runs every few seconds, and no probe fails.
- A backup that would breach the free-space margin is refused.
- An altered backup file is detected by its hash and not restored.
- Backup files are unreadable by a non-admin account.
- End-of-event cleanup removes every backup the manifest lists and nothing else.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
