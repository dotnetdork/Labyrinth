# 07. Cleanup and Tool Integrity

**Status:** Draft · reviewed 2026-10-02 · Phase: 🟩 Sustain · Priority: P1

## 1. Two goals

1. **Cleanup:** when the event ends or a module is removed, leave no stray files, timers, rules or accounts.
2. **Tool integrity:** know that the Labyrinth code on each host is the code that was released, and that nobody changed it.

## 2. Cleanup

- Every module lists its `outputs` in `module.yml` (design 00), and every `apply` writes to the run manifest.
- `cleanup` removes temporary files; `rollback` undoes changes. They are separate so the operator can clean up without reverting.
- End-of-event cleanup removes revert timers, scheduled tasks, temporary accounts and copied code from hosts, but keeps logs and reports until they are collected.
- **Accounts.** The only accounts cleanup ever deletes are ones Labyrinth itself created, such as honey-accounts (design 09), and recorded in the run manifest when it created them. Cleanup never deletes an account that existed before Labyrinth ran; deleting an unexpected account is a separate, approved step during the event (design 05, section 6.4). Domain honey-accounts, created by hand (design 11, section 5), are removed by hand too.
- Cleanup never deletes evidence or anything the manifest does not list. The quarantine area (design 17, section 5) and saved account evidence are evidence: they are kept, like logs and reports, until they are collected.

- Cleanup only touches Labyrinth paths (design 00 standard paths).

## 3. Materials handling

Competition materials, including team-generated reports and documents, must stay in the competition area, and nothing may be removed without authorization (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rules 4.4, 10.5). Collect logs for the debrief only as far as those rules and the officials allow.

## 4. Rejected: encrypted script folder with a shared password

The earlier idea was an encrypted folder, decrypted with a shared team password. It was rejected because:

- The password has to be distributed and typed on every host, which creates the leak it is meant to prevent.
- The team's own code must be public anyway (NCCDC, 2025, Rule 5.6.1), so there is nothing to hide.
- Encryption gives confidentiality, not integrity. The real risk is tampering, not reading.

## 5. Replacement: signed manifest and known commit

| Control | How |
|---|---|
| Release identity | A tagged release with a commit hash. The hash is kept in the team's offline record (design 05, section 2) and matches the declared release (NCCDC, 2025, Rule 5.6.2). |
| Manifest | A list of every file with its SHA-256, generated at release time. The manifest's own SHA-256 is kept in the offline record. |
| Signature | The manifest is signed with a team key, using `ssh-keygen -Y sign`. The public key is kept in the offline record and stored on the control node. |
| Immutable location | Code sits in a root-owned, read-only directory on each host (`<root>/bin`). The core checks this before every `apply`, `keep` and `rollback`, the revert timer's included: the code folder, the configuration folder and the data root, everything in them, and every folder above them must be changeable only by root (Linux) or by administrators, SYSTEM and TrustedInstaller (Windows). On Linux that means owned by root and not writable by group or others; a folder above may be writable if it is sticky, like `/tmp`. Otherwise the command refuses with 20 and changes nothing. The check only reads: Labyrinth never changes the owner or permissions of its own code. The revert timer runs `labyrinth.sh` from the real path, with links resolved. |
| Verify before run | The control node checks the manifest signature before every run. On each host, the runner checks every file against the manifest before it loads any of the core (below), and prints the manifest's SHA-256, which the operator compares by eye with the value in the offline record. |
| Push, run, delete | Code is pushed to a host, run, and removed, unless the module needs a resident component. |

**Why the signature is checked only on the control node.** `ssh-keygen -Y verify` needs OpenSSH 8.1 or later. RHEL 8 ships 8.0, and the OpenSSH bundled with Windows Server 2019 is older still (*Background*), so a host may not be able to check a signature at all. The control node can be chosen to have a recent OpenSSH; hosts only need SHA-256, which they all have. In local mode with no control node, the operator checks the manifest hash by eye against the offline record.

### 5.1 The release check on each host

