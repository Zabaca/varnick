---
problem: prompts-cant-run-on-a-schedule
title: A run is a print-mode claude that never asks and ends by itself, and opening it resumes its conversation
summary: Option 01's automations, Settings, storage, firing, cadence, catch-up and overlap. The difference is that each run is `claude -p` with the prompt, in a zmx session of its own, not an interactive pane. A tool the automation doesn't allow is refused with no dialog, so a run never waits on the user. It ends by itself when Claude is done, and is held to a number of turns and a working limit. The pane folder's hooks still run, so Done, errors and Message come as for a pane. There is no Needs you: a run that needed a permission or an answer finishes with that said in its last words. While it runs, opening it shows its turn and a read-only view. Once it has ended, opening it resumes the conversation in a new tab, where the user can allow what was refused and carry on. Nothing has to end finished runs or keep them out of the strip, because a run has no tab until opened. Not recommended first: it gives up the Needs you the user named, and the watching of a run as a pane.
status: proposed
---

## Solution

**Everything but the run is option 01's:** the automation's fields, Settings › Automations, a file per host, protocol 29 for the headless host's list, firing by the running Varnick or the headless host's timer, presets with the zone, catch-up once within 12 hours, one run at a time.

**A run is print mode.**
- **What it runs:** the same login-shell command line as a pane, with these flags:
  - `--print` (`-p`), with the prompt;
  - `--permission-prompts none`, with `--permission-mode dontAsk` or, when the automation chose it, the skip flag;
  - the automation's allowed tools beside `notify`'s;
  - a turn limit.

  It runs in the automation's folder, as its agent, in a zmx session named for the run. So a Mac's run survives Varnick quitting, as panes do.
- **No dialog, ever.** A tool not allowed is refused, and Claude carries on or stops. The permission choice is two-way: Allowed tools only (the default), or Skip permission checks for that automation. "Ask" has no meaning without someone to ask.
- **It ends by itself.** The zmx session ends when claude prints its result. The working limit kills it sooner, with the conversation kept.
- **The pane folder and hooks are a pane's.** The hooks write the turn (working, then waiting at Stop), the stop file and the message file, as in any pane. So the readers and the notice table work unchanged:

  | A run… | notice |
  |---|---|
  | ends | Done |
  | ends on an API error | an error |
  | calls `notify` | a Message |
- **"Stuck" is said, not raised.** A run that hit a refusal or needed an answer ends with a Done. Its last words, which Claude writes, say what it couldn't do. The run list shows the number of refused tools from the transcript beside the outcome.

**Where a run shows.**
- **A run is not a tab until it is opened.** It is a record in the automation's history, with its conversation id, and a zmx session while it runs. The launch sweep spares the zmx sessions of running runs, which are named in the automations' file.
- **The board's Runs tab** lists the runs, as in option 01.
- **Opening a running run** shows its live turn and a read-only view of what it has written. A print-mode run has no terminal UI to attach to.
- **Opening an ended run** resumes its conversation in a new tab, interactively, under the automation's permission choice. The user can then allow what was refused and carry on.
- **The phone** lists runs under Runs. A push for a run lands on a page for that run, showing its outcome with an Open that resumes it on the host. A running run has no pane to land on, so this part is new to the page.

## Trade-offs

- **A run never waits on anyone.** It can't sit on a dialog for a day, needs no 24-hour end, and blocks its next slots only while it actually works.
- **It cleans up after itself.** No process outlives the run, no reaper is needed, and there are no hidden tabs to keep out of a dozen lists. That removes option 01's largest risk.
- **There is no Needs you.** The user's third decision named it. Here a run that needed a yes finishes with the work undone, and the user learns of it from the Done and the last words, then resumes and allows. For a nightly job that is a lost night.
- **It can't be watched or steered while it runs.** It can't be typed into or answered, and is visible only as a turn and text. That isn't the "open as a pane" of a pane in Claude's own terminal UI until it ends.
- **Print mode isn't the interactive session.** What differs is partly unverified:
  - whether `--agent` is honoured;
  - whether the Stop hook writes the turn as interactively;
  - how AskUserQuestion and ExitPlanMode behave.

  Some of the user's skills and hooks may act differently there.
- **The phone needs a run page.** A run with no pane has nothing for a push to land on, so the Phone page gains a view of its own.
- **Less to build on the Mac** (no hidden tabs, no ending of finished runs). More on the phone, and a check of print mode before anything relies on it.

## User Stories

1. As the user, I want an unattended run never to stop on a dialog, so that a nightly job always finishes by morning, done or not.
2. As the user, I want a run to end its own process, so that runs never pile up.
3. As the user, I want to open an ended run and carry on from it, allowing what it was refused.
4. As the user, I want the run's last words, and the tools it was refused, in the run list, so that I know without opening it whether it got stuck.

Option 01's stories 1–3, 6, 7 and 9–12 apply too.

## Implementation Decisions

- **The print-mode line** is a new shape of the shared command line. It has `--print` and the run's permission flags in place of the interactive flags, and the hooks' settings are the same as a pane's. It is shared by both hosts, as the pane's line is.
- **The run's pane folder** is made and cleared as a pane's start does it, so the readers find the turn, the stop file and the message there.
- **The refused tools** are counted from the transcript's tool results. The entry Claude Code writes for a refusal is undocumented and is checked first (below).
- **No run tab, no hidden-tab rule.** The run record is the history row, and opening an ended run is the Recent path's resume.

## Testing Decisions

- **A throwaway check first,** in a scratch folder, of `claude -p` started the way a run would be:
  - does `--agent` apply;
  - do the Stop and SessionStart hooks write as in a pane;
  - is a tool allowed nowhere refused, and what does the transcript say for it;
  - does a resumed print-mode conversation open interactively with its whole history;
  - what does AskUserQuestion do.

  If the hooks don't run, the notices need a reader of the run's result, and this option grows.
- **The slot check and the hand tests are option 01's,** less overlap with Needs you. Instead, a run that needs Bash it isn't allowed ends Done, with the refusal in the list.

## Out of Scope

Option 01's list, and:
- an Ask mode for print runs through a permission tool that relays to the user (`--permission-prompt-tool`), which would bring the dialog back as a notice. It is possible later, if a print run that waits ever proves needed.

## Further Notes

- **This option and option 01 share everything but the run,** so the choice between them is the user's open question: does a stuck run wait for you, or get refused and end?
- **Option 01's Allowed tools only** gives most of this option's never-waits inside a pane, by refusing with no dialog. It doesn't give the self-ending, which option 01 replaces with ending a finished run after 10 minutes.
- **Open questions:**
  1. Is losing Needs you acceptable for unattended runs? Recommendation: no. Take option 01, with Allowed tools only for the automations that must never wait.
  2. If this option is chosen, should a running run be viewable live on the phone? Recommendation: the turn and the last text only, since print mode has no screen.
