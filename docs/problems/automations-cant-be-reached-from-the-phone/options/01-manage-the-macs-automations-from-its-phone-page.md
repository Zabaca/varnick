---
problem: automations-cant-be-reached-from-the-phone
title: Manage a Mac's automations from its Phone page
summary: The Phone page of a Mac lists that Mac's automations and lets the user switch one on or off, run it now, make and edit one, and delete one after a confirm. The Mac stays the only writer and checks every change as it checks a session's. The phone never sets Skip permissions.
status: accepted
---

## Solution

The Phone page of a Mac gets an **Automations** button on its home, beside Outline, hidden on a headless host. It opens a list of that Mac's automations. Each row shows the name, the cadence in words, when it next runs, how its last run ended, whether it is on, and the mark a session or the phone left until the user has seen it.

Tapping a row opens it. There the user can switch it on or off, run it now, edit it, or delete it. Delete asks first, because it drops the run history. A **New automation** button opens the same form empty.

The form has a name, a prompt, a folder (Home or one of the projects the phone already lists), an optional agent of that folder, the cadence presets, the working limit and the permissions. The permissions are Varnick's setting, Ask, or Allowed tools only, with the allowed tool rules. The phone does not offer Skip. An automation the user set to Skip on the Mac can be switched and run from the phone and can't be edited there.

The Runs list on the home links each run to its automation.

## Trade-offs

- **A prompt typed on the phone becomes an unattended run on the Mac.** A device can already start a session with any prompt, so the new reach is the schedule, not the prompt. Without Skip on the phone, a lost phone can't mint a run that bypasses every prompt beyond what a device's `start` already allows.
- **A Mac's automations only.** A headless host keeps its own, edited from a Mac's Settings.
- **The phone's edit can overwrite a change made at the Mac meanwhile,** as a session's edit can; the marks and the Mac's own editor are as they are.
- **No protocol bump.** The new request is only ever sent by a host's own page server, which ships in the same app as the relay.

## User Stories

1. As the user, I want to see my automations on my phone, with when each runs next and how its last run ended, so that I know what is scheduled while I am away.
2. As the user, I want to switch an automation off from my phone, so that one that misbehaves stops without my going to the Mac.
3. As the user, I want to run an automation now from my phone, so that I can try it or get its result at once.
4. As the user, I want to make an automation from my phone, so that an idea for a recurring prompt is scheduled when I have it.
5. As the user, I want to edit an automation's prompt, cadence, folder, agent, limit and permissions, so that I can fix one away from the desk.
6. As the user, I want to delete an automation only after the phone asks, so that I don't lose its run history by a stray tap.
7. As the user, I want what the phone changed to show as a mark on the Mac, naming the device, so that I see it as I see a session's change.
8. As the user, I want the phone not to be able to set Skip permissions, so that a lost phone can't make a run that never asks.
9. As the user, I want to go from a run in Runs to its automation, so that I can switch off the one that made it.

## Implementation Decisions

- **One new relay request, `phoneAutomations`,** for a listed device only. A paired Mac and a headless host are refused. It carries a kind (list, switch, run now, save, delete) and the fields of a save in the names the session tools use.
- **The Mac's running Varnick answers on the main actor,** reading and writing through its automation store with the checks the session tools use (the same field validation, folders and agents read on the Mac, no Skip, no edit of a Skip automation), and refusing while either file can't be read.
- **The mark** records the device's name and that it was the phone. Run now and Delete leave none: they are the user's acts and leave their own trace (a run; no automation).
- **The page** adds one view, `#automations`, with the list, one automation, and the form. It checks nothing the Mac decides: it sends the fields and shows the Mac's problems.
- **No change to the headless host's requests or to the files' formats** beyond one optional word on a mark.

## Testing Decisions

- The device allow-list, the shaping of a row and the form's field rules are pure and checked by `make check-slots` and the page's `bun test`.
- A request into a live Mac, its mark and the page on a phone are not tested without the user's restart.

## Out of Scope

- Automations of a headless host from the phone.
- Setting Skip permissions from the phone.
- Opening a run's session from the automation view (Runs does that).