The manifest is `release.sha256` in Labyrinth's folder: one `<sha256>  <path>` line per file, the format `sha256sum -c` reads, with paths relative to the folder and `/` between folders. It covers `labyrinth.sh`, `labyrinth.ps1` and every file under `core`, `phases`, `platform`, `profiles` and `vendor`. `tools/release/manifest.sh` (or `manifest.ps1`) writes it into the copy that will be deployed and prints its SHA-256, which the team captain records in the offline record. The copy then goes to the hosts byte for byte: a checkout that changes line ends changes the hashes.

- **When.** Every command, before the runner loads the rest of the core: `core/safety/release.sh` and `core/safety/Release.ps1` need nothing else, so a changed core file is found before any of it runs. The revert timer's `rollback` is checked like any other command.
- **What fails.** A listed file that is missing, is a link or differs; a file under the covered paths that the list does not name, such as one dropped into `phases`; a line that is not in the format, names a path outside the folder, or repeats a path; a list that is empty or is itself a link. The command then refuses with `20`, names the first problem, and changes nothing. A refused `rollback` also sends a notice to whoever is logged in (`wall`, `msg`), because the run's changes stay in place.
- **No list.** A copy taken straight from the repository has no `release.sha256`. Then `apply`, `keep` and `rollback` warn `no release.sha256, so Labyrinth's files were not checked`, and the hash lines say `not checked`. They do not refuse: the operator decides, from the team's notes, whether this copy is the one to run.
- **What it shows.** `version` and the recap of every `apply`, just before the group-name prompt, print `Release: <sha256>`. The operator compares it with the offline record by eye.
- **Its limit.** The check is code in the release. An intruder with root who changes the runner or the check as well can make it print the expected hash. What catches that is a check with the host's own tools, which the manual gives: `sha256sum release.sha256` (or `Get-FileHash`) against the offline record, then `sha256sum -c --quiet release.sha256`. The check on each run catches a changed, planted or missing file, a damaged copy, and a partial update; the host's own tools catch the rest.

The persistence sweep covers what the check does not (design 17, section 3): files in Labyrinth's data root that no run record explains, and look-alike timers and tasks.

Resident components (timers, watchers) are hashed by the integrity check (design 04) like any other critical file.

```mermaid
flowchart TD
    REL["Tagged release<br/>commit hash in the offline record"] --> MAN["Manifest: SHA-256 of every file"]
    MAN --> SIG["Manifest signed with the team key"]
    SIG --> CHK{"Control node checks the signature;<br/>host checks the manifest hash<br/>and every file hash"}
    CHK -->|mismatch| NO(["Refuse to run"])
    CHK -->|match| RUN["Push code to host, run it"]
    RUN --> RES{"Module needs a<br/>resident component?"}
    RES -->|no| DEL["Remove pushed code"]
    RES -->|yes| KEEP["Keep in read-only {root}/bin;<br/>hashed by the integrity check"]
    DEL --> CLN["End of event: cleanup removes only<br/>what the run manifest lists"]
    KEEP --> CLN
    classDef sustain fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class REL,MAN,SIG,RUN,DEL,KEEP,CLN sustain
    class NO stop
```

*Figure: code runs only after the signed manifest and every file hash match the declared release, and cleanup later removes only what the run manifest recorded. Green is sustain work and the dashed red outline is the refusal.*

## 6. Acceptance tests

- A tampered module file makes the pre-run check fail and the run refuse to start.
- A changed core file makes every command refuse with `20` before any of the core runs, the revert timer's `rollback` included, which also sends a notice. A file added under `core` or `phases`, and a listed file that is missing, are refused the same way.
- With no `release.sha256`, `apply`, `keep` and `rollback` warn and go on, and the hash lines say `not checked`. With one that matches, `version` and the apply recap print its SHA-256.
- Code, configuration or a data root that an account other than root (Linux) or an administrator (Windows) can change makes `apply`, `keep` and `rollback` refuse with 20, and nothing changes.
- A wrong signature is rejected.
- A manifest whose SHA-256 differs from the offline record's value is rejected on a host with no `ssh-keygen -Y`.
- Cleanup deletes a honey-account the manifest lists and leaves every account that existed before the run.
- After cleanup, a listing of Labyrinth paths, timers, tasks and rules matches the pre-run inventory except for kept logs.
- Cleanup run twice gives the same result.
- Rollback restores the changed files byte for byte.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
