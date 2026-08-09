# 39 — The menu was unusable at the size it had just become

**What to build:** A command menu that survives ninety rows — findable, readable, and unable to break the window it sits in.

**Blocked by:** 36, 38.

**Status:** done.

**Realizes:** no state path.

## Why this exists

Ticket 36 made the menu show what the agent actually has, and ticket 38 gave the agent plugins and skills. The list went from thirteen rows to ninety, and every weakness in it that had been invisible at thirteen became the whole experience at ninety.

Five defects, all found by the developer using it.

## What was wrong

**Two rules were deciding one thing.** The machine asked whether a name *starts with* the draft to decide whether the menu is open; the matcher would also match *inside* a name. Every plugin-qualified command fell through the gap — nothing starts with `/grill`, so the menu closed on the exact keystroke that should have found `mattpocock-skills:grill-with-docs`, and the list the matcher would have returned was never rendered. The matcher was right and never got asked.

**The rows overlapped.** The name sat in a fixed `24ch` inline-block, so anything longer — a qualified name, or a name plus its argument hint — drew *underneath* the description. `/effort low|medium|high|Currentxxhigh` is two pieces of text in the same place, not a cramped column.

**The menu blanked the Surface panel.** Unbounded, ninety rows grew the composer's column until the flex row outgrew the window and pushed the panel off the side. It looked like a rendering bug in the panel and was a height in the menu.

**The selection was a shade of text.** On a list this long you lose your place the moment you look away.

**And the list arrived too late to be useful.** It can only reach Core stamped with a Turn id, so a window that had not run a Turn had never been told what the agent accepts — which is exactly when someone types `/`.

## What it does now

- **One predicate.** `isCommandDraft` and `matchCommands` ask the same question, two-character floor included. Asserted, including the case the old rule got right: `/clear everything` still closes the menu.
- **A flex row.** The name column keeps a `min-width` floor so a scan finds it in the same place, and a long name pushes the description rather than colliding with it.
- **A height cap** with its own scroll, and `shrink-0` on the composer.
- **A band for the selected row** — an accent rule down the left and a wash behind it — on a surface one step up from the transcript (`--ground-raised`), so a ninety-row list reads as laid over the conversation rather than as part of it.
- **A cache.** The agent host writes the list beside the session pointer; Core asks the runtime for it at start-up. From the second launch onward the menu is populated before anything is typed. The first launch of a fresh clone still fills on the first Turn, because the SDK's `init` does not arrive until a message is sent — measured, and recorded in `agent.ts`.

## What was removed

`/effort` and `/model` were one row per value — eight of thirteen rows spent on two settings, on the argument that a command per value needs no parsing. They are one row each taking a value now, and the signature bar answers a wrong one.

`/retry`, `/interrupt` and `/restart` are gone entirely. Each already had a control where the thing it acts on is: a failed Turn renders its own retry, a crashed agent renders its own restart, and Escape stops an answer. Verified reachable before removal rather than after.

## Left open, deliberately

**varnick's four remaining commands are all CLI commands too** — `/clear`, `/compact`, `/model` and `/effort`. They exist because varnick keeps its own copy of state the CLI's versions would change behind its back: the transcript, the token meter, the footer.

The better answer is to listen rather than duplicate. `conversation_reset` and `compact_boundary` both already arrive, the compaction summary already reaches varnick through the `PostCompact` hook, and the runtime report already carries `model`. Then all four rows go — and something better than tidiness happens, because **today running the CLI's `/clear` would leave the two halves disagreeing.** It does not bite only because `mergeCommands` hides the CLI's version behind varnick's, which is masking rather than fixing.

That is a domain change — it touches `CONTEXT.md`'s event list and two `#/states` cards — so it is written down here rather than assumed.

- [x] A plugin-qualified command is found from inside its name
- [x] No row draws on top of another
- [x] The menu cannot push the Surface panel off the window
- [x] The selected row is findable at a glance
- [x] The menu is populated before the first Turn of the second launch onward
- [x] `bun test packages`, `bun run drive`, typecheck and lint green

Found by the developer, one screenshot at a time.
