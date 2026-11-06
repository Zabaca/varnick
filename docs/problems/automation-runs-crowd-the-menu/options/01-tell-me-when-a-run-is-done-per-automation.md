---
problem: automation-runs-crowd-the-menu
title: "Tell me when a run is done", per automation, off by default
summary: Each automation gets a switch, "Tell me when a run is done", off by default and off for every automation saved before it. With it off, a run nobody has opened raises no Done notice when its turn ends, on the Mac or on the phone. A run that needs the user, stops on an error or sends a message still notifies as now, Run now always tells, and the global switches still apply on top.
status: accepted
---

Accepted by the user on 2026-11-06 (relayed by the coordinator), in this shape: a per-automation setting, off by default for scheduled runs, so a run that just finishes raises no Done notice, while a run that needs them, stops on an error or sends its own `notify` message notifies exactly as now, on the Mac and on the phone page. The details below were left to the plan and are recorded here.

## Solution

Each automation has a switch, **Tell me when a run is done**. Off, which is how every automation starts and how every automation saved before this change reads, a run whose tab nobody has opened raises no Done notice when its turn ends: no menu line, no dot, no sound and no push to the phone. Everything else a run tells the user is as it was: Needs you (a permission dialog, a question, a plan), Stopped on an error, and a Message it sends with `notify`.

On, a run raises Done as it does today.

The switch is decided when a run starts and kept for that run. A run that the user has opened (from the Runs tab, a notice or the phone) or taken over is an ordinary session from then on and raises Done like any other, whatever the switch says. **Run now** always raises Done, whatever the switch says: the user started it by hand and is waiting to see it end.

The global switch Settings › Notifications › "is done" still applies on top: with it off nothing raises Done, and an automation's switch can't bring it back. Each phone subscription's own "is done" switch applies on top in the same way.

The switch is in the automation editor (Settings › Automations, for this Mac and for a headless host), on the Phone page's automation form, and in the automation tools a Claude session has (`tell_when_done`, which `automations_list` reports).

## Trade-offs

- **A quiet run is found in the Runs tab, not the menu.** A run that finished without a message leaves no trace in the menu; the board's Runs tab and the phone's Runs list still show it, and its result is in its conversation. A run that should say something says it with `notify`, which is the better notice anyway (it carries a title).
- **Off for existing automations too.** The user's automations change behaviour at the first launch of this build without being edited. That is the user's wish (the hourly one quiet); one that should tell is switched on in its editor.
- **Fixed at the run's start.** Switching it on or off changes the next runs, not one already going, as taking a rule out of an automation's allowed tools does (ADR 0040's amendment of 2026-10-29). A Done that stands from before is cleared as any notice is.
- **No new switch in Settings › Notifications.** The global switches stay four; the new one belongs to the automation, so a typed session's Done is never affected.

## User Stories

1. As the user, I want an hourly automation's runs to finish without a Done notice, so that the menu holds only what needs me.
2. As the user, I want a run that waits on a dialog or a question to still tell me, so that it doesn't sit for 24 hours.
3. As the user, I want a run that stops on an error to still tell me, so that a broken automation is noticed.
4. As the user, I want a run's own `notify` message to still reach me on the Mac and on the phone, so that "X draft waiting" arrives as before.
5. As the user, I want to turn Done notices back on for one automation, so that a run I care about tells me when it ends.
6. As the user, I want Run now to tell me when it is done, so that trying an automation shows me its end.
7. As the user, I want a run I opened to behave like any session, so that a follow-up prompt I send in it raises Done when it ends.
8. As the user, I want my interactive sessions' Done notices unchanged, so that quieting runs costs me nothing elsewhere.
9. As the user, I want the phone to get no push for a quiet run's Done, so that my phone isn't buzzed every hour.
10. As the user, I want a Claude session that makes an automation for me to be able to set the switch, so that "tell me when each run is done" works when I ask for it.
11. As the user, I want to set the switch from the phone's automation form, so that it is one of the fields I can edit there.
12. As the user, I want an automation kept on a headless host to have the same switch, so that its runs are as quiet as this Mac's.

## Implementation Decisions

- **One optional field on the automation,** written only when on and read as off when absent, so every automation file saved before reads as off and an automation left at the default is written as it was. No version bump of the automations file: an older build drops the field on its next write, which reads as off again (the quiet side).
- **The run's record carries the decision:** an unopened run whose Done is quiet, set at the start from the automation's switch and whether it was Run now, and kept for the record's life. The notice rule reads it only while the run is unopened, so an opened run raises Done like any pane. A record without it (any pane, and every run started by an earlier build) is not quiet.
- **On the Mac, the notifier treats a quiet run as if its "is done" switch were off** for that pane alone, in all three places it decides (the turn's change, the settle and the tick). The table of `NoticeRule` is unchanged, so the phone's copy of it is too; the turn has still moved on, so a standing notice is cleared as the switch-off row does, and a standing Message folds the Done as now.
- **On the phone, the tab listing says it.** The run mark on a tab nobody opened (protocol 29) gains an optional field saying its Done is quiet. The host's page server reads it and treats the Done of such a tab as cleared, so no subscription is pushed one and a Message folded with it pushes no Done to a subscription without Messages. No protocol bump: the field is optional and the page server ships with the relay that writes it; an older host leaves it out, and its runs push Done as before.
- **A headless host's runs:** its run record and listing carry the same field, set at its own start of a run (Run now included), and the Mac's unseen view of a host run takes it from the mark when it adopts the run, so the Mac raises no Done for it either. A host on an older relay leaves it out: its runs raise Done as before, and its save drops the field from the automation (read as off).
- **The editor** has a switch row "Tell me when a run is done" after the working limit, saying that off a finished run raises no notice until it is opened, that Needs you, errors and messages still come, and that Run now always tells. Save carries it like the other fields, and a host's save merges it like them.
- **The session tools** take `tell_when_done` (a boolean) on create and edit, off when a create leaves it out, and `automations_list` reports it. A session may set it either way: it changes only what the user is told. An edit that changes it says so in the mark.
- **The Phone page's form** has a checkbox for it, sent with the other fields as the session tools take them (an edit sends it only when the box changed); the automation's own page says whether it is on.

## Testing Decisions

- The automation file round trip (absent reads off; on is written, off is not), the tools' reading, making and editing of the field with the mark's words, the host's save carrying it and treating it as an editor field, the phone row and the phone's field check, the run mark the listing chooses, and the rule for when a run's Done is quiet: `make check-slots` and `make check-voice`, test first.
- The tool schema's new property: `make check-mcp`.
- The page server's watcher pushing no Done for a quiet run's tab, still pushing its Needs you, error and message, and pushing Done for a tab without the field: `bun test` over the watcher on its fake clock. The phone form's draft and what an edit sends: `bun test` over its rules.
- The Mac's notifier, the editor and the headless host's start and listing are built and checked by hand after a restart (no test target reaches them).

## Out of Scope

- A per-automation switch for the other kinds (needs me, errors, messages): the user wants those as they are.
- Task Runs that no automation started, and their own notice: they are started by hand or by a session, and are not the menu's problem.
- Clearing or grouping the Done notices of runs that do tell (a "clear all" in the menu).
- A run ended at its limit still tells no one (ADR 0040, Consequences); unchanged.
