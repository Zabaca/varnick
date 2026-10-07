---
problem: closed-lid-pauses-sessions
title: Hold a system-sleep assertion while on AC
summary: A Stay awake on AC setting, off by default. While it is on, the Mac is on AC and isn't running hot, Launchy holds one PreventSystemSleep power assertion, the one `caffeinate -s` takes, and otherwise holds none. The menu bar item toggles the setting and says why nothing is held, and the icon shows when something is. The assertion dies with Launchy's process, so a quit or crash can't leave the Mac awake. No root and no helper. It solves the problem only if PreventSystemSleep keeps a closed Mac awake with no external display, which the user is testing.
status: proposed
---

## Solution

Launchy gets a **Stay awake on AC** setting, off by default and saved across launches. A small main-actor object, shaped like Listener, owns at most one IOKit power assertion of type PreventSystemSleep, the type `caffeinate -s` takes. It holds the assertion exactly when three things are true:

- the setting is on;
- the Mac is on AC power;
- the thermal state is nominal or fair.

It decides again whenever one of the three changes, and releases the assertion as soon as any of them stops being true.

The status menu gets a "Stay Awake on AC" item with a checkmark. While the setting is on but nothing is held, the item says why: on battery, running hot, or an error. While the assertion is held, the menu bar icon becomes a cup, so the user can see before closing the lid that it's safe to.

Nothing happens at quit. The assertion belongs to Launchy's process, and powerd drops it when the process ends, whether by Quit, a crash, `make run` or `launchctl kickstart -k`. The next launch takes it again if the conditions hold.

## Trade-offs

