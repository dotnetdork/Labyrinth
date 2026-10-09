# 12. Dynamic Bans

**Status:** Draft · reviewed 2026-10-02 · Phase: 🟪 Deceive · Priority: P2

## 1. Goal

Turn repeated hostile touches into automatic, expiring blocks, and keep the blocking fast when there are thousands of them (Blueprint §3.5). A ban drops the address in both directions, so an implant cannot call back to an address that is already banned, and a known callback address can be banned outbound once a person confirms it (section 6.1). Most ban triggers are trap hits from the deception layer (design 09), so bans are deployed with it, after logging is in place (design 10).

## 2. Rules that shape it

| Rule | Effect |
|---|---|
| No offensive activity against systems outside the team's network (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 4.10). | A ban drops traffic on the team's own host, inbound from the address and outbound to it. Dropping traffic is not offensive activity. A ban never scans, probes or contacts the address. |
| Active responses such as TCP resets are allowed, and anything that interferes with the scoring engine is the team's responsibility (NCCDC, 2025, Rule 4.11). | A ban may cut a connection already open to the banned address. The scoring engine and the host's outbound dependencies can never be banned (section 4), and automatic bans are refused when the host cannot tell sources apart (section 5). |
| Tools must not deliberately break expected functionality; indiscriminately ending all outbound connections is given as an example (NCCDC, 2025, Rule 5.6.5). | Blocking one hostile address is targeted, not indiscriminate. Bans are per address and expiring. There is no "block everything" mode, and an outbound ban never covers a range (section 6.1). |
| Team tools may not use outside resources apart from DNS (NCCDC, 2025, Rule 5.6.4). | Offenders are never reported to or checked against an outside reputation service. |
| Officials make manual scoring checks, and traffic generators send ordinary user traffic, and suspicious traffic, from random source addresses; anything that interferes with the scoring engine or manual scoring checks is the team's responsibility (Midwest Collegiate Cyber Defense Competition [MWCCDC], 2025, Competition Rules 5, 6 and 14; *Verified* 2026-10-09). | Not every legitimate client of a scored service comes from the scoring engine's address, and a simulated user may fail a login. So failed logins on a scored service's login only raise an alert (section 3). A trap port, the planted key and a honey-account stay instant bans, because no legitimate check touches them. |

## 3. Triggers

| Trigger | Source | Default action |
|---|---|---|
| Any packet to a trap port | Firewall deny log (Blueprint §4.1) | Ban at once |
| Use of the planted SSH key | sshd fingerprint log (Blueprint §4.4) | Ban at once |
| Any logon attempt on a honey-account | Trip log (design 09) | Ban at once and raise an incident (design 02) |
| Repeated failed logins on a login path that is not scored, such as admin SSH on a host where SSH is not a scored service | Authentication log | Ban after a threshold within a time window |
| Repeated failed logins on a scored service's login (for example SSH, mail or FTP where scored, or a scored web app's login page) | Authentication log | Alert only, never a ban; the alert names the address and account so a person can judge it |
| Repeat offender | Ban history | Longer ban |
| A host connecting out to a likely command-and-control address | Unusual-outbound search (design 10, section 5) | Alert; an outbound ban only after a person approves it (section 6.1) |

Thresholds, windows and ban lengths are **configuration**, not code, so the operator can tune them during the event without changing the frozen release (NCCDC, 2025, Rule 5.6.2). `config/bans.example` shows their shape.

## 4. The never-ban list

Loaded from run-time configuration before any ban is possible. If it is missing or empty, bans stay off.

- the scoring engine's addresses;
- the officials' addresses, where known;
- the control node and the operators' admin sources;
- the SIEM (Security Information and Event Management system) and any log collector;
- the host's own gateway and its own addresses;
- the host's outbound dependencies: the DNS resolvers and NTP servers in the run-time configuration, any web proxy or package mirror the event provides, and any address a scored service connects out to.

A trigger from an address on this list is **alerted, never banned**. A trap hit from the scoring engine's address points to a misconfiguration and is investigated by a person.

## 5. Source-address gate

> [!WARNING]
> If outside traffic reaches a host through NAT (network address translation) on a router, the scoring engine and the Red Team can appear to come from the same last-hop address (Blueprint §3.5). Banning that address blocks scoring.

Before enabling bans on a host, the module's `check` step reads recent connection logs and refuses to enable bans if:

- the scoring engine's configured address is not seen as a distinct source; or
- one address accounts for most inbound sources, which suggests the host only sees a translating router.

The refusal is exit code 20 (blocked by a safety gate, design 00) with a message naming the address. The operator can still use trap alerts; only automatic banning stays off.

## 6. How bans are enforced

**Linux.**

- One kernel address set (ipset, or an nftables set) holds the banned addresses, with a timeout on each entry, and one rule per chain matches the whole set. Thousands of bans stay as fast as one (Blueprint §5.3).
- The set is matched on the `INPUT` chain by source and on the `OUTPUT` chain by destination. On hosts running Docker it is also matched on `DOCKER-USER` by source and by destination, because container traffic bypasses `INPUT` and `OUTPUT` (Blueprint §3.3).
- The match rules come before the rule that accepts established connections. So a new ban also stops a session or a reverse shell already open to that address: an active response, which the rules allow (NCCDC, 2025, Rule 4.11).
- **The watcher** is a small native Labyrinth watcher, in bash, on every Linux host. It tails the logs above and adds addresses to the set. Most triggers in section 3 (trap ports, the planted key, honey-accounts) are not things fail2ban handles out of the box, so they would need custom rules either way.
- **fail2ban.** Where the host's repositories offer it, the `packages` module installs it after the lockdown and keeps it stopped (design 20, section 4), because on some distributions it starts at once with an SSH ban rule on, before the never-ban list is in place. Labyrinth never adds a repository for it, so a RHEL-family host without EPEL relies on the native watcher alone. This module then adds the never-ban list to fail2ban's `ignoreip` setting through a drop-in file in `jail.d`, so it cannot ban the scoring engine, turns off every jail for a scored service's login in the same drop-in (section 3), and only then starts it. A fail2ban that was already running is handled the same way. The native watcher still handles Labyrinth's own triggers.

