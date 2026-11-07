---
problem: sessions-cant-reach-each-other-reliably
title: Option 01, with today's `varnick` server moved whole into Varnick's plugin, so each pane runs one server that has the tools and delivers the messages
summary: As option 01, but instead of a second, push-only server beside today's, every pane's one Varnick server comes from the plugin and also declares the channel. It saves one small process per pane. The cost is that Claude Code names a plugin's tools after the plugin, so every Varnick tool is renamed (`notify`, `look`, `pane_open` and the rest gain a plugin prefix): the hooks and allowances that name `notify` and `task_result`, the automations' saved Allowed tools that name `outline_append`, the user's own permission rules for Varnick's tools and the docs all change, and the headless host's server keeps the old names. Not recommended.
status: proposed
---

## Solution

Everything in option 01 holds but the servers.

**One server, from the plugin.** Panes no longer get a `varnick` server through `--mcp-config`. Varnick's plugin's one server is today's, which also declares the channel and pushes, and lists the tools the pane's sets name. One plugin folder serves every pane, so the sets come from the pane's environment, which Varnick sets at each start, as the pane id does.

**Every pane loads the plugin,** runs and Task steps included (they need `notify` and `task_result`), whether this Mac is ready for channels or not; only panes that get the pane tools are started with the channel.

**Every tool is renamed.** Claude Code names a plugin's tools after the plugin and the server (seen 2026-11-07 with a test plugin), so `mcp__varnick__notify` becomes a longer name with the plugin's prefix, and so for every tool:

- The hook that records a session's message, and the allowances for `notify` and `task_result`, name the new forms, and the headless host's server, which keeps `--mcp-config`, keeps the old: both must be matched.
- Automations' saved Allowed tools that name `outline_append` are rewritten once, when the file is read, since a run would otherwise lose the tool.
- The user's own permission rules that name Varnick's tools (asking before `click` or `type`, say) can't be rewritten by Varnick: they stop matching, and the guide says to rename them.

## Trade-offs

- **One process per pane,** as today: no second server (about 5 MB each).
- **Every tool name changes,** with a one-time rewrite of saved data, rules Varnick can't reach, and two names for `notify` across hosts. A permission rule that silently stops matching can mean a tool that asked before now runs without asking, or the reverse.
- **The channel depends on the plugin loading,** and now so does every tool: a Claude Code that refuses the plugin folder leaves a pane with no Varnick tools at all, where option 01 loses only the messages.
- **Panes get the plugin even when the Mac isn't ready,** so Claude Code's plugin handling is on every pane's path.

## User Stories

1. As the user, I want one Varnick process per pane, so that many panes cost less memory.
2. As the user, I want my automations' allowed tools rewritten for me, so that a run keeps `outline_append`.
3. As the user, I want to be told which of my permission rules name Varnick's tools, so that I can rename them.

## Implementation Decisions

- **The tool sets travel in the pane's environment,** read by the server at start, since the plugin's server line is shared.
- **The new tool names** are built in one place, used by the hooks, the allowances and the check for an automation's Allowed tools, which accepts both forms.
- **The automations file** is rewritten once from the old names to the new.

## Testing Decisions

- `make check-mcp` and the hook checks cover both name forms; the automations rewrite joins the automation checks.
- **By hand:** every set in a pane, a run and the voice session; a message notice from `notify` in a pane and on a headless host.

## Out of Scope

As option 01.

## Further Notes

- **Seen 2026-11-07:** a test plugin's tool was named with its plugin and server's names.
- **Size, in agent time:** option 01's plus 1.5 to 2 hours (the renames, both forms in the hooks, the rewrite, docs).
- **Recommended against:** the memory it saves is small next to a rename that reaches saved data and rules Varnick can't see.
