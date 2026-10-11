---
problem: sessions-cant-read-or-drive-varnick
title: Option 01's requests as a command line, for any agent, script or shell in a pane
summary: A second front end on option 01's socket requests, reached through a command instead of the MCP server. `Varnick --panel <tool> [arguments as JSON]`, run from a pane's shell through the peer link, sends one line and prints the reply. Any agent, skill or script in a pane can use it, with no `--mcp-config` and no session restart, and it reads the pane id from the pane's environment. But Claude reaches it through Bash, whose only gate is a prompt that a Skip-permissions session never shows. Like Screen access's option 04, it is best added later, on the same requests.
status: proposed
---

## Solution

`Varnick --panel panel`, `Varnick --panel outline_read '{"depth":2}'` and so on. Each runs before anything of the app starts, as `--mcp` does. It sends the same `panel` socket line that option 01's server sends, prints the reply's text and exits non-zero on a refusal. The pane comes from `VARNICK_PANE_ID` in the caller's environment, and a run outside a pane is refused. The Panel access switch governs it as it governs the MCP tools.

## Trade-offs

- **Any caller:**
  - a skill can carry a script that uses it, such as a `/outline` skill that reads and adds bullets;
  - an agent other than Claude Code can use it, and so can the user's own shell in a terminal pane;
  - nothing to restart: the command is the running build's.
- **The gate is Bash's.** Claude Code shows no per-tool rule for it, only Bash's prompt, which a Skip-permissions session never shows. As with Screen access, the switch is the only stop.
- **The pane id is still a label.** Any process of the user can set it, as with the MCP server.
- **Two front ends** for one set of requests. The relay stays as thin as `--mcp`: no reading, no acting.

## User Stories

1. As someone writing a skill, I want a script to read and add bullets in the Outline without an MCP server.
2. As a Varnick user, I want to read what the panel shows from my own shell.

## Implementation Decisions

- **The same request, router, refusals and replies as option 01,** with a new mode in the entry point above the app's start that writes nothing.
- **The peer link (`PeerLink`)** is the command's path, as for the MCP server.
- **Standard output is the reply's text.** Refusals go to standard error, with exit status 1.

## Testing Decisions

- `make build`. By hand after a restart, from a terminal pane: `Varnick --panel panel` prints the panel's state; with the switch off, it prints the refusal and exits 1; run outside a pane, it is refused.

## Out of Scope

- `keys` (option 02) from the command line.

## Further Notes

- **It depends on option 01's requests.** Recommended: later, if a skill or another agent needs it.
