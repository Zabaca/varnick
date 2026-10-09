---
problem: problems-not-on-the-board
title: A Problems tab on the board, with work links for each session and subagent, made by hooks and /work, from every host
summary: The board gets a Problems tab, the prototype's variant D, whose columns come from each problem's files. Every Claude pane keeps a work record in its folder (none, a problem or an option), and every subagent can keep its own beside it, with a log of every link made. A hook on file writes links the writer by path, a `/work` skill links it on request, and the builder links itself to its option and ties its branch to it in git. Building is an option with a live link or a tied branch not yet merged. Links reach a paired Mac's board in the relay's replies (protocol 17), and a session that ends keeps its links in its saved record and in the search database. The merge sets `shipped`. Rough effort is six days, in three branches.
status: accepted
---

## Solution

### The Problems tab

The board gets two tabs in its header, **Sessions** (today's board, unchanged) and **Problems**. Tab and ⇧Tab switch between them, `!problems` opens the board on Problems, and ⌘⇧B opens it on the tab last shown.

Problems is a kanban with one card per problem, in five columns:

- **Backlog**: nothing decided. Cards sort by severity, high first.
- **Decided**: an option is accepted, and nothing builds it.
- **Building**: an option is `in-progress`, or has live work (below).
- **Shipped**: an option is shipped and the problem is still open.
- **Closed**: the problem says closed, or every option was rejected or abandoned.

The rule is the prototype's, with two changes: a problem with no options yet is in Backlog (the prototype put it in Closed), and live work is this option's Building, not the prototype's guess.

```ts
// prototypes/problems-kanban/model.ts at 74ff0cc
export function kanbanStage(p: Problem): Stage {
  if (p.declared === "closed") return "none";
  const st = p.options.map((o) => o.declared);
  if (st.includes("in-progress") || liveBuilds(p.slug).length) return "building";
  if (st.includes("accepted")) return "decided";
  if (st.includes("shipped")) return "shipped";
  if (st.includes("proposed")) return "options";
  return "none";
}
```

A card shows the problem's title, the severity on a Backlog card, and session chips: two, then "+3", and all of them once opened. ↩ or a click opens a card, and the opened card says why it is in its column:

- Backlog: how many options are proposed, or none yet.
- Decided: each accepted option, by number and title.
- Building: each option being built, and what makes it live: an `in-progress` status, a session or subagent linked to it, or a branch with commits not on main.
- Shipped: each shipped option.
- Closed: the problem's status, or every option rejected or abandoned.

A problem that a session wrote first also says which session it came out of. There is no slug, no option chip, no last-touched date and no way to change a status from the board. The arrows move between cards as on Sessions, and D and the End session key are taken and do nothing. (amended 2026-10-09: in a card that shows all its chips, ↓ and ↑ move onto them and between them, ↓ off the last chip moves on to the next card, ↩ or a click on a chip opens that session as the Sessions tab's Open does, and esc steps out of the chips before it closes the board. Also amended 2026-10-09: there is no Show evidence switch and no E key, which the board takes and does nothing with; evidence and every chip show only in a card opened with ↩ or a click, so chips are reachable only in an opened card, and esc on a chip collapses the card.)

**Which problems.** Every project in Launchy's project list whose main checkout has a problems folder, read from disk as it is now. When more than one project has problems, each card carries its project's pill.

### Work links

A **work link** ties work to a problem or to one of its options. Each Claude pane keeps one record, the session's, which is **none** (discovery: the default, and a state of its own), **a problem**, or **an option of a problem**. Each subagent or teammate can keep its own record beside it; one that has none works under its session's. A record also names the repository, as its main checkout's folder, so a builder in a worktree links to the same problem as a planner in the checkout.

Every link made is also appended to the pane's **work log**: when, who (the session, or the subagent's id and type), and the link. A link made by creating a problem's description is marked as that problem's origin. The record is what is live; the log is the history.

Links are made in four ways, and no other:

1. **By writing a problem's files.** A hook before Write, Edit, MultiEdit and NotebookEdit looks at the path. A file under a problem's folder, or under the scratch folder of an existing problem, links whoever writes it (the subagent when the call is a subagent's, else the session) to that problem. It never replaces an option record: only `/work` changes one, and the log keeps the write either way. It never blocks a write and prints nothing.
2. **By `/work`.** A skill anyone can invoke, the user or Claude: `/work problem <slug>`, `/work option <slug>/<NN>`, `/work none`, and `/work` alone to show the records. Its script checks the slug and option against the files and prints one marker line. A hook after Bash finds that line in the output and writes the caller's record, so `/work` in a subagent sets the subagent's own.
3. **By the skills that create work.** The builder's first step is `/work option <slug>/<NN>`. The planner writing a problem and a ticket claim, an edit under the problem's scratch folder, are links of the first kind and need nothing more.
4. **At the start of every session.** The SessionStart hook Launchy already installs adds one line for Claude, in a repository that has problems and the `/work` skill: what `/work` does, and the open problems, by slug and title.

When a subagent ends, its own record is removed; its links stay in the log.

### Building

An option that isn't shipped, rejected or abandoned is being built when:

- an open session's record names it, here or on a paired Mac; or
- a subagent's own record names it while its session is open (the record goes when the subagent ends); or
- a branch tied to it has commits that aren't on main.

**Tying a branch.** `/work option` run on a branch other than main records the option in the repository's git config for that branch. Every worktree shares that config, it goes when the branch is deleted, and the board reads all ties with one git command, then counts each tied branch's commits not on main. A merged branch, or a deleted one, stops counting.

A link to a shipped option doesn't count, so a session left open after its merge doesn't keep the card in Building.

### Shipped

The merge that completes an option sets the option's status to `shipped` in the merge commit itself: merged without committing, the status edited, then committed with the merge message. The branch's tie says which option it built. The rule is written once, in the issue tracker's description of option statuses, and the orchestrator's merge step points to it.

### Session chips

A chip is a card on the Sessions tab whose links, live, logged or archived, name the problem. It shows that card's title and a dot for its column (Running, Stopped, Completed), Running first. A subagent's link shows its session's chip; the opened problem card names the subagent's type beside it.

### Peers

The relay reads a pane's work records and log where it reads the turn, on a Mac and on the headless host, and sends the links in `status` and `sessions` (protocol 17). A paired Mac's link matches this Mac's problem by the project's group and name and the slug. A paired Mac's session that becomes an ended card here keeps the links of its last listing.

### History

When a Claude pane closes, its log's links are copied into its saved record, so ended and Completed cards keep their chips. The history sync copies every saved record's links into a table of its own in the search database, never deleted, so which sessions worked on a problem can be asked after Recent and Completed have dropped them. (amended 2026-10-09: the table is written when a pane closes, and the history sync copies the saved records' links that were missed, rather than the sync alone; the sync also copies those of the headless host's sessions, which has no search database of its own, and not a paired Mac's, which keeps its own.)

## Trade-offs

- **Deterministic.** Every chip and every Building card comes from a write, a `/work`, a branch tie or a status, and the opened card says which.
- **It misses work that writes nothing.** A session that only reads, or writes through Bash or an MCP tool, links only through `/work`.
- **The claude command line changes,** with four hook entries: before file writes, after Bash, at a subagent's end, and the SessionStart line. Both Macs need a rebuild and the headless host a reinstall, and sessions started earlier link only once restarted.
- **Protocol 17.** Every Mac and the headless host must run one commit, and the Phone page server's protocol constant moves with it.
- **Each file write and each Bash call** runs one more short shell, a few milliseconds.
- **A denied write still links,** since the hook runs before the tool. The user chose before; a hook after the tool would link only writes that happened.
- **The SessionStart line** costs a few hundred tokens per session start in a repository with problems.
- **A branch on another Mac** counts only while its builder's session is open there: its git config isn't on this Mac.
- **A subagent killed without ending** keeps its record until its session ends.

## User Stories

1. As the user, I want a Problems tab beside Sessions on the board, so that I can see every problem's stage in one place.
2. As the user, I want Backlog sorted by severity, so that the worst open problems come first.
3. As the user, I want a problem in Building only while something is really being built, so that the column means work in progress.
4. As the user, I want to open a card and read why it is in its column, so that I can trust the board.
5. (dropped 2026-10-09: no Show evidence switch; cards open one at a time.)
6. As the user, I want each problem to show the sessions that worked on it, live first, so that I can find them.
7. As the user, I want a discovery session to stay unlinked until it writes a problem, and then link by itself, so that I never have to remember to.
8. As the user, I want to link a session to a problem or an option myself with `/work`, so that work that writes no file is counted too.
9. As the user, I want a builder subagent linked to its option without linking its orchestrator's session to it, so that the chips say who did what.
10. As the user, I want a builder's branch to keep its option in Building until it is merged, even after the builder's session ends.
11. As the user, I want the merge to mark the option shipped, so that statuses stop drifting.
12. As the user, I want a session's links kept after it ends, so that a Completed card still shows which problems it worked on.
13. As the user, I want sessions on my other Mac and on the headless host to show on this Mac's Problems tab.
14. As a Claude session, I want to be told at start what `/work` does and which problems are open, so that I can link my work.

## Implementation Decisions

- **One definition of a link** in the shared package beside the pane folder's other files: the record's and the log's format, how to read and write them, and the relay's reader, as the turn has. Links name the repository by its main checkout's folder, found through git from the written path, so a worktree's links are its checkout's.
- **The hooks** are three more entries in the settings that hold the turn hooks, POSIX shell with no jq, writing by rename and appending one line to the log. They match a JSON key only after `{` or `,`, so text in the content being written can't pass for a path. They print nothing and exit 0, on every host. A subagent's id goes into a file name only if it is letters, digits, dashes and underscores.
- **The `/work` marker** is one line the script builds when it runs, so printing the script itself never links anything. The hook after Bash reads only that line's form, and the last one wins.
- **The skill** lives in the repository, beside Scratch's skill. The SessionStart line is printed only where it exists.
- **The Problems model** is pure: problems, options, links, branch ties and the Sessions cards in, columns, sorting, chips and evidence out, so it can be tested without the UI.
- **Reading, kept off the main actor.** The problem files are read when the tab opens and every 5 s while it shows, and the branch ties the same way through the read-only git rules. Each second's tick stats one log per pane, as it stats the turn file, and reads the records only when that changes. Nothing in the view reads a file. Nothing is read while the tab is hidden.
- **Saved state.** The record's links are a new optional field of the pane's saved record, so older files load and an older build ignores them. The history table is created if missing, written only by the sync, and never read by search.
- **Peers.** `status` and `sessions` gain optional links, with their coding keys, and the protocol moves to 17.

## Testing Decisions

- The column rule, sorting, chips and evidence, over made-up problems, options, links and ties, once a test target exists.
- The hooks, run in a shell with made-up inputs and a throwaway pane folder: a write under a problem, under a scratch folder with and without a problem, elsewhere, content that quotes a path, a subagent's call, an option record a write must not replace, and the `/work` marker.
- **By hand, after a restart of both Macs and a reinstall of the headless host:**
  - a new session is unlinked and its first line names `/work` and the open problems;
  - writing a problem links the session, and the card says where it came from;
  - a builder started on an option puts the card in Building, with its session's chip and the builder's type in the evidence;
  - after its merge the card is in Shipped, with the status set in the merge commit;
  - a session on the other Mac shows its chip here;
  - closing a session leaves its chip on its ended card.

## Out of Scope

- Links from transcripts, merges, tickets or Bash commands.
- Changing a status from the board.
- Opening a session from its chip. (amended 2026-10-09: built, see Solution, Session chips: ↓ onto a chip, ↩ or a click opens it.)
- The Phone page.
- Branches pushed from another Mac but not fetched here.
- Searching sessions by problem: the history is kept for it, nothing reads it yet.

## Further Notes

- **Three branches.** First, the tab from the files and branch ties alone, which changes no command line (option 03). Second, every hook, `/work`, the records, logs, chips and saved history. Third, the peers' replies and the search database's table. The second and third each need the rebuild and reinstall.
- **Once accepted:** an ADR for work links from hooks and explicit marks, never from transcripts. `CONTEXT.md` gains **Work link**. `where-it-breaks.md` gains the hooks' rules beside the turn hooks', the marker, the tab's reads, and protocol 17. The skill and the agents' steps are written with the writing-for-agents skill.
- **Prototype:** variant D, captured on the local branch `prototype/problems-kanban` at 74ff0cc, never pushed. Its links came from transcripts, which this option replaces.
