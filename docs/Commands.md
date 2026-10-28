# The `laby` Command (Planned)

This page shows the commands a person types to run Labyrinth once the new command line is built, with what each one does and when to use it. It is written for teammates learning the tool, not for the people building it.

> [!NOTE]
> **Planned, not built yet.** These commands arrive in Roadmap stage 4b. Until then the runner takes the older words (`plan`, `apply`, `keep`, `rollback`, `runs`), which the [operator manual](https://github.com/dotnetdork/Labyrinth/blob/main/docs/manual/labyrinth.md) describes, and those old words keep working afterward too. The exact rules, including every flag and every edge case, are in [Conventions, section 3.3](Conventions.md#33-the-new-command-line-and-automatic-runs-specified-planned); if this page and that section ever disagree, the Conventions section wins.

## The idea in one paragraph

Labyrinth installs as `labyrinth`, with the short name `laby`; both work the same. Naming a phase on its own only **previews** it: nothing changes. Adding `-r` **runs** it. A run asks no questions while it works, apart from one question at the very end: "can you still log in?" Anything risky that a person must decide goes into a **queue** to look at later, instead of stopping the run. Every run gets a short **run ID** (such as `7f3a`) that the keep and undo commands need.

The five phases, in the order they run: **Lock out** (take control back), **Harden** (shrink what can be attacked), **Observe** (see what happens), **Deceive** (plant traps) and **Sustain** (keep everything running). On the command line the phase words are `init`, `harden`, `observe`, `deceive` and `sustain`, where `init` means Lock out and then Harden in one run.

## Where am I?

```
laby
```

Shows this host's status: its group and profile, which phases have been run or kept, any revert timer still counting down, how many items wait in the queue, and a `Next:` line with the one command to run next. It changes nothing. When in doubt, start here.

## The first minutes

```
laby init
```

**Preview** the first minutes: the lockdown and the hardening behind it. Lists every change Labyrinth would make on this host. Nothing changes and nothing is written, so run it as often as you like.

```
laby -r init
```

**Run** the first minutes. Labyrinth locks the host down (changes passwords, removes unknown SSH keys, ends intruder sessions, closes the firewall to everything except scored services), then hardens it behind the lockdown (installs the team's tools, takes backups, sweeps for footholds, patches). `-r` can go before or after the phase: `laby init -r` is the same.

It ends with the login check:

```
Firewall and SSH changes are on a timer: undone at 14:32 UTC (in 5 min).
Open a NEW login to this host now and check that it works.
Are the new passwords recorded?
Keep the changes? [y/N]
```

Open a second login window, check you can get in, make sure the new passwords are in the team's offline record, then answer `y`. Answering `n`, or not answering before the timer runs out, undoes the firewall and SSH changes, so a mistake cannot lock the team out. Changes that only take access away from an intruder, such as a new password, are kept as soon as they check out and are not undone by the timer.

## The later phases

```
laby observe            preview the Observe phase
laby -r observe         run it
laby -r deceive         run the Deceive phase
laby -r sustain         run the Sustain phase
```

Each works like `init`: the phase word alone previews, `-r` runs. Run the phases in order; each one assumes the ones before it are done.

## The queue: changes waiting for a person

Some changes are too risky to make on their own, such as deleting an account or changing a scored service that has no test. A run puts those in this host's queue and carries on.

```
laby -q
```

**List** the queue. Each item has a number that never changes, the module that wants it, and why. Nothing changes.

```
laby -q -a 1,3
```

**Approve** items 1 and 3: Labyrinth applies just those, in a new run with the same backups, timer and checks as any run. Ranges work too: `-a 1-4,7`, or `-a all` (which shows the count and asks first). Short letters can be joined: `laby -qa 1,3`.

```
laby -q -d 2
```

**Decline** item 2: it leaves the queue, recorded, and nothing changes.

## Fixing a mistake

```
laby -k 7f3a
```

**Keep** run `7f3a`'s firewall and SSH changes when you missed the login question (for example, the window closed) but have checked a new login works. It must be done before the timer fires; after that, the changes are already undone.

```
laby -u 7f3a
```

**Undo** run `7f3a`, newest change first. Changes that were kept early, such as new passwords, stay.

```
laby -u 7f3a --all
```

Undo **everything** from that run, including new passwords and removed keys. It asks first, because it can hand an intruder their access back. After it, change those passwords again and correct the offline record.

```
laby --history
```

List this host's runs with their IDs, to find the one to keep or undo. Every keep and undo needs an ID on purpose, so a run is never kept or undone by guesswork. The last four characters of the ID are enough.

## Checking the services

```
laby --probe
```

Test every scored service on this host once, the same way the runs do. It changes nothing, and exits with code `30` if a service fails. Useful after any change made by hand.

## Help

```
laby -h                 the main help, one screen
laby -u -h              help for one action: add -h to what you would type
laby -h observe         help for a phase
laby --manual           the full manual, scrollable (Linux also: man laby)
laby -V                 the version and the release's hash
```

Help never runs anything. Even `laby -r init -h` only shows help, so it is always safe to add `-h` to a command you are unsure of.

## Options that change how a command behaves

| Type | Long form | What it does |
|---|---|---|
| `-v` | `--verbose` | Show the full detail for every module, not one line each |
| `-y` | `--yes` | Answer yes to "are you sure?" questions. It never answers the login check |
| `-P NAME` | `--profile NAME` | Use this profile; it must match the host's line in the `hosts` file |
| | `--no-revert` | No revert timer and no login check. For test machines only |

## A typical host, start to finish

```
laby                     check where the host stands
laby init                preview the first minutes
laby -r init             run them; open a new login, check it, answer y
laby -q                  look at what is waiting for a person
laby -q -a 2             approve what the team agreed to
laby -r observe          then the later phases, in order
laby --probe             re-check the scored services at any time
```

## On Windows

The same commands work in PowerShell: `laby -r init`, `laby -q -a 1,3`. The long forms also work in PowerShell's own style, such as `laby -Run init` or `laby -NoRevert`, because long names ignore case and dashes. Type `/?` or `laby -h` for help; a bare `-?` is taken by PowerShell itself and shows a short page that points to `laby -h`.

## Not covered here

The commands for sealing the baseline, checkpoints, backups and restores, and remote mode (running from one control node across many hosts) are planned for later stages. Their names are decided when each is built, and they will be added to this page then.