- **No root, no install step, nothing system-wide.** Any process may take an assertion (IOPMLib.h), and nothing outlives Launchy.
- **Fails safe.** A dead or quit Launchy holds nothing, so the Mac sleeps on lid close as it does today.
- **Rests on an assertion Apple calls unsupported.** The SDK marks PreventSystemSleep deprecated since 10.9 and "not supported", yet `caffeinate -s` still takes it and `pmset -g assertions` still lists it. Whether it keeps a closed Mac awake with no external display is what the user's test settles. If it doesn't, this option doesn't solve the problem. A later macOS could stop honouring it with no error, and the only symptom would be a Mac that sleeps.
- **Follows Launchy, not the sessions.** With Keep sessions running, zmx sessions outlive a quit but the assertion doesn't. A closed lid then sleeps the Mac and they pause until it wakes.
- **A restart leaves a gap.** A closed Mac can sleep between the old instance exiting and the new one taking the assertion: up to about ten seconds under `make run`'s restart, less under `kickstart`. Sessions pause, they don't end.
- **Heat is guarded, not prevented.** The thermal guard lets go at serious, before critical, and the setting's detail line warns against a bag. A Mac plugged in inside a bag that stays below serious stays awake.
- **Other sleep still works** (inferred: assertions are requests powerd weighs, and the user's own sleep wins). Apple menu › Sleep, the power button and low battery still sleep the Mac.

## User Stories

1. As a Launchy user with my MacBook plugged in at my desk, I want to close the lid and have my sessions keep working, so that long tasks finish while the laptop is shut.
2. As a Launchy user, I want the Mac to sleep as usual when I unplug it and close the lid, so that it doesn't drain the battery or cook in my bag.
3. As a Launchy user, I want to see in the menu bar whether a closed lid will keep the Mac awake right now, so that I know before I close it.
4. As a Launchy user, I want the menu to say why it isn't keeping the Mac awake (on battery, running hot, an error), so that I can plug in or fix it.
5. As a Launchy user, I want to turn it on and off from the menu bar as well as from Settings, so that I don't have to open the panel.
6. As a Launchy user, I want the setting to stay on across restarts, so that I set it once.
7. As a Launchy user, I want a quit or crash of Launchy to let the Mac sleep again, so that Launchy never leaves the Mac awake by accident.
8. As a Launchy user on a fanless Air, I want Launchy to let the Mac sleep when it runs hot with the lid closed, so that it doesn't overheat.
9. As a user on another Mac driving sessions on the Air through its peer link, I want the Air to stay reachable with its lid closed on AC, so that those sessions keep going.

## Implementation Decisions

**The assertion**
- The type is PreventSystemSleep, given by its string name, which `pmset -g assertions` shows. It is created with IOPMAssertionCreateWithName at level on, under a name that shows it is Launchy's ("Launchy: stay awake on AC").
- At most one assertion is held at a time. Taking one when one is held, or releasing when none is, does nothing.
- PreventUserIdleSystemSleep is no use here. IOPMLib.h says it doesn't cover lid close, and claude already holds it while a session works.

**When it is held**
- It is held exactly when the setting is on, the power source is AC, and the thermal state is nominal or fair. In every other case it is released. Every change decides again from all three inputs, so there is no other state to keep in step.
- Launchy checks for AC itself instead of leaving powerd to ignore the assertion on battery. The menu has to say whether the Mac is on AC anyway, and this way the battery behaviour doesn't rest on caffeinate's 2012 man page.
- AC is the providing power source type in IOKit's power source snapshot. Launchy reads it at start and again when the `com.apple.system.powersources.source` notification fires, registered through notify on the main queue. That notification is posted only when the source switches between AC and battery, not when the charge level changes.
- Thermal is ProcessInfo's thermal state and its change notification. The assertion is released at serious or critical and taken again at fair or nominal. On a fanless Air, serious is where it is throttling (inferred).
- A failed create is shown with its return code and tried again on the next change, never in a loop.
- Each change of state is logged with NSLog ("Launchy: stay awake: …"), so the LaunchAgent log shows when and why it was taken or released.

**The object**
- It is one shared main-actor object with a published state, shaped like Listener. The states are off (setting off), holding, on battery, running hot, and failed with a reason. Small extensions on the state supply the menu title note and the tooltip, as `Listener.State` supplies `note` and `detail`.
- It is started only from the app's launch, after Settings is read. The command-line modes never take the assertion: the peer relay, sync, search, rerank eval and search eval. Reading the setting never starts the object either, since `--search` and `--search-eval` build the model without the app launch and a relay must never keep the Mac awake.

**The setting**
- "Stay awake on AC" goes in Settings › Claude, after Keep sessions running, off by default. It is a UserDefaults boolean read with a default in init, like Keep sessions running.
- Detail line: "Keeps the Mac awake with the lid closed while it's plugged in, so sessions keep running. Sleeps as usual on battery or when it runs hot. Keep it out of a bag: a closed Mac cools poorly."
- While the setting is on but nothing is held, the row shows why beside the toggle: secondary text for on battery, orange for running hot or failed. This follows how semantic search shows its state.
- The setting is saved across launches. Listening is off at each launch because it uses the microphone; this setting is a standing preference for unattended work.
- The Settings panel has a fixed height and scrolls, so the row changes no panel height.

**The menu bar**
- A "Stay Awake on AC" item goes in the status menu, in its own group after the listening items. It carries a checkmark while the setting is on, the way Pin Launchy shows its state, and a click flips the setting.
- While the setting is on but nothing is held, the title adds the reason in parentheses, as the listening item does: "(on battery)", "(running hot)", "(failed: …)". The tooltip carries the longer detail.
- The status icon is `cup.and.saucer.fill` while the assertion is held. Listening's waveform wins when both apply, since the microphone being on matters more to see. One function picks the icon from both states, replacing the listening-only one.

**Exit and restart**
- Nothing is done at quit. powerd drops a process's assertions when it exits, so every way Launchy stops releases it. This is inferred from caffeinate's documented behaviour and checked by hand below.
- At launch the object starts from the saved setting and takes the assertion if the conditions hold.
- Restarts aren't bridged (see Trade-offs).

## Testing Decisions

There is no test target. These checks are by hand, after the user restarts Launchy.

- **Gate, before building.** With no external display and on AC, run `caffeinate -s` in a terminal. Close the lid for ten minutes with something observable running: a loop appending the time to a file every ten seconds, or a ping from a paired Mac. Open it and look for gaps, and for Sleep entries in `pmset -g log`. Then repeat on battery, where the Mac should sleep. Also confirm that `pmset -g assertions` lists caffeinate's assertion under PreventSystemSleep. If the Mac sleeps on AC, stop: this option doesn't solve the problem.
- `make build` passes.
- **Setting off:** `pmset -g assertions` lists nothing of Launchy's, the menu item is unchecked, and the icon is the magnifying glass.
- **On, on AC:** a PreventSystemSleep assertion named as Launchy's, owned by Launchy's pid. The item is checked with no note, and the icon is the cup.
- **Unplug:** within a couple of seconds the assertion is gone, the item notes "(on battery)", the Settings row says so, and the icon goes back. Plug in again and it returns.
- **Lid closed:** on AC for ten minutes, the timestamp loop running in a Launchy terminal pane shows no gaps. On battery, the Mac sleeps.
- **Exit:** after Quit from the menu, and separately after `kill -9` of Launchy's pid, the assertion is gone. Relaunched with the setting on, it comes back.
- **Command-line modes:** `Launchy --search` run with the setting on takes no assertion.
- **Icon priority:** with listening on and the assertion held, the waveform shows. With listening off, the cup shows.
- **Running hot:** optional. Load every core on the Air until the thermal log line appears. Otherwise, read the log line the next time it happens.

## Out of Scope

- Keeping the Mac awake while Launchy isn't running, such as zmx sessions after a quit.
- Bridging a restart, for example the restart script holding `caffeinate -s` for a few seconds.
- A `!` launcher command for the setting.
- Idle sleep with the lid open, which claude's own assertion and the AC sleep setting already cover. Display sleep.
- Telling paired Macs whether this one is staying awake.
- A time limit on staying awake.

## Further Notes

- If the gate fails, there is one cheap thing to try before option 02. IOPMLib.h names NetworkClientActive as PreventSystemSleep's successor and says it "keeps the system awake in dark or full wake, as long as the system is on AC power". It also says assertions may not be honoured "under battery, thermal, or user circumstances", and lid close may count as one of those. caffeinate has no flag for it, so testing it needs a few lines of throwaway code.
- Once accepted, **Stay awake** belongs in CONTEXT.md's Workspace terms.
