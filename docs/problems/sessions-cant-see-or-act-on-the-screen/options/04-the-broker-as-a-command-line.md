---
problem: sessions-cant-see-or-act-on-the-screen
title: Option 01's broker as a command line, `launchy-screen`, for any agent in a pane
summary: The same broker, verbs, per-pane switch, approval, refusals, indicator and record as option 01, reached through a command instead of an MCP server. `launchy-screen look`, `point`, `click` and `type`, run from a pane's shell, send one line on the user-only socket and print the reply as JSON. A picture is written to a file in the pane's folder, and the path is printed. It works for any agent or script in a pane, and needs no `--mcp-config` or session restart. But Claude reaches it through Bash, so Claude Code's only gate is its Bash prompt, which a Skip-permissions session never shows. Launchy's approval still stands for click and type.
status: proposed
---

## Solution

A command, a link to Launchy's own binary in its relay style, that each pane finds on its `PATH`:

```
launchy-screen look [--app NAME] [--text] [--picture]
launchy-screen point ID|X,Y,W,H --note TEXT
launchy-screen click ID|X,Y
launchy-screen type [--into ID] TEXT | --key NAME
```

Each run sends one line on the peer socket, as `Launchy --mcp` does in option 01, and prints the reply as JSON. Everything Launchy checks and shows is option 01's.

## Trade-offs

- **Any agent, any script.** Codex, a shell script or a custom app's server in a pane can use it, not only Claude Code.
- **No restart.** Nothing is added to claude's command line. A session started before the switch can use it as soon as its pane has Screen access.
- **Weaker gate in Claude Code.** Claude calls it through Bash. With permission prompts on, the user sees the command line. With Skip permissions, there is no prompt. Option 01's tools can carry their own permission rule; this can't. Launchy's approval for click and type is unchanged.
- **Pictures by file.** Claude reads a picture by reading the file. It lands in the pane's folder and stays until the pane closes, unlike option 01's in-call image.
- **Discoverable by text.** Claude learns the command from a line the SessionStart hook adds when the pane has Screen access, the way ADR 0020's `/work` line is added. It isn't a listed tool.

## User Stories

1. As a Launchy user, I want any agent in a pane I enable to look, point and, with my approval, act, through one command.
2. As a Launchy user, I want everything else in option 01.

## Implementation Decisions

- **As option 01**, except the transport:
  - a link named `launchy-screen` to Launchy's binary, beside it, put on each pane's `PATH`;
  - JSON on standard output, and exit codes for refused (2), not approved (3), no Screen access (4) and Launchy not running (5).
- **Pictures** go to `screen-look.png` in the pane's folder, replaced by each `look --picture` and removed when the pane closes.
- **The SessionStart line** names the command, only for a pane with Screen access on.

## Testing Decisions

Option 01's seams and hand checks, run as commands. Also: a pane without Screen access gets exit code 4. And the picture file is gone after the pane closes.

## Out of Scope

As option 01.

## Further Notes

- **Can stand beside option 01:** the same socket operation, two front ends. Recommended only if agents other than Claude Code need it. Otherwise option 01's tools give Claude Code its own per-tool permission rule.
