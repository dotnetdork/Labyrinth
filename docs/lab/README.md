# The Labyrinth test lab

Labyrinth's unit tests run in CI with test doubles. Tests that change a real host run in two places (Conventions, section 9):

- **CI runners:** Ubuntu, and Windows Server, including a throwaway single domain controller. They run on every pull request that touches the module.
- **This lab:** local virtual machines, run by a person before each release, for everything a CI runner cannot host.

This page lists the lab machines, how to build them, and what has been tested on each. It holds no addresses, passwords or event details. Like everything in this repository, it is public.

## 1. Machines

Build each machine from the vendor's public install media, with the default minimal install unless the row says otherwise. Use a private virtual network with no route to the internet. Labyrinth must work without one (NCCDC, 2025, Rule 5.6.4).

| Role | Platforms | Used for |
|---|---|---|
| Linux server | Ubuntu LTS, Debian stable | Lockout, observe and sustain modules; UFW and nftables |
| RHEL-family server | Fedora, Rocky Linux or Oracle Linux | The same modules; firewalld; SELinux enforcing |
| Linux web server | Either Linux family, with nginx or Apache, a PHP app and MySQL or MariaDB | Service packs (design 18), the persistence sweep's web shell tests (design 17), and planted known-exploited flaws such as an old WordPress plugin and a vulnerable `pkexec` (design 21) |
| Linux mail and DNS | Either Linux family, with Postfix, Dovecot and BIND | Service packs; DNS probes |
| Domain controller | Windows Server, two versions: the oldest still supported and the newest | Design 11: domain checks, LDAP and Netlogon settings, the domain checklist |
| Member server | Windows Server, joined to the domain, with IIS | Windows member settings, ring order, logons after default-deny |
| SIEM | A free Splunk edition, or the SIEM the event is expected to use | Log forwarding and saved searches (design 10) |
| Control node | Any Linux host | Remote mode (design 00, section 5); the version scan of the team's own hosts (design 21) |
| Package mirror | A local mirror or caching proxy for both Linux families, on the lab network | Installs and security updates (designs 15 and 20). Switched off for the tests that need no source |
| Appliances | Free or trial images where the vendor offers them | Runbook rehearsal only (design 16); never automated |

A **scoring stand-in** runs the probes from the control node against the scored services, so each test can show that scored services keep passing.

## 2. How to run a lab pass

1. Restore every machine to its clean snapshot.
2. Plant the test conditions the spec's acceptance tests name, for example a reverse-shell cron job (design 17) or an account with Kerberos pre-authentication off (design 11).
3. Copy the release to each machine, and the run-time configuration from the `*.example` templates filled with lab values. Lab values never go into the repository.
4. Run the module's acceptance tests with `LAB_REALSYSTEM=1`.
5. Record the result in the matrix below, then restore the snapshots.

## 3. Results matrix

One row per module, platform and version. A module is not released on a platform that neither CI nor the lab has tested.

| Module | Platform | Version | Where | Result | Release |
|---|---|---|---|---|---|

## References

National Collegiate Cyber Defense Competition. (2025, December 10). *Rules and requirements*. Retrieved October 2, 2026, from https://www.nationalccdc.org/rules.html
