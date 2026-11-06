---
title: Labyrinth Operator Manual
---

<!--
  Single source for every Labyrinth manual. tools/manual/build.sh turns it into
  the Linux and Windows PDFs, the Linux man page and the Windows help topic.

  A line holding only a "linux" or "windows" marker comment starts text that
  appears in that platform's manuals only; a line holding only an "end"
  marker comment ends it. Everything else appears in both. These words are
  replaced for each platform: @CMD@ (how to start Labyrinth), @ROOT@ (the
  default data root), @ADMIN@ (who may run it) and @MANUAL@ (which manual).
  Write in the plain style of docs/Overview.md (Conventions, section 9).
-->

This is the operator manual for Labyrinth, @MANUAL@. It explains how to run Labyrinth on a host, what each command does, and what to do when something goes wrong. It does not assume you have memorized commands or security terms: each term is explained the first time it appears.

**Who this is for:** the person at the keyboard during the event, who knows what a server and a command line are but has not used Labyrinth under pressure before. [How Labyrinth Works](../Overview.md) explains the ideas behind the tool; this manual explains how to use it.

**Status:** Labyrinth is being built. This manual describes the command line as it is specified in [the conventions](../Conventions.md#3-how-a-module-is-run).

# 1. What Labyrinth does

Labyrinth makes security changes to a host quickly, safely and reversibly. The work is split into five **phases**, run in this order:

| Phase | In one line |
|---|---|
| `lockout` | Take control back from the attacker. |
| `harden` (planned) | Close the holes behind the lockout: install what the host needs, patch, remove what is not needed. |
| `observe` | See what is happening on the host. |
| `deceive` | Plant traps that give the attacker away. |
| `sustain` | Keep everything running and be able to undo mistakes. |

The `harden` phase is specified but not built yet: its modules (named `harden.*`) arrive in the first usable release (Roadmap). Until then, the runner accepts `lockout`, `observe`, `deceive` and `sustain`, and the Harden modules run in their current phases.

Each phase is made of **modules**: small, single-purpose pieces of automation, such as "change the default administrator password". Which modules run on a host depends on its **profile**, the kind of host it is (for example, a Linux web server). Labyrinth ships six profiles: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc` and `appliance`. A profile of the same name in the `profiles` folder of the configuration replaces the shipped one for that run, but it can only list modules Labyrinth ships. The `appliance` profile never changes a router or firewall appliance; its modules only print steps for a person to carry out.

Labyrinth always shows you what it would do before it does anything, and every change it makes can be undone.

# 2. Before you start

You need:

<!-- linux -->
- **A root shell.** Labyrinth changes the system, so it runs as root. Use `sudo` in front of each command, as the examples do.
- **Labyrinth's folder on the host,** normally `/opt/labyrinth`. The program is `labyrinth.sh` in its `bin` folder. The installer below puts the commands `laby` and `labyrinth` in `/usr/bin`, so you can type them anywhere; without it, run the commands from the program's folder: `cd /opt/labyrinth/bin`.
<!-- end -->
<!-- windows -->
- **An elevated PowerShell window.** Labyrinth changes the system, so it runs as an Administrator. Right-click Windows PowerShell and choose **Run as administrator**.
- **Labyrinth's folders on the host.** The data root is normally `C:\ProgramData\Labyrinth`. The program, `labyrinth.ps1`, is in `C:\Program Files\Labyrinth`, where only Administrators can change it. The installer below adds that folder to the machine's `PATH`, so you can type `laby` anywhere in a new window; without it, run the commands from the program's folder.
- **Permission to run the script.** The installer's `laby` command (a file named `laby.cmd`) starts Windows PowerShell with the execution policy set aside for that one run, and never changes the policy of the host. Without the installer, if Windows refuses to run the script because of the execution policy, start it like this instead, for this window only: `powershell -ExecutionPolicy Bypass -File .\labyrinth.ps1 lockout`.
<!-- end -->
- **The release hash,** in the team's notes kept off the hosts. When the team makes a release, the captain records the SHA-256 of its release list, `release.sha256`. Before it runs, Labyrinth checks each of its own files against that list, and it prints the list's hash on the `SHA-256:` lines of `-V` and of every run, and in the installer's `WARNING` box, as two lines of eight groups of four. Compare it with the team's notes by eye. If they differ, stop: this copy is not the release the team checked. A copy taken straight from the repository has no list, and its `SHA-256:` line says `not checked`.
- **The event's configuration,** in the `etc` folder under the data root (section 10). The team prepares these files before the event, as **Preparing the configuration** below explains. The two that matter most:
  - `hosts` lists every host Labyrinth may act on, with its **group** (which wave of hosts it belongs to), its profile and its platform: `ubuntu` (any Debian-family system; `debian` means the same), `rhel-family`, `windows` or `appliance`.
  - `protected-accounts` is the **protected set**: accounts Labyrinth must never touch, such as the officials' accounts and the accounts the scoring engine logs in with. If this file is missing or empty, Labyrinth refuses to run.

**Getting it onto a host.** Each release is published as one archive, and the team's notes hold the archive's SHA-256. You fetch the archive, compare its SHA-256 with the notes, and only then unpack it. Nothing here needs more than the host's own tools. `<tag>` is the release's tag, as written in the team's notes; work in an empty folder.

<!-- linux -->
Fetch the archive:

```
tag=<tag>
url=https://github.com/dotnetdork/Labyrinth/releases/download/$tag
curl -fsSLO "$url/labyrinth-$tag.tar.gz"
```

Print its SHA-256 and compare it with the notes, character by character:

```
sha256sum labyrinth-$tag.tar.gz
```

If it differs, stop and do not unpack the archive: fetch it again, or use the team's own copy. If it matches, unpack the archive as root, so that the files belong to root, and check the list of files inside it:

```
sudo tar --no-same-owner -xzf labyrinth-$tag.tar.gz
cd labyrinth-$tag
sha256sum -c --quiet release.sha256
```

The last command prints nothing when every file matches the list. Then install it, as below.
<!-- end -->
<!-- windows -->
Fetch the archive. The first lines set the tag and the address, and make Windows PowerShell use TLS 1.2, which older Windows Server releases need:

```
$tag = '<tag>'
$url = "https://github.com/dotnetdork/Labyrinth/releases/download/$tag"
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Invoke-WebRequest -UseBasicParsing -Uri "$url/labyrinth-$tag.zip" `
  -OutFile "labyrinth-$tag.zip"
```

Print its SHA-256 and compare it with the notes, character by character. `Get-FileHash` prints capital letters; the case does not matter:

```
Get-FileHash "labyrinth-$tag.zip"
```

If it differs, stop and do not unpack the archive: fetch it again, or use the team's own copy. If it matches, unpack the archive in your elevated window, so that the files belong to the Administrators, and check the list of files inside it. The last command prints nothing when every file matches the list:

```
Expand-Archive "labyrinth-$tag.zip" -DestinationPath .
cd "labyrinth-$tag"
Get-Content .\release.sha256 | ForEach-Object {
  $h, $f = $_ -split '  ', 2
  if ((Get-FileHash $f).Hash -ne $h) { $f }
}
```

Then install it, as below.
<!-- end -->

Where only a console reaches the internet, fetch the archive and compare its SHA-256 there, then copy it to the host over the admin path and compare it again on the host before you unpack it. Never pipe a download into a shell, and never skip the comparison.

**Installing it.** The installer sets Labyrinth up on a host in one guided step. Fetch and check the release as above. Then, in the unpacked folder:

<!-- linux -->
```
sudo ./install.sh
```

It checks the release against `release.sha256` and refuses if a file differs. It then shows the release hash in a `WARNING` box (compare it with the team's notes; if it differs, answer no) and, under `CHANGES TO THIS HOST`, where the program, the data root, the commands and the manual will go, and asks `Install? [y/N]`. Anything but `y` changes nothing; `-y` answers yes for you, and without a terminal it refuses unless you give `-y`. It then:

- creates the data root, `/opt/labyrinth`, with `etc`, `state`, `logs` and `backup` open to root only (`--root DIR` picks another);
- copies the program to `/opt/labyrinth/bin`, owned by root;
- adds the commands `laby` and `labyrinth` in `/usr/bin`. If something else already has the name `laby`, it leaves `laby` out and says so; if something else has the name `labyrinth`, it installs nothing;
- installs the manual, so `man laby` works (when this copy has the built manual; otherwise it skips it with one line). It never replaces another program's manual page: if `laby` is left out, or another program already has a `laby` page, only `man labyrinth` is added;
- copies the configuration templates into `/opt/labyrinth/etc` without the `.example` ending, never replacing a file that is already there.

It first checks that only root can change the program's folder, the commands' folder, the manual's folder, every folder above them, and an existing data root and everything in it, and refuses if not. It warns if root's `PATH` has a folder that others can write to. It ends by telling you what to fill in (the templates hold placeholder names) and the next command, `sudo laby`.

The installer is safe to run again, for example to install a new release: it replaces the program completely and never touches the configuration, the run records, the backups or the logs. It refuses while any revert timer is armed, because the timer would run the code being replaced; it names the run and when its timer fires. Keep the run (`sudo laby -k ID`) or undo it (`sudo laby -u ID`) first.
<!-- end -->
<!-- windows -->
```
.\install.ps1
```

It checks the release against `release.sha256` and refuses if a file differs. It then shows the release hash in a `WARNING` box (compare it with the team's notes; if it differs, answer no) and, under `CHANGES TO THIS HOST`, where the program, the data root, the commands, the `PATH` change and the help topic will go, and asks `Install? [y/N]`. Anything but `y` changes nothing; `-y` answers yes for you, and without a terminal it refuses unless you give `-y`. It then:

- creates the data root, `C:\ProgramData\Labyrinth`, with `etc`, `state`, `logs` and `backup`, and makes it usable by Administrators and SYSTEM only (`-Root DIR` picks another);
- copies the program to `C:\Program Files\Labyrinth`, where only Administrators can write;
- adds that folder to the machine's `PATH`, so that `laby` and `labyrinth` work in a new PowerShell or command window. If another program on the `PATH` already has the name `labyrinth`, it installs nothing; if one has the name `laby`, it says so, and you type `labyrinth` instead;
- installs the help topic, so `Get-Help about_Labyrinth` shows the manual (if PowerShell does not find it, run `Import-Module Labyrinth` first). When this copy has no built manual, it skips this with one line;
- copies the configuration templates into `C:\ProgramData\Labyrinth\etc` without the `.example` ending, never replacing a file that is already there.

It first checks that only Administrators, SYSTEM and TrustedInstaller can change the program's folder and every folder above it, and refuses if not. If the data root is already there but still open to other accounts, it makes it private, then checks it the same way; if something in it belongs to an account that is not an administrator, it installs nothing, so a person can check that file first. It ends by telling you what to fill in (the templates hold placeholder names) and the next command, `laby`.

The installer is safe to run again, for example to install a new release: it replaces the program completely and never touches the configuration, the run records, the backups or the logs. It refuses while any revert timer is armed, because the timer would run the code being replaced; it names the run and when its timer fires. Keep the run (`laby -k ID`) or undo it (`laby -u ID`) first.
<!-- end -->

**Preparing the configuration.** Prepare the configuration once, before the event, so that only the values you learn on the day are left to fill in. Keep the prepared folder in storage the team controls and keeps private, such as a private repository or a drive the captain holds. Never put it in Labyrinth's repository or any public place: its files name the team's accounts and, once filled in, the event's addresses.

Ahead of time, fill in what you already know: tuning values such as the revert timer's minutes, every allowance with the local rule or inject that permits it, and the versions and hashes of anything Labyrinth will download. Leave out what you only learn at the event, such as addresses, host names and scored services, or keep placeholders for them that you replace on the day.

These files are the same on every host, so you write them once and copy them to each one: `event.conf`, `hosts`, `protected-accounts`, `services`, `scoring-allowlist`, `never-ban`, `outbound-allow`, `pre-approved`, and any profile in the `profiles` folder.

One file belongs to a single host: `seed.conf`, which Labyrinth writes itself when you make the host's decoy seed (section 5). Never copy it to another host, and never copy a host's whole `etc` folder to the others: every host would then get the same seed, so its traps would sit at the same places on every host, and a seed seen on one host would give all of them away. Copy from the prepared folder instead, which has no `seed.conf`, and make each host's seed on that host.

At the event, after installing Labyrinth on a host, copy the prepared files into its `etc` folder, replacing the templates the installer put there. For example, with the prepared folder in `prepared`:

<!-- linux -->
```
sudo cp -r prepared/. /opt/labyrinth/etc/
```
<!-- end -->
<!-- windows -->
```
Copy-Item .\prepared\* C:\ProgramData\Labyrinth\etc -Recurse -Force
```
<!-- end -->

Then fill in what is left, and check the result with a preview, such as `@CMD@ lockout`, which reads every file and names the file and line of any mistake, before you run anything.

# 3. Words you will see

| Word | Meaning |
|---|---|
| Phase | A stage of defense. There are five, run in order: `lockout`, `harden`, `observe`, `deceive` and `sustain`. |
| Module | One small job in a phase, such as turning off password logins. Each has a plain name and an ID, such as `lockout.firewall`: the phase, a dot, then its short name. `@CMD@ -h <module-id>` explains it. |
| Host group | A set of hosts that Labyrinth changes together, such as `ring1`. The team's hosts file gives each host its group; the first group holds one test host of each kind, so a mistake shows up there before it reaches the rest. `-r` asks you to type the group's name before it changes anything. |
| Run | One use of `-r` on one host. |
| Run ID | The name of a run, such as `20261002T140301Z-4f2a`: the start time in UTC and four random characters. Wherever a command asks for a run, the last four characters (`4f2a`) are enough. |
| Preview | A dry run: each module reports what it would change. Nothing is changed and nothing is written. |
| Real run | A run with `-r`: Labyrinth plans, asks you to confirm, then makes the changes. |
| Revert timer | A timer started before a risky change. If nobody **keeps** the run in time, the timer undoes the run by itself. It protects you if a change locks you out. |
| Keep | Telling Labyrinth that a run's changes are good, with `-k`: the revert timer is cancelled and the changes stay. |
| Kept once verified | A change that only takes access away from an intruder, such as a new admin password or a removed planted key, cannot lock you out. Labyrinth keeps it as soon as its check passes and no scored service got worse, so the revert timer does not hand the intruder their access back. |
| Undo | Undoing what a run changed, newest first. The revert timer starts one automatically; you can start one too with `-u`. |
| Break-glass account | The emergency login, kept in the team's offline record, used only when normal access fails. Labyrinth asks you to confirm it works before changing anything. |
| Scored service | A service the scoring engine checks, such as a website, email or DNS. Labyrinth tests them before and after each change. |
| Exit code | The number Labyrinth ends with, which says how it went (section 9). |

# 4. Quick start

New to Labyrinth? `@CMD@ -h basics` explains these ideas on one screen. Run with nothing after it, Labyrinth prints its help.

The normal way to use Labyrinth is: preview, run, check, keep.

1. **See what would change.** Nothing is changed.

   ```
   @CMD@ lockout
   ```

2. **Make the changes.** Labyrinth plans again, then asks you to confirm three things: that you are logged in at the console with the break-glass account, the host's group name, and, at the end, whether to keep the run.

   ```
   @CMD@ -r lockout
   ```

3. **Check that you can still get in.** Open a new login session, on the console or over the network, and make sure it works. Do not close your current session yet.

4. **Keep the run.** At the keep prompt, type `keep`. If you are not sure, type anything else: the revert timer stays armed and undoes the run when it fires. You can still keep it before then, with the last four characters of the run ID:

   ```
   @CMD@ -k 4f2a
   ```

**If something is wrong,** undo the run at once instead of waiting for the timer. Labyrinth prints the run ID at the start of every run; the last four characters are enough:

```
@CMD@ -u 4f2a
```

# 5. Commands

Labyrinth does **one action per line**. A phase on its own is a preview. Every other action is a flag, and the options it needs go on the same line:

<!-- linux -->
| To | Type | Ends with |
|---|---|---|
| See this host's status and what to do next | `@CMD@` | 0 |
| Preview a phase | `@CMD@ PHASE` | 0, 10, 20 or 40 |
| Run a phase | `@CMD@ -r PHASE` | 0, 10, 20, 30 or 40 |
| Keep a run | `@CMD@ -k ID` | 0, 20 or 40 |
| Add time to a run's revert timer | `@CMD@ --extend ID` | 0, 20 or 40 |
| Undo a run | `@CMD@ -u ID [--all [-y]]` | 0, 20 or 40 |
| List the runs | `@CMD@ --history` | 0, 20 or 40 |
| List what a run changed | `@CMD@ --show ID` | 0, 20 or 40 |
| Test the scored services | `@CMD@ --probe` | 0, 20, 30 or 40 |
| Make this host's decoy seed | `@CMD@ --new-seed [-y]` | 0, 20 or 40 |
| Check a seed you typed | `@CMD@ --seed-check` | 0, 20 or 30 |
| Show the version | `@CMD@ -V` | 0 |
| Read this manual | `@CMD@ --manual` | 0 or 40 |
| Get help | `@CMD@ -h [TOPIC]` | 0 |
<!-- end -->
<!-- windows -->
| To | Type | Ends with |
|---|---|---|
| See this host's status and what to do next | `@CMD@` | 0 |
| Preview a phase | `@CMD@ PHASE` | 0, 10, 20 or 40 |
| Run a phase | `@CMD@ -r PHASE` | 0, 10, 20, 30 or 40 |
| Keep a run | `@CMD@ -k ID` | 0, 20 or 40 |
| Add time to a run's revert timer | `@CMD@ -Extend ID` | 0, 20 or 40 |
| Undo a run | `@CMD@ -u ID [-All [-y]]` | 0, 20 or 40 |
| List the runs | `@CMD@ -History` | 0, 20 or 40 |
| List what a run changed | `@CMD@ -Show ID` | 0, 20 or 40 |
| Test the scored services | `@CMD@ -Probe` | 0, 20, 30 or 40 |
| Make this host's decoy seed | `@CMD@ -NewSeed [-y]` | 0, 20 or 40 |
| Check a seed you typed | `@CMD@ -SeedCheck` | 0, 20 or 30 |
| Show the version | `@CMD@ -V` | 0 |
| Read this manual | `@CMD@ -Manual` | 0 or 40 |
| Get help | `@CMD@ -h [TOPIC]` | 0 |
<!-- end -->

`PHASE` is `lockout`, `observe`, `deceive` or `sustain`. `ID` is a run ID or its last four characters; `-k`, `-u` and the extend and show actions always need one. `-r` may come before or after the phase. Two actions on one line are an error (exit 40), and so is a word that is not a phase.

This manual writes the program's name as `laby`. The installer (section 2) puts `laby`, and the longer name `labyrinth`, on the path, and the program's own help and hints then write the name you typed. Without the installer, type `@CMD@` instead; the help and hints write the name you started it with.

Phases, long option names and run IDs can be typed in any mix of upper and lower case. The short letters are the exception: `-P` and `-V` are capitals, and `-r`, `-k`, `-u`, `-y` and `-h` are lower case. `-p` and `-v` are errors, and Labyrinth says which letter you meant.

When a line is wrong, Labyrinth ends with 40 and prints, on the error output, the name it was started by, one line saying what is wrong, sometimes a line saying how to fix it, and a pointer to the help of the action on the line:

<!-- linux -->
```
./labyrinth.sh: 'obsrve' is not a phase. Did you mean 'observe'?
The phases are lockout, observe, deceive and sustain.
Try './labyrinth.sh -h'.
```
<!-- end -->
<!-- windows -->
```
.\labyrinth.ps1: 'obsrve' is not a phase. Did you mean 'observe'?
The phases are lockout, observe, deceive and sustain.
Try '.\labyrinth.ps1 -h'.
```
<!-- end -->

## status

Type `@CMD@` alone to see where this host stands and the one command to run next:

<!-- linux -->
```
labyrinth 0.1.0: status of host web1
Group:    ring1, profile linux-web
lockout   kept (run 4f2a, 2026-10-02 14:03 UTC)
observe   armed: undo at 14:41 UTC (run 7c19, 2026-10-02 14:26 UTC)
deceive   not run
sustain   not run
Timer:    run 7c19 is undone at 14:41 UTC, in 12 minutes
Next: check you can log in from a NEW session, then 'sudo ./labyrinth.sh -k 7c19'.
```
<!-- end -->
<!-- windows -->
```
labyrinth 0.1.0: status of host web1
Group:    ring1, profile windows-member
lockout   kept (run 4f2a, 2026-10-02 14:03 UTC)
observe   armed: undo at 14:41 UTC (run 7c19, 2026-10-02 14:26 UTC)
deceive   not run
sustain   not run
Timer:    run 7c19 is undone at 14:41 UTC, in 12 minutes
Next: check you can log in from a NEW session, then .\labyrinth.ps1 -k '7c19'.
```
<!-- end -->

Each phase shows the state of its latest run, in the words of the history (below), or `not run`. The `Next:` line gives the first of these that applies:

1. The `hosts` file is missing, does not list this host, or is malformed: fix it, then type the name again.
2. A revert timer is armed: check that you can still log in, then keep the run.
3. The host is in the `manual` group: Labyrinth does nothing here; configure it by hand, from its runbook.
4. A phase has not run, or its latest run was undone: preview the first such phase.
5. Otherwise: test the scored services.

The status changes nothing and writes nothing. Run it as @ADMIN@: otherwise it shows the first lines of the help and how to run it as @ADMIN@. It always ends with 0, even on a host that is not set up yet.

## preview *phase*

Shows what every module of the phase would change on this host. Nothing is changed, and nothing is written, not even a log. Run it as often as you like. Run it as @ADMIN@: only @ADMIN@ can read the configuration.

Ends with 0 when nothing needs changing, 10 when something does, 20 when a safety check blocks a module or the configuration cannot be read, and 40 on an error.

## run (-r) *phase*

Plans, then makes the changes behind the safety checks described in section 7. It must be run as @ADMIN@. When a module needs a change, then before anything changes, it asks you to name the break-glass account (the first run on a host only) and to type this host's group name. Modules that only look, such as the inventory, record what they find first (section 7).

Ends with 0 when every change was made and checked, 10 when only steps for a person to carry out are left, or the highest problem code otherwise: 20 blocked, 30 a check after a change failed, 40 an error. A run is blocked when it is not run as @ADMIN@, when another Labyrinth run holds the lock, when this host is not in the `hosts` file, or when a safety check fails.

**Some modules only.**
<!-- linux -->
`--only LIST` keeps just the modules you name, and `--skip LIST` drops them, for a preview or a run: `sudo laby -r lockout --only lockout.inventory`. A list is module IDs of the phase, separated by commas, and the two cannot be used together.
<!-- end -->
<!-- windows -->
`-Only LIST` keeps just the modules you name, and `-Skip LIST` drops them, for a preview or a run: `laby -r lockout -Only lockout.inventory`. A list is module IDs of the phase, separated by commas, and the two cannot be used together.
<!-- end -->
Everything else is as in a full run: the same checks, backups, revert timer and keep question, and the run says it is partial. A module that needs one you left out is blocked, and nothing changes; the message gives the command with the module put back. The inventory is the one module a run may leave out, and only when the host already has a dependency map from an earlier run. An ID that is not a module of the phase in the profile is a usage error that suggests the nearest one.

## keep (-k) *run*

Keeps a run's changes: cancels its revert timer, then records that the run was kept. The run is always needed. Without one, `-k` changes nothing and ends with 40; run as @ADMIN@, it also lists the runs whose timer is armed, to choose from.

Ends with 0 when the run is kept, 20 when it is not run as @ADMIN@, when Labyrinth's files could be changed by another account (section 11), or when it is too late because the run was already undone, and 40 when the timer could not be cancelled or the keep could not be recorded. If the timer could not be cancelled, the run is **not** kept and the timer will still undo it: Labyrinth says when, and gives the command to try again.

## extend *run*

Pushes back a run's revert timer, for when checking the logins takes longer than the timer allows. Each time you run it, it adds one timer length to the time the timer has left. The length is `REVERT_MINUTES` in `event.conf`, 5 minutes unless the team changed it. If the timer would fire in 2 minutes, one extension makes it fire in 7 and a second in 12. You never type a time: a time after the ID is an error (exit 40). There is no limit on how often you extend, but each extension is short, so a run that people stop extending is still undone.

<!-- linux -->
```
@CMD@ --extend 7f3a
Timer:  now fires 21:39 UTC (in 7 minutes)
Next:   @CMD@ -k 7f3a
```
<!-- end -->
<!-- windows -->
```
@CMD@ -Extend 7f3a
Timer:  now fires 21:39 UTC (in 7 minutes)
Next:   @CMD@ -k 7f3a
```
<!-- end -->

The run is always needed. Without one, the extend action changes nothing and ends with 40; run as @ADMIN@, it also lists the runs whose timer is armed, to choose from. Only a run whose timer is armed can be extended. A run that was already kept, already undone, or made with
<!-- linux -->
`--no-revert`
<!-- end -->
<!-- windows -->
`-NoRevert`
<!-- end -->
has no timer to extend, and is refused with 20. A run whose timer was lost (`armed: timer lost` in the history) gets a new timer. The new timer is set before the old one is removed, so a failed extension leaves the old timer in place.

Each extension is written to the run log and to the run's record, and the history, the status and the show command then give the new time. Extending does not keep the run: when you have checked the logins, keep it with `-k`.

Ends with 0 when the timer is extended, 20 when it is not run as @ADMIN@, when Labyrinth's files could be changed by another account (section 11), or when the run has no armed timer, and 40 when the timer could not be extended or the extension could not be recorded.

## undo (-u) *run*

Undoes what the run changed, newest change first. This is exactly what the revert timer does when it fires. You must name the run. Without one, it changes nothing and ends with 40; run as @ADMIN@, it also lists the runs to choose from. Running it twice is safe.

Changes that were kept once verified stay: undo lists them first and leaves them in place. To undo them too, add
<!-- linux -->
`--all`.
<!-- end -->
<!-- windows -->
`-All`.
<!-- end -->
If that undoes a password change, the old password is back: change it again and correct the offline record. Because of that, Labyrinth asks first:

<!-- linux -->
```
Undo run 4f2a with --all? It also undoes changes kept once verified,
such as a new password, which can give an intruder access back. [y/N]
```
<!-- end -->
<!-- windows -->
```
Undo run 4f2a with -All? It also undoes changes kept once verified,
such as a new password, which can give an intruder access back. [y/N]
```
<!-- end -->

Type `y` to go ahead; anything else undoes nothing. To answer yes without being asked, add `-y`. With no terminal to ask on, such as from a script, it undoes nothing and ends with 40 unless `-y` is given. Undo without
<!-- linux -->
`--all`,
<!-- end -->
<!-- windows -->
`-All`,
<!-- end -->
which is what the revert timer runs, never asks, and neither does a run with nothing kept once verified.

When an undo undoes anything, it also shows a short notice on every terminal logged in to the host, so the team knows, even when nobody was watching the revert timer.

Ends with 0 when the run is undone, 20 when not run as @ADMIN@ or when Labyrinth's files could be changed by another account (section 11), and 40 on an error.

## history

<!-- linux -->
`--history` lists
<!-- end -->
<!-- windows -->
`-History` lists
<!-- end -->
this host's runs, oldest first, with the run ID, phase, start time (UTC) and state:

- `armed`: the revert timer is set, with the time it will undo the run (the new time after an extension). If that time has passed, it says when the timer was due; if Labyrinth cannot tell, it says the time is unknown;
<!-- linux -->
- `armed: timer lost`: the run is still armed, but systemd no longer has its revert timer, because its unit files were removed or damaged. Nothing will undo the run by itself. Keep it or undo it now;
<!-- end -->
- `kept`: someone kept the run;
<!-- linux -->
- `no revert`: the run was made with `--no-revert`, so no timer will undo it;
<!-- end -->
<!-- windows -->
- `no revert`: the run was made with `-NoRevert`, so no timer will undo it;
<!-- end -->
- `undone`: the run was undone;
- `undone with errors`: the run was undone, but some of it could not be; section 11 explains what to do;
- `not kept, no timer`: the run changed nothing that needed a timer.

Below the list, it shows how to name a run by its last four characters. Then it lists the logs of the runs that had problems (section 11). It changes nothing, but it must be run as @ADMIN@. Ends with 0, 20 when not run as @ADMIN@, and 40 on an error.

## show *run*

<!-- linux -->
`--show` lists
<!-- end -->
<!-- windows -->
`-Show` lists
<!-- end -->
what one run changed. Name the run by its ID or its last four characters; without one, it lists the runs and shows none. It shows the run's phase, profile, host, group, start and end (UTC) and state, then each module in run order with its status and every change it made. The status is `applied`, `kept once verified`, `undone`, `blocked, nothing changed`, or `failed` with what failed and whether it was undone. Each change shows what was done and to what, the previous value, and the backup folder, where Labyrinth recorded them. The last line gives the path of the run log. Passwords never appear, and the contents of backed-up files are never printed. It changes nothing, but it must be run as @ADMIN@. Ends with 0, 20 when not run as @ADMIN@, and 40 on an error.

## probe

<!-- linux -->
`--probe` tests
<!-- end -->
<!-- windows -->
`-Probe` tests
<!-- end -->
every scored service once, the way the scoring engine would, and prints the result for each. Changes nothing. Run it as @ADMIN@, so it can read the configuration. Ends with 0 when every service passes, 20 when there is no list of scored services or the list names none, 30 when any service fails, and 40 on an error.

The `services` file lists one service per line: a name, the kind of probe, the host, the port and the text the answer must contain (`-` for none). An `http` or `https` host may end in a path, such as `web.example.test/shop/cart`, so the probe checks that page and not only `/`; without a path it checks `/`. A path starts with `/`, may end in a `?query`, and uses only letters, digits and `._~/+=&-`; write any other character as a `%` escape, such as `%20` for a space. A space, a scheme (`http://`), a path on any other kind of probe or an unescaped character is an error. The probe does not follow a redirect.

The kinds of probe are `http`, `https`, `dns`, `smtp`, `pop3`, `imap`, `ftp` and `tcp`. The `smtp`, `pop3`, `imap` and `ftp` kinds connect and read the greeting the service sends: `220` for `smtp` and `ftp`, `+OK` for `pop3` and `* OK` for `imap`, plus the text in the last field when you give one. An `imap` service that answers `* BYE`, or says nothing before the timeout, fails. The probe logs in to nothing and reads no mailbox; it ends an `imap` connection with `a1 LOGOUT` and the others with `QUIT`.

## new-seed

<!-- linux -->
`--new-seed` makes
<!-- end -->
<!-- windows -->
`-NewSeed` makes
<!-- end -->
this host's **decoy seed**: a long code that the decoys on this host (traps that give an intruder away) are worked out from. Labyrinth saves it in `seed.conf` in the configuration folder, shows it once on the terminal, and waits until you type `recorded`; then it clears the screen. Put the seed in the offline record, and post it in the team chat with this host's name. Labyrinth shows it nowhere else and never logs it.

If the host already has a decoy seed, Labyrinth asks before it replaces it, because the decoys made from the old seed must be made again. `-y` answers yes without asking.

It must be run as @ADMIN@, from a terminal, and checks both before it makes or saves anything. If the terminal goes before you type `recorded`, nobody recorded the seed, so Labyrinth does not keep it: the file is put back as it was. Ends with 0 when the seed is saved (or when you answer no to the question), 20 when not run as @ADMIN@, when there is no terminal, or when the terminal goes before `recorded`, and 40 on an error.

## seed-check

<!-- linux -->
`--seed-check` asks
<!-- end -->
<!-- windows -->
`-SeedCheck` asks
<!-- end -->
for a seed at a prompt on the terminal and says whether it is a valid seed. Use it on a seed that someone sent you or that you copied by hand: the last group of a seed is worked out from the rest, so a typo anywhere is caught. Case, spaces and dashes do not matter. The seed is typed at the prompt and never given on the command line. A message about a bad seed says what is wrong, never the seed. It reads no configuration and needs no @ADMIN@, so it works on any machine with Labyrinth. Ends with 0 when the seed is valid, 20 when there is no terminal, and 30 when it is not valid.

## help (-h) [*topic*]

Prints help for the whole program, or for one topic. A topic is an action (`run`, `keep`, `undo`, `history`, `show`, `probe`, `new-seed`, `seed-check`, `version`), an option (such as `profile` or `root`), a phase, or one of two more:

- `@CMD@ -h basics` explains phases, modules, previews and runs, the history, the revert timer, keep, undo and scored services, in plain words, on one screen.
- `@CMD@ -h <module-id>`, such as `@CMD@ -h lockout.firewall`, explains one module: its name, its phase and order, what it may change in plain words, whether it can affect a scored service, the platforms it runs on, its folder, and then its own page: what it checks and changes, why, what can go wrong, how to undo it, and what to do when it fails. Every warning, block, failure and error in the output names the page to read.

`-h` can also follow the action (`@CMD@ -r -h`) or a phase (`@CMD@ lockout -h`) and shows that page. Typing nothing shows the status, not the help.
<!-- linux -->
`--help`, `/?` and `-?` do the same as `-h`.
<!-- end -->
<!-- windows -->
`-Help` and `/?` do the same as `-h`.
<!-- end -->

Help never runs anything. It takes no lock, writes no log and reads no configuration, so it works as a normal user and on a host that is not set up. It ends with 0 even when the rest of the line is wrong, because the help is what you asked for. A topic that does not exist gets one line, with a suggestion if one is close, then the main help. One thing can still stop it: if a file of Labyrinth's own differs from the release (section 11), even help ends with 20.

Commands in help and in hints are printed the way you started Labyrinth, so you can copy and run them:
<!-- linux -->
the path you typed, such as `./labyrinth.sh` or `/opt/labyrinth/bin/labyrinth.sh`, with `sudo` in front when you used sudo.
<!-- end -->
<!-- windows -->
`.\labyrinth.ps1` when you are in Labyrinth's folder, and its full path otherwise.
<!-- end -->

The main help ends with how to open this manual (below).

## version (-V)

Prints Labyrinth's version and site, which program printed it, and the release hash on its `SHA-256:` lines (section 2).
<!-- linux -->
`--version` does the same.
<!-- end -->
<!-- windows -->
`-Version` does the same.
<!-- end -->

## manual

<!-- linux -->
`--manual` opens this manual, one screen at a time, from the release's `manual` folder. When nothing can page it, it is printed. Once installed, `man laby` shows it too.
<!-- end -->
<!-- windows -->
`-Manual` opens this manual, one screen at a time: the copy in the release's `manual` folder, otherwise the one the installer put where `Get-Help about_Labyrinth` finds it. When the output is not a window, such as a file, it is printed.
<!-- end -->
It changes nothing and needs no @ADMIN@. Ends with 0, or 40 when this copy of Labyrinth has no manual.

# 6. Options

Options can go before or after the action and the phase. Give a value after a space, an equals sign or a colon:
<!-- linux -->
`--root /srv/lab`, `--root=/srv/lab` and `--root:/srv/lab`
<!-- end -->
<!-- windows -->
`-Root D:\Lab`, `-Root=D:\Lab` and `-Root:D:\Lab`
<!-- end -->
all work. A word that starts with a dash and holds a long name (even with one dash) is that long name. Anything else with one dash is a stack of short letters, and the letter that takes a value goes last: `-rP test lockout` runs `lockout` with the profile `test`. After a lone `--`, every word is a word, not an option.

<!-- linux -->
| Option | What it does | Used by |
|---|---|---|
| `-r`, `--run` | Run a phase for real. May come before or after the phase. | action |
| `-k`, `--keep ID` | Keep a run. The ID is always needed. | action |
| `--extend ID` | Add one timer length to a run's revert timer. The ID is always needed; no time is given. | action |
| `-u`, `--undo ID` | Undo a run. The ID is always needed. | action |
| `--history` | List this host's runs. | action |
| `--show ID` | List what one run changed. The ID is always needed. | action |
| `--probe` | Test every scored service once. | action |
| `--new-seed` | Make this host's decoy seed, show it once and save it. | action |
| `--seed-check` | Check a seed you type at a prompt. | action |
| `-P`, `--profile NAME` | Use this profile instead of the one in the `hosts` file. On a run, it must match the host's line. | preview, run |
| `--root DIR` | The data root, if not `/opt/labyrinth`. Must be a full path. | all |
| `--config DIR` | The configuration folder, if not `<root>/etc`. Must be a full path, and for a preview, run, probe and new-seed it must exist. | all |
| `--break-glass NAME` | Answers the break-glass prompt without typing. | run |
| `--confirm-group GROUP` | Answers the group-name prompt without typing. | run |
| `--approve LIST` | Approves items without the approval prompt; see section 7. | run |
| `--all` | Also undoes the changes that were kept once verified. Asks first. | undo |
| `-y`, `--yes` | Answers yes to the question before `-u ID --all` or before `--new-seed` replaces a seed. Refused anywhere else. | undo with `--all`, new-seed |
| `--no-revert` | Arms no revert timer and asks nothing at the end: the changes stay until you undo them. For test machines only. Refused anywhere else. | run |
| `--only LIST` | Preview or run just these modules of the phase: module IDs separated by commas. Not together with `--skip`. | preview, run |
| `--skip LIST` | Preview or run every module of the phase but these. Not together with `--only`. | preview, run |
| `-h`, `-?`, `--help` | Show help. | all |
| `-V`, `--version` | Show the version. | all |
| `--manual` | Open this manual. | action |

Example: `sudo ./labyrinth.sh -r lockout --root /srv/labyrinth`
<!-- end -->
<!-- windows -->
| Option | What it does | Used by |
|---|---|---|
| `-r`, `-Run` | Run a phase for real. May come before or after the phase. | action |
| `-k`, `-Keep ID` | Keep a run. The ID is always needed. | action |
| `-Extend ID` | Add one timer length to a run's revert timer. The ID is always needed; no time is given. | action |
| `-u`, `-Undo ID` | Undo a run. The ID is always needed. | action |
| `-History` | List this host's runs. | action |
| `-Show ID` | List what one run changed. The ID is always needed. | action |
| `-Probe` | Test every scored service once. | action |
| `-NewSeed` | Make this host's decoy seed, show it once and save it. | action |
| `-SeedCheck` | Check a seed you type at a prompt. | action |
| `-P`, `-Profile NAME` | Use this profile instead of the one in the `hosts` file. On a run, it must match the host's line. | preview, run |
| `-Root DIR` | The data root, if not `C:\ProgramData\Labyrinth`. Must be a full path; `/` and `\` both work. | all |
| `-Config DIR` | The configuration folder, if not `<root>\etc`. Must be a full path, and for a preview, run, probe and new-seed it must exist. | all |
| `-BreakGlass NAME` | Answers the break-glass prompt without typing. | run |
| `-ConfirmGroup GROUP` | Answers the group-name prompt without typing. | run |
| `-Approve LIST` | Approves items without the approval prompt; see section 7. | run |
| `-All` | Also undoes the changes that were kept once verified. Asks first. | undo |
| `-y`, `-Yes` | Answers yes to the question before `-u ID -All` or before `-NewSeed` replaces a seed. Refused anywhere else. | undo with `-All`, new-seed |
| `-NoRevert` | Arms no revert timer and asks nothing at the end: the changes stay until you undo them. For test machines only. Refused anywhere else. | run |
| `-Only LIST` | Preview or run just these modules of the phase: module IDs separated by commas. Not together with `-Skip`. | preview, run |
| `-Skip LIST` | Preview or run every module of the phase but these. Not together with `-Only`. | preview, run |
| `-h`, `-Help` | Show help. | all |
| `-V`, `-Version` | Show the version. | all |
| `-Manual` | Open this manual. | action |

Example: `.\labyrinth.ps1 -r lockout -Root D:\Labyrinth`

Use `-h` for help, not `-?`: PowerShell takes `-?` for itself and shows its own page. `/?` works. PowerShell's common parameters, such as `-Verbose`, are not supported.

A run ID that PowerShell can read as a number must be put in quotes, or PowerShell turns it into one: all digits, such as `0123`, but also forms such as `4e21` (4 times 10 to the 21st) and `12d`. Labyrinth says so when it happens. If in doubt, quote it: `.\labyrinth.ps1 -k '4e21'`.
<!-- end -->

An option given twice, an option with no value, or a word Labyrinth does not know is an error (exit 40). Labyrinth says which word is wrong and, for a near miss, suggests the right one. An option that the action does not use, such as a break-glass answer on a preview, only earns a warning.

**Planned, not built yet.** These are not accepted: `-q`, `-a` and `-d` (queue the run, no questions in the middle of it, and the login check); `-v` (short output); and `init` and `harden`. Typing one of the flags is a usage error (exit 40) that says it is planned and not built yet; the rest is an ordinary mistake.

# 7. What happens during a run

A run goes through a fixed series of safety checks. If one fails, the run stops before anything changes, and Labyrinth says why.

1. **You are @ADMIN@,** the host is listed in `hosts`, and the protected set is loaded.
2. **No other run is in progress** on this host. Only one run at a time may change a host.
3. **Every module is planned.** If any plan has an error, nothing is applied. If nothing needs changing, the run goes straight to step 6 and asks you nothing.
4. **Break-glass check,** when a module needs a change. Log in at the host's own console with the break-glass account, then type its name at the `Break-glass account name:` prompt. Labyrinth asks this once per host. It takes your word for it, then looks for that account's session at the console. Your answer is saved only once you confirm the plan in step 5, so a run that stops before then asks again next time; the run's manifest records what the console check found. If it finds none, it warns `no session for NAME was found at this host's console` and goes on: stop there and check the login yourself if you did not just use it.
5. **Confirmation,** when a module needs a change. Labyrinth shows what each module will do and the release hash on its `SHA-256:` lines, which you compare with the team's notes (section 2), then asks you to type the host's group name. Anything else stops the run, and nothing is changed or saved.
6. **Recording.** Before the first change, each module that only looks runs once more, this time allowed to write its own files, only inside the data root's `state` folder. The inventory is one (below). A preview never does this. If such a module fails, Labyrinth says so, the run's exit code shows it, and the changes still go ahead, unless a later module needs it.
7. **Changes start.** For each module that needs a change, in order:
   - the revert timer is armed (or moved later), unless the module only reads;
   - the change is made;
   - the module checks its own work; if the check fails, that module is undone and the run stops;
   - the scored services are tested again; if one that worked before now fails, that module is undone and the run stops;
   - a change that only takes access away is kept now, if the scored services were tested, and the timer leaves it alone.
8. **Keep or not.** If every change was kept once verified, the run is kept and nothing is asked. Otherwise, check that a new login works, then type `keep`. Pressing Enter, or typing anything else, leaves the timer armed.

Some modules never change anything on their own: they print a checklist for a person to follow, or ask you which items to change.

**Modules that only look.** A module of this kind has a preview and nothing else: it never changes the host. In a run it records, as step 6 describes, and a run in which nothing else needs changing ends right after it, with no questions. If the recording fails, the summary says so and the run ends with 40.

**The inventory (`lockout.inventory`).** The first module of the `lockout` phase, so it runs before anything changes. It writes down what the host has: accounts, groups, administrator rules, authorized SSH keys (by fingerprint, never the key), listening ports, services, scheduled jobs, startup items, installed packages, firewall rules and open connections. It uses only the system's own tools and never records a password or a private key. It also finds, for each service in the `services` file, the addresses that service connects out to, so that the firewall's default deny does not cut them off. A preview prints what it found and writes nothing; a run writes two files in `state/inventory`: the inventory, `<UTC time>.jsonl`, one line per item, and `deps`, the map, one line per outbound connection: the service, the address, the protocol, the port and the program. The map only grows: a later run adds lines and never removes one, and you remove a line by hand. It is a snapshot taken at one moment, so a connection a service makes only now and then can be missed; the checks after the lockout show a break, and the module can be undone. `@CMD@ -h lockout.inventory` has its help page.

**Approving items.** A module that asks first lists each item it would change on an `Item:` line, such as `cron-3f1a@2a2c17aaaf66 (cron): runs from /tmp`. The first word is the item's id, then `@` and its fingerprint, a short code for how the item looks now. In brackets is its category, and last is why the module picked it. During the run, Labyrinth shows the items again and asks which to change:

- Type the ids you approve, separated by spaces, for example `cron-3f1a cron-77b0`.
- Type `category:cron` to approve every item of that category in this plan.
- Press Enter at the `Items to approve` prompt to approve nothing. Nothing is then changed.

An id that is not in the plan is ignored, and Labyrinth says so. If anything else is typed, the module is blocked and changes nothing.

To approve without the prompt, for example from a script, list the items when you start the run, separated by commas:
<!-- linux -->
`--approve harden.persistence_sweep:cron-3f1a@2a2c17aaaf66`
<!-- end -->
<!-- windows -->
`-Approve harden.persistence_sweep:task-3f1a@2a2c17aaaf66`
<!-- end -->
Each entry is the module ID, a colon, then the item as its `Item:` line shows it, id and fingerprint together. Copy them from a preview. Categories are not accepted here, because they could include items you never saw. The prompt is then not asked.

If an item has changed since the plan you copied it from, its fingerprint no longer matches. The item is left alone, and Labyrinth says so and records it. The module checks again just before it changes each item. Approvals are never stored: an undo does not need them.

**Approving before the event.** Some items can be approved before anyone has seen a plan, for example the security update for one scored package. Write each one as a line in the `pre-approved` file in the configuration folder: the module ID, the category, then the item id, or `*` for every item of that category. For example, a line naming the patching module, the category `security-update` and the package `openssl` approves that one package's security update in advance. A module accepts this only for the categories its `module.yml` lists under `pre_approvable`, which are safe to change without anyone seeing each item; for any other category, the line is ignored and Labyrinth says so after the plan. The plan shows the items a line approves on a `Note:` line. During the run, they are approved without asking, and Labyrinth asks only about the rest; when every item is approved in advance, it asks nothing. They are still checked against this run's plan, the module's own checks, the tests of the scored services and the revert timer, like any other item.

**New passwords.** A module that sets a new password shows it once, straight on your screen, and never writes it to a file or a log:

```
  New password for root, shown once:

      Kq7-hT2xRm9.wPz4bNe8

  Type 'recorded' once it is in the offline record:
```

Copy it into the team's offline record, check the copy, then type `recorded`. Anything else asks again. Labyrinth then clears the password from the screen. It cannot clear copies kept elsewhere: the scrollback of tmux or screen, a terminal's own log, or a transcript (`Start-Transcript`) still holds the password. Do not run password modules inside them, or clear and close them once the password is recorded. If the window closes before you type `recorded`, the module puts the old password back, because nobody has the new one. Answer within the revert time: when the revert timer fires, it stops the run, even at this prompt, and undoes it, the new password included. A module that sets passwords needs a terminal to show them on; started without one, for example from a script with no window, it changes nothing and is blocked. (Planned, first usable release: the typed `recorded` goes away. The password is shown once, and recording it is part of the single end-of-run question, which asks you to confirm that the passwords are recorded and you can still log in.)

# 8. Reading the output

A preview looks like this:

```
labyrinth 0.1.0: plan lockout, profile web
run 20261002T140301Z-4f2a (plan mode: nothing is recorded)
This is a plan: Labyrinth only looks, and nothing on web1 changes.
Host web1 is in group ring1.
Checking 2 modules of profile web, most urgent first.

OK       Example check (lockout.example)
  Found:     nothing to do
CHANGE   Password logins (lockout.other)
  Found:     password logins are on
  Will do:   turn password logins off
  Risk:      changes this host; each change is saved first and can be undone

Summary: 2 modules: 1 OK, 1 CHANGE.
Nothing on this host was changed.
Next: @CMD@ -r lockout
plan finished: exit 10 (change needed)
```

The first two lines are the header: the version, plan or `APPLY`, the phase and the profile, then the run ID. A preview records nothing, so its run ID is never in the history. In a run, the second line also names the host and its group. Write the run's ID down, or remember its last four characters. The next lines say what the run will do and how many modules it checks.

Each module's result starts with a status word, then the module's title and, in brackets, its ID:

| Word | In a preview | In a run |
|---|---|---|
| `OK` | Nothing to do. | Applied and checked, or undone cleanly. |
| `CHANGE` | A change is needed. | About to make a change, or to undo one. |
| `WARN` | Skipped on this platform, or only steps a person must carry out. | A checklist only, or a clean-up step failed. |
| `BLOCKED` | A safety check blocks it. | A safety check blocked it. |
| `FAIL` | (not used) | Its check failed, or a scored service got worse. |
| `ERROR` | Something went wrong. | The change or its undo failed. |

Under the result, each line starts with a label that says what kind of line it is:

| Label | Means |
|---|---|
| `Found:` | What the module saw on the host. |
| `Will do:` | What a run would change. |
| `Did:` | What the module changed, or `undone` when Labyrinth undid it. |
| `Why:`, `Risk:` | Why the change matters, and what it could break. |
| `Problem:`, `Cause:` | What went wrong, and why. |
| `Fix:` | What to do about it. |
| `Undo:` | How the change is undone. |
| `Item:` | Something a module asks you to approve: its id and fingerprint, its category, and why (section 7). |
| `Approved:` | The items you approved. |
| `Note:` | Anything else the module printed. |
| `Script:`, `It said:` | The module's script that failed, and its last lines when it gave no reason. |
| `Log:` | The run log, which holds everything (section 11). |
| `More:` | The command that explains the module: `@CMD@ -h <module-id>`. |

A long line wraps onto another line with the same label. Every `WARN`, `BLOCKED`, `FAIL` or `ERROR` says what went wrong, what to do, and ends with `More:`. A module with nothing to apply shows `OK` with `no apply step; nothing changed`. If the profile has no modules for the phase, one `WARN` line names the phase.

After a blank line, the run ends with:

- `Summary:` the number of modules, and how many got each status word. In a run that stopped partway, it also counts the modules that did not run.
- `Nothing on this host was changed.` after a preview, or a run that changed nothing.
- `Log:` the path of the run log, when there is one.
- `Next:` the one thing to do next. It is left out when there is nothing to do. After a preview, it is the `-r` command, with any profile, data root and configuration folder you gave the preview. If the profile is not the one this host is listed with, that run is refused. When the command is too long for one line, `Next:` stands alone and the command follows on the next line, indented, so you can copy it whole.
- The last line gives the exit code and what it means.

The probe reports in the same way, one line per scored service:

```
labyrinth 0.1.0: probe the scored services
OK       [web] pass: status 200
FAIL     [mail] fail: no banner
Summary: 1 OK, 1 FAIL
<!-- linux -->
Next: bring the failed service back, then run '@CMD@ --probe' again.
<!-- end -->
<!-- windows -->
Next: bring the failed service back, then run '@CMD@ -Probe' again.
<!-- end -->
probe finished: exit 30 (a service failed)
```

`WARN` means a service could not be checked, for example because a tool is missing. An undo first lists the modules it leaves in place because they were kept once verified, then says how many modules it undoes, shows each as `CHANGE` and then `OK` or `ERROR`, and ends with `undo finished: exit 0 (undone)`, or `exit 40 (error)` if a module could not be undone.

A run also recaps twice. Before it asks for the group name, it lists what each module will do and says that a revert timer will be armed. If you are connected over the network, it also reminds you to keep a second session open. Before it asks whether to keep the changes, it gives the time, in UTC and in minutes from now, at which the revert timer will undo them.

# 9. Exit codes

Every command ends with one of these numbers. Scripts can test it; people can read the line Labyrinth prints with it.

| Code | Meaning |
|---|---|
| 0 | Done, or nothing to do. |
| 10 | A change is needed (preview), or only steps a person must carry out are left (run). |
| 20 | Blocked by a safety check. The blocked part changed nothing. |
| 30 | A check after a change failed, and that change was undone. The changes made before it stay, and the revert timer is still armed. For probe: a scored service failed. For the seed check: the seed is not valid. |
| 40 | An error, including a mistyped command. Read the message. |

# 10. Files

Everything Labyrinth keeps is under one folder, the **data root**: `@ROOT@` unless you choose another with the root option.

<!-- linux -->
| Folder | Holds |
|---|---|
| `<root>/bin` | The program, and `release.sha256`, the hash of each of its files. The commands `laby` and `labyrinth` are links to it in `/usr/bin`. |
| `<root>/etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`, `outbound-allow`, `pre-approved`. Labyrinth itself writes `seed.conf` here: this host's decoy seed. It is for this host only: never copy it to another host. |
| `<root>/state` | Run records: one folder per run under `state/runs`, with the run's change record (`manifest.jsonl`), its timer, and its log (`output.log`). The inventory and the dependency map are in `state/inventory`. |
| `<root>/logs` | Logs, one folder per kind. |
| `<root>/backup` | Copies of every file taken before it was changed. |

Only root can read `etc`, `state` and `backup`. Only root may be able to change any of it, or `-r`, `-k` and `-u` refuse (section 11).
<!-- end -->
<!-- windows -->
| Folder | Holds |
|---|---|
| `C:\Program Files\Labyrinth` | The program, its `laby.cmd` and `labyrinth.cmd` commands, and `release.sha256`, the hash of each of its files. It is not under the data root. |
| `<root>\etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`, `outbound-allow`, `pre-approved`. Labyrinth itself writes `seed.conf` here: this host's decoy seed. It is for this host only: never copy it to another host. |
| `<root>\state` | Run records: one folder per run under `state\runs`, with the run's change record (`manifest.jsonl`), its timer, and its log (`output.log`). The inventory and the dependency map are in `state\inventory`. |
| `<root>\logs` | Logs, one folder per kind. |
| `<root>\backup` | Copies of every file taken before it was changed. |

Only Administrators, SYSTEM and the account that runs Labyrinth can use the data root. If a file under it belongs to another account, Labyrinth refuses to run until a person checks the file and removes it. If an account that is not an administrator could change the program, the configuration or the data root, `-r`, `-k` and `-u` refuse too (section 11).
<!-- end -->

The revert timer's length is `REVERT_MINUTES` in `event.conf` (5 minutes in the example file).

<!-- linux -->
Each revert timer is a systemd timer named `lab-revert-<run>-<n>`, with its unit files in `/etc/systemd/system`. You do not need to manage it by hand: use `-k` or `-u`, which also delete those files. The timer survives a restart; if its time passed while the host was off, it fires as soon as the host starts.
<!-- end -->
<!-- windows -->
Each revert timer is a scheduled task named `\Labyrinth\lab-revert-<run>-<n>`, run as SYSTEM. You do not need to manage it by hand: use `-k` or `-u`. The task survives a restart; if its time passed while the host was off, it runs as soon as it can.
<!-- end -->

# 11. When something goes wrong

Most errors that stop Labyrinth are two lines: what failed and why, then how to recover. Do what the second line says, then run the same command again.

**Read the run log.** Every run, keep and undo writes a log of the run: everything you saw, your answers to the questions, and every line the modules printed, with the time each started and how it ended. A `FAIL` or `ERROR` shows its path on a `Log:` line, and so does the end of the run. The history lists the logs of the runs that had problems. Only @ADMIN@ can read the log; open it with any text viewer. A preview writes no log: its output is all there is.

**You are locked out.** Do nothing: when the revert timer fires, it undoes the run, and every terminal logged in to the host shows a notice. It leaves the changes that were kept once verified, such as a new admin password, because they cannot lock you out; the new password is in the offline record. If you cannot wait, log in at the console with the break-glass account and list the runs with
<!-- linux -->
`@CMD@ --history`.
<!-- end -->
<!-- windows -->
`@CMD@ -History`.
<!-- end -->
The run that is `armed` is the one to undo; its ID is also on the second line of the run. Then run `@CMD@ -u` with the last four characters of that ID, for example `@CMD@ -u 4f2a`.

**"The run stopped".** A module failed partway through a run. The changes made before it are still in place, and the revert timer is still armed; Labyrinth says when it fires and prints the commands to undo or keep the changes, undo first. If in doubt, undo them: the timer would do the same, only later.

**An `ERROR` line during an undo ("its undo stopped").** Labyrinth could not undo one module of the run. The `Problem:` line says that its undo stopped and the change may still be in place, and the `Fix:` line names the backup folder that holds the module's files as they were before the run. The other modules are still undone, the undo ends with exit code 40, and the history shows the run as `undone with errors`. Restore that module's files by hand from the backup folder and check the service it affects, then run the same undo again: it is safe to repeat.

**"another Labyrinth run (pid N) holds ... lock".** A run is already in progress on this host. Wait for it to finish. If that process has ended, run the command again: a lock left by a process that is gone is taken over. Rarely, after a crash, another program gets the same process number and the lock stays held. If no Labyrinth run is going, delete the `lock` folder in the data root's `state` folder, then run the command again.

**A module's `Problem:` line** says what stopped it. If the module gave no reason, Labyrinth says so, names the module's script on a `Script:` line, and in a preview shows the script's last lines as `It said:` lines. The `More:` line gives the command that explains the module.

<!-- linux -->
**"needs root".** `-r`, `-k`, `-u`, `--history` and `--show` need full rights. Run the command again with `sudo`.
<!-- end -->
<!-- windows -->
**"needs an elevated Administrator session".** `-r`, `-k`, `-u`, `-History` and `-Show` need full rights. Open PowerShell with **Run as administrator** and run the command again.
<!-- end -->

<!-- linux -->
**"needs root to read".** A file in the configuration folder, or the folder itself, can be read only with full rights; after the first run that is normal. A preview and the probe refuse rather than treat the file as missing, which could turn off a safety check without anyone noticing. Run the command again as @ADMIN@.
<!-- end -->
<!-- windows -->
**"needs an elevated Administrator session to read".** A file in the configuration folder, or the folder itself, can be read only with full rights; after the first run that is normal. A preview and the probe refuse rather than treat the file as missing, which could turn off a safety check without anyone noticing. Run the command again as @ADMIN@.
<!-- end -->

<!-- linux -->
**"... can be changed by an account other than root".** Labyrinth runs its program, its configuration and its run records as root, and the revert timer runs them again later. So `-r`, `-k` and `-u` refuse if any other account could change them: the program folder, the configuration folder, the data root, anything in them, or any folder above them. The line names the first one found. Install Labyrinth with the installer (section 2), which refuses a folder that others can change; or keep it in `/opt/labyrinth`, owned by root and not writable by group or others: `sudo chown -R root: /opt/labyrinth` and `sudo chmod -R go-w /opt/labyrinth`. A copy unpacked in a home folder or under `/tmp` is refused.
<!-- end -->
<!-- windows -->
**"... can be changed by an account that is not an administrator".** Labyrinth runs its program, its configuration and its run records as an administrator, and the revert timer runs them again later as SYSTEM. So `-r`, `-k` and `-u` refuse if any other account could change them: the program folder, the configuration folder, the data root, anything in them, or any folder above them. The line names the first one found. Install Labyrinth with the installer (section 2): it puts the program in `C:\Program Files\Labyrinth` and makes the data root, `C:\ProgramData\Labyrinth`, private to administrators. A copy unpacked in a user's own folder, or one that gives Users or Authenticated Users the right to change it, is refused.
<!-- end -->

**"... differs from the release", "is not in the release" or "is missing".** Before it runs anything, Labyrinth checks each of its own files against `release.sha256`, and one was changed, added or removed. Every action refuses, help and the revert timer's undo too, which also shows a notice on every terminal: the changes of an armed run stay in place until this is mended. Until you know otherwise, treat it as a sign of an intruder. Note the line, copy Labyrinth here again from the team's copy, and check the copy with the host's own tools, which do not depend on Labyrinth's code. In Labyrinth's folder:
<!-- linux -->
`sha256sum release.sha256` must print the hash in the team's notes, and `sha256sum -c --quiet release.sha256` must print nothing.
<!-- end -->
<!-- windows -->
`(Get-FileHash .\release.sha256).Hash.ToLower()` must print the hash in the team's notes, and `Get-Content .\release.sha256 | ForEach-Object { $h, $f = $_ -split '  ', 2; if ((Get-FileHash $f).Hash -ne $h) { $f } }` must print nothing.
<!-- end -->
Then run the command again. Labyrinth's own check finds a changed, added or missing file. It cannot find an intruder who changed the check as well, who could make it print the expected hash; the commands above can.

**The archive's SHA-256 does not match the team's notes.** The archive you fetched is not the one the team recorded: the download may be damaged, or it may not be the release. Do not unpack it, and do not run anything from it. Delete it and fetch it again (section 2). If it still differs, use the team's own copy of the release and tell the captain.

**"no release.sha256, so Labyrinth's files were not checked".** This copy has no release list, so Labyrinth could not check its files, and `SHA-256:` says `not checked`. A copy taken straight from the repository has none. Go on only if the team's notes say this copy is the one to run.

**"the protected set is not loaded".** The line ends with the reason: there is no `protected-accounts` file in the configuration folder, or it lists no accounts. Labyrinth will not change anything without it. Copy in the team's prepared file.

**"is malformed".** A line in `hosts`, `event.conf`, `protected-accounts`, `services` or a profile does not have the expected form. The message names the file and line number, and what it expected. Correct that line.

**"no profile named".** No profile file has that name. The next line lists the profiles there are; check the name for a typing mistake.

**"folder does not exist" or "is a file, not a folder".** The path given with the configuration option is not a folder, or, without that option, there is no `etc` folder under the data root. Check the data root option for a typing mistake, or give the folder that holds the `hosts` file. `-k` and `-u` still work without it.

**"lists no service".** The `services` file is there but names no scored service, so nothing can show that a change left the services working. The probe stops, and a run blocks every module that can affect a scored service. List the scored services, one per line.

**"the plan was not confirmed".** The group name typed at the prompt was not this host's group; the line says what was typed. Nothing was changed. Run the same command again and type the group name shown in the prompt.

**"break-glass not confirmed".** The name typed at the break-glass prompt is not listed with the class `breakglass` in `protected-accounts`, or nothing was typed. Nothing was changed. Log in at the console with the break-glass account, run the same command again and type that account's name.

**"does not serve this host's platform".** This host's line in `hosts` names a platform this program does not serve, so a preview, `-r` and the probe refuse to run here. Correct the line, or use the Labyrinth runner for that platform on the host. `-k` and `-u` still work, so a run can always be undone.

**"is an appliance".** This host's line in `hosts` says it is an appliance, such as a firewall. Labyrinth never changes an appliance; configure it by hand, from its runbook.

**"too late".** You tried to keep a run that was already undone, by the timer or by hand. Its changes are gone. Preview and run it again if you still want them.

**"could not be cancelled".** `-k` could not stop the revert timer, so the run was not kept and the timer will still undo it at the time shown. Run the `Retry:` command it prints.

**"could not be extended".** The extend action could not set the new revert timer, so the earlier timer is unchanged and still undoes the run at the time shown. Run the `Retry:` command it prints.

**"the keep could not be recorded".** `-k` cancelled the revert timer, so the changes stay, but the run's record could not be written. The history may not show the run as `kept`. Check that the data folder is not full or read-only.

**"internal error".** Something failed that Labyrinth did not expect, such as a full disk or a damaged file. The line says where, and the next line says what it means for the run: "Nothing was changed.", "The run stopped." with the commands to undo or keep it, or the command to repeat. Exit code 40.

# 12. See also

- [How Labyrinth Works](../Overview.md): the ideas behind the tool, in plain language.
- [Conventions, section 3](../Conventions.md#3-how-a-module-is-run): the exact rules for the command line, options and output.
- [Design 03, the lockout panic button](../design/03-Lockout-Panic-Button.md): the safety checks and the revert timer in detail.
