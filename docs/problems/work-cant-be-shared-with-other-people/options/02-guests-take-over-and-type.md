---
problem: work-cant-be-shared-with-other-people
title: Option 01, plus a per-share "Let them type" that lets the guest take over the tab and type, as a paired Mac does
summary: Built on option 01. When sharing a tab, the user can also tick Let them type, after a warning that anything typed into a Claude pane or a terminal runs on this Mac as the user. The guest then gets Take over on the shared tab's cards, types into its Claude and terminal panes through the page server's terminal channel, and uses its web and app panes with every method. Control is the tab's, as for any machine: the host's cards show "Controlled by Sam" with Take over. A guest never ends a session, never starts or splits one and never changes the layout; closing a pane or the tab hands it back. Stopping the share takes the tab back first. Not recommended for the first build; to be decided once option 01 is in use. Rough effort is about three days on top of option 01.
status: proposed
---

## Solution

**Asking for it.** The share sheet of option 01 gains Let them type, off by default. Ticking it shows, before Share:

"Sam will be able to take over this tab and type into its Claude sessions and terminals. Whatever Sam types runs on this Mac as you: Claude's tools and a terminal's commands, with your files, your keys and your logins. Skip permissions is on, so Claude runs them without asking." (The last sentence shows only while Skip permissions is on.)

It can be turned on or off later from the sharing bar. Turning it off while the guest is in control takes the tab back first.

**What the guest can then do.**
- **Take over** the shared tab from any of its cards, exactly as a paired Mac does: every Claude and terminal pane is relabelled for the guest, then their clients are detached.
- **Type** into its Claude and terminal panes. The guest's pane runs a small client that carries the terminal over the page server's terminal websocket, the one the phone types through, as a paired Mac's pane runs `ssh`.
- **Use its web and app panes** with every method, as a paired Mac does.

**What the guest still can't do.**
- **Change the tab.** No split, new pane, divider, rename, file pane or file tree. The layout is frozen while the guest holds the tab, for the host too, as it is today while any other machine holds it.
- **End anything.** ⌘W on a pane, or closing the tab, hands control back to this Mac, never ends a session or a terminal. Done isn't offered.
- **Start, resume or reopen** anything, or reach any other tab.

**The host's side.**
- **The cards.** While the guest is in control, the host's cards show "Controlled by Sam" with the live screen and Take over, as for another Mac.
- **The sharing bar** says "Sam is typing in this tab" while the guest holds it.
- **Stop sharing** with the guest in control first takes the tab back (relabel for this Mac, detach the guest's clients), then removes the share, so nothing the guest has open can type afterwards.

## Trade-offs

- **It is the remote share the user described.** Two people can work in one tab, handing control back and forth.
- **It hands over the account.** A terminal is a shell as the user. A Claude pane runs whatever the guest asks of it with the user's rights, and without asking under Skip permissions. Watching (option 01) exposes what is shown. Typing exposes everything the account can reach, from this Mac and onward: SSH keys, cloud logins, the Keychain items the account unlocks without a prompt. Only for someone the user would give the account to.
- **One tab, all or nothing.** Take over takes every Claude and terminal pane (ADR 0034). Someone who wants to share one session for typing and keep another opens a second tab.
- **Control left with a guest who went away.** A guest whose Mac sleeps keeps the label, as a phone does. The host's card shows it, and Take over is one click.
- **More than option 01 to get right.** The terminal channel, a client on the guest's side, the release rule and the take-back on Stop.

## User Stories

1. As the user, I want to let a colleague type in a shared tab, so that we can work in it together.
2. As the user, I want to be warned plainly that typing runs commands as me before I allow it.
3. As the user, I want to allow typing per share, and turn it off again, without stopping the share.
4. As the user, I want to see when the guest holds the tab, and take it back with one click.
5. As the user, I want Stop sharing to take the tab back before the guest loses access, so that nothing they have open can still type.
6. As the guest, I want to take over a shared tab and type in it as I would on my own Mac.
7. As the guest, I want closing a pane or the tab to hand it back, never to end the user's work.

## Implementation Decisions

- **The share carries a flag,** "may type", in option 01's shares file. Turning it off with the guest in control takes the tab back in the same step.
- **What the relay adds for a guest who may type:**
  - `take` for a shared tab;
  - `attach`, without take, for a pane session of a shared tab whose label names the guest;
  - `end` for a shared tab or one of its panes, always answered as a release, never as an end, whatever the origin says.
- **Still refused:** `start`, `resume`, `reopen`, `arrange`, `files`, `done` and every other op.
- **The page server's terminal channel** is admitted for such a guest, with the same per-guest caps. Its existing rule stands: an attach without take works only for a session labelled for the caller.
- **The guest's terminal client** is Varnick's own binary in a small mode that joins the websocket to the pane's input and output, run as the pane's command. No new dependency.
- **The control label names the guest's id,** so `controlName` gives the guest's name, from the shares file, wherever a controller is named.
- **The port proxy** admits every method for a guest who may type, as for a paired Mac.
- **The launch sweep** spares a session labelled for a guest of a live share, as it spares one labelled for a listed peer or device.

## Testing Decisions

- **The relay's rules, with tests:**
  - a guest who may type gets `take` and `attach` on the shared tab, and nothing on another;
  - `end` from a guest releases and never kills;
  - `start`, `arrange` and `reopen` stay refused;
  - turning the flag off refuses the next `attach`.
- **`bun test`:** the terminal channel admits a guest who may type and refuses one who may not.
- **By hand, on option 01's test tailnets:**
  - the guest takes over, types in a terminal and a Claude pane, and closes a pane, which hands it back;
  - the host takes over in the middle of the guest's typing;
  - Stop sharing while the guest types, and check that their client is gone before the share is;
  - with the flag off, the guest has no Take over and their old client can't attach.

## Out of Scope

- Typing into only some panes of a shared tab.
- Splits or new sessions by a guest.
- Ending sessions by a guest.
- An approval prompt on the host for each take-over.

## Further Notes

- **Why not first.** Option 01 is useful alone (showing work), its blast radius is what is on screen, and it proves the hard parts (Tailscale identity, the guest interface, the scoped relay) before any keystroke crosses. This option is a small step on top of it, and is the user's call once option 01 has been used with a real guest.
- A per-take-over approval on the host was considered and left out: the user already chose this person and this tab, and a prompt on every hand-back would be noise. It can be added if the flag alone proves too coarse.
