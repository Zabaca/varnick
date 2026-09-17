# The chat is a terminal running the Claude Code CLI

The window shows a terminal, served by ttyd from a zmx session, running the plain `claude` on your PATH. There is no chat built on the Agent SDK. Plan mode, permission prompts, skills, slash commands, resume and the transcript all come from Claude Code, and the durable transcript is the one Claude Code already writes under the agent's home. The previous version owned all of that and spent most of its bugs on keeping a mirror in agreement with the SDK.

zmx rather than tmux, because a Session must survive the window and replay scrollback into xterm.js, which is what zmx does and tmux does not. ttyd's own page is loaded in an iframe; no terminal code is owned here.

Consequences: a structured view of the transcript, if wanted, is read from Claude Code's files, never recorded separately. Tools the Host offers the agent are reached through the Door (ADR-0006), not as in-process MCP tools.
