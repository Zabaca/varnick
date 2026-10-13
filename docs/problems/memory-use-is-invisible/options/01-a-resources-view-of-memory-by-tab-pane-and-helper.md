---
problem: memory-use-is-invisible
title: A Resources view, with memory by tab, pane and helper and a Close on each tab
summary: Recommended. ⌘⇧M or `!resources` shows Resources in place of the panel's content, as ⌘⇧B shows the board. It gives Varnick's total, the same processes again by kind, and the app's own memory split into on-device models and the rest. Then come the tabs, biggest first, each opening into its panes and their processes, with Close on each tab. Below the tabs it lists the helpers that belong to no tab, other machines' tabs open here (where they run, with no figures), and, greyed, Claude Code outside Varnick. Every process is counted once, read through libproc with no subprocess, and only while the view shows.
status: shipped
---

## Solution

**Opening it.** Resources shows in place of the panel's content, as the board does:
- ⌘⇧M, listed in Settings › Shortcuts as "Show / hide Resources";
- `!resources`, which `!memory` also finds.

The same key again, or esc, goes back to what was underneath. Resources, the board and the outline never show together, and Settings shows over any of them.

**What it shows,** top to bottom. Every figure is a footprint, the figure Activity Monitor's Memory column shows.

1. **The header:** Varnick's total and its process count, such as "Varnick 8.4 GB · 37 processes". Each process is counted once.
2. **By kind:** one line that groups the same processes by kind, each kind with its total and count. The kinds are the app, Claude Code, MCP tools, web pages, the Phone page server, app servers, zmx, and shells and other. This is the table the session made.
3. **The app:** Varnick's own footprint, split three ways:
   - **On-device models:** MLX's own count, in use plus cached, naming the models loaded now, or "none loaded";
   - **Graphics:** the app's other graphics memory (drawing, web view layers), shown when macOS reports it;
   - **Everything else.**
4. **Tabs, biggest first.** One row for each tab that runs here, with:
   - its icon and name, as search shows them;
   - its total and its process count;
   - a Close button.

   A tab opens, with a click or →, into its panes. Each pane shows its total and its processes: Claude Code, Varnick's MCP tool, the commands Claude runs, a terminal's shell and what runs in it, an app's server, a page's WebKit process, and the pane's zmx.
5. **Not in a tab:** what Varnick runs that belongs to no open pane:
   - the Phone page server and its port proxy;
   - the text helper, while it runs;
   - WebKit's shared GPU and network processes;
   - what other machines run here to reach this Mac's tabs;
   - Varnick's ssh links to other machines;
   - zmx sessions of Varnick's that no open pane holds.
6. **Tabs on other machines** open here: each tab's name, "Runs on <machine>", and this Mac's share of it (its ssh clients). Nothing is asked of the host.
7. **Claude Code outside Varnick,** greyed: one row with a count and a total, such as "6 processes in other apps and terminals · 3.2 GB". It has no list and no actions. It is there so Varnick's figures and this row add up to what Activity Monitor shows for Claude Code.

**Rows stay put.** The order is set when Resources opens, and again when a tab opens or closes. The figures then change in place, every 3 seconds, so a row never moves under the pointer.

**Close** on a tab does what the tab's × does. Every pane closes, and a tab with a Claude conversation goes to Stopped and Recent. A pane that must ask first (the card of a session another machine controls) brings its tab up to ask. Only tabs that run here have Close.

**Keys:**
- ↑ and ↓ select a tab;
- → and ← open and close it;
- ↩ shows it;
- the End session key (⌘W) closes the selected tab, as Close does;
- esc goes back.

The Mark tab done and Restart session keys are taken and do nothing, so no key reaches the tab underneath.

**Measuring** happens only while Resources shows in a visible panel: once as it shows, then every 3 seconds.

## Trade-offs

