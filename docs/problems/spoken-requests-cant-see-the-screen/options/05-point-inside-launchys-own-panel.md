---
problem: spoken-requests-cant-see-the-screen
title: When the panel is on screen, point inside it, built from Launchy's own state rather than Accessibility
summary: Option 01 never reads Launchy's own windows. So with the panel open and a session's name on it, "where is Kestrel on my screen" reads the app behind the panel and answers "I can't see that on your screen." This option looks in the panel first whenever it is on screen. Launchy lists what the panel shows from its own state, with each row's or control's kind, and takes the frames from SwiftUI's layout. The user's own names (sessions, folders, projects, Macs, problems) are matched on this Mac, by the request's words and then by the panel's session ranking, and never sent. Launchy's own control names go to the same Jev call option 01 makes. So do page rows, but only those TypeSafe already judged for the search on screen. A match gets option 01's Arrow. Nothing found in the panel falls through to option 01's read of the app behind it.
status: proposed
---

## Solution

A request routed to `screen` while the panel is on screen looks in the panel first:

1. **List the panel's targets from Launchy's own state.** Launchy doesn't use Accessibility on itself. It lists:
   - the header's tabs and badges;
   - the search field and the pin button;
   - the result rows, session rows, prompt line, suggestions and commands that are visible now;
   - on the board, its tabs, columns and cards;
   - in Settings, its rows' titles.

   Each target carries a kind: **Launchy's** (a name Launchy itself wrote: "Settings", "Pin", "Running", "Problems") or **the user's** (a page's title and site, a session's title, a folder, a project, a Mac, an agent, a problem's title).
2. **Match the user's names on this Mac.** The request's search words (the strip Hey Launchy already uses) are matched against each user target's title and names. The match is by words in order, or the name's words joined, as the decide step already matches session folders.
   - No word match: the visible sessions are ranked with the panel's own session search (keyword and meaning) on those words. The best one above the session floor wins.
   - A match is pointed at, and nothing about it leaves the Mac.
3. **Ask Jev about the rest.** Launchy's own names, and page rows TypeSafe already judged for the search on screen (title and site only), go to option 01's Jev call, with "Launchy" as the window's title. `present` at 0.5 or more points.
4. **Fall through.** Nothing in the panel: option 01 reads the frontmost other app, as it does today.

The **Arrow** is option 01's, drawn over the panel. The panel keeps key, and focus and selection don't move.

## Trade-offs

- **It answers what the user is looking at.** The panel floats over everything, so while it is shown, a request about the screen is usually about it. Today such a request gets "I can't see that on your screen."
- **The user's names never leave the Mac.** Sessions, folders, projects, Macs and agents stay on this Mac, as ADR 0016 and 0017 keep them. Problem titles and Recent rows do too. So does any page row TypeSafe hasn't judged.
  - Page rows add nothing new to TypeSafe. With the filter on TypeSafe, the panel's own search already sent the title, site and description of the 20 pages it judged.
  - The session ranking embeds the request's words through Search embeddings, on this Mac or the user's own server, as a spoken search already does.
- **Matching names locally is weaker than Jev.** ADR 0019 set code matching aside as the only chooser: "where do I approve this" never matches "Allow". For the user's names it is the private choice, and those names are what a request about the panel usually says ("where's Kestrel", "the session about the reranker"). The session ranking covers paraphrase for sessions only. A paraphrased project name or problem title is missed. Unmeasured.
- **State, not Accessibility.**
  - Launchy's own Accessibility tree is answered by its own main thread, the one that also draws the panel.
  - SwiftUI's tree would give rows as text without saying which is a session and which a page. Launchy then couldn't keep sessions away from TypeSafe.
  - Its own state knows each target's kind and the row behind it.
  - The cost: each view that can be pointed at has to report its frame. That is new plumbing, in the shape the tab drag already uses.
- **A request about the app behind the panel costs one more Jev call** (about 0.12 s, measured for option 01) before it falls through.
- **An amendment to ADR 0019:** code matching becomes the chooser for the user's own names inside the panel, and Jev stays the chooser for everything that may be sent.

## User Stories

1. As a Launchy user with the panel open, I want "where is Kestrel on my screen" to point at the Kestrel tab, so that I find it among a dozen tabs.
2. As a Launchy user, I want "which one is the session about the reranker" to point at that session's row in the session list or on the board.
3. As a Launchy user, I want "where's the settings button" or "where's the pin" to point at Launchy's own controls.
4. As a Launchy user, after a `?` search, I want "where's the page about shader caching" to point at that result row.
5. As a Launchy user, I want my session, project and Mac names never sent anywhere to be pointed at.
6. As a Launchy user with the panel open over another app, I want a request about that app still answered from that app.

## Implementation Decisions

**When the panel is looked in**
- **When:** a request decided as `screen` while the panel is on screen. That means it is visible, on the active Space, and not wholly covered (its occlusion state says visible). A pinned panel under other windows isn't.
- **Gated as option 01:** Point at the screen on, which needs the TypeSafe gate. The local match sends nothing, but routing to `screen` is Jev's.
- **The order:** the panel first, then option 01's read of the frontmost other app. That read is unchanged.

**Targets, from state**
- **One registry on the launcher model** holds each pointable view's target: an id, its kind, its name or names, and its frame. Views fill it while they are on screen. It is a plain property, not published, like the tab drag's frames, so recording a frame never redraws the panel.
- **What reports a target**, by what the panel shows:
  - the session list: tabs, paired Macs' sessions, Recent rows;
  - a `?` search: result rows, with the section labels as Launchy's;
  - the prompt line, the suggestions and the commands;
  - a tab: the header's tabs, its badges (project, Mac, agent) and the pin;
  - the board: its tabs, columns and cards;
  - Settings: its rows' titles.
- **Names by kind:**
  - **Launchy's:** the control's or label's own words, as Launchy wrote them.
  - **The user's:** a page row's title and site; a session's title, folder, project word, Mac and agent; a problem card's title.
  - Never a terminal's contents, a prompt's text, a Settings value (an address, a folder path, a key) or a session's prompts.
- **Visible only.** A row inside a scrolling list counts when its centre is inside the list's visible frame, as option 01 keeps an element whose centre is inside the window. The list reports its own frame for this.

**Frames**
- **Each target reports its frame** in SwiftUI's global space, through a geometry reader or a geometry change, the way the tab drag reports its tabs' frames.
- **One conversion,** beside option 01's: the panel's content coordinates (top-left origin) to the panel's window, then to the screen. The Arrow takes it from there.
- **Read again before drawing,** as option 01 does: a target that has left the registry (the row scrolled away, the panel hid) is gone, and nothing is drawn.

**Choosing**
- **The user's names, on this Mac:**
  - The request's search words are matched against each user target's names: words in order, or joined, ignoring case and punctuation, with the same rules as the decide step's folder match (three letters or more, not only stop words).
  - Several matches: the first in reading order, top to bottom and left to right, so a tab comes before its Recent row.
  - No match: the visible session targets (tabs, session rows, board cards) are ranked by the panel's session search passes on the same words. The best one above the session floor is taken.
- **Jev, for what may be sent:**
  - Launchy's own names, plus page rows whose relevance TypeSafe judged for the current search: the panel's filter ran on TypeSafe and finished, and the row carries its judgment. Title and site only.
  - One call, option 01's `target` and `present`, with "Launchy" as the window's title. Each description is the name and the kind ("Settings (button)", "Running (column)", "Rust lifetimes, doc.rust-lang.org (page)").
  - `present` at 0.5 or more points.
- **Neither:** fall through to option 01.

**The note**
- Option 01's fixed sentences, with the kind in words: "Here's the Kestrel tab.", "Here's the session Kestrel.", "Here's the Settings button.", "Here's the page Rust lifetimes."
- Spoken and written to the transcript as option 01's are. A session's title in the transcript is what a spoken answer already puts there.

**Logs and the command line**
- **The timing line** adds where the pick came from: panel words, panel ranking, panel Jev, or fell through. Never a name.
- **`--ask`** runs without the panel, so it can't exercise this.
- **A `--panel-targets` dump** of the registry was considered and left out. It would print the user's names, and the hand checks cover it.

**State**
- Nothing saved. No new setting: it is part of Point at the screen.

## Testing Decisions

- **No test target.** The pure seams are:
  - the targets from the panel's state (mode, rows, tabs, board) in, the kinds and names out;
  - the local match: the request's words and the targets in, a target or none out;
  - which page rows may be sent (the filter's backend, its status and the rows' judgments in);
  - the frame conversion (the panel's frame and a global rect in, a screen rect out).
- **By hand, after the user restarts Launchy,** with Point at the screen on:
  - Open a tab, so the header shows several. Ask "where is" one tab's name "on my screen". The arrow is on that tab, and the panel keeps key and its tab.
  - With the empty field, ask for a Recent session by a word of its title, then by what it was about.
  - Run a `?` search with the filter on TypeSafe. Ask for one of the first pages by its topic, and for a session row in the results.
  - Ask "where's the pin" and "where's settings".
  - Open the board and ask for a card by its session's name.
  - With the panel open over System Settings, ask for a switch there. The arrow is in System Settings.
  - Pin the panel and cover it with another window, then ask for a tab. It falls through to the app in front.
  - Launchy's log holds no names, and nothing names a session in the TypeSafe request (the timing line says "panel words" or "panel ranking").
  - On a second display and with the panel resized, the arrow lands on the row.

## Out of Scope

- **"Which session needs me"**: pointing at the tab or card whose turn waits on the user. That is a question about **Turn**, not about what the screen shows. It must be answered with the panel hidden too, so it belongs with `sessions-finish-unnoticed`, which already reads turns. Once this option's registry exists, pointing at the card when the board is shown is a small addition there.
- Accessibility on Launchy's own windows.
- Inside a pane: a terminal's text, a web pane's page, a custom app.
- Opening, selecting or activating the target. The Arrow only points.
- Sending session, project, Mac, agent or problem names to Jev.

## Further Notes

- **Seen 2026-10-09, after option 01 shipped (merge 63807cc).** With the panel open and a session's name on it, a request for that name "on my screen" got "I can't see that on your screen". Option 01 reads the frontmost other app whenever Launchy has focus (`ScreenReader.focusedApplication`). The request and the name are the user's and are kept locally.
- **ADR:** an amendment line to ADR 0019, on acceptance. Inside Launchy's own panel, targets come from its state. The user's names are matched on this Mac by words or the session ranking and never sent. Only Launchy's own names, and page rows TypeSafe already judged, go to Jev.
- **`where-it-breaks.md` on acceptance:**
  - the registry is a plain property, never published;
  - what a target's names may hold, by kind;
  - the "already judged" rule for page rows;
  - the one panel-to-screen conversion.
- **Verified in the code at 63807cc and after:**
  - option 01's read skips Launchy's own process;
  - the tab drag reports tab frames through a preference in a named space;
  - the panel's filter records its backend and status for the results on screen, and judges the first 20 pages;
  - a row carries its relevance;
  - the decide step's folder match;
  - the Arrow sits at screen-saver level, above the panel, and ignores the mouse.
- **Inferred:**
  - SwiftUI's global space is the panel's content coordinates with a top-left origin;
  - Launchy's own Accessibility tree would come without kinds and would load its main thread;
  - how often requests about the panel name what it shows;
  - the session ranking's floor is right for picking among a few visible sessions.
