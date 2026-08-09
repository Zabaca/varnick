# 36 — The command menu listed only the commands varnick wrote

**What to build:** A menu that offers everything the running agent will accept — its skills, its plugins, the CLI's own commands — beside varnick's, with the descriptions and argument hints that make a list of thirty findable.

**Blocked by:** None.

**Status:** done.

**Realizes:** no new state path. `composer.typing` and `composer.menu` are unchanged; what changed is what the list contains and how it is ranked.

## The defect

The menu was a thirteen-entry literal in `chat-surface.tsx` — `/clear`, `/compact`, `/retry`, `/interrupt`, `/restart`, five efforts, three models — and `SET_COMMANDS` was fed from that same literal. **No skill, plugin or CLI command had ever appeared in it**, in a window whose entire subject is an agent that has dozens.

Executing them already worked: a message whose text is `/foo` is handed to the SDK like any other and the CLI runs it. What did not exist was any way to *know* they were there. This is a discovery feature; the send path is untouched.

The runtime's list was also already half-arrived and unused — `RuntimeReport.slashCommands` carries the init message's **names only** and was rendered as decorative chips in the runtime panel. Descriptions and argument hints come from each command's own frontmatter and have to be asked for.

## Ported from forge, with the reasons

Each of these was learned against a live runtime, and each has an obvious alternative that makes the list *wider* as more is typed:

- **Aliases match exactly, never by prefix.** `/usage` carries the alias `cost`, so a prefix rule makes a lone `c` drag it in beside `compact` and `clear` — the first keystroke of a hunt returning more than no keystroke did.
- **Substrings count only from two characters.** One character is inside half the names and all of the descriptions; forge's `c` found `mem-search`.
- **A query nothing answers is nothing, never the full list.** A filter that falls back to everything says a command exists when it does not — the one lie a discovery surface must not tell.
- **A name can arrive twice from the runtime alone.** forge observed `caveman:caveman` as both a command (with its argument hint) and a skill of the same name (with a paragraph and no hint). Merged rather than dropped: the hint from whichever has one, the longest description, aliases unioned.
- **The signature bar exists for the gap the menu leaves.** Accepting `/agents` settles the command and closes the list, which is the moment its `[name]` stops being visible anywhere.

## What varnick added to it

- **Two sources, one list, and varnick's wins a collision.** `/compact` in this window means the Compaction this window implements — a machine state that can fail and says so — not the CLI command that would be sent as text. Rows are marked `· agent` rather than separated: someone hunting wants one ranked list, and which half a row came from only matters once they have found it.
- **`can()` still gates varnick's rows and only varnick's.** A command that cannot run is not offered; an agent command has no `run` and is deliberately not given one.
- **Multi-word names survive.** forge closes its menu at the first space; varnick's `/effort xhigh` and `/model sonnet-5` are single commands, so `isCommandDraft`'s existing rule — keep the menu while any name still prefixes the draft — is kept over forge's.

## How the list gets there

`AgentSessionPort` gained a sixth member, `supportedCommands()`. The argument for it is the one that interface's own doc demands: **nothing else can see this list.** It is assembled inside the Claude Code process from the CLI's commands, the skills it discovered and the plugins it loaded, and it changes while the agent works.

It rides the turn-event channel beside the runtime report, held and replayed at the start of each Turn for the same timing reason — it arrives outside any Turn, and an update with no Turn to stamp it with is dropped. `commands_changed` **replaces** the held list, which is what the SDK asks of a client; a merge would go on offering a skill that has gone. Asking is best-effort: a Session that will not answer costs a menu one refresh out of date, never a Turn.

## Watch for

- **The list is cleared when the agent goes**, like the runtime report, and for the same reason: offering a skill from an agent that is not there is the menu claiming something exists when it does not.
- `COMMAND_LIMIT` caps how many arrive, not how long each is. A runtime with a thousand commands is one this menu cannot help with anyway.
- The empty list and `null` are different facts on the agent host: empty means it was asked and has none, `null` means nobody has asked.

- [x] Skills, plugins and CLI commands appear in the menu with their descriptions
- [x] Argument hints from frontmatter are shown, and again once the menu closes
- [x] Typing narrows the list rather than widening it, and no match shows no rows
- [x] varnick's own commands keep their `can()` gating and win a name collision
- [x] `bun test packages`, `bun run drive`, typecheck and lint green

Asked for by the developer, twice, after reviewing forge's implementation.
