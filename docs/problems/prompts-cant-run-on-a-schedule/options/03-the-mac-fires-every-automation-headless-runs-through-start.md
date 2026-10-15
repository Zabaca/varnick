---
problem: prompts-cant-run-on-a-schedule
title: The Mac fires every automation, and a headless run is the `start` a typed `^host` prompt already sends
summary: Only the running Varnick on the Mac that saved an automation fires it. Automations are kept on that Mac alone. A run on this Mac is option 01's hidden run tab. A run on the headless host is the existing `start` request, labelled for this Mac, exactly what typing `^host` and the prompt does today, into a run tab held out of sight on this Mac. Nothing changes on the headless host, there is no protocol bump, and there is no timer to install. The cost is the reason for choosing the always-on host: a headless run falls due only while this Mac is awake with Varnick running, so a run due at 3:00 with the lid shut runs when the Mac wakes. Once it has started, it keeps going on the headless host while the Mac sleeps. Not recommended as the whole answer. It fits as a first slice of option 01 for headless runs, if the user wants them before option 01's second step.
status: proposed
---

## Solution

- **Kept on the Mac that saved them.** Automations live in a file in Varnick's support folder on the Mac that saved them, edited in Settings › Automations as in option 01. A headless host keeps none. Another Mac doesn't see them and doesn't fire them.
- **Fired by the running Varnick alone:** a check once a minute, at launch and on wake, with option 01's due, missed and catch-up rules, cadence presets and overlap.
- **A run on this Mac** is option 01's run: a Claude pane in zmx, in a run tab kept out of the strip, the board's Sessions tab and Recent until opened from the board's Runs tab or a notice. It has option 01's notices, limits, ending and permissions.
- **A run on the headless host** is the `start` request with the automation's prompt, folder, agent and permission choice, labelled for this Mac. It is the request a typed `^host` prompt sends. This Mac attaches as it does for any session it starts there, in a run tab it keeps out of sight, so it follows the turn and raises the notices. The host's page server pushes to the phone by its existing routing, including after this Mac falls asleep and the session has no client.
- **To the headless host and the phone, a run is an ordinary tab.** Nothing marks it, so the phone's Home lists it among the host's tabs and other Macs see it in their session lists.

## Trade-offs

- **The smallest change that reaches the headless host.** No protocol bump, no installer flag, no timer and nothing new on Linux. The headless host's rule "nothing starts one unasked" stays true, since this Mac asks.
- **The always-on host isn't used as always-on.** A run due while this Mac sleeps, or while Varnick is quit, waits for the Mac. With the catch-up rule it then runs once. What the headless host adds is only that a run keeps going there once started, with its notices pushed to the phone.
- **One Mac's automations.** A user with two Macs has two lists, and an automation saved on one runs only while that one is awake.
- **Runs crowd the other screens.** The phone's Home and the other Macs' session lists show every headless run as a tab, since nothing in the protocol marks it. Adding the mark is the protocol bump this option avoids.
- **Everything built here carries into option 01.** The list, the editor, the check, run tabs and the Runs tab carry over. Moving the firing of headless runs to the host later replaces only the `start` call and the storage of those automations.

## User Stories

1. As the user, I want a headless automation to run there without my reinstalling the host, so that I can try automations on the always-on host now.
2. As the user with my Mac awake, I want a headless run to notify me on the Mac, and on my phone once I've left.

Option 01's stories apply too, except 2, which holds only while the Mac is awake.

## Implementation Decisions

- **The firing step** is option 01's Mac step. For a headless automation it calls the same start a typed `^host` prompt does, with a fresh session id and the automation's fields, and marks the tab it opens as a run here.
- **The permission choice** travels in the `start` request's existing skip-permissions field for Skip. Ask and Allowed tools only need the request to carry the mode and the allowed tools, which it can't today. So this option offers only Ask and Skip for headless runs, unless a protocol bump is accepted after all.
- **No change to the relay, the installer or the page server.**

## Testing Decisions

- **Option 01's slot check and its This Mac hand tests.**
- **Headless, Mac awake:** a run starts on the host and shows the Mac's notice when it's done.
- **Lid shut through a slot:** the run starts at wake, marked late.
- **Mac asleep mid-run:** with a long run started and the Mac then put to sleep, the phone gets the push when it ends.

## Out of Scope

Option 01's list, and the headless host's own firing, which is option 01's second step.

## Further Notes

- **The allowed tools and the Allowed tools only mode don't reach a headless run here.** The `start` request carries only skip-permissions. That limit is what keeps this option off the protocol.
- **Open questions:**
  1. Is a headless run that waits for the Mac to wake good enough to begin with? Recommendation: only as a stopgap. The user picked the headless host for runs that don't need the Mac.
  2. Should the headless host's runs be marked, so the phone and other Macs list them apart? Recommendation: if that bump is made, take option 01's second step in the same bump.
