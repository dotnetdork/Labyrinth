# 06. Status Feed and MOTD

**Status:** Draft 1 · 2026-09-29 · Phase: Observe · Priority: P2

## 1. Goal

Show each team member, on login, a short current status: active alerts for this host, recent changes, and what to check. Keep it least-privilege: the SIEM must not gain access to every host.

## 2. Design: push from the control node

The SIEM holds no keys to managed hosts. Instead:

1. The control node queries Splunk for a small, fixed set of saved searches (per-host alert counts, last integrity findings, decoy trips).
2. It renders one short text file per host.
3. It pushes each file to its host using the operator SSH key (design 05) into a root-owned status path.
4. The host's login banner or `update-motd.d` script prints that file.

This adds no new trust path: the control node already administers the hosts.

## 3. Cross-segment flows

Competition networks are often split into segments behind separate firewalls. Only the minimum flows are opened: log forwarding to Splunk and the control node's admin path. The MOTD feed adds no new flow, because it reuses the admin path. Any new flow is checked against the firewall plan and the scoring allowlist first (National Collegiate Cyber Defense Competition [NCCDC], 2025, Rule 4.11).

## 4. Content rules

- Maximum about 15 lines, plain text.
- Sanitise every field taken from logs: strip control characters, escape sequences and anything after a length limit. Attacker-controlled log text must not be able to inject terminal codes into an operator's screen.
- No secrets, no credentials, no seed values.
- Show the time of the last update; mark stale status clearly (for example older than 10 minutes).

## 5. Windows

Windows has no MOTD. Use a pre-logon legal notice for a static line, and a status file plus a small PowerShell function or shortcut that prints it. Keep it optional.

## 6. Failure behaviour

If the push fails, the host shows the last good status marked stale. A failure never blocks a login and never changes a scored service.

## 7. Acceptance tests

- An alert in Splunk appears in the host banner within the target interval.
- A log line containing escape sequences is rendered harmlessly.
- Stopping Splunk marks status stale and logins still work.
- The SIEM host has no authorised access to any managed host.
- No new firewall rule is required beyond the existing admin path.

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved September 29, 2026, from https://www.nationalccdc.org/rules.html
