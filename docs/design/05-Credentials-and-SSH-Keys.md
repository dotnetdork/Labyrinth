# 05. Credentials and SSH Keys

**Status:** Draft · reviewed 2026-09-29 · Phase: 🟥 Lock out · Priority: P0

## 1. Rules that shape it

| Rule | Effect |
|---|---|
| Administrator-class passwords are not used for scoring and may be changed freely; other user passwords need the notification process (Midwest Collegiate Cyber Defense Competition [MWCCDC], 2025, Rule 13) | Automation rotates admin-class credentials only. |
| Officials must get access on request (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 4.1) | When an official asks, the captain gives them a working credential from the team's offline record or logs in for them. No standing account or key is created for this (section 5). |
| POP3 (Post Office Protocol 3) scoring uses domain users (MWCCDC, 2025, Functional Services section; *Provisional*) | Domain-wide password resets are manual-only. |
| No deliberate breakage (NCCDC, 2025, Rule 5.6.5) | Never disable accounts wholesale. |

## 2. Password rotation

- **Who is rotated:** root, Administrator and equivalents, and team operator accounts. Never scoring accounts.
- **Generation:** a cryptographic random source, a length chosen by the profile, and a character set that survives the target's shell and login prompt.
- **Record:** shown once on the operator's screen, to be copied into the team's offline record. Labyrinth never writes it to disk, logs or shell history.
- **The offline record** is where the team keeps the secrets Labyrinth must not store: new passwords, the break-glass credential, the event seed (design 03) and the release fingerprint (design 07). It stays out of the repository and off every competition host: on paper, or in a local file on an operator's own machine that is not synced to any cloud service, because outside storage and collaboration services are prohibited during the event (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 5.2). Teammates share these secrets only through the official team chat or in person. Activity on that chat may be logged and released (NCCDC, 2025, Rule 5.5), so every credential shared there is rotated after the event (section 5).
- **Order:**
  1. Set the new credential.
  2. Test it from a fresh session.
  3. Acknowledge that it is recorded.
  4. Only then close the old session.
- **User-level accounts:** manual checklist only, following the notification process.
- **Crown jewels** (domain admin, KRBTGT) rotate at set checkpoints, not continuously. KRBTGT needs two resets with a replication wait and is manual-only.

## 3. Username policy

Choosing our own names or random ones is a trade-off:

| Approach | Benefit | Cost |
|---|---|---|
| Random names for new operator accounts | Harder to guess | Harder for the team to remember and to type under stress |
| Role-based names (`ops-linux`, `ops-win`) | Easy to use and audit | Guessable |
| Renamed built-ins (where allowed) | Removes the default target | Can break services and scripts |

**Recommendation:**

- Keep built-in admin names unless the packet allows changes.
- Add role-based operator accounts with strong credentials.
- Rely on keys plus source restriction rather than name secrecy.
- Renames are manual-only.

## 4. SSH key design

- **Algorithm:** ed25519.
- **One key per role**, not per person and not one for all: `ops-linux`, `ops-monitor`. Losing one key limits the blast radius. There is no break-glass key (section 5).
- **Restrictions in `authorized_keys`:** `from="<control node>"`, `restrict`, and `command="<forced command>"` for automation keys.
- **Registry:** a signed list of approved public keys per host (state path). Anything else found in an authorized keys file is backed up, then removed, by the lockout module.
- **Rotation:** generate a new key, install it alongside the old one, test a fresh login, then remove the old key. Rotation is a module run, not a manual edit.
- **Private keys** stay on the control node, protected with a passphrase, never copied to managed hosts.
- **Optional:** short-lived SSH (Secure Shell) certificates from a team certificate authority if the team decides the added moving part is worth it.
- **Ubuntu 24.04:** SSH is socket activated, so changes to the listening port need the socket unit as well as the daemon configuration.
- **Hardening:** a drop-in file in `sshd_config.d`, tested with `sshd -t` before reload, with a dead-man revert (design 01).

```mermaid
flowchart TD
    subgraph pw["Password rotation (section 2)"]
        direction LR
        P1["Set the new credential"] --> P2["Test it from a fresh session"]
        P2 --> P3["Operator acknowledges it<br/>is in the offline record"]
        P3 --> P4(["Close the old session"])
    end
    subgraph key["SSH key rotation (section 4)"]
        direction LR
        K1["Generate a new ed25519 key"] --> K2["Install it alongside<br/>the old key"]
        K2 --> K3["Test a fresh login"]
        K3 --> K4(["Remove the old key"])
    end
    pw ~~~ key
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef ok fill:#e3f6e8,stroke:#15803d,color:#0f3d20
    class P3 human
    class P4,K4 ok
    style pw fill:#fde8e8,stroke:#c0392b,color:#4a1111
    style key fill:#fde8e8,stroke:#c0392b,color:#4a1111
```

*Figure: passwords and SSH keys rotate in the same order: the new credential is created and tested before the old one is closed or removed. Both lanes are lock-out work (red); amber is the operator's own step and green is the safe end point.*

## 5. Break-glass and official access

Break-glass is how the team gets back into a host it has locked itself out of. It is also what the captain hands over when an official asks for access. Officials run the virtualization platform, so they already have each host's console; what they may need from the team is a working login.

A break-glass path must not become a backdoor, so:

- **No new account and no key.** The break-glass credential is the rotated password of an existing admin-class account (root or the local Administrator), kept by the captain in the team's offline record (section 2). Labyrinth never creates an account or an SSH key for it.
- **Console first.** It is verified at the host's console before any change (design 01 gate). Where the platform allows it without blocking the team's own admin path, it works only at the console; on Linux, `PermitRootLogin no` in the SSH drop-in (section 4) already does this.
- **Rotated like any admin password.** Its rotation follows section 2, and the new password is verified at the console before the next change. It is never locked or removed. Unregistered SSH keys on the account are still removed.
- **Watched.** A successful logon with it raises an alert (design 10, section 5).
- **Rotated after use** and after the event.

**Official accounts** named in the event packet are never changed without the White Team's permission. They are still watched: their logons raise an alert, and the team confirms unexpected ones with the White Team. If the White Team agrees, the captain rotates the password and hands them the new one.

## 6. Acceptance tests

- After rotation, the new credential works from a fresh session and the old fails.
- A scoring account is unchanged.
- An unregistered key is removed and backed up; a registered key stays.
- A key with a wrong source address cannot log in.
- A bad `sshd` configuration is rejected by the syntax test and does not reload.
- A dead-man revert restores SSH access when verify is failed on purpose.
- No account or SSH key is created for break-glass.
- The break-glass password works at the console after rotation, and root cannot log in over SSH.
- A logon with the break-glass credential or an official account raises an alert.

## References

Midwest Collegiate Cyber Defense Competition. (2025). *2025 Midwest Collegiate Cyber Defense Competition qualifier team packet* [PDF]. https://brazil.minnesota.edu/ccdc/ccdc-2025/2025MWCCDCQTeamPack.pdf

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
