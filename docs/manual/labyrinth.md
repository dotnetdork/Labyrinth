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

**Status:** Labyrinth is being built. This manual describes the commands as they are specified in [the conventions](../Conventions.md#31-commands-options-gates-and-the-order-of-an-apply).

# 1. What Labyrinth does

Labyrinth makes security changes to a host quickly, safely and reversibly. The work is split into four **phases**, run in this order:

| Phase | In one line |
|---|---|
| `lockout` | Take control back from the attacker. |
| `observe` | See what is happening on the host. |
| `deceive` | Plant traps that give the attacker away. |
| `sustain` | Keep everything running and be able to undo mistakes. |

Each phase is made of **modules**: small, single-purpose pieces of automation, such as "change the default administrator password". Which modules run on a host depends on its **profile**, the kind of host it is (for example, a Linux web server). Labyrinth ships six profiles: `linux-server`, `linux-web`, `linux-siem`, `windows-member`, `windows-dc` and `appliance`. A profile of the same name in the `profiles` folder of the configuration replaces the shipped one for that run, but it can only list modules Labyrinth ships. The `appliance` profile never changes a router or firewall appliance; its modules only print steps for a person to carry out.

Labyrinth always shows you what it would do before it does anything, and every change it makes can be undone.

# 2. Before you start

You need:

<!-- linux -->
- **A root shell.** Labyrinth changes the system, so it runs as root. Use `sudo` in front of each command, as the examples do.
- **Labyrinth's folder on the host,** normally `/opt/labyrinth`. The program is `labyrinth.sh` in its `bin` folder, so run the commands from there: `cd /opt/labyrinth/bin`.
<!-- end -->
<!-- windows -->
- **An elevated PowerShell window.** Labyrinth changes the system, so it runs as an Administrator. Right-click Windows PowerShell and choose **Run as administrator**.
- **Labyrinth's folder on the host,** normally `C:\ProgramData\Labyrinth`. The program is `labyrinth.ps1` in its `bin` folder, so run the commands from there: `cd C:\ProgramData\Labyrinth\bin`.
- **Permission to run the script.** If Windows refuses to run it because of the execution policy, start it like this instead, for this window only: `powershell -ExecutionPolicy Bypass -File .\labyrinth.ps1 plan lockout`.
<!-- end -->
- **The event's configuration,** in the `etc` folder under the data root (section 10). The team prepares these files before the event. The two that matter most:
  - `hosts` lists every host Labyrinth may act on, with its **group** (which wave of hosts it belongs to), its profile and its platform.
  - `protected-accounts` is the **protected set**: accounts Labyrinth must never touch, such as the officials' accounts and the accounts the scoring engine logs in with. If this file is missing or empty, Labyrinth refuses to run.

# 3. Words you will see

| Word | Meaning |
|---|---|
| Phase | A stage of defense. There are four, run in order: `lockout`, `observe`, `deceive` and `sustain`. |
| Module | One small job in a phase, such as turning off password logins. Each has a plain name and an ID, such as `lockout.firewall`: the phase, a dot, then its short name. `@CMD@ help <module-id>` explains it. |
| Run | One use of `plan` or `apply` on one host. |
| Run ID | The name of a run, such as `20261002T140301Z-4f2a`: the start time in UTC and four random characters. Wherever a command asks for a run, the last four characters (`4f2a`) are enough. |
| Plan | A dry run: each module reports what it would change. Nothing is changed and nothing is written. |
| Apply | A real run: Labyrinth plans, asks you to confirm, then makes the changes. |
| Revert timer | A timer started before a risky change. If nobody **keeps** the run in time, the timer undoes the whole run by itself. It protects you if a change locks you out. |
| Keep | Telling Labyrinth that a run's changes are good: the revert timer is cancelled and the changes stay. |
| Rollback | Undoing what a run changed, newest first. The revert timer starts one automatically; you can start one too. |
| Break-glass account | The emergency login, kept in the team's offline record, used only when normal access fails. Labyrinth asks you to confirm it works before changing anything. |
| Scored service | A service the scoring engine checks, such as a website, email or DNS. Labyrinth tests them before and after each change. |
| Exit code | The number Labyrinth ends with, which says how it went (section 9). |

# 4. Quick start

New to Labyrinth? `@CMD@ help basics` explains these ideas on one screen. Run with no command, Labyrinth prints three steps to start with.

The normal way to use Labyrinth is: plan, apply, check, keep.

1. **See what would change.** Nothing is changed.

   ```
   @CMD@ plan lockout
   ```

2. **Make the changes.** Labyrinth plans again, then asks you to confirm three things: that you are logged in at the console with the break-glass account, the host's group name, and, at the end, whether to keep the run.

   ```
   @CMD@ apply lockout
   ```

3. **Check that you can still get in.** Open a new login session, on the console or over the network, and make sure it works. Do not close your current session yet.

4. **Keep the run.** At the keep prompt, type `keep`. If you are not sure, type anything else: the revert timer stays armed and undoes the run when it fires. You can still keep it before then:

   ```
   @CMD@ keep
   ```

**If something is wrong,** undo the run at once instead of waiting for the timer. Labyrinth prints the run ID at the start of every run; the last four characters are enough:

```
@CMD@ rollback 4f2a
```

# 5. Commands

Every command has the same shape: the command, then the phase or run it acts on, then any options.

```
@CMD@ <command> [<phase> | <run>] [options]
```

Commands, phases, option names and run IDs can be typed in any mix of upper and lower case. The short flags are the exception: type `-h` and `-V` exactly as shown, because `-v` is an error.

## plan *phase*

Shows what every module of the phase would change on this host. Nothing is changed, and nothing is written, not even a log. Run it as often as you like.

Ends with 0 when nothing needs changing, 10 when something does, 20 when a safety check blocks a module, and 40 on an error.

## apply *phase*

Plans, then makes the changes behind the safety checks described in section 7. You are asked to confirm before anything changes.

Ends with 0 when every change was made and checked, or the highest problem code otherwise: 20 blocked, 30 a check after a change failed, 40 an error.

## keep [*run*]

Keeps a run's changes: cancels its revert timer, then records that the run was kept. Without a run, it keeps the only run whose timer is armed; if more than one is armed, it lists them and keeps nothing.

Ends with 0 when the run is kept, 20 when it is not run as @ADMIN@ or it is too late because the run was already rolled back, and 40 when the timer could not be cancelled or the keep could not be recorded. If the timer could not be cancelled, the run is **not** kept and the timer will still undo it: Labyrinth says when, and gives the command to try again.

## rollback *run*

Undoes everything the run changed, newest change first. This is exactly what the revert timer does when it fires. You must name the run. Without one, it changes nothing and ends with 40; run as @ADMIN@, it also lists the runs to choose from. Running it twice is safe.

Ends with 0 when the run is rolled back, 20 when not run as @ADMIN@, and 40 on an error.

## runs

Lists this host's runs, oldest first, with the run ID, phase, start time (UTC) and state:

- `armed`: the revert timer is set, with the time it will undo the run. If that time has passed, it says when the timer was due; if Labyrinth cannot tell, it says the time is unknown;
<!-- linux -->
- `armed: timer lost (restart?)`: the run is still armed, but systemd no longer has its revert timer, usually because the host restarted. Nothing will undo the run by itself. Keep it or roll it back now;
<!-- end -->
- `kept`: someone kept the run;
- `rolled back`: the run was undone;
- `rolled back with errors`: the run was undone, but some of it could not be; section 11 explains what to do;
- `not kept, no timer`: the run changed nothing that needed a timer.

Below the list, it shows how to name a run by its last four characters. Then it lists the logs of the runs that had problems (section 11). It changes nothing, but it must be run as @ADMIN@. Ends with 0, 20 when not run as @ADMIN@, and 40 on an error.

## probe

Tests every scored service once, the way the scoring engine would, and prints the result for each. Changes nothing. Ends with 0 when every service passes, 20 when there is no list of scored services, 30 when any service fails, and 40 on an error.

## help [*topic*]

Prints help for every command, or for one. Two more topics:

- `@CMD@ help basics` explains phases, modules, plan and apply, runs, the revert timer, keep, rollback and scored services, in plain words, on one screen.
- `@CMD@ help <module-id>`, such as `@CMD@ help lockout.firewall`, explains one module: its name, its phase and order, what it may change in plain words, whether it can affect a scored service, the platforms it runs on, its folder, and then its own page: what it checks and changes, why, what can go wrong, how to undo it, and what to do when it fails. Every warning, block, failure and error in the output names the page to read.

After any command,
<!-- linux -->
`-h`, `-?` or `--help`
<!-- end -->
<!-- windows -->
`-h` or `-Help`
<!-- end -->
does the same, once the rest of the line is correct.

## version

Prints Labyrinth's version.
<!-- linux -->
`-V` or `--version`
<!-- end -->
<!-- windows -->
`-V` or `-Version`
<!-- end -->
does the same.

# 6. Options

Options can go before or after the command. Give a value after a space, an equals sign or a colon:
<!-- linux -->
`--root /srv/lab`, `--root=/srv/lab` and `--root:/srv/lab`
<!-- end -->
<!-- windows -->
`-Root D:\Lab`, `-Root=D:\Lab` and `-Root:D:\Lab`
<!-- end -->
all work.

<!-- linux -->
| Option | What it does | Used by |
|---|---|---|
| `--profile NAME` | Use this profile instead of the one in the `hosts` file. On apply, it must match the host's line. | plan, apply |
| `--root DIR` | The data root, if not `/opt/labyrinth`. Must be a full path. | all |
| `--config DIR` | The configuration folder, if not `<root>/etc`. Must be a full path, and for plan, apply and probe it must exist. | all |
| `--break-glass NAME` | Answers the break-glass prompt without typing. | apply |
| `--confirm-group GROUP` | Answers the group-name prompt without typing. | apply |
| `--approve LIST` | Approves items without the approval prompt; see section 7. | apply |
| `-h`, `-?`, `--help` | Show help. | all |
| `-V`, `--version` | Show the version. | all |

Example: `sudo ./labyrinth.sh apply lockout --root /srv/labyrinth`
<!-- end -->
<!-- windows -->
| Option | What it does | Used by |
|---|---|---|
| `-Profile NAME` | Use this profile instead of the one in the `hosts` file. On apply, it must match the host's line. | plan, apply |
| `-Root DIR` | The data root, if not `C:\ProgramData\Labyrinth`. Must be a full path; `/` and `\` both work. | all |
| `-Config DIR` | The configuration folder, if not `<root>\etc`. Must be a full path, and for plan, apply and probe it must exist. | all |
| `-BreakGlass NAME` | Answers the break-glass prompt without typing. | apply |
| `-ConfirmGroup GROUP` | Answers the group-name prompt without typing. | apply |
| `-Approve LIST` | Approves items without the approval prompt; see section 7. | apply |
| `-h`, `-Help` | Show help. | all |
| `-V`, `-Version` | Show the version. | all |

Example: `.\labyrinth.ps1 apply lockout -Root D:\Labyrinth`

Use `-h` for help, not `-?`: PowerShell takes `-?` for itself and shows its own page. PowerShell's common parameters, such as `-Verbose`, are not supported.

Run IDs that are all digits, such as `0123`, must be put in quotes, or PowerShell turns them into a number: `.\labyrinth.ps1 keep '0123'`.
<!-- end -->

An option given twice, an option with no value, or a word Labyrinth does not know is an error (exit 40). Labyrinth says which word is wrong and, for a near miss, suggests the right one.

**Older forms still work.** A phase on its own (`@CMD@ lockout`) means `plan lockout`, and `--apply` with a phase means `apply`. They are kept because a revert timer that is already armed still uses them.

# 7. What happens during an apply

An apply goes through a fixed series of safety checks. If one fails, the run stops before anything changes, and Labyrinth says why.

1. **You are @ADMIN@,** the host is listed in `hosts`, and the protected set is loaded.
2. **No other run is in progress** on this host. Only one run at a time may change a host.
3. **Every module is planned.** If any plan has an error, nothing is applied. If nothing needs changing, the run ends here without asking you anything.
4. **Break-glass check.** Log in at the host's own console with the break-glass account and type its name. Labyrinth asks this once per host. It takes your word for it, then looks for that account's session at the console and records what it found in the run's manifest. If it finds none, it warns `no session for NAME was found at this host's console` and goes on: stop there and check the login yourself if you did not just use it.
5. **Confirmation.** Labyrinth shows what each module will do, then asks you to type the host's group name. Anything else stops the run.
6. **Changes start.** For each module that needs a change, in order:
   - the revert timer is armed (or moved later), unless the module only reads;
   - the change is made;
   - the module checks its own work; if the check fails, that module is undone and the run stops;
   - the scored services are tested again; if one that worked before now fails, that module is undone and the run stops.
7. **Keep or not.** Check that a new login works, then type `keep`. Anything else leaves the timer armed.

Some modules never change anything on their own: they print a checklist for a person to follow, or ask you which items to change.

**Approving items.** A module that asks first lists each item it would change on an `Item:` line, such as `cron-3f1a@2a2c17aaaf66 (cron): runs from /tmp`. The first word is the item's id, then `@` and its fingerprint, a short code for how the item looks now. In brackets is its category, and last is why the module picked it. During the apply, Labyrinth shows the items again and asks which to change:

- Type the ids you approve, separated by spaces, for example `cron-3f1a cron-77b0`.
- Type `category:cron` to approve every item of that category in this plan.
- Press Enter to approve nothing. Nothing is then changed.

An id that is not in the plan is ignored, and Labyrinth says so. If anything else is typed, the module is blocked and changes nothing.

To approve without the prompt, for example from a script, list the items when you start the apply:
<!-- linux -->
`--approve lockout.persistence:cron-3f1a@2a2c17aaaf66,lockout.persistence:cron-77b0@5821d4d89f00`
<!-- end -->
<!-- windows -->
`-Approve lockout.persistence:task-3f1a@2a2c17aaaf66,lockout.persistence:task-77b0@5821d4d89f00`
<!-- end -->
Each entry is the module ID, a colon, then the item as its `Item:` line shows it, id and fingerprint together. Copy them from a plan. Categories are not accepted here, because they could include items you never saw. The prompt is then not asked.

If an item has changed since the plan you copied it from, its fingerprint no longer matches. The item is left alone, and Labyrinth says so and records it. The module checks again just before it changes each item. Approvals are never stored: a rollback does not need them.

**New passwords.** A module that sets a new password shows it once, straight on your screen, and never writes it to a file or a log:

```
  New password for root, shown once:

      Kq7-hT2xRm9.wPz4bNe8

  Type 'recorded' once it is in the offline record:
```

Copy it into the team's offline record, check the copy, then type `recorded`. Anything else asks again. Labyrinth then clears the password from the screen. It cannot clear copies kept elsewhere: the scrollback of tmux or screen, a terminal's own log, or a transcript (`Start-Transcript`) still holds the password. Do not run password modules inside them, or clear and close them once the password is recorded. If the window closes before you type `recorded`, the module puts the old password back, because nobody has the new one. Answer within the revert time: when the revert timer fires, it stops the run, even at this prompt, and undoes it, the new password included. A module that sets passwords needs a terminal to show them on; started without one, for example from a script with no window, it changes nothing and is blocked.

# 8. Reading the output

A plan looks like this:

```
labyrinth 0.1.0-dev: plan lockout, profile web
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
Next: @CMD@ apply lockout
plan finished: exit 10 (change needed)
```

The first two lines are the header: the version, plan or `APPLY`, the phase and the profile, then the run ID. A plan records nothing, so its run ID is never listed by `runs`. In an apply, the second line also names the host and its group. Write the apply's run ID down, or remember its last four characters. The next lines say what the run will do and how many modules it checks.

Each module's result starts with a status word, then the module's title and, in brackets, its ID:

| Word | In a plan | In an apply |
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
| `Will do:` | What an apply would change. |
| `Did:` | What the module changed, or `rolled back` when Labyrinth undid it. |
| `Why:`, `Risk:` | Why the change matters, and what it could break. |
| `Problem:`, `Cause:` | What went wrong, and why. |
| `Fix:` | What to do about it. |
| `Undo:` | How the change is undone. |
| `Item:` | Something a module asks you to approve: its id and fingerprint, its category, and why (section 7). |
| `Approved:` | The items you approved. |
| `Note:` | Anything else the module printed. |
| `Script:`, `It said:` | The module's script that failed, and its last lines when it gave no reason. |
| `Log:` | The run log, which holds everything (section 11). |
| `More:` | The command that explains the module: `@CMD@ help <module-id>`. |

A long line wraps onto another line with the same label. Every `WARN`, `BLOCKED`, `FAIL` or `ERROR` says what went wrong, what to do, and ends with `More:`. A module with nothing to apply shows `OK` with `no apply step; nothing changed`. If the profile has no modules for the phase, one `WARN` line names the phase.

After a blank line, the run ends with:

- `Summary:` the number of modules, and how many got each status word. In an apply that stopped partway, it also counts the modules that did not run.
- `Nothing on this host was changed.` after a plan, or an apply that changed nothing.
- `Log:` the path of the run log, when there is one.
- `Next:` the one thing to do next. It is left out when there is nothing to do. After a plan, it is the apply command, with any profile, data root and configuration folder you gave the plan. If the profile is not the one this host is listed with, that apply is refused. When the command is too long for one line, `Next:` stands alone and the command follows on the next line, indented, so you can copy it whole.
- The last line gives the exit code and what it means.

`probe` reports in the same way, one line per scored service:

```
labyrinth 0.1.0-dev: probe the scored services
OK       [web] pass: status 200
FAIL     [mail] fail: no banner
Summary: 1 OK, 1 FAIL
Next: bring the failed service back, then run '@CMD@ probe' again.
probe finished: exit 30 (a service failed)
```

`WARN` means a service could not be checked, for example because a tool is missing. A `rollback` says how many modules it undoes, shows each as `CHANGE` and then `OK` or `ERROR`, and ends with `rollback finished: exit 0 (rolled back)`, or `exit 40 (error)` if a module could not be undone.

An apply also recaps twice. Before it asks for the group name, it lists what each module will do and says that a revert timer will be armed. If you are connected over the network, it also reminds you to keep a second session open. Before it asks whether to keep the changes, it gives the time, in UTC and in minutes from now, at which the revert timer will undo them.

# 9. Exit codes

Every command ends with one of these numbers. Scripts can test it; people can read the line Labyrinth prints with it.

| Code | Meaning |
|---|---|
| 0 | Done, or nothing to do. |
| 10 | A change is needed (plan), or only steps a person must carry out are left (apply). |
| 20 | Blocked by a safety check. The blocked part changed nothing. |
| 30 | A check after a change failed, and that change was undone. For probe: a scored service failed. |
| 40 | An error, including a mistyped command. Read the message. |

# 10. Files

Everything Labyrinth keeps is under one folder, the **data root**: `@ROOT@` unless you choose another with the root option.

<!-- linux -->
| Folder | Holds |
|---|---|
| `<root>/bin` | The program. |
| `<root>/etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`. |
| `<root>/state` | Run records: one folder per run under `state/runs`, with the run's change record (`manifest.jsonl`), its timer, and its log (`output.log`). |
| `<root>/logs` | Logs, one folder per kind. |
| `<root>/backup` | Copies of every file taken before it was changed. |

Only root can read `etc`, `state` and `backup`. Only root may be able to change any of it, or `apply`, `keep` and `rollback` refuse (section 11).
<!-- end -->
<!-- windows -->
| Folder | Holds |
|---|---|
| `<root>\bin` | The program. |
| `<root>\etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`. |
| `<root>\state` | Run records: one folder per run under `state\runs`, with the run's change record (`manifest.jsonl`), its timer, and its log (`output.log`). |
| `<root>\logs` | Logs, one folder per kind. |
| `<root>\backup` | Copies of every file taken before it was changed. |

Only Administrators, SYSTEM and the account that runs Labyrinth can use the data root. If a file under it belongs to another account, Labyrinth refuses to run until a person checks the file and removes it. If an account that is not an administrator could change the program, the configuration or the data root, `apply`, `keep` and `rollback` refuse too (section 11).
<!-- end -->

The revert timer's length is `REVERT_MINUTES` in `event.conf` (5 minutes in the example file).

<!-- linux -->
Each revert timer is a systemd timer named `lab-revert-<run>-<n>`. You do not need to manage it by hand: use `keep` or `rollback`. The timer lives only in memory, so a restart drops it: an armed run is then not undone by itself, and `runs` shows it as `armed: timer lost (restart?)`. After a restart, check `runs` and keep or roll back each armed run.
<!-- end -->
<!-- windows -->
Each revert timer is a scheduled task named `\Labyrinth\lab-revert-<run>-<n>`, run as SYSTEM. You do not need to manage it by hand: use `keep` or `rollback`. The task survives a restart; if its time passed while the host was off, it runs as soon as it can.
<!-- end -->

# 11. When something goes wrong

**"another Labyrinth run (pid N) holds ... lock".** A run is already in progress on this host. Wait for it to finish. If that process has ended, run the command again: a lock left by a process that is gone is taken over. Rarely, after a crash, another program gets the same process number and the lock stays held. If no Labyrinth run is going, delete the `lock` folder in the data root's `state` folder, then run the command again.

Most errors that stop Labyrinth are two lines: what failed and why, then how to recover. Do what the second line says, then run the same command again.

**Read the run log.** Every apply, keep and rollback writes a log of the run: everything you saw, your answers to the questions, and every line the modules printed, with the time each started and how it ended. A `FAIL` or `ERROR` shows its path on a `Log:` line, and so does the end of the run. `runs` lists the logs of the runs that had problems. Only @ADMIN@ can read the log; open it with any text viewer. A plan writes no log: its output is all there is.

**A module's `Problem:` line** says what stopped it. If the module gave no reason, Labyrinth says so, names the module's script on a `Script:` line, and in a plan shows the script's last lines as `It said:` lines. The `More:` line gives the command that explains the module.

<!-- linux -->
**"needs root".** `apply`, `runs`, `keep` and `rollback` need full rights. Run the command again with `sudo`.
<!-- end -->
<!-- windows -->
**"needs an elevated Administrator session".** `apply`, `runs`, `keep` and `rollback` need full rights. Open PowerShell with **Run as administrator** and run the command again.
<!-- end -->

<!-- linux -->
**"... can be changed by an account other than root".** Labyrinth runs its program, its configuration and its run records as root, and the revert timer runs them again later. So `apply`, `keep` and `rollback` refuse if any other account could change them: the program folder, the configuration folder, the data root, anything in them, or any folder above them. The line names the first one found. Keep Labyrinth in `/opt/labyrinth`, owned by root and not writable by group or others: `sudo chown -R root: /opt/labyrinth` and `sudo chmod -R go-w /opt/labyrinth`. A copy unpacked in a home folder or under `/tmp` is refused.
<!-- end -->
<!-- windows -->
**"... can be changed by an account that is not an administrator".** Labyrinth runs its program, its configuration and its run records as an administrator, and the revert timer runs them again later as SYSTEM. So `apply`, `keep` and `rollback` refuse if any other account could change them: the program folder, the configuration folder, the data root, anything in them, or any folder above them. The line names the first one found. Keep Labyrinth in `C:\ProgramData\Labyrinth`, where `apply` makes the data root private to administrators. A copy unpacked in a user's own folder, or one that gives Users or Authenticated Users the right to change it, is refused.
<!-- end -->

**"the protected set is not loaded".** The line ends with the reason: there is no `protected-accounts` file in the configuration folder, or it lists no accounts. Labyrinth will not change anything without it. Copy in the team's prepared file.

**"is malformed".** A line in `hosts`, `event.conf`, `protected-accounts`, `services` or a profile does not have the expected form. The message names the file and line number, and what it expected. Correct that line.

**"no profile named".** No profile file has that name. The next line lists the profiles there are; check the name for a typing mistake.

**"folder does not exist" or "is a file, not a folder".** The path given with the configuration option is not a folder. Give the folder that holds the `hosts` file, or leave the option out to use the one under the data root. `keep` and `rollback` still work without it.

**"does not serve this host's platform".** This host's line in `hosts` names a platform this program does not serve, so `plan`, `apply` and `probe` refuse to run here. Correct the line, or use the Labyrinth runner for that platform on the host. `keep` and `rollback` still work, so a run can always be undone.

**"is an appliance".** This host's line in `hosts` says it is an appliance, such as a firewall. Labyrinth never changes an appliance; configure it by hand, from its runbook.

**"too late".** You tried to keep a run that was already rolled back, by the timer or by hand. Its changes are gone. Plan and apply again if you still want them.

**"could not be cancelled".** `keep` could not stop the revert timer, so the run was not kept and the timer will still undo it at the time shown. Run the `Retry:` command it prints.

**"the keep could not be recorded".** `keep` cancelled the revert timer, so the changes stay, but the run's record could not be written. `runs` may not show the run as `kept`. Check that the data folder is not full or read-only.

**"The run stopped".** A module failed partway through a run. The changes made before it are still in place, and the revert timer is still armed; Labyrinth says when it fires and prints the commands to keep or undo the changes. If in doubt, roll back.

**"internal error".** Something failed that Labyrinth did not expect, such as a full disk or a damaged file. The line says where, and the next line says what it means for the run: "Nothing was changed.", "The run stopped." with the commands to keep or undo it, or the command to repeat. Exit code 40.

**"rollback FAILED".** Labyrinth could not undo one module of the run. The line names the module and the backup folder that holds its files as they were before the run. The other modules are still undone, and `runs` shows the run as `rolled back with errors`. Restore that module's files by hand from the backup folder, then check the service it affects.

**You are locked out.** Do nothing: when the revert timer fires, it undoes the run. If you cannot wait, log in at the console with the break-glass account and run `rollback`.

# 12. See also

- [How Labyrinth Works](../Overview.md): the ideas behind the tool, in plain language.
- [Conventions, section 3](../Conventions.md#3-how-a-module-is-run): the exact rules for commands, options and output.
- [Design 01, the lockout panic button](../design/01-Lockout-Panic-Button.md): the safety checks and the revert timer in detail.
