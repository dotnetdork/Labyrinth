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

**Status:** Labyrinth is being built. This manual describes the commands as they are specified in [the conventions](../Conventions.md#31-commands-options-gates-and-the-order-of-an-apply). Until the command-line work is finished, the program does not yet accept every form shown here, and its output does not yet look exactly as described in section 8.

# 1. What Labyrinth does

Labyrinth makes security changes to a host quickly, safely and reversibly. The work is split into four **phases**, run in this order:

| Phase | In one line |
|---|---|
| `lockout` | Take control back from the attacker. |
| `observe` | See what is happening on the host. |
| `deceive` | Plant traps that give the attacker away. |
| `sustain` | Keep everything running and be able to undo mistakes. |

Each phase is made of **modules**: small, single-purpose pieces of automation, such as "change the default administrator password". Which modules run on a host depends on its **profile**, the kind of host it is (for example, a Linux web server).

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
| Run | One use of `plan` or `apply` on one host. |
| Run ID | The name of a run, such as `20261002T140301Z-4f2a`: the start time in UTC and four random characters. Wherever a command asks for a run, the last four characters (`4f2a`) are enough. |
| Plan | A dry run: each module reports what it would change. Nothing is changed and nothing is written. |
| Apply | A real run: Labyrinth plans, asks you to confirm, then makes the changes. |
| Revert timer | A timer started before a risky change. If nobody **keeps** the run in time, the timer undoes the whole run by itself. It protects you if a change locks you out. |
| Keep | Telling Labyrinth that a run's changes are good: the revert timer is cancelled and the changes stay. |
| Rollback | Undoing what a run changed, newest first. The revert timer starts one automatically; you can start one too. |
| Break-glass account | The emergency login, kept in the team's offline record, used only when normal access fails. Labyrinth asks you to prove it works before changing anything. |
| Scored service | A service the scoring engine checks, such as a website, email or DNS. Labyrinth tests them before and after each change. |
| Exit code | The number Labyrinth ends with, which says how it went (section 9). |

# 4. Quick start

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

Commands, phases and option names can be typed in any mix of upper and lower case.

## plan *phase*

Shows what every module of the phase would change on this host. Nothing is changed, and nothing is written, not even a log. Run it as often as you like.

Ends with 0 when nothing needs changing, 10 when something does, 20 when a safety check blocks a module, and 40 on an error.

## apply *phase*

Plans, then makes the changes behind the safety checks described in section 7. You are asked to confirm before anything changes.

Ends with 0 when every change was made and checked, or the highest problem code otherwise: 20 blocked, 30 a check after a change failed, 40 an error.

## keep [*run*]

Keeps a run's changes: cancels its revert timer, then records that the run was kept. Without a run, it keeps the only run whose timer is armed; if more than one is armed, it lists them and keeps nothing.

Ends with 0 when the run is kept, 20 when it is too late because the run was already rolled back, and 40 when the timer could not be cancelled or the keep could not be recorded. If the timer could not be cancelled, the run is **not** kept and the timer will still undo it: Labyrinth says when, and gives the command to try again.

## rollback *run*

Undoes everything the run changed, newest change first. This is exactly what the revert timer does when it fires. You must name the run; without one, Labyrinth lists the runs and changes nothing. Running it twice is safe.

Ends with 0 when the run is rolled back, 20 when not run as @ADMIN@, and 40 on an error.

## runs

Lists this host's runs, oldest first, with the run ID, phase, start time (UTC) and state:

- `armed`: the revert timer is set, with the time it will undo the run. If that time has passed, it says when the timer was due; if Labyrinth cannot tell, it says the time is unknown;
- `kept`: someone kept the run;
- `rolled back`: the run was undone;
- `rolled back with errors`: the run was undone, but some of it could not be; section 11 explains what to do;
- `not kept, no timer`: the run changed nothing that needed a timer.

Below the list, it shows how to name a run by its last four characters. It changes nothing, but it must be run as @ADMIN@. Ends with 0, 20 when not run as @ADMIN@, and 40 on an error.

## probe

Tests every scored service once, the way the scoring engine would, and prints the result for each. Changes nothing. Ends with 0 when every service passes, 20 when there is no list of scored services, 30 when any service fails, and 40 on an error.

## help [*command*]

Prints help for every command, or for one. `-h` and `--help` after any command do the same.

## version

Prints Labyrinth's version. `-V` and `--version` do the same.

# 6. Options

Options can go before or after the command. Give a value with a space or an equals sign.

<!-- linux -->
| Option | What it does | Used by |
|---|---|---|
| `--profile NAME` | Use this profile instead of the one in the `hosts` file. On apply, it must match the host's line. | plan, apply |
| `--root DIR` | The data root, if not `/opt/labyrinth`. Must be a full path. | all |
| `--config DIR` | The configuration folder, if not `<root>/etc`. Must be a full path. | all |
| `--break-glass NAME` | Answers the break-glass prompt without typing. | apply |
| `--confirm-group GROUP` | Answers the group-name prompt without typing. | apply |
| `-h`, `--help` | Show help. | all |
| `-V`, `--version` | Show the version. | all |

Example: `sudo ./labyrinth.sh apply lockout --root /srv/labyrinth`
<!-- end -->
<!-- windows -->
| Option | What it does | Used by |
|---|---|---|
| `-Profile NAME` | Use this profile instead of the one in the `hosts` file. On apply, it must match the host's line. | plan, apply |
| `-Root DIR` | The data root, if not `C:\ProgramData\Labyrinth`. Must be a full path. | all |
| `-Config DIR` | The configuration folder, if not `<root>\etc`. Must be a full path. | all |
| `-BreakGlass NAME` | Answers the break-glass prompt without typing. | apply |
| `-ConfirmGroup GROUP` | Answers the group-name prompt without typing. | apply |
| `-Help`, `-?` | Show help. | all |
| `-Version` | Show the version. | all |

Example: `.\labyrinth.ps1 apply lockout -Root D:\Labyrinth`

Run IDs that are all digits, such as `0123`, must be put in quotes, or PowerShell turns them into a number: `.\labyrinth.ps1 keep '0123'`.
<!-- end -->

An option given twice, an option with no value, or a word Labyrinth does not know is an error (exit 40). Labyrinth says which word is wrong and, for a near miss, suggests the right one.

**Older forms still work.** A phase on its own (`@CMD@ lockout`) means `plan lockout`, and `--apply` with a phase means `apply`. They are kept because a revert timer that is already armed still uses them.

# 7. What happens during an apply

An apply goes through a fixed series of safety checks. If one fails, the run stops before anything changes, and Labyrinth says why.

1. **You are @ADMIN@,** the host is listed in `hosts`, and the protected set is loaded.
2. **No other run is in progress** on this host. Only one run at a time may change a host.
3. **Every module is planned.** If any plan has an error, nothing is applied. If nothing needs changing, the run ends here without asking you anything.
4. **Break-glass check.** Log in at the host's own console with the break-glass account and type its name. Labyrinth asks this once per host.
5. **Confirmation.** Labyrinth shows what each module will do, then asks you to type the host's group name. Anything else stops the run.
6. **Changes start.** For each module that needs a change, in order:
   - the revert timer is armed (or moved later), unless the module only reads;
   - the change is made;
   - the module checks its own work; if the check fails, that module is undone and the run stops;
   - the scored services are tested again; if one that worked before now fails, that module is undone and the run stops.
7. **Keep or not.** Check that a new login works, then type `keep`. Anything else leaves the timer armed.

Some modules never change anything on their own: they print a checklist for a person to follow, or ask you which items to change.

# 8. Reading the output

Every run starts with a two-line header naming the version, the phase, the profile and the run ID. Write the run ID down, or remember its last four characters.

Each module's result starts with a status word:

| Word | In a plan | In an apply |
|---|---|---|
| `OK` | Nothing to do. | Applied and checked, or undone cleanly. |
| `CHANGE` | A change is needed. | About to make a change. |
| `WARN` | Skipped on this platform. | A checklist only, or a clean-up step failed. |
| `BLOCKED` | A safety check blocks it. | A safety check blocked it. |
| `FAIL` | (not used) | Its check failed, or a scored service got worse. |
| `ERROR` | Something went wrong. | The change or its undo failed. |

A module's own messages are indented under its result line. The run ends with a `Summary:` line counting each status word, a `Next:` line with the one command to run next, and the exit code with its meaning.

# 9. Exit codes

Every command ends with one of these numbers. Scripts can test it; people can read the line Labyrinth prints with it.

| Code | Meaning |
|---|---|
| 0 | Done, or nothing to do. |
| 10 | A change is needed (plan only). |
| 20 | Blocked by a safety check. The blocked part changed nothing. |
| 30 | A check after a change failed, or a probe failed. The change was undone. |
| 40 | An error, including a mistyped command. Read the message. |

# 10. Files

Everything Labyrinth keeps is under one folder, the **data root**: `@ROOT@` unless you choose another with the root option.

<!-- linux -->
| Folder | Holds |
|---|---|
| `<root>/bin` | The program. |
| `<root>/etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`. |
| `<root>/state` | Run records: one folder per run under `state/runs`, with the run's change record (`manifest.jsonl`) and its timer. |
| `<root>/logs` | Logs, one folder per kind. |
| `<root>/backup` | Copies of every file taken before it was changed. |

Only root can read `etc`, `state` and `backup`.
<!-- end -->
<!-- windows -->
| Folder | Holds |
|---|---|
| `<root>\bin` | The program. |
| `<root>\etc` | The event's configuration: `hosts`, `protected-accounts`, `event.conf`, `services`, `scoring-allowlist`, `never-ban`. |
| `<root>\state` | Run records: one folder per run under `state\runs`, with the run's change record (`manifest.jsonl`) and its timer. |
| `<root>\logs` | Logs, one folder per kind. |
| `<root>\backup` | Copies of every file taken before it was changed. |

Only Administrators, SYSTEM and the account that runs Labyrinth can use the data root. If a file under it belongs to another account, Labyrinth refuses to run until a person checks the file and removes it.
<!-- end -->

The revert timer's length is `REVERT_MINUTES` in `event.conf` (5 minutes in the example file).

<!-- linux -->
Each revert timer is a systemd timer named `lab-revert-<run>-<n>`. You do not need to manage it by hand: use `keep` or `rollback`.
<!-- end -->
<!-- windows -->
Each revert timer is a scheduled task named `\Labyrinth\lab-revert-<run>-<n>`, run as SYSTEM. You do not need to manage it by hand: use `keep` or `rollback`.
<!-- end -->

# 11. When something goes wrong

**"another Labyrinth run (pid N) holds ... lock".** A run is already in progress on this host. Wait for it to finish. If that process has ended, run the command again: a lock left by a process that is gone is taken over.

**"protected set: ... not found" or "... is empty".** The `protected-accounts` file is not in the configuration folder, or has no accounts. Labyrinth will not change anything without it. Copy in the team's prepared file.

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