**Windows.** Optional and off by default. A scheduled task reads the relevant events and keeps two block rules in the rule group `Labyrinth`, one inbound and one outbound, with the same address list, expiring entries. Windows Firewall block rules take precedence over allow rules, so the ban holds whatever else is allowed. Blocking is often better done at the perimeter (Blueprint §3.5), through the appliance runbook (design 16).

```mermaid
flowchart TD
    GATE{"Source-address gate:<br/>can this host tell<br/>sources apart?"}
    GATE -->|no| OFF(["Bans stay off;<br/>alerts only"])
    GATE -->|yes| EV["Trigger: trap hit, planted key,<br/>honey-account, failed logins"]
    EV --> NB{"Source on the<br/>never-ban list?"}
    NB -->|yes| AL["Alert a person;<br/>no ban"]
    NB -->|no| TH{"Threshold met?"}
    TH -->|no| WAIT["Count and wait"]
    TH -->|yes| BAN["Add to the ban set<br/>with an expiry"]
    BAN --> LOG[("Trip log and SIEM")]
    AL --> LOG
    classDef deceive fill:#efe7fb,stroke:#7c3aed,color:#351465
    classDef human fill:#fff4d6,stroke:#b7791f,color:#4a3108
    classDef store fill:#eef1f5,stroke:#475569,color:#1e293b
    classDef stop fill:#f6f6f6,stroke:#b42318,color:#4a1111,stroke-dasharray:4 3
    class EV,TH,WAIT,BAN deceive
    class GATE,NB,AL human
    class LOG store
    class OFF stop
```

*Figure: bans are enabled only when the host can tell its traffic sources apart, a source on the never-ban list is only alerted, and every other trigger that meets its threshold becomes an expiring ban recorded in the trip log. Purple is the ban logic, amber a safety check or a hand-off to a person, gray the log and the dashed red outline the case where bans stay off.*

### 6.1 Outbound bans

Red Teams hide command-and-control traffic in ordinary-looking flows and rotate callback addresses (design 10, section 5), and an inbound default deny does not stop a host from calling out. An address is banned outbound in two ways:

- **With an inbound ban.** Every ban covers both directions (section 6), so an attacker who tripped a trap cannot be reached by a callback either. This needs no extra step.
- **On its own, after approval.** A hit from the unusual-outbound search is an alert, not a ban, because its confidence is medium and a wrong outbound ban can break a service that depends on that address. The alert becomes an approval item (Conventions, section 3.1) naming the host, the address, the port, the process if known, and the run-time configuration entry it failed to match. Once a person approves it, the address joins the same ban set with an expiry, so it is dropped in both directions, recorded in the run manifest and undone by `rollback`.

An outbound ban is always one address, never a range or a port on its own. An address on the never-ban list (section 4) is refused (`20`) and stays an alert. Filtering all of a host's outbound traffic is a different control, default-deny outbound, which is offered per host after approval (design 10, section 5).

## 7. Tier, verify and roll back

- **Tier 2** (design 01): a wrong ban can cut off a real client, so bans are enabled per ring with the scoring-style probes before and after.
- **Tier 3** (design 01): an outbound ban on its own (section 6.1) is applied only after a person approves it.
- **Verify** (Blueprint §8): send a packet to a trap port from a lab address that is not on the never-ban list and expect a ban; send one from a never-ban address and expect an alert only.
- **Roll back:** stop the watcher, flush the set and remove the match rules. Each is recorded in the run manifest.

## 8. Acceptance tests

- A trap-port hit from a lab attacker bans that address within seconds, and the ban expires on time.
- A trap-port hit from the lab scoring engine's address raises an alert and no ban.
- On a lab host behind a translating router, the source-address gate refuses to enable bans.
- Ten thousand bans do not measurably slow a scored-service probe.
- On a Docker host, a banned address cannot reach a published container port.
- With the never-ban list empty, the module refuses to start.
- After a lab attacker's address is banned, a connection from the host out to that address fails, and a reverse shell already open to it is cut.
- An unusual-outbound alert creates an approval item and no ban; once approved, the address is banned outbound and a scored-service probe still passes.
- An outbound ban on a DNS resolver, NTP server or other address on the never-ban list is refused (`20`) and stays an alert.
- An outbound ban request for a range is refused.
- On a Docker host, a container cannot connect out to a banned address.
- On Windows, a banned address is blocked both inbound and outbound, even when an allow rule covers it.
- On a host that already runs fail2ban, the never-ban list appears in its `ignoreip`, and a failed-login burst from the lab scoring engine's address is not banned by either watcher.
- On a host where SSH is scored, a failed-login burst from a lab address that is on no list raises an alert and no ban, from either watcher, and the scoring-style SSH probe still passes.
- On a host where SSH is not scored, the same burst against admin SSH bans the address.
- A trap-port hit from that same lab address is banned at once.

## References

Midwest Collegiate Cyber Defense Competition. (2025). *2025 Midwest Collegiate Cyber Defense Competition qualifier team packet* [PDF]. https://brazil.minnesota.edu/ccdc/ccdc-2025/2025MWCCDCQTeamPack.pdf

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
