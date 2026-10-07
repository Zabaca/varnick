---
problem: closed-lid-pauses-sessions
title: Disable sleep through a root helper that watches AC
summary: A small helper runs as root under launchd, installed once with sudo by a make target, and is the only thing that sets `pmset disablesleep`. It turns sleep off only while Launchy holds a connection to it, the Mac is on AC and isn't running hot. It turns it back on in every other case, at its own start, and when Launchy's connection closes. Launchy's setting, menu item and icon work as in option 01. The lid-close behaviour doesn't depend on PreventSystemSleep. The cost is root code, an install step, and a system-wide flag that stays set if the helper is removed carelessly.
status: proposed
---

## Solution

`pmset -a disablesleep 1` sets the system's SleepDisabled flag, which `ioreg` shows beside AppleClamshellCausesSleep. While it is set the Mac doesn't sleep, lid closed or not (inferred from how closed-lid tools use it; the spike below checks). Setting it needs root.

**The helper** is a separate small executable, the only Launchy code that runs as root, run by a system LaunchDaemon that starts at load and is kept alive.

- **Install.** A make target run with sudo copies it into a root-owned system folder. The daemon never runs a binary from the build folder: a root daemon running a file the user can overwrite hands root to anything running as the user.
- **Socket.** It listens on a Unix socket and accepts only the installing user's uid, checked from the peer's credentials.
- **The rule.** SleepDisabled is on exactly when a client connection is open, the power source is AC, and the thermal state is nominal or fair. In every other case it is off. The helper watches the power source notification and the thermal state itself, so a Launchy that hangs can't keep sleep disabled on battery.
- **Reset.** On its own start it sets SleepDisabled off before anything else, which covers a crash or reboot with it on.
- **Reporting.** It sends its state to the client on each change, one short line each: holding, on battery, running hot, or failed with the reason.
- **Mechanism.** It runs `pmset`, the documented command, rather than private IOKit calls.

**Launchy** keeps option 01's setting, menu item, icon, states and logging, with two changes:

- "Holding" means the helper reports sleep disabled.
- "Helper not installed" is one more state, shown in the Settings row and the menu note together with the make command that installs it.

While the setting is on, Launchy keeps one connection to the helper open. Closing it is the off signal, and turning the setting off, quitting, crashing and being killed all close it. If the helper restarts, Launchy reconnects after a short backoff. Launchy takes no assertion of its own.

A matching uninstall target sets SleepDisabled off, then removes the daemon and the helper.

## Trade-offs

- **Lid close is covered without PreventSystemSleep.** This doesn't depend on an assertion Apple calls unsupported.
- **Root code and an install step.** sudo is needed once, and again whenever the helper changes. This adds a daemon running as root (small, but it needs review as such), a second executable target, and two make targets.
- **Fails open if the helper is gone.** While the helper runs, a dead Launchy turns sleep back on as safely as option 01 does. A helper removed by hand while the flag is on leaves it on, and pmset settings persist across reboots (inferred). That is the worst failure here: a Mac that never sleeps, on battery and in a bag. The helper's start and the uninstall target both reset the flag. A removal by hand doesn't.
- **System-wide and blunt.** While on, SleepDisabled stops every sleep, including Apple menu › Sleep (inferred). Other tools that set it, such as a closed-lid helper from another app or the user's own pmset, fight with the helper, which overwrites them at start and on each change.
- **More to verify.** Socket permissions, the helper's restarts and Launchy's reconnects all need checking.
- **Same UI as option 01.**

## User Stories

Option 01's stories 1 to 9, plus:

10. As a Launchy user, I want one command to install the helper and one to remove it, with my Mac's sleep back as it was after removal, so that trying it costs nothing permanent.
11. As a Launchy user without the helper installed, I want the setting to tell me how to install it, so that turning it on isn't a silent no-op.
12. As a Launchy user, I want only my own account to be able to keep the Mac awake through the helper, so that other users or processes can't.

## Implementation Decisions

**Why not the alternatives**

- **SMAppService.** It registers a daemon shipped inside an app bundle and needs approval in Login Items. Launchy is a bare executable started from its build folder, with its Info.plist linked into the binary. Bundling it is a separate change, and moving the microphone and system audio grants to a new code identity may prompt again (inferred). A sudo make target matches how `make install` already installs the LaunchAgent.
- **A sudoers rule letting Launchy run pmset itself.** It is cheaper, with no daemon, but then Launchy would set the flag itself. A crash or quit would leave it on, with nothing to turn it off until Launchy next starts, so it fails open in the common case.
- **The clamshell selector IOPMLibDefs.h declares (`kPMSetClamshellSleepState`).** It is undocumented, the privilege it needs is unknown, and it would still need a root helper if it needs root.
- **Clamshell mode with a display-emulator dongle.** It needs no code, but it needs the dongle, and the GPU drives a display nobody sees, which adds heat to a closed fanless Mac.

**Protocol**
- An open connection means "want". The helper's lines carry its state and nothing else. The helper never reads Launchy's UserDefaults or files.

**Thermal and AC**
- The rule and thresholds are the same as option 01's, but evaluated in the helper.

## Testing Decisions

There is no test target. These checks are by hand.

- **Spike, before building.** With no external display and on AC, run `sudo pmset -a disablesleep 1`. Close the lid for ten minutes with a timestamp loop running and confirm there are no gaps, and that `ioreg -r -k AppleClamshellState -d 1` showed `SleepDisabled = Yes`. Run `sudo pmset -a disablesleep 0` and confirm it reads No. Check whether the flag survives a reboot, which decides how much the reset at start matters.
- `make build` passes. After installing the helper, `sudo launchctl print system/<label>` shows it running.
- **Option 01's UI checks,** reading `SleepDisabled` from `ioreg` in place of `pmset -g assertions`.
- **`kill -9` Launchy:** SleepDisabled goes to No.
- **`kill -9` the helper:** launchd restarts it, the flag reads No, Launchy reconnects, and the flag reads Yes again on AC.
- **Uninstall:** the flag reads No and the daemon is gone.
- **Socket permissions:** a connection from another uid is refused, if a second account is at hand. Otherwise check the socket's owner and mode.

## Out of Scope

- Option 01's out-of-scope list.
- Making Launchy an app bundle.

## Further Notes

- This option replaces option 01 rather than adding to it. Pick it only if option 01's gate fails.
