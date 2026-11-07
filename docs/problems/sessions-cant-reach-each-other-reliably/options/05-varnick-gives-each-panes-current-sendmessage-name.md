---
problem: sessions-cant-reach-each-other-reliably
title: No channel. Varnick lists each pane's current `SendMessage` name, so a session turns a pane id into an address at the moment it sends, and Claude Code delivers
summary: Instead of a channel, `board_read` and `panel` give, beside each Claude session on this Mac, the name `SendMessage` takes right now, read at each read from Claude Code's own file for the conversation the pane holds, as `tab_open` reads it today. A session opened with `tab_open` finds its opener on the board, marked as the session that opened it, instead of looking an id up with `claude agents --json`. Claude Code's `SendMessage` keeps doing the delivery, with its own rules and its idle notice. Nothing to approve, no admin password, no experimental feature, no new process, and it works for every Varnick user at once. It stays on one Mac, and a name can still change between the read and the send.
status: proposed
---

## Solution

**Names on the board.** `board_read` lists each Claude session on this Mac with its current `SendMessage` name after its id and title ("s7 … · send to kestrel-4e", made up), read at that read from Claude Code's file for the conversation the pane holds now, never cached. `panel` does the same for the panes of the caller's tab. A session another Mac hosts gets none: `SendMessage` can't reach it. A session whose file can't be read gets none, and the line says so.

**The opener, marked.** In a session opened with `tab_open`, `board_read` marks the session that opened it: "opened this session". The note saved with the pane gains the opener's pane id to find it, kept as the note is kept.

**`tab_open`'s paragraph** keeps the opener's name at the open and tells the session, when a send fails, to read the board and send to the name on the line marked as its opener, in place of `claude agents --json`. If no line is marked, the opener isn't running here: say so in its own reply, as today.

**Delivery is Claude Code's,** as today: the receiver answers the message's `from`, `notify_when_idle` gives one notice when it is done, and Claude Code's own rules for messages between sessions apply.

## Trade-offs

- **Nothing to approve or install.** No policy file, no admin password, no hidden flags, no reliance on Anthropic's switch for channels, no extra process. It works for every Varnick user as soon as they restart their panes.
- **One Mac only.** `SendMessage` reaches sessions on the same Mac; paired Macs' sessions stay out of reach.
- **Names still change.** A name read now is wrong after the receiver restarts; the sender reads again when a send fails, and a send that names a session that merely looks alike is still possible if the session takes a suggestion (the paragraph and the guide say never to).
- **The undocumented file grows in weight.** Every board read now reads Claude Code's per-session files, which Claude Code doesn't document; a change there blanks the names and nothing else.
- **Claude Code's rules, not Varnick's.** A receiver in a different permission mode holds a message for the user's approval (Claude Code's description, not tried here), which is stricter than option 01's skip rule; Varnick can't add a rule of its own or a rate cap.
- **The idle notice is kept,** which option 01 doesn't offer.
- **What reaches Anthropic** grows by every listed session's name, with the board's titles.

## User Stories

1. As a lead session, I want the board to give me the name to send to for a pane id I hold, so that I can reach a helper I opened without guessing.
2. As a session opened with `tab_open`, I want the board to show me which session opened me and its current name, so that I can reach it after it restarts without reading a list of every session.
3. As the user, I want this to work without an admin password or a plugin, so that nothing on my Mac changes but Varnick.
4. As a sender, I want `notify_when_idle` to keep working, so that I learn when a helper is done.

## Implementation Decisions

- **The name** is read off the main actor by the conversation id the pane's record holds, with `tab_open`'s reader, at each `board_read` and `panel`.
- **The opener's pane id** joins the opener note, optional, as in option 01; the board's mark comes from it.
- **The paragraph's** failure step changes and is pinned by `make check-open`; a pane started before the build keeps its recorded paragraph until a compaction, as today.
- **Docs:** where-it-breaks' `tab_open` entry, the privacy doc (names in the board's reply), the guide.

## Testing Decisions

- **The pure parts** (a board line with and without a name, the opener's mark, the paragraph) in `make check-open`'s table.
- **By hand:** from Home, `tab_open` a helper; Restart Home; the helper's send fails, it reads the board, finds the mark and reaches Home under its new name; a lead reads a helper's name for an id and sends to it.

## Out of Scope

Other Macs, a Varnick push of any kind, and anything Claude Code's `SendMessage` doesn't do.

## Further Notes

- **Verified in the code at 2f6ddf2:** the reader of Claude Code's per-session file and its use by `tab_open`; the opener note.
- **Tested 2026-11-06:** a restart renames a session; the receiver answers `from`; the idle notice.
- **Size, in agent time:** about 1 hour of building, 20 minutes of review, and a 10-minute hand test.
- **An alternative to options 01 to 04,** not a combination. It could also come first and stay as the fallback on Macs where the channel isn't approved, where option 01 keeps today's path.
