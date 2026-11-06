---
problem: sessions-cant-start-sessions-in-other-projects
title: Option 01, with Varnick giving the new session its name at the start, so the reply needs no wait and no read of Claude Code's files
summary: As option 01, but Varnick starts the new session with a name of its own making (the project's folder name and the first four characters of the pane's id, such as kestrel-3f9a), passed to claude as its display name, and gives that name in the reply at once. Nothing waits for Claude Code to register the session and nothing reads its files. The cost is that the name is the session's display name everywhere Claude Code shows one (its prompt box, the resume picker, the terminal title, which Varnick shows as the pane's title), and maybe the name the board and search use, in place of Claude's own title. That, and that the name reaches `SendMessage`, must be tried before it is built.
status: proposed
---

## Solution

Everything in option 01 holds but how the reply learns the name.

**Varnick names the session.** A Claude pane opened with `tab_open` is started with a display name of Varnick's making, given to claude with its own name flag at every start of that pane (the first, a Restart, a restore after Varnick restarts), so it never changes while the pane lives. The name is made from the record each time, so no field holds it:

- the project's folder name, lower case,
- a hyphen and the first four hexadecimal characters of the pane's id: `kestrel-3f9a` (made up).

Four characters from a random id make two live sessions of one project with the same name a matter of chance (about one in 65,000 for a pair), and Claude Code adds a suffix to a name another session already has, which would make the reply's name wrong in that case alone.

**The reply** gives the name at once, with the `s` id, as option 01's does: no wait for the session to register, and no file of Claude Code's read.

**The caller does not choose the name.** A name of the caller's choosing ("builder") would collide with another session's more often, and then the reply would be wrong unless Varnick read the file anyway.

## Trade-offs

- **Simpler and sooner.** The reply is ready as soon as the tab is made, even when claude is slow to start, and nothing depends on a file Claude Code doesn't document; the name flag is in Claude Code's help.
- **The name is the session's display name.** Claude Code shows it in its prompt box, its resume picker and the terminal title (its help says so). Varnick takes the terminal title as the pane's title, so the tab and its card may read `kestrel-3f9a` where they would have read Claude's own title. If Claude Code also records it in the transcript as a rename (unverified), the board and search rank it above Claude's title (`search-names-sessions-differently` option 03), so the session keeps that name in search after it ends. Either would make these tabs harder to tell apart than the user's own.
- **Unverified that the name reaches `SendMessage`.** Claude Code's code (read, not tried) records a name given with the flag as the user's, and the session file carries it; that `ListAgents` lists it and `SendMessage` takes it is inferred.
- **A rename still breaks it,** as in option 01: a `/rename` replaces the name, and the next start of the pane puts Varnick's back.
- **Only for `tab_open`.** Sessions started any other way keep Claude Code's derived names, so a caller in Home that is itself unnamed is still known only by its derived name (option 04 needs it).

## User Stories

1. As a session, I want the reply to give the new session's name at once, even when claude starts slowly, so that I can send it work without waiting or calling again.
2. As the user, I want the name to stay the same across Restarts of that pane, so that a session that opened it can still reach it.
3. As the user, I want a tab opened this way to be told apart from my own on the board and in search, so that I can see what a session started.

## Implementation Decisions

- **The name is passed at every start of the pane** (not stored), made from the record's folder and id, so Restart and restore keep it with no saved field. Only panes whose record says they were opened by `tab_open` get it, so one optional field on the session record marks that (older files load; an older build ignores it).
- **The reply** gives the made name without reading anything back.
- **Docs** as option 01, less the where-it-breaks entry for reading Claude Code's file, plus one for the name flag: a Claude Code that drops or renames it, or changes what a name may hold, makes the reply's name wrong with no error.

## Testing Decisions

- **Before building:** start `claude` by hand with a name in a scratch folder and check that `ListAgents` from another session lists that name, that `SendMessage` reaches it, what the terminal title is, and whether the transcript records a rename (a `custom-title` entry).
- **By hand after a restart,** as option 01, plus: the name in the reply is the one `ListAgents` lists; after a Restart of the pane and a restart of Varnick it is the same; the board's card and the search row show what the user expects.

## Out of Scope

As option 01. Naming every session Varnick starts, which would give every session a known name but take Claude's titles off all of them.

## Further Notes

- **Read on the user's Mac, 2026-11-06 (Claude Code 2.1.319):** the name flag's help says the name shows in the prompt box, the resume picker and the terminal title; Claude Code's code treats a name given with the flag as the user's and adds a suffix on a collision. Not tried.
- **Verified in the code at 29551eb:** Varnick takes a Claude pane's terminal title as the pane's title.
- **Combines with** option 01 alone, as the other way to the name. Option 04 still reads Claude Code's file for the caller's own name, so with option 04 the read is needed anyway.
