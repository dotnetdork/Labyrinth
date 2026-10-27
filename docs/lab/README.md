# The Labyrinth test lab

Labyrinth's unit tests run in CI with test doubles. Tests that change a real host run in two places (Conventions, section 9):

- **CI runners:** Ubuntu, and Windows Server, including a throwaway single domain controller. They run on every pull request that touches the module.
- **This lab:** local virtual machines, run by a person before each release, for everything a CI runner cannot host.

This page lists the lab machines, how to build them, and what has been tested on each. It holds no addresses, passwords or event details. Like everything in this repository, it is public.

## 1. Machines

Build each machine from the vendor's public install media, with the default minimal install unless the row says otherwise. Use a private virtual network. Run each test twice where it matters: once with a route to the package mirror and the download sources, and once with none, because Labyrinth falls back to pasting files in by hand when nothing answers (NCCDC, 2025, Rule 5.6.4; design 20).

| Machine | Platform | Used for |
|---|---|---|
| RHEL-family host | A current RHEL-family release (Rocky Linux or Oracle Linux), with a web stack (nginx or Apache, a PHP app, MariaDB) | Service packs (design 18), the persistence sweep's web shell tests (design 17), firewalld and SELinux enforcing, Podman containers (design 22), and planted known-exploited flaws such as an old WordPress plugin and a vulnerable `pkexec` (design 21) |
| Ubuntu host | A supported Ubuntu LTS release, with a mail stack (Postfix and Dovecot) | Service packs; UFW; Docker containers from `docker.io` (design 22); mailbox and message-count proofs for service replacement |
| Debian host | A supported Debian release, with a free Splunk edition | Log forwarding and saved searches (design 10); the forwarder download and checksum check; the Debian lockdown with no firewall front end, where raw nftables holds until UFW takes over (design 19) |
| Domain controller | A supported Windows Server release | Design 11: domain checks, LDAP and Netlogon settings, the domain checklist |
| Member server | An older supported Windows Server release, joined to the domain, with SQL Server | Windows member settings, the SQL Server service pack, ring order, logons after default-deny |
| Router | An open-source router image | Runbook rehearsal (design 16); never automated |
| Firewall appliance | A free or trial image where the vendor offers one | Runbook rehearsal only (design 16); never automated |
| Control node | Any Linux host | Remote mode (design 00, section 5); the version scan of the team's own hosts (design 21) |
| Package mirror | A local mirror or caching proxy for both Linux families, on the lab network | Installs, security updates and the official-package checks (designs 04, 15 and 20). Switched off for the tests that need no source |

Addresses in the lab are placeholders from the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and never go into this repository.

A **scoring stand-in** runs the probes from the control node against the scored services, so each test can show that scored services keep passing.

## 2. How to run a lab pass

1. Restore every machine to its clean snapshot.
2. Plant the test conditions the spec's acceptance tests name, for example a reverse-shell cron job (design 17) or an account with Kerberos pre-authentication off (design 11).
3. Copy the release to each machine, and the run-time configuration from the `*.example` templates filled with lab values. Lab values never go into the repository.
4. Run the module's acceptance tests with `LAB_REALSYSTEM=1`.
5. Record the result in the matrix below, then restore the snapshots.

Service replacement (design 22) is rehearsed per service: record how long the rebuild, the data copy and the comparison take, and the time from switch to a passing probe, so the team knows before an event whether a rebuild fits the time an inject allows.

## 3. Results matrix

One row per module, platform and version. A module is not released on a platform that neither CI nor the lab has tested.

| Module | Platform | Version | Where | Result | Release |
|---|---|---|---|---|---|

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
