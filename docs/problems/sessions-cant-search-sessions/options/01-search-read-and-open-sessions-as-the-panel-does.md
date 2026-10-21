---
problem: sessions-cant-search-sessions
title: Three tools in every pane, that search sessions, History and bookmarks as the panel does, read a session, and open a result as ↩ does
summary: Accepted on 2026-10-20 (the user's choice, relayed by the coordinator), with History and bookmarks added by the user. Every Claude pane that has Panel access gets three tools. `find` searches what the panel's search does, Claude sessions on this Mac and the paired Macs and the History and bookmarks of every Chrome profile, ranked as the panel ranks them (words and meaning, the same floor for sessions, this Mac's open sessions first), with sessions narrowed by project, Mac, agent and time. It answers sessions first, then pages, each marked by its kind (Claude session, page or bookmark). A session has its name, project, Mac, when it was used, its tab and whether that is Open, Closed or Done, a matching excerpt, its conversation id and an `s` id when a pane here is on it. A page or bookmark has its title, address, site, when it was last visited, its description and the matching excerpt. `session_read` gives one session's conversation as text, the user's prompts and what Claude wrote, never tool calls, tool output or thinking, paged by exchange. `find_open` does what ↩ on the row does: for a session it brings its tab up, reopens a closed tab, or resumes it in a new tab, or beside the calling pane; for a page it opens the address in the user's browser, or in a Browser pane beside the calling pane. Everything a search or a read returns goes to Anthropic with the calling session, browsing history included, as the user accepted; nothing goes to TypeSafe and nothing is logged but kinds and counts.
status: shipped
---

## Solution

Three new tools join Panel access's set, so every Claude pane that lists `panel` lists them, from its next start or restart. No switch, as Panel access has none. Each call is a Panel access request on the user-only socket, answered on the main actor by the running Varnick, after the router's own checks (Varnick started, the calling pane is a Claude pane here).

| Tool | Arguments | What it does |
|---|---|---|
| `find` | `query`, `kinds`, `project`, `mac`, `agent`, `from`, `to`, `limit`, `pages` | The sessions, pages and bookmarks the panel's search would show for those words, in the same order, sessions with the tab each is in. |
| `session_read` | `conversation`, `around`, `after`, `last` | One session's conversation as text: each exchange's prompt and Claude's written text, numbered, paged. |
| `find_open` | `conversation` or `address`, `place` | What ↩ on that row does, or the session resumed, or the page opened, beside this pane. |

**Searching** runs the passes the panel runs. Sessions are ranked as the prompt line ranks them: keyword matches and the words' meaning fused by reciprocal rank, the meaning-only similarity floor (kept under a project or a time too), and the conversations a pane here is on first. A project, Mac, agent or time range keeps only those sessions before the cut, as the leading `#`, `^` and `@` words do in the panel; with a project or a time and no words, the most recently used come first. Pages and bookmarks are ranked as `?` search ranks them, keyword and meaning fused, apart from the sessions so neither takes the other's places, and with no relevance filter (below). With no words and no filter it lists the most recently used sessions, which is the nearest a session gets to the panel's empty-field list. The calling session's own conversation is left out, as the voice session's tool leaves it out.

**Telling results apart.** The reply has a Sessions section, then a Pages section, as `?` search lists them, and every result's first field is its kind: `Claude session`, `page` (from History) or `bookmark`. Sessions are named by a conversation id and pages by their address, so the id a result carries says what `find_open` takes. `kinds` asks for sessions, pages (History and bookmarks together) or both, which is the default.

**A session result** says, in this order:
- its kind, `Claude session`;
- its name, as the board and the panel name it;
- its project folder's name and its full folder on this Mac, or the paired Mac's name and the folder there;
- its agent, when it was started as one;
- when it was first and last used (a date and time, and in words for the past week);
- its tab: the tab's name, and Open, Closed or Done, "on <Mac>" for a paired Mac's, or "no tab" when none is known;
- whether a pane here is on it now, with that pane's `s` id (the one `show`, `pane_read` and `board_read` use) and its turn;
- how it matched (words, meaning or both) and a **matching excerpt**: for a keyword match, the fragment of the prompt the words are in, with the words marked; for a match by meaning, the start of the exchange that scored best; and the number of that exchange, which `session_read` takes;
- its conversation id, which the other two tools take.

**A page or bookmark result** says, in this order:
- its kind, `page` or `bookmark`;
- its title;
- its address, which `find_open` takes and WebFetch can fetch;
- its site;
- when it was last visited (a date and time, and in words for the past week), and the paired Mac's name when only that Mac visited it;
- how it matched, and the matching excerpt for a keyword match, with the words marked;
- its description as search keeps it: the page's own description, its History title when that differs, and the search terms that led to it, cut at 300 characters.

**Reading** gives a session's exchanges in order. Each is its number, when its prompt was typed, the prompt, and every text block Claude wrote before the next prompt. Tool calls, tool results, thinking, sidechains and Claude Code's own synthetic entries are left out, so command output and file contents a session read are not in it. `around` starts at an exchange (the excerpt's number) with a few before it; `after` continues where a capped read stopped; `last` gives the most recent exchanges. Each call stops at a size cap and ends with the exact call that continues it, as `outline_read` does. A paired Mac's session gives what that Mac already sends: every prompt, and Claude's last reply after each cut at 1,000 characters, marked as such. Pages have no read tool: a session fetches a page's address with WebFetch, as the voice session does.

**Opening** with `place` left out does what ↩ on the row in the panel does, through the same function:
- **A session:** it brings the tab up if it is open here, opens a paired Mac's open tab on cards, reopens a closed tab from Completed, Recent or the ended cards with every pane it had, or resumes the conversation alone in a new tab, in its own folder, as its agent, on the Mac that holds it. It follows `show`'s rules: it never brings the panel up, hides or pins it, takes no keyboard and clears nothing the user typed, and it is refused while the panel is hidden, while Settings, the Restart Varnick card or the split picker shows, and for 2 s after the user's key.
- **A page or bookmark:** it opens the address in the user's default browser, as ↩ does, but without bringing the browser to the front and without hiding the panel, which ↩ does when the panel isn't pinned. The page is there when the user switches to the browser, and the reply says so.

With `place: beside` (or `below`) a session is resumed in a new pane beside the calling session's, and a page opens in a Browser pane there, both placed as `pane_open` places a pane and with its rules, and both work with the panel hidden.

## Trade-offs

- **The same search the user has,** by the same code: a session finds what the panel would show for the same words, the paired Macs' sessions and pages included, and sees where each session lives now. A fix to ranking is a fix to both.
- **More than the panel shows, by asking.** The panel shows 5 sessions under the prompt line, and 3 sessions and its pages with `?`; a session can ask for up to 20 sessions and 40 pages. Past the panel's few, the floor still keeps unrelated sessions out, so a broad search may answer fewer sessions than it asked for. Pages have no floor, as in the panel: there are always 40 nearest ones.
- **No relevance filter on pages.** The panel's `?` search has a model judge its top 20 pages and move the relevant ones up, on TypeSafe or on this Mac. `find` gives the fused order the panel shows before that pass, so nothing goes to TypeSafe and a call never waits on a model. A page the filter would have lifted can sit lower here.
- **A matching excerpt for a session matched by meaning needs a change to the search store.** Today the store keeps each session's best score and not which exchange gave it. It has to keep the exchange's position beside each vector. The panel could show the same excerpt later; this option doesn't change the panel.
- **Reading is clean, but not complete.** Leaving tool output out keeps a read small and keeps file contents and command output (secrets that were printed included) out of it. A session that needs what a tool returned can still read the raw transcript on this Mac with its own file tools, as it can today.
- **A paired Mac's sessions read thin.** Their prompts are whole, but each exchange has only Claude's last reply, cut at 1,000 characters. Reading them whole would need a new request between Macs and a protocol change (Out of Scope).
- **Opening starts sessions and loads pages.** Reopening a closed tab or resuming a conversation starts Claude in a pane, on the user's plan, with nobody asked, as `pane_open` already can. A reopened tab shows in the panel's strip and, while the panel is up, comes to the front, as the user's ↩ would. A page opens in the user's browser with the user's cookies for that site, or in a Browser pane with Varnick's.
- **More reaches Anthropic, browsing history included.** What a search or a read returns goes to Anthropic with the calling session and stays in its transcript on this Mac: other sessions' names, folders, Macs, tab names, excerpts of the user's prompts and of Claude's replies, with `session_read` whole prompts and Claude's whole text, and for pages up to 40 addresses a call with their titles, sites, last visits, descriptions and the search terms that led to them. That is what ADR 0031 kept out ("not a transcript or a prompt that neither the card nor the screen shows"), and until now only the voice session sent History or bookmarks to Anthropic. The user accepted both on 2026-10-20. Chrome profile names and bookmark folders are not sent.
- **Every pane gets it,** with nothing to turn it off, as with the rest of Panel access. Claude Code's per-tool rules can still ask before `find_open` (inferred, as for `outline_act`).

## User Stories

1. As the user, I want to ask a session to find an earlier session in my own words and get back what the panel would show me, so that I don't have to search by hand and tell it what I found.
2. As the user, I want a session to find a page I visited or bookmarked, as my `?` search does, so that it can open it or fetch it.
3. As the user, I want every result to say whether it is a Claude session, a page or a bookmark, so that the session never mistakes one for another.
4. As the user, I want a session's search to cover my paired Macs' sessions and pages too, so that where something happened doesn't change whether it is found.
5. As the user, I want to narrow a session's search by project, Mac, agent or time, as my `#`, `^` and `@` words do, so that "last week in the relay project" finds what I mean.
6. As the user, I want each session result to say its tab and whether that tab is open, closed or done, so that the session knows whether it is live work or history.
7. As the user, I want each result to show the part that matched, so that the session can tell look-alike results apart without reading each one.
8. As the user, I want a session to read what was said in another session, prompts and Claude's answers, without the tool output, so that it can pick up where that one left off.
9. As the user, I want a session to bring a found session up in my panel, or open a found page, the way ↩ would, so that I can see it.
10. As the user, I want a session to resume a past conversation, or open a page, beside itself, so that it can use it while I keep working.
11. As the user, I want none of this to bring my panel or my browser up over the app I'm in, or take my typing, so that a session searching never gets in my way.
12. As the user, I want Varnick's log to keep none of the words searched or read, so that the log stays as private as it is now.

## Implementation Decisions

**Where the tools live**
- In Panel access's set, listed after `panel`, `show` and `keys`, so every pane that has Panel access has them (ADR 0031's amendment of 2026-10-17 is the one statement of which sessions get which sets; it gains these names). The voice session has Panel access's set, so it gets them too and keeps its own `search`. Runs, Task steps and headless hosts get none, as they get no Panel access.
- **Names:** `find`, `session_read` and `find_open`. `search` stays the voice session's tool's name, and both are listed to the voice session, so the new one can't take it.
- They are router tools like `panel` and `show`, not a `PanelAccessView`: they read no view. The router answers them through one new type beside `VoiceSearchAccess`, which runs the search passes the panel runs. The panel's session listing for the prompt line and the new tool share one ranking function, and pages go through `RelevanceSearch`'s keyword and meaning passes as the panel's `?` search does, so the two can't drift. The voice session's tool is left as it is.
- **The request is unchanged:** Panel access's request with new tool names. `PanelRequest.version` stays, the relay still refuses a line without `op`, and no peer protocol change is needed.
- **A tab another machine controls:** `find` and `session_read` only describe, so they join the tools answered there (`answersControlled`), at the user's word of 2026-10-17 for reads. `find_open` was to keep the refusal, as `show` does; the user changed that on 2026-10-21 after a hand test from his phone ("yes" to "Beside, from the phone: allowed ... Plain open, from the phone: still refused, with a message suggesting beside instead"). So `find_open` with `place` works there as `pane_open` does: the resumed Claude pane or the Browser pane is added for the controlling machine and shows on it within about 5 seconds, with the page index check and the permission rule kept. Plain `find_open` there is allowed, as on the Mac (the user's "allow" of 2026-10-21, after a hand test showed it already opened a page): a session's tab is brought up or reopened on the Mac, and appears in the phone's tab list, and a page opens in the Mac's default browser behind the app in front. The reply says it went to the Mac and that the user on the controlling device does not see it, and suggests `place`. A session still needs the Mac's panel to be up, which nobody can do from the phone, so there the refusal names `place: beside`.

**`find`**
- `query`: words, at most the panel's prompt-line limit (1,000 characters); optional for sessions, required for pages.
- `kinds`: `sessions`, `pages` (History and bookmarks) or `both`, the default. When `project`, `agent`, `from` or `to` is given and `kinds` is left out, only sessions are searched, since those narrow sessions alone.
- `project`: a folder's name (any folder of that name, on any Mac) or a full path (that folder and everything under it), as the panel's `#project` and the spoken pipeline's folder names do.
- `mac`: a paired Mac's name as the peer list names it, or "this Mac"; it narrows sessions. `agent`: an agent's name.
- `from`, `to`: ISO 8601 dates or times; a session counts when it was used at any time in the range (first prompt before the end, last after the start), the store's existing time filter.
- `limit`: sessions, 5 by default, 1 to 20. `pages`: pages and bookmarks, 10 by default, 1 to 40 (the panel's result limit).
- **Ranking, sessions:** the prompt line's: keyword and meaning, fused; the meaning-only floor (`sessionSimilarityFloor`), always, a project or a time included; this Mac's open conversations first. When a project or a time chose the sessions and no word or meaning match clears the floor, the most recently used come back, and the reply says nothing matched on its first line. (A hand test on 2026-10-21 showed that dropping the floor under a project made unrelated sessions answer as meaning matches; the option first said the floor dropped there.) No judge, as sessions never have one.
- **Ranking, pages:** `?` search's keyword and meaning passes, fused, History and bookmarks together and apart from sessions; no relevance filter, as the voice session's tool runs none (ADR 0017 as option 09 of `listening-never-answers` amended it). So `find` sends nothing to TypeSafe and never loads this Mac's relevance model.
- **Leaving out:** the calling session's own conversation, before the cut (ask for one more).
- **Tabs:** each session's tab and standing come from the same function that groups the panel's rows under their tabs. A tab's row itself is not a result; each session result carries its tab.
- **The excerpt:** the store's keyword snippet with its highlight marks turned into plain markers; for a session matched by meaning, the best exchange's text, cut at 300 characters. The store keeps each exchange vector's position beside its row id when it loads them, and the semantic ranking returns the best position with the best score. A match by both gives the keyword snippet and the exchange's number. A page matched by meaning alone has no excerpt, only its description.
- **A page's description** is the store's search text for it: the page's own description, the History title when it differs, and the search terms; its address is given once, as its own field. Not its tags, which hold Chrome profile names and bookmark folders.
- **No embedder** (no model and no server): keyword only, and the reply says so on its first line.
- **The reply:** a first line ("5 sessions and 10 pages, best first" or "Nothing matched"), then "Sessions:" with one block per session in the order above, then "Pages:" with one block per page or bookmark. Times as dates with the time of day, plus the spoken pipeline's words for the past week. Conversation ids and addresses in full. An `s` id only for a pane on this Mac, from the calling pane's own table.

**`session_read`**
- `conversation`: an id, as `find` gives it. Any session in the index may be read, not only one a search returned. The calling session's own conversation is refused (it has its own context).
- **This Mac's session:** read from its transcript, the newest copy when a session left one in two folders (the rule the index uses). An exchange starts at a typed prompt, as the index defines one; its text is the prompt, then every text block Claude wrote until the next typed prompt, in order. A task notification, a teammate's message or an interruption is shown as a one-line marker, not as a prompt.
- **A paired Mac's session:** the prompts and last replies that Mac sent, numbered the same way, with a first line saying only Claude's last reply after each prompt is kept, cut at 1,000 characters.
- `around`: an exchange number; the read starts two exchanges before it. `after`: continue from the exchange after that number. `last`: the most recent N exchanges. With none, it starts at the first exchange.
- **Bounded, and continued:** about 40,000 characters a call, a single prompt or reply cut at 8,000 with a marker, and a last line naming the exact call that continues it. Measured on this Mac (below), the median session fits in one call and about one in five needs more.
- **Live sessions:** a session that is working now is read as its transcript stands, and the reply says it is still running.

**`find_open`**
- `conversation` (a session) or `address` (a page or bookmark), one of them. Refused for the calling session's own conversation, for a conversation this Mac can't find in the index, and for an address that is not a page or bookmark in the index (so it opens only what search found) or is not http or https.
- **A session with no `place`:** the function ↩ runs on that session's row (`openMatch`), so the same tab rules apply: open here comes up with that pane focused; open on a paired Mac opens its tab on cards; closed reopens whole from Completed, Recent or the ended cards; with no tab left it resumes alone in a new tab, on the Mac that holds it, in its own folder, as its agent. `show`'s refusals apply first (panel hidden, Settings, the Restart Varnick card, the split picker, the tab strip's list, a key within 2 s), since it changes what the panel shows.
- **A page with no `place`:** opened in the user's default browser, as ↩ opens it, without activating the browser and without dismissing the panel. Refused for 2 s after a key of the user's in the panel. Not opened twice for the same address within a few seconds, so a retry doesn't open two tabs.
- **`place: beside` or `below`:** a new pane in the calling pane's tab, placed as `pane_open` places a pane and with its rules: focus stays where it was, the panel is never raised, and the pane counts as opened by this session for `pane_close`. For a session, a Claude pane resuming the conversation, which never skips permission checks when the caller doesn't. A conversation already open in a pane here is refused with that pane's `s` id ("open in s4: use show"), so it is never resumed twice on this Mac, and a paired Mac's conversation is refused with `place` (it resumes on that Mac, which needs the tab form). For a page, a Browser pane at the address, as `pane_open`'s `kind: page`.
- **The reply:** what happened ("Brought up its tab", "Reopened the closed tab", "Resumed in a new tab", "Resumed beside this pane as s7", "Opened in the browser, behind the app in front", "Opened beside this pane as s8"), the `s` id of the pane now on it, and whether the panel was hidden.
- **Not:** ending, marking or restarting a session, or typing into one.

**Refusals,** each a sentence the session can act on: Varnick is still starting; the calling pane is not a Claude pane here; an unknown conversation or address; the caller's own conversation; a bad argument (a date that doesn't parse, an unknown Mac or agent, a limit out of range, pages asked for with no words, both or neither of `conversation` and `address`); `find_open`'s view and pane refusals above.

**The log:** one line per call, as the router writes it: the tool, the outcome's kind, counts (sessions, pages, exchanges, characters) and the duration. Never a query word, a project, a name, an excerpt, an address or a conversation id.

**Docs the builder updates with the code**
- ADR 0031: an amendment, "Sessions search sessions, History and bookmarks, read sessions and open what they find". It reverses for these tools "not a transcript or a prompt that neither the card nor the screen shows", records that History and bookmarks reach Anthropic from any session that searches them (the user's acceptance of 2026-10-20), and adds the names to the amendment that says which sessions get which sets.
- ADR 0042: a line that the voice session's `search` is no longer the only path by which History and bookmarks reach Anthropic, and that option 09's question (g) is answered by `find`, with the voice session's tool left as it is.
- ADR 0018, or a line in where-it-breaks: the store keeps each exchange vector's position, and the semantic ranking still keeps one entry per session before fusion.
- `docs/privacy-and-security.md`, under Panel access: what a search and a read send to Anthropic (the list in the Trade-offs, browsing history and bookmarks with their addresses, titles, descriptions and search terms among them), what is never sent (profile names, bookmark folders, tool output in a read), that nothing goes to TypeSafe, and that `find_open` can start sessions on the user's plan and open pages with the user's cookies. Its opening section, which says what leaves the Mac, says that History reaches Anthropic through a session's search.
- `CONTEXT.md`: **Session**, **History** and **Bookmark** gain that a session can find them through Panel access.
- `docs/agents/where-it-breaks.md`, Panel access: these tools, their limits, the shared ranking functions, that pages get no relevance filter here, and that the voice session keeps its own `search`.
- README and the guide: one line each.

**State:** none saved. No new defaults key, no `sessions.json` change, no change to the search database's tables. The exchange positions live in the store's memory.

**Where it breaks.** The items of `docs/agents/where-it-breaks.md` this touches:
- **Search store:** sessions never go to the relevance filter; pages and sessions are ranked apart; several vectors map to one session row and the ranking keeps one per session before fusion; the meaning-only floor.
- **Panel access:** `--mcp` never reads or acts; the router's order; the tools answered in a controlled tab; `show`'s refusals and "never the panel's visibility"; the pane tools' permission rule and "opened by this session".
- **Focus and keys:** a view changes only through the model's own functions; a tab under a hidden panel is not swapped.
- **Peers:** nothing new is asked of a paired Mac; a paired Mac's open tab opens on cards; a conversation resumes on the Mac that holds it.

## Testing Decisions

- **No test target.** `make build`, `make check-mcp`, then by hand after the user restarts Varnick and restarts a session.
- **Seams for a test target later,** all pure: the arguments into words, kinds and a session filter; a transcript's lines into exchanges for a read (prompts, Claude's text, markers, the cut and the continuation); the best exchange's position from the ranking.
- **`make check-mcp`:** the three tools are listed wherever `panel` is, and not for a run, a Task step or a headless host.
- **By hand, in a restarted session:**
  - `find` with words the user would type gives the same sessions, in the same order, as the panel's prompt line for the same words; with `project`, the same as `#project`; with `mac`, the same as `^mac`.
  - `find` with the words of a `?` search gives its sessions and its pages in the panel's order before the relevance filter (turn the filter off to compare), each page marked `page` or `bookmark`.
  - A session matched by meaning only has an excerpt from the exchange that matched; `session_read` with `around` that number starts there.
  - An unrelated search (a recipe, a news site) answers no sessions.
  - A paired Mac's session shows its Mac and tab standing; reading it says it holds last replies only. A page only a paired Mac visited names that Mac.
  - Each tab standing: a session open here (with its `s` id), one in Recent, one in Completed, one with no tab.
  - `session_read` of a long session pages to the end with the calls it names; no tool output appears.
  - `find_open` on an open session brings its tab up; on a closed tab reopens it whole; on a session with no tab resumes it in a new tab in its folder as its agent; with the panel hidden it is refused; with `place: beside` it opens beside the caller and `pane_close` can close it.
  - `find_open` on a page opens it in the browser while the user stays in the app in front; with `place: beside` a Browser pane opens beside the caller; an address not in the index is refused.
  - Varnick's log holds kinds and counts only.

## Out of Scope

- A paired Mac's full transcript, which needs a new request between Macs and a protocol change.
- A relevance filter on `find`'s pages, on TypeSafe or on this Mac.
- Showing a session in the panel without opening it, and showing the panel's own search rows (option 03).
- Ending, marking, restarting or typing into a found session; typing into sessions belongs to `orchestration-lives-in-one-session`.
- Changing what the panel shows for a match by meaning (the new excerpt could be shown there later).
- A headless host's sessions, which session search doesn't hold (below).
- The voice session's `search`, which stays as it is. Folding it into `find` later would leave one search tool.

## Further Notes

**Decided on 2026-10-20** (the user's answers, relayed by the coordinator)
- **The approach:** "New search tools (Recommended)", this option.
- **(a) What it searches:** "Include browsing too". The user overrode the recommendation of sessions only: `find` covers History and bookmarks as the panel's search does, and the user accepted that a search sends them to Anthropic with the calling session.
- **(b) Full reads:** "Yes, minus tool output (Recommended)".
- **(d) Opening without asking:** "Yes, like Return (Recommended)".
- **Defaults the user wasn't asked, which the user can change:**
  - **(c)** Paired Macs' sessions and pages are found and opened; a read of a paired Mac's session gives its prompts and Claude's last reply after each.
  - **(e)** A resumed session opens in its own tab, as ↩ puts it; beside the calling session is the other place.
  - **(f)** Hidden runs' and the voice session's conversations are found like any session, as in the panel.
  - **(g)** No setting turns it off, as with the rest of Panel access.
- **Planner's choices made when adding pages, the user's to change:** no relevance filter on pages, so nothing goes to TypeSafe; a page opens in the browser behind the app in front rather than over it, and the panel stays as it is; profile names and bookmark folders are not sent; a page is opened only when it is in the index.

**Rough effort:** one slice for `find` and `session_read`, a second for `find_open` and the excerpt by meaning; about 800 to 1,100 lines with the docs.

**Verified in the code at bddf4ce**
- Which sets each pane gets, and that the voice session's `search` is listed for it alone and refused from other panes.
- `panel` gives the search's mode and emptiness only; `keys` refuses ↩ on a prompt, a `?` result and a Recent or paired Mac's row; `show pane` refuses a card with no tab open here; `pane_open` takes no conversation to resume, and its `kind: page` opens an http or https address in a Browser pane.
- The prompt line's ranking (keyword and meaning fused, the floor, open here first, the `#`, `^` and `@` filter applied before the cut, 5 shown), `?` search's 3 sessions and up to 40 pages with pages and sessions ranked apart, and the store's time and folder-name filters.
- ↩ on a page opens its address with the system's default browser and dismisses the panel unless it is pinned; ↩ on a session goes through `openMatch`, `openTab` and `resumeSession`.
- A page row's search text is its description, its History title, its search terms and its address; its tags are its Chrome profile names and bookmark folders.
- The grouping under tabs and the Open, Closed and Done standing; a row's second line (the keyword fragment, else the folder and when).
- The store keeps one best score per session and no exchange position.
- The router's order, the tools answered in a controlled tab, and its log line.
- **A headless host's sessions are not in session search:** a headless host answers a paired Mac's `rows` request with no rows, so no Mac holds them. That stays so here.

**Measured on this Mac on 2026-10-20** (aggregates only, by a throwaway script over the transcripts, with the reader's rules: typed prompts and Claude's text blocks, no tool calls, tool results, thinking, sidechains or synthetic entries): 445 sessions with a typed prompt. Their text is 8,300 characters at the median, 74,000 at p90, 315,000 at p99 and 780,000 at most; 95 of them are over 40,000. Exchanges: 4 at the median, 33 at p90, 405 at most. The largest single prompt or block of Claude's text in a session: 2,400 characters at the median, 5,500 at p90, 48,000 at most; 20 sessions have one over 8,000. So a 40,000-character page reads most sessions whole, and the 8,000-character cut touches few.

**Inferred**
- Automation runs' conversations are indexed, since a run's prompt is passed as a typed one.
- Claude Code's per-tool rules can ask before `find_open` while allowing the reads.
- Opening an address without activating the browser leaves the user's app in front (the system's open call takes that choice; not tried here).

**Unverified, for the builder to check first**
- That a reopened tab under a visible panel that is not key leaves every terminal's size alone (the rule `show` already follows).
