---
title: Varnick doesn't show how much memory it uses, or what uses it
description: Nothing in Varnick says how much memory it uses, or which tab, pane or helper uses it. When the user asked how much RAM Varnick uses, a session had to find out with `ps` and `footprint` and add up the table by hand. Its first count was wrong, because it counted every `claude` process on the Mac as Varnick's.
impact: When memory runs short, the user can't tell which tab to close. Nor can they tell whether the app, its models, its helpers or Claude Code is what grew. Each answer costs a session's time, and it is wrong unless each process's ancestry is followed. Most of the memory is Claude Code in panes (6.45 GB in the snapshot below), and it grows with every tab left open.
severity: mid
evidence: The user's question and a session's measurement of 2026-10-13, relayed by the coordinator; the measurement used `ps` and `footprint` on the user's Mac. Code read at 0b3f9b2. On 2026-10-13 the planner also looked at this Mac's processes, read-only: `ps`, zmx's listing, and two small libproc probes built in a scratch folder. What they printed stays out of the repo. Varnick was not run.
status: closed
---

## What the user asked for (2026-10-13)

A process view inside the app, like the table the session made. The user and the coordinator discussed its shape:
- a view of its own, shown in place of the panel's content like the board or Settings;
- a row for the app, one for each kind of helper, and one for each tab, which lists its panes and their processes;
- sorted by memory, with a Close action on each tab.

## Measured (2026-10-13)

All figures are footprints, the figure Activity Monitor's Memory column shows. One session took them with `ps` and `footprint`.

| What | Footprint | Processes |
|---|---|---|
| Varnick, the app | 1.36 GB | 1 |
| … of that, graphics (IOAccelerator) | about 1.07 GB | |
| … of that, malloc | about 0.29 GB | |
| Claude Code in Varnick's panes | 6.45 GB | 8 |
| Varnick's MCP tool, one per Claude pane | 136 MB | 7 |
| WebKit page processes | up to 158 MB | 5 |
| Phone page server and port proxy (Bun) | 103 MB | 2 |
| zmx | 41 MB | 10 |
| Custom app servers | 24 MB | 2 |
| Claude Code outside Varnick, in other apps and terminals | 3.2 GB | 6 |

- **The graphics share is unexplained.** The session guessed it was the on-device MLX models plus drawing, but nothing checked that. The transcriber it named isn't an MLX model: Listening uses Apple's SpeechAnalyzer (verified in the code). Varnick's MLX models are the search embedder, the relevance filter's reranker and text generation, each only when set to run on this Mac.
- **The first count was wrong.** It took all 14 `claude` processes for Varnick's, and 6 of them belonged to other apps and terminals. A process is Varnick's only when its ancestry leads to Varnick, or to one of Varnick's zmx sessions.

## Today

Verified in the code at 0b3f9b2 and by the read-only looks above, unless marked.

**Nothing shows memory.** No view, row or setting reports memory or processes. MLX's memory figures are printed only by the reranker's evaluation command.

**Where Varnick's processes are**
- **A Claude, terminal or app pane runs in a zmx session of its own** while Keep sessions running is on. An app's server always does. The session's daemon is a child of launchd, not of Varnick, and its arguments name the session, which is named after the pane's id. The pane's program is the daemon's child: the login shell that becomes `claude`, a terminal's shell, or an app's `bun`. Claude's MCP servers and the commands it runs are below that. Varnick's own child is only the pane's zmx client, about 2 MB.
- **With Keep sessions running off,** a Claude or terminal pane's program is Varnick's child, through the login shell.
- **Varnick's MCP tool** in a Claude pane is Varnick's own binary, run with the pane's id in its arguments. The file it runs from can be gone, because it is an older launch's snapshot and those are removed. Its path then can't be read, but its arguments can.
- **Claude Code's executable is named after its version,** so the kernel's name for a Claude process is a version number. It is known by the folder it runs from, or by its first argument.
- **WebKit's processes are children of launchd.** There is one page process per web, app or Markdown file pane (inferred), plus a GPU process and a network process the pages share. WebKit's public API gives no web view's process id. Its private API has one for each web view (not tried). macOS's private responsibility call names Varnick as responsible for Varnick's WebKit processes, and names another app for that app's own. Checked on this Mac for Varnick and two other apps.
- **A pane's processes are each their own responsible process,** under their zmx daemon. So the responsibility call can't tell whose they are; their ancestry can.
- **The Phone page server, with its port proxy,** runs in a zmx session of its own, named for the Phone page.
- **Another machine's tab open here** runs on its host. This Mac holds only the panes' ssh clients. The host's `tabs` listing carries no memory figures.
- **The rename's check for a running Launchy** already lists every process and reads parents, paths and arguments, through libproc and sysctl. It is short-lived code, removed with the rename's cleanup.

**Figures that need no subprocess**
- **A process's footprint** comes from libproc for any process of the same user. Checked with a probe from a terminal. Varnick isn't sandboxed.
- **MLX counts its own memory,** in use and cached, for the whole process, not per model. Varnick caps MLX's cache at 64 MB, and MLX aborts the app if it is touched without its Metal library.
- **Varnick's own graphics share** is in its task's VM information (the graphics ledger). Whether MLX's buffers are counted there is inferred, not checked.

**Models already unload when idle.** The embedder, the reranker and text generation each drop their weights 10 minutes after their last use. Each can instead run on a server (Settings › Models), where it holds no memory here.

**The panel's other views.** The board and the outline each replace the panel's content, never together, and Settings shows over them. Each opens with a shortcut and a `!` command (⌘⇧B and `!kanban`, ⌘⇧Y and `!outline`). Each takes its own keys before the shortcuts, ⌘W included, so no key reaches the hidden tab. The board reads once a second, and only while it shows in a visible panel.

**Keys.** The tabs-past-the-strip-are-hidden options the user accepted take ⌘⇧P, ⌘⌥[ and ⌘⌥]. ⌘⇧M is bound to nothing: not in Varnick's shortcuts, its menus, or the outline's own keys.

## Overlap with other problems

- **`models-run-only-on-this-mac`** (options 01 to 03 shipped). A model that runs on a server holds no memory on this Mac, and a Resources view's app row would show the difference.
- **`tabs-past-the-strip-are-hidden`** (options 01 and 02 accepted). It takes the keys above, and its projects column also groups tabs, by project.
