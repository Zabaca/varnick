---
problem: sessions-cant-reach-each-other-reliably
title: Option 01, with Varnick's channel installed into Claude Code as a plugin from a marketplace Varnick keeps, in place of loading a plugin folder per pane
summary: As option 01, but the channel reaches each pane the way the 2026-11-07 test proved end to end. Varnick keeps a one-plugin directory marketplace in its support folder and installs `varnick` from it into the user's Claude Code once, at the user's level, from an Install row added to option 01's setup checklist, and panes start with `plugin:varnick@varnick` as their channel. The policy entry names that marketplace. The cost is a plugin in the user's Claude Code that every session loads, Varnick's or not (outside Varnick its server finds no pane and stays idle), and a copy in Claude Code's plugin cache that must be updated when Varnick changes it. Kept as option 01's fallback if Claude Code doesn't accept a plugin folder's channel.
status: proposed
---

## Solution

Everything in option 01 holds but how the channel reaches a pane.

**Installed once, from Varnick's own marketplace.** Varnick keeps a directory marketplace named `varnick` in its support folder, holding the one plugin `varnick` with the channel server. Varnick adds the marketplace and installs or updates the plugin with Claude Code's own plugin commands, at the user's level, off the main actor, from the setup checklist (below), and again at launch when Claude Code lists an older copy while the switch is on.

**The channel per pane.** Panes start with `plugin:varnick@varnick` as their channel, while the switch is on and the checklist passes, and no plugin folder.

**Setup: option 01's switch and checklist,** with one more row before the approval: **Varnick's plugin is installed**, with an **Install** button that says it adds a plugin to the user's Claude Code, loaded by every session, and runs the commands above. The approval row's policy file names `varnick@varnick` instead of `varnick@inline`; everything else in it holds (the drop-in file, Anthropic's list, the password dialog). Turning the switch off leaves the plugin installed and idle, so on again is instant.

**Outside Varnick.** The plugin is on in every Claude Code session of the user's, so its server starts in a plain terminal's session too. There it finds no pane id, lists nothing, pushes nothing and stays until the session ends; such a session isn't started with the channel, so Claude Code registers nothing.

**Removing it.** Under the checklist, a button that uninstalls the plugin and removes the marketplace, and the guide says to press it before removing Varnick.

## Trade-offs

- **The proven path.** A plugin installed from a local directory marketplace, approved by policy, was registered with no dialog and answered in about 7 s (the coordinator's test of 2026-11-07). Option 01's plugin folder is proven only up to the allowlist step.
- **A plugin in the user's Claude Code.** It shows in `/plugin`, every session starts its idle server (one more small process in each terminal session too), and it outlives Varnick unless removed.
- **A copy to keep current.** Claude Code runs an installed plugin from its cache copy, so a change to the plugin's server line needs an update command; the server itself is Varnick's binary through the link, so a new Varnick build needs none.
- **Writes Claude Code's plugin settings,** which option 01 never does (it changes only the tracking value, and only on Allow).
- **A policy that turns off plugins loaded from a folder** (Claude Code has such a setting, read in its code) would stop option 01 and not this one.

## User Stories

1. As the user, I want Varnick's channel to work the way it was already proven, so that turning it on doesn't depend on an untested path.
2. As the user, I want Varnick to install and update its plugin itself, so that I never run plugin commands.
3. As the user, I want a session in a plain terminal to be unaffected beyond an idle process, so that my other Claude work is as it was.
4. As the user, I want one button to remove the plugin, so that removing Varnick leaves nothing in Claude Code.

## Implementation Decisions

- **The marketplace** is a folder in Varnick's support folder with the marketplace manifest and the plugin, rewritten at launch when it differs; the server's command is the link's absolute path, and the pane id comes from the pane's environment, as in option 01.
- **Install and update** run Claude Code's own plugin commands through the account's login shell, as Varnick runs claude, from the checklist and at launch while the switch is on; their outcome, never their output, is logged.
- **The channel server without a pane id** answers `initialize` without the channel capability and lists nothing.
- **The install row** reads Claude Code's plugin list for the plugin, enabled, from that marketplace, and its version against the one Varnick keeps.

## Testing Decisions

- **The pure parts** (the marketplace's files, the policy reading with this entry) join option 01's check table.
- **By hand:** the switch's Install row installs the plugin and the checklist goes on to pass; a session in a plain terminal starts with the idle server and no channel line; the remove button leaves `/plugin` without it.

## Out of Scope

As option 01. Installing per project folder (local scope), which would write a settings file into every project and Home.

## Further Notes

- **Tested 2026-11-07 (the coordinator):** the install, the policy entry and the push; the cache copy.
- **Unverified:** that turning the plugin off in Claude Code's settings and on again per pane through `--settings` would keep it out of other sessions; not needed by this option.
- **Size, in agent time:** option 01's plus 45 minutes to 1 hour (the install row, updates, the remove button).
- **Combines with** options 01 (as its delivery) and 02.