- **Two private calls of macOS.** WebKit's process id for a web view puts each page under its pane. The responsibility call finds WebKit's shared processes. A macOS update can change either:
  - without the first, the pages count together under Not in a tab;
  - without both, the pages fall out of Varnick's total.

  Varnick already uses one private call, to move itself to Applications.
- **The models' figure is MLX's whole count.** With two models loaded, the row names both but can't split the figure between them.
- **Figures for this Mac only.** Another machine's tab shows where it runs, not what it uses there.
- **Close ends a working session without asking,** as × does. It can be resumed from Stopped.
- **A little work every 3 seconds while Resources shows:** one list of the user's processes and a few calls for each. Nothing while it is hidden.

## User Stories

1. As the user, I want to see how much memory Varnick uses in all, counted as Activity Monitor counts it.
2. As the user, I want to see which tab uses the most, and what in it does: Claude, a server it started, or a page.
3. As the user, I want to close a heavy tab from where I see its figure.
4. As the user, I want to tell whether the app, its models or its helpers grew.
5. As the user, I want to see what Claude Code outside Varnick uses, so the figures add up to Activity Monitor's.
6. As the user, I want the view to cost nothing while I'm not looking at it.

## Implementation Decisions

**Which processes are Varnick's**
- **One walk of the user's processes.** For each process: its parent, its path and its footprint, through libproc. No `ps`, `footprint` or zmx call.
- **Arguments are read (sysctl) of a few processes only:** zmx, ssh (a background connection's title names its socket in Varnick's folder, which tells Varnick's links from the user's own), Varnick's binary, the MCP tool's link, and any process whose path can't be read. They are only used to match processes, never shown or logged, because a Claude pane's carry its prompt.
- **Varnick's processes are:**
  - Varnick and its descendants;
  - each zmx process whose arguments name one of Varnick's sessions (a pane's, or another of Varnick's own), and its descendants;
  - Varnick's binary started as a relay for another machine, and its descendants;
  - the WebKit processes Varnick is responsible for.
- **A pane's processes are:**
  - in zmx: its daemon and the daemon's descendants, plus every zmx client of its session, wherever it was started;
  - without zmx: its client's descendants;
  - its page process: WebKit's id for the pane's web view, read again at each measure, since a page that navigates to another site can move to a new process.
- **A Claude process is known by the folder it runs from, or by its first argument,** never by its name. Claude Code outside Varnick is every Claude process that isn't Varnick's.

**Structure**
- **A pure function builds what the view shows.** It takes the process table and the open panes (id, kind, tab, zmx client, page process). It returns:
  - the rows by tab, the processes in no tab, other machines' tabs, the outside row, and the line by kind;
  - every Varnick process exactly once.

  This is where tests go.
- **The reader runs off the main actor** and publishes one result. The view reads only that.
- **Showing and hiding follow the outline's.**
  - Resources, the board and the outline close each other, and showing a tab closes Resources.
  - The panel's height is fixed, as the board's is.
  - When the panel shows again with Resources up, it measures again.
- **Panel access:** while Resources shows, a session's `keys` is refused ("Resources is showing"), and the panel's description says "Showing: Resources". There is no read tool.

**The app's split**
- **MLX's figure is read only while one of its models is loaded,** so a Mac with none loaded never touches MLX.
- **Graphics** is the graphics ledger of Varnick's own task, less MLX's figure. It is shown only when the ledger reads more than MLX's figure. That MLX's buffers count in the ledger is inferred.

**The key and the command**
- **A new shortcut,** "Show / hide Resources", in the Varnick group. It is ⌘⇧M by default and can be rebound.
- **A new `!` command,** `!resources`, which `!memory` also matches. Its detail line reads "Memory by tab, pane and helper (also !memory)".

**Nothing is saved.** There is no new field in the saved sessions file and no new setting. A rebound key is saved as every shortcut's is.

## Testing Decisions

