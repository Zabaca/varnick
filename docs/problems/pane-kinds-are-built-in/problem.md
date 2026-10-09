---
title: Only built-in tools open in a pane, and Scratch rides on every Claude session
description: The split picker offers Claude, Terminal and Browser and nothing else, so a tool of the user's own that should sit beside a session has to be written into Launchy. Scratch, the one such tool, is built in. Launchy runs its Vite server on Deno and adds its folder and instructions to every Claude pane in every folder, whether or not a page is ever built.
impact: Each new pane tool means changing, rebuilding and restarting Launchy. Every Claude session carries Scratch's system prompt and an extra directory, though here 2 of 36 Claude panes ever built a page. Launchy keeps 275 lines for one tool, most of them process handling (port and pid files, adopting and killing orphaned servers, stopping them at Quit). Scratch is tied to Deno, and the user now prefers Bun for its developer experience.
severity: mid
evidence: Measured 2026-10-03 on the user's Mac. Scratch's code is 275 lines, plus its hooks in the pane, the model and Quit. The appended system prompt is about 1,400 characters once its paths are filled in. Launchy's scratch folder holds 36 pane folders, and 2 of them have an index.html. Two `deno run -A npm:vite` servers were running, kept alive across restarts by the zmx setting. `-A` grants Deno every permission, so Deno's sandbox was never in use.
status: closed
---

A split (⌃⌘⇧E side by side, ⌃⌘⇧O top and bottom) asks what the new pane holds: Claude, Terminal or Browser, picked with C, T or B. The list is fixed in Launchy's code. A tool the user builds for themselves can only appear there by adding it to Launchy.

Scratch is the one tool that was added that way. Each Claude pane gets a **Scratch area**, a folder under Launchy's own support folder. Claude learns about it from text appended to its system prompt, and reaches it through an extra `--add-dir`. When Claude writes `index.html` there, Launchy starts a Vite dev server on Deno for that folder and opens a browser pane beside the Claude pane by itself. All of this happens for every Claude pane in every folder, used or not.

Launchy also manages those servers' lives. It keeps each one's port and pid in the pane's folder, stops it when the pane ends, stops it at Quit unless the pane is kept in zmx, and at launch either adopts a server a kept pane still owns or kills it as an orphan. Claude and terminal panes already get their survival from zmx (ADR 0004). Scratch servers get theirs from this separate logic.

The same per-pane folder holds a file that isn't Scratch's at all: the SessionStart hook writes the pane's current conversation there (ADR 0001). That file is how a pane follows `/clear` and `/resume`.
