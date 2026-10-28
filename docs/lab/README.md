# The Labyrinth test lab

Labyrinth's unit tests run in CI with test doubles. Tests that change a real host run in two places (Conventions, section 9):

- **CI runners:** Ubuntu, and Windows Server; a runner with a throwaway single domain controller is planned. They run on every pull request that touches the module.
- **This lab:** local virtual machines, run by a person before each release, for everything a CI runner cannot host.

This page lists the lab machines, how to build them, and what has been tested on each. It holds no addresses, passwords or event details. Like everything in this repository, it is public.

## 1. Machines

Build each machine from the vendor's public install media, with the default minimal install unless the row says otherwise. Use a private virtual network. Run each test twice where it matters: once with a route to the package mirror and the download sources, and once with none, because Labyrinth falls back to pasting files in by hand when nothing answers (NCCDC, 2025, Rule 5.6.4; design 02).

| Machine | Platform | Used for |
|---|---|---|
| Debian-family hosts | A supported Ubuntu LTS release and a supported Debian release | UFW; the Debian lockdown with no firewall front end, where raw nftables holds until UFW takes over (design 01); Docker containers from `docker.io` (design 13) |
| RHEL-family host | A current RHEL-family release (Rocky Linux, Oracle Linux or Fedora) | firewalld and SELinux enforcing; Podman containers (design 13) |
| Linux web server | Either Linux family, with nginx or Apache, a PHP app and MySQL or MariaDB | Service packs (design 11), the persistence sweep's web shell tests (design 06), and planted known-exploited flaws such as an old WordPress plugin and a vulnerable `pkexec` (design 09) |
| Linux mail and DNS | Either Linux family, with Postfix, Dovecot and BIND | Service packs; DNS probes; mailbox and message-count proofs for service replacement |
| SIEM | A free Splunk edition, or the SIEM the event is expected to use | Log forwarding and saved searches (design 14); the forwarder download and checksum check |
| Domain controller | Windows Server, two versions: the oldest still supported and the newest | Design 12: domain checks, LDAP and Netlogon settings, the domain checklist |
| Member server | Windows Server, joined to the domain, with IIS or SQL Server | Windows member settings, the SQL Server service pack, ring order, logons after default-deny |
| Appliances | An open-source router image, and a free or trial firewall image where the vendor offers one | Runbook rehearsal only (design 05); never automated |
| Control node | Any Linux host | Remote mode (design 00, section 5); the version scan of the team's own hosts (design 09) |
| Package mirror | A local mirror or caching proxy for both Linux families, on the lab network | Installs, security updates and the official-package checks (designs 02, 08 and 10). Switched off for the tests that need no source |

Addresses in the lab are placeholders from the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and never go into this repository.

A **scoring stand-in** runs the probes from the control node against the scored services, so each test can show that scored services keep passing.

## 2. How to run a lab pass

1. Restore every machine to its clean snapshot.
2. Plant the test conditions the spec's acceptance tests name, for example a reverse-shell cron job (design 06) or an account with Kerberos pre-authentication off (design 12).
3. Copy the release to each machine, and the run-time configuration from the `*.example` templates filled with lab values. Lab values never go into the repository.
4. Run the module's acceptance tests with `LAB_REALSYSTEM=1`.
5. Record the result in the matrix below, then restore the snapshots.

Service replacement (design 13) is rehearsed per service: record how long the rebuild, the data copy and the comparison take, and the time from switch to a passing probe, so the team knows before an event whether a rebuild fits the time an inject allows.

## 3. Results matrix

One row per module, platform and version. A module is not released on a platform that neither CI nor the lab has tested.

| Module | Platform | Version | Where | Result | Release |
|---|---|---|---|---|---|

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
