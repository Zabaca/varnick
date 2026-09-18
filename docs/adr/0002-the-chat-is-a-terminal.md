# The chat is a terminal running the Claude Code CLI

The window shows a terminal, served by ttyd from a zmx session, running the plain `claude` on your PATH. There is no chat built on the Agent SDK. Plan mode, permission prompts, skills, slash commands, resume and the transcript all come from Claude Code, and the durable transcript is the one Claude Code already writes under the agent's home. The previous version owned all of that and spent most of its bugs on keeping a mirror in agreement with the SDK.

zmx rather than tmux, because a Session must survive the window and replay scrollback into xterm.js, which is what zmx does and tmux does not. ttyd's own page was loaded in an iframe, and no terminal code was owned here; the amendment below is where that changed.

Amendment, 2026-09-18: the page owns the terminal widget. Instead of ttyd's page in an iframe, the page mounts xterm.js itself and speaks ttyd's websocket protocol, because the iframe is another origin and a key pressed inside it cannot be mapped — Shift+Enter has to leave as ESC CR for Claude Code to read it as a newline, and Option has to be Meta. ttyd and zmx still own the terminal, and the socket is the one the iframe was using.

Consequences: a structured view of the transcript, if wanted, is read from Claude Code's files, never recorded separately. Tools the Host offers the agent are reached through the Door (ADR-0006), not as in-process MCP tools.