- **No test target yet.** Tests for the pure function, once there is one, would cover:
  - a pane in zmx, and one without;
  - a Claude pane whose MCP tool's file is gone;
  - a restored pane whose daemon is older than this launch;
  - a session of Varnick's that no pane holds;
  - two web views that share a page process;
  - a Claude process outside Varnick;
  - a process gone between two steps of the walk.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **Opening:** ⌘⇧M and `!resources` open it. Esc goes back to the tab underneath, focused, and ⌘W never reaches that tab.
  - **Totals:** Varnick's total plus the outside row matches Activity Monitor, process for process, within a few percent.
  - **A Claude pane** lists claude, Varnick's MCP tool and zmx. A build started in a terminal pane shows under that pane while it runs.
  - **A web pane** lists its page process, and still does after navigating to another site.
  - **Close** closes a tab as × does, and the tab's card is in Stopped.
  - **Keep sessions running off:** a new Claude pane is still under its tab.
  - **Another machine's tab** reads "Runs on <machine>".
  - **Outside:** a `claude` in another terminal app is counted in the greyed row, not in a tab.
  - **Models:** after a search with the relevance filter on, the models line names the reranker. Ten minutes later it says none loaded.
  - **Rows:** they don't move while Resources is open, and are sorted again when it reopens.
  - **Hidden:** with the panel hidden, Varnick's CPU in Activity Monitor is what it is without Resources.

## Out of Scope

- **Figures from other machines.** These would need a request in the peer protocol, on the Mac and the headless relay (which would read `/proc` on Linux), and so a protocol bump.
- **Badges on board cards and tab rows** (option 03).
- **Unloading models from the view, or sooner.** They already unload after 10 idle minutes. The app row will show whether their share matters.
- **CPU, energy and disk.**
- **Figures over time, graphs, and alerts at a threshold.**
- **A Panel access read tool,** which would let a session answer "how much memory does Varnick use" from Varnick itself.
- **The Phone page.**

## Further Notes

- **No ADR:** nothing crosses machines. CONTEXT.md gains **Resources**.
- **where-it-breaks to update:**
  - Panel size: Resources' fixed height;
  - Focus and keys: its keys, the session keys it takes, and showing a tab closing it;
  - Panel access: `keys` refused while it shows;
  - Signing: the WebKit row relies on Varnick being its own responsible process, which a launchd start ensures. A Varnick started from a terminal would leave the terminal responsible for its WebKit processes (inferred).
- **Verified (code at 0b3f9b2, and read-only probes on 2026-10-13):**
  - a zmx daemon's arguments name its session;
  - the session's program is the daemon's child, and Claude's MCP tool is below it;
  - a footprint is readable through libproc for the user's processes;
  - the responsibility call names Varnick for its WebKit processes, and each pane process as its own;
  - Claude's kernel name is its version;
  - an MCP tool's path can be unreadable;
  - MLX's in-use and cached counts exist, and its cache is capped at 64 MB;
  - the three models unload after 10 idle minutes;
  - ⌘⇧M is free.
- **Inferred, not tried:**
  - WebKit's private per-view process id, from its private header;
  - one page process per web view, unless pages open each other;
  - MLX's buffers counting in the graphics ledger.
- **Picked:**
  - ⌘⇧M, and `!resources` with `!memory`;
  - 3 seconds;
  - the order fixed while Resources is open;
  - Close offered only on tabs that run here.
- **A third tab of the board** would reuse the board's showing, keys and panel height. The user chose a view of its own. The board is about turns, and its Problems tab is behind an experimental switch.
- **Decided by the user (2026-10-13),** each the recommendation:
  1. **Put each page under its pane, through WebKit's private process id?** Yes, with the responsibility call for the shared processes. Without it, all pages are one row under Not in a tab, and Varnick uses one private call fewer.
  2. **Show Claude Code outside Varnick?** Yes: one greyed row with a count and a total, and no list, so the figures match Activity Monitor.
  3. **⌘⇧M and `!resources` (`!memory`)?** Yes. Both are free, and M is for memory.
  4. **Show other machines' tabs with "Runs on" and no figures from the host?** Yes. Their figures would need a protocol bump on both relays.
