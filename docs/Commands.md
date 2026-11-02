# The `laby` Command

This page shows the commands a person types to run Labyrinth, with what each one does and when to use it. It is written for teammates learning the tool, not for the people building it.

> [!NOTE]
> **Working now and planned.** The status, preview, run, keep, undo, history, show, probe, the decoy seed commands, help, the manual and the version work now. Parts marked **Planned** are not built yet; each names its stage (Roadmap). The installer (`sudo ./install.sh` on Linux, `.\install.ps1` as Administrator on Windows) adds the commands `laby` and `labyrinth`; without it, `laby` means `./labyrinth.sh` on Linux or `.\labyrinth.ps1` on Windows, run from the release folder. The exact rules, including every flag and every edge case, are in [Conventions, section 3.1](Conventions.md#31-commands-options-gates-and-the-order-of-an-apply) for what works now and [section 3.3](Conventions.md#33-automatic-runs-and-the-rest-of-the-command-line-specified-planned) for what is planned; if this page and Conventions ever disagree, Conventions wins.

## The idea in one paragraph

Naming a phase on its own only **previews** it: nothing changes. Adding `-r` **runs** it. Every run gets a short **run ID** (such as `7f3a`) that the keep and undo commands need. Labyrinth installs as `labyrinth`, with the short name `laby` (left out, with a note, if another command already has that name). **Planned** (stages 4b and later): a run asks no questions while it works, apart from one question at the very end: "can you still log in?" Anything risky that a person must decide goes into a **queue** to look at later, instead of stopping the run. Today a run asks its own questions as it goes, ending with the keep question.

The five phases, in the order they run: **Lock out** (take control back), **Harden** (shrink what can be attacked), **Observe** (see what happens), **Deceive** (plant traps) and **Sustain** (keep everything running). The phase words that work now are `lockout`, `observe`, `deceive` and `sustain`. **Planned** (with the Harden phase): `harden`, and `init`, which means Lock out and then Harden in one run.

## Where am I?

```
laby
```

Shows this host's status: its group and profile, the latest run of each phase (not run, kept, undone, or armed with the time its revert timer fires), any revert timer still counting down, and a `Next:` line with the one command to run next. It changes nothing. When in doubt, start here. **Planned** (with the queue): how many items wait in the queue.

## The first minutes

```
laby lockout
```

**Preview** the lockdown. Lists every change Labyrinth would make on this host. Nothing changes and nothing is written, so run it as often as you like.

```
laby -r lockout         short form
laby --run lockout      long form, the same
```

**Run** the lockdown. Labyrinth takes control of the host back: it changes passwords, removes unknown SSH keys, ends intruder sessions and closes the firewall to everything except scored services. `-r` can go before or after the phase: `laby lockout -r` is the same. It asks you to confirm as it goes (the break-glass account, the host's group) and ends with its keep question: open a second login window, check you can get in, make sure the new passwords are in the team's offline record, then type `keep`. Pressing Enter, or typing anything else, leaves the revert timer armed, and it undoes the firewall and SSH changes when it runs out, so a mistake cannot lock the team out. Changes that only take access away from an intruder, such as a new password, are kept as soon as they check out and are not undone by the timer.

**Planned** (the Harden phase): `laby init` previews and `laby -r init` runs the lockdown and the hardening behind it (the team's tools, backups, a sweep for footholds, patching) as one run. The run will end with a login check instead of today's keep question (issue #66):

```
Firewall and SSH changes are on a timer: undone at 14:32 UTC (in 5 min).
Open a NEW login to this host now and check that it works.
Are the new passwords recorded?
Keep the changes? [y/N]
```

## The later phases

```
laby observe            preview the Observe phase
laby -r observe         run it (long form: laby --run observe)
laby -r deceive         run the Deceive phase
laby -r sustain         run the Sustain phase
```

Each works like `lockout`: the phase word alone previews, `-r` runs. Run the phases in order; each one assumes the ones before it are done.

## Running some of a phase's modules

```
laby lockout --only lockout.firewall      preview just that module
laby -r lockout --skip lockout.ssh-config run every module but that one
```

`--only LIST` keeps just the modules you name; `--skip LIST` drops them. A LIST is module IDs of the phase, separated by commas. Use them to run again the one module whose settings you just fixed, without running the whole phase again. The gates, backups, revert timer and keep question are the same as for a full run, and the run says it is partial. If a module you kept needs one you left out, it is blocked and nothing changes; the message gives the command with the module put back. `lockout.inventory` is the one you may leave out of a run, and only when the host already has a dependency map from an earlier run. The two options cannot be used together.

## The queue: changes waiting for a person (Planned)

Planned (first usable release). Some changes are too risky to make on their own, such as deleting an account or changing a scored service that has no test. A run puts those in this host's queue and carries on.

```
laby -q                 short form
laby --queue            long form, the same
```

**List** the queue. Each item has a number that never changes, the module that wants it, and why. Nothing changes.

```
laby -q -a 1,3          short form
laby --queue --approve 1,3
```

**Approve** items 1 and 3: Labyrinth applies just those, in a new run with the same backups, timer and checks as any run. Ranges work too: `-a 1-4,7`, or `-a all` (which shows the count and asks first). Short letters can be joined: `laby -qa 1,3`.

```
laby -q -d 2            short form
laby --queue --decline 2
```

**Decline** item 2: it leaves the queue, recorded, and nothing changes.

## Fixing a mistake

```
laby -k 7f3a            short form
laby --keep 7f3a        long form, the same
```

**Keep** run `7f3a`'s changes when you missed the keep question (for example, the window closed) but have checked a new login works. It must be done before the timer fires; after that, the changes are already undone.

```
laby -u 7f3a            short form
laby --undo 7f3a        long form, the same
```

**Undo** run `7f3a`, newest change first. Changes that were kept early, such as new passwords, stay.

```
laby -u 7f3a --all
laby --undo 7f3a --all
```

Undo **everything** from that run, including new passwords and removed keys. It asks first (`[y/N]`), because it can hand an intruder their access back; add `-y` to answer yes without being asked, for example from a script. After it, change those passwords again and correct the offline record.

```
laby --history
```

List this host's runs with their IDs, to find the one to keep or undo. Every keep and undo needs an ID on purpose, so a run is never kept or undone by guesswork. The last four characters of the ID are enough.

```
laby --show 7f3a
```

List what that run changed: its phase, profile, host, group, start and end, and state, then each module with its status and every change it made, with the previous value and the backup where there is one. Use it to undo something by hand, to explain a change to a reviewer, or to see whether a run touched SSH. It changes nothing, and passwords never appear. The last line gives the run log, which holds everything the run printed.

## Checking the services

```
laby --probe
```

Test every scored service on this host once, the same way the runs do. It changes nothing, and exits with code `30` if a service fails. Useful after any change made by hand.

## The decoy seed

```
laby --new-seed
```

Make this host's decoy seed, once per host. It shows the seed once; post it in the team chat with the host's name, write it in the offline record, then type `recorded` and it is cleared from the screen. If the host already has one, it asks before replacing it (`-y` answers yes). The installer never makes a seed, because one made at install time would be copied along with the machine.

```
laby --seed-check
```

Type a seed at the prompt to check it for typos. It needs no root and reads no configuration, so it works on any machine with Labyrinth. A seed never goes on the command line itself: it would stay in the shell history.

## Help

```
laby -h                 the main help, one screen (also --help)
laby -h undo            help for one command or phase (also --help undo)
laby -V                 the version and the release's hash (also --version)
laby --manual           the full manual, one screen at a time (Linux also: man laby)
```

Adding `-h` to any command shows that command's help instead of running it: `laby -u 7f3a -h` shows the help for undo, and `laby -r lockout -h` changes nothing. So it is always safe to add `-h` to a command you are unsure of.

## Options that change how a command behaves

| Type | Long form | What it does |
|---|---|---|
| `-P NAME` | `--profile NAME` | Use this profile; it must match the host's line in the `hosts` file |
| `-v` | `--verbose` | **Planned** (first usable release). Show the full detail for every module, not one line each |
| `-y` | `--yes` | Answer yes to the question before `laby -u ID --all`, or before `--new-seed` replaces a seed. **Planned** (first usable release): also the queue's "are you sure?" questions. It never answers the login check |
| | `--no-revert` | With `-r`: no revert timer and no keep question; the changes stay until you undo them with `-u`. For test machines only |
| | `--only LIST` | Preview or run just these modules of the phase (module IDs, separated by commas) |
| | `--skip LIST` | Preview or run every module of the phase but these |

## A typical host, start to finish

Working now:

```
laby                     check where the host stands
laby lockout             preview the lockdown
laby -r lockout          run it; open a new login, check it, type keep
laby observe             preview the next phase
laby -r observe          then the later phases, in order
laby --history           find a run's ID
laby --show 7f3a         see what that run changed
laby --probe             re-check the scored services at any time
laby --new-seed          make this host's decoy seed, once
```

Planned (stages 4b and later):

```
laby init                preview the first minutes (Lock out, then Harden)
laby -r init             run them; open a new login, check it, answer y
laby -q                  look at what is waiting for a person
laby -q -a 2             approve what the team agreed to
```

## On Windows

The same commands work in PowerShell: `laby -r lockout`, `laby -k 7f3a`. The long forms also work in PowerShell's own style, such as `laby -Run lockout` or `laby -Undo 7f3a`, because long names ignore case and dashes. Type `/?` or `laby -h` for help; a bare `-?` is taken by PowerShell itself and shows a short page that points to `laby -h`.

## Not covered here

The commands for sealing the baseline, checkpoints, backups and restores, and remote mode (running from one control node across many hosts) are planned for later stages. Their names are decided when each is built, and they will be added to this page then.
