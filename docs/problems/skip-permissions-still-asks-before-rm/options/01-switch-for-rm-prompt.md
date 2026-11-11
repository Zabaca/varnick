---
problem: skip-permissions-still-asks-before-rm
title: A Settings switch that turns the delete prompt off, for sessions that skip permissions
summary: A new Settings switch, off by default, right after Skip permissions. When it and Skip permissions are both on, a Claude session Varnick starts here no longer asks before `rm` on a path Claude Code can't resolve or one that could be the home folder or the project's root.
status: accepted
---

## Solution

Accepted by the user, relayed by the coordinator on 2026-11-11.

A switch in Settings, under Skip permissions, off by default and never turned on by a migration. It does nothing while Skip permissions is off. Its text says plainly that it removes the last guard on deletes, including `rm -rf ~`.

When a session starts with Skip permissions and the switch is on, Varnick launches Claude Code with the documented environment variable that turns the prompt off. A session that doesn't skip permissions never gets it, whatever the switch says.

## Trade-offs

- **It removes the only prompt left before a destructive delete.** That is why it is a separate switch, off by default, rather than part of Skip permissions.
- **It applies to new sessions only.** A running session keeps the environment it started with.
- **Some settings keep the prompt on even with the switch** (a permission-request hook, a permission prompt tool, deny or ask rules on Bash, Edit or Read, a block on reads outside the working directory, claude run inside another claude). The switch can't override them.
- **Sessions on another Mac or a headless host** follow the setting only if it is carried across; see Implementation Decisions.

## User Stories

1. As a user who runs unattended sessions with Skip permissions, I want a cleanup like `cd out && rm -f h-wide/*` not to stall on a prompt, so that the session finishes without me.
2. As a user, I want the switch off until I turn it on, so that Skip permissions alone keeps the delete guard.
3. As a user, I want Settings to say what the switch removes, so that I turn it on knowing.

## Implementation Decisions

- The switch is stored like Skip permissions and is off for everyone until chosen.
- The variable goes in the launch environment only, never the settings Varnick passes to claude, because Claude Code ignores it there.
- Only a process that actually starts with Skip permissions gets it.
- Other Macs and headless hosts: kept local to the Mac that starts the session unless carrying it is a small change; the docs say which.

## Testing Decisions

No test target exists. Checked by building, then by hand after a restart: with both switches on, `mkdir somedir && touch somedir/a && rm -f somedir/*` runs with no prompt in a new session; with the new switch off it prompts.

## Out of Scope

- Changing what Skip permissions itself does.
- Removing the prompt for sessions that don't skip permissions.

## Further Notes

Claude Code's documentation lists the settings that keep the prompt on regardless; see the problem's evidence.
