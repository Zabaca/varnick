---
title: Automations can't be reached from the phone
description: The user's automations (prompts a Mac starts on a cadence) can be listed, made, edited, switched, run and deleted only in Varnick's Settings on the Mac, or by a Claude session there. The Phone page shows only the runs nobody has opened. Away from the Mac, the user can't see what is scheduled, turn one off, run one now or write a new one.
impact: A scheduled prompt that misbehaves away from the desk keeps firing until the user is back at the Mac, and an idea for a recurring prompt waits there too. The phone can already start sessions, read the Outline and use Voice mode, so Automations is the gap in what the phone can manage.
severity: low
evidence: The user's request of 2026-10-29, relayed by the coordinator ("from the phone I don't have access to automations. Can we add."). Code and docs read at 5c98857 (main).
status: open
---

## What the user wants

**Automations** (`CONTEXT.md` › Automation) in the phone app, the **Phone page** (`CONTEXT.md` › Phone page): the same list and the same changes as Settings › Automations has.

## Today

- **Automations are a Mac's own.** The list and the runs are two files in that Mac's support folder (ADR 0040, 0041). The only editors are the Settings page, the four tools a Claude session on that Mac has (ADR 0040's amendments), and, for a headless host, the same page with a request to that host.
- **The relay refuses a device.** The five automation requests (protocol 29) are for a listed Mac only, and only a headless host answers them; a Mac's app answers that it keeps its own. The Phone page's server asks the relay as a device, so it can't reach them.
- **The Phone page shows the runs, not the automations.** Home lists the runs nobody has opened under Runs, each opened like any tab. It shows nothing of the automation behind one.
- **A device can already start a session with any prompt,** in any project the Mac lists (`start`, ADR 0011), so a prompt typed on the phone already runs unattended on the Mac with whatever permissions the Mac's Skip permissions gives it.
