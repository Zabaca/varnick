---
title: A Task can only act in Varnick's own browser, not in the user's apps or their logged-in browser
description: Since option 01 shipped, behind Settings › Experimental › Tasks, a task on a website is carried out in a Task pane, a browser of Varnick's own whose website data starts empty. The user's goal is computer use, and websites came first. A task can't use the user's own browser and its logins, or act in any other app. Claude also never wakes on its own alarms or on the harness's signals (no progress, a loop, a budget nearly spent), which option 01 deferred to a later ticket.
impact: A task that needs the user's logins, or that happens in an app rather than on a site, is still done by hand, or handed to a Claude session that drives the user's screen one turn per step, which the user allows only with approval each time.
severity: mid
evidence: The user's concept and constraints of 2026-10-14, relayed by the coordinator (below). agent-lab's hybrid pilots of 2026-10-14. hybrid-loop (9c97aec) and hybrid-loop-2 (1d41b21) cover spoken search-and-answer. hybrid-browser 1 to 13 cover a made-up shop, with design summaries in hybrid-browser-11 (9b24a0b) and hybrid-browser-13 (9dbca12). Also agent-lab's learnings file. Code and docs were read on main at cec89bd. Nothing was run in Varnick for this problem.
status: open
---

## What the user wants (2026-10-14)

**The concept, in the user's words:**
- the harness owns the loop;
- state is split. System 1 state is what Jev reads, System 2 state is what Claude reads, and Claude can write into System 1's;
- Jev takes every action it can and never writes text;
- Claude writes and steers. It wakes when Jev asks, on alarms or on harness signals;
- the two work independently and together.

**What the pilots added:**
- the harness does the heavy lifting. It keeps a best-first frontier with a peek at every link, a value bank for forms, checks in code and rules for getting stuck;
- Jev's 0.7 bar works for choosing actions, but its judgements of content are good only for ranking;
- Claude has to be shown the harness state and the trail.

**Scope and order:**
- **The goal is computer use,** for example "navigate to X and create an account" or "find the price on this site". Websites come first.
- **Search-and-answer is out.** It is nearly one step, and the loop measured no gain there (below).

**Constraints the user set:**
- **Agents never drive the user's screen** without approval each time. The design needs an exception the user agrees to, or a surface of its own. The pilots used a headless browser with a fresh profile. A surface Varnick owns is to be weighed against the user's real browser through Accessibility, and one recommended.
- **Credentials, terms and final submits go to the user.** Passwords never enter either model's state. Whatever reads the page must redact password fields: the pilots found a leak through the accessibility snapshot.
- **No daemons or LaunchAgent spikes inside a session.** XProtect once killed a Claude process that ran installs, launchctl and a downloaded binary together (ADR 0013).
- **Behind a switch in Settings › Experimental.** Off means nothing runs.
- **Jev is the intended System 1.** TypeSafe's allowance for Jev on the user's account was used up, so the pilots ran local Clef-flash in its place. Real Jev speed on these calls is unmeasured. The design has to say what happens when neither Jev nor Clef is there.
- **The loop's own open questions become follow-up tests:**
  - peek when a page has several plausible links, even when Jev is confident (the dead-end regression);
  - real sites, with logins, scripts and many links;
  - real Jev speed;
  - larger samples;
  - cutting Claude's blocking guidance, 62 to 84% of the time.

## Why this is its own problem

- **`listening-never-answers`** is about answering a spoken question from History, Bookmarks, sessions and the web. Its option 07 pipeline is shipped. The same loop, tried there first (hybrid-loop, -2), got fewer answers right or used more Claude turns than Claude alone, and the user put search-and-answer out of scope. A task may later be started by voice (option 04 here), but the work is not answering.
- **`sessions-cant-see-or-act-on-the-screen`** gives Claude sessions in panes tools for the user's own screen: look, point, click, type, drag and window. Permissioning is deferred until `panes-share-launchys-permissions` cuts the grants panes inherit. Here the actor is Varnick itself, carrying out a task the user hands it, under gates the user set. The recommended surface is Varnick's own, not the screen. Those tools are only the substrate of option 02.
- **`spoken-requests-cant-see-the-screen`** points at one thing in the window in front. It is one step, and it never acts.
- **`sessions-cant-read-or-drive-varnick`** lets sessions read and drive Varnick's own panel. It has nothing to do with sites.

## What the pilots found

All of it comes from agent-lab, on 2026-10-14:
- the sites were made up, a shop and a store, served on this Mac;
- System 1 was local Clef-flash 4-bit standing in for Jev, charged on a fitted Jev clock of about 115 ms a call. Clef's own time is about twice that in real time;
- System 2 was Claude Haiku 5.5 through `claude -p`;
- each figure comes from 1 or 2 runs.

Read it as direction, not proof.

**Where it pays.**
- **Not on search-and-answer.**
  - hybrid-loop: the loop used 0.9 fewer Claude turns a question than Haiku alone with search tools, but got 1.5 fewer of 8 right, at the same time.
  - hybrid-loop-2: with a turn-0 plan and an own-first rule it matched Haiku on answers, but used more Claude turns and answered 1.9 s later.
- **On long sequential tasks:** navigating a site, filling a form over several pages, finding something behind several links.
  - The final setup (hybrid-browser-13, two runs a task) solved 10 of 10. Claude alone solved 7 of 10: it failed the odd site twice and the misleading page once.

| Task (made-up shop) | Claude alone: solved, Claude calls, simulated s | Hybrid: solved, Claude calls, simulated s |
|---|---|---|
| Busy page (26 links) | 2/2, 11–17, 11.3–11.7 | 2/2, 2, 3.0–3.2 |
| Misleading preview | 1/2, 4–6, 6.3–7.5 | 2/2, 3–4, 4.8–8.1 |
| Oddly named section | 0/2, 16–22, 16.3–51.0 | 2/2, 3, 3.8–4.3 |
| Three-page checkout | 2/2, 36, 24.3–33.9 | 2/2, 10–11, 16.4–17.2 |
| True dead end | 2/2, 19–20, 16.2–17.0 | 2/2, 6–11, 13.1–23.7 |

**The harness does most of the work.**
- **The frontier.**
  - System 1 peeks at every body link: a plain fetch of its title, headings, first lines and links, cached, about 0.3 s a decision with loads in parallel. It scores each preview, as a ranking only.
  - The harness follows the best link not yet explored. It looks deeper on a page that only links onward, and backs up to the next branch after a failed landing or a failed read, within a budget of depth 3 and 8 follows.
- **Reads decided in code.**
  - A question with an answer shape (how much, how long, a cost) passes only a read that has a number.
  - Markers such as "being updated" fail a read.
  - A failed read tries the page's other text blocks first.
  - Only reads the code can't decide go to Claude: once in the final runs, and right both times.
- **Forms and the value bank.**
  - The task's values are asked of Claude in the background when the task starts. The bank is keyed by meaning, and a correction replaces the old entry.
  - Fields are filled by id, and System 1 maps the rest: new fields, select and radio options.
  - Only fields that can't be mapped, or that failed, go to Claude, in the background. System 1 waits only when it is about to submit with a value still coming.
- **Checks in code:** digits compared for phone and ZIP fields, and passwords redacted from the snapshot.
- **Rules for getting stuck:**
  - no progress (the same page for 3 steps) bars the action and goes back;
  - a loop bars the way in, but must not bar the only way into a flow;
  - self-links are never offered.

**System 1 chooses and ranks. It doesn't judge content.**
- It picks the next action from a list the harness writes, ranks links by their previews, maps form fields and decides when to submit or read out.
- Its top choice at a P of 0.7 or more was right on 61 of 61 decisions in the early pilots. Lowering navigation to 0.6 derailed the checkout.
- Its judgements of content were wrong in every direction:
  - promising previews scored as holding the fact (0.85 to 0.96);
  - a footer read as the answer;
  - the right paragraph rejected (0.16).
- Its weak spot: confident on a page, it clicks without peeking. That is how it walked into the dead end in hybrid-browser-13, which hybrid-browser-10 had skipped in 5.1 s.

**System 2 writes values, judges what code can't, and steers when System 1 is unsure.**
- **What it needs to see:** the harness state (jobs in flight, the bank, checks, bars), the whole trail, the whole page the first time, and replies such as wait and fix_field. Without them its guidance misled about half the time. With them it was right on the checkout.
- **Two sessions per task.** A long-lived session per role, values and guidance, kept the two from queueing behind each other.
- **Blocking guidance is still 60 to 85% of the hybrid's time.**

**Tried and dropped:**
- System 1 as the controller of search-and-answer;
- a turn-0 Claude plan;
- alarms for expected states. Alarms stay for surprises only, filtered by a System 1 question;
- Claude's advice as the answer to being stuck;
- peeking only the top 3 links by name;
- a System 1 fact check as a verdict;
- backing out of pages that only link onward;
- System 1's read-out check as the final word.

**What holds only because the shop was made up:**
- **The gates were the shop's own button names:** "Create account", "Continue to payment", "Place order", and "terms" in a checkbox's name. They say nothing about recognising a final submit on a real site.
- **The answer shape and the markers were word rules** on the task and the page. ADR 0037 rules such rules out of spoken requests' decisions.
- **Peeks were plain fetches of server-rendered pages.** A page built by scripts would preview empty (inferred).
- **Every page loaded in about 300 ms** (charged), with no login, no bot check and at most 26 links.
- **The browser was headless Chrome through Playwright,** reading the page from Playwright's accessibility snapshot, whose parser hid links inside text blocks until hybrid-browser-7.

## Today

Verified in the code and docs at cec89bd unless marked.

**What acts for the user**
- **Hey Varnick never acts.** A spoken request is answered aloud and with the Arrow, and "nothing is ever opened, clicked or focused" (the glossary's Spoken request, ADR 0015).
  - The route's "do" answer catches requests for things Varnick can't do (a timer, a message, music) and gives the can't-do line.
  - Inferred, not tried: "create an account on this site", said aloud, gets that line or a search.
- **Screen access** gives Claude sessions in panes look, point, click, type, drag and window on the user's screen (ADR 0023).
  - Each action shows the Arrow for a second, then brings the target app to the front, one action at a time across sessions.
  - It reads a window's Accessibility tree and never a field's value. A picture of the window paints password fields black.
  - Chrome often leaves a page's content out of its tree, so Chrome pages are read from a picture's text (ADR 0021).
  - Each step a session takes is a Claude turn.

**Browser panes**
- A Browser pane is a `WKWebView` with an address bar, picked from the split picker. It lives across the panel hiding and showing.
- It is made with a plain `WKWebViewConfiguration`, so every Browser pane shares WebKit's default website data: cookies, storage and logins. That default is inferred from WebKit's documentation. The code sets no store.
- No code in Varnick reads a page's DOM or acts in one.

**Jev in Varnick**
- Three callers each build their own request to TypeSafe's `systemone` endpoint:
  - the route of a spoken request, many named questions in one call, pinned to `jev-1.13.0` with a 1.5 s deadline;
  - the relevance filter's judge;
  - the screen picker.
- Jev is asked only with the relevance filter on TypeSafe and a key saved (ADR 0016, 0037). Otherwise the same questions go to the Text generation model.
- Measured for those features, not for this loop: about 0.11 to 0.12 s a call (the screen-pointing eval, the route).

**Models on this Mac**
- Gemma 4 E2B for Text generation, the Qwen3 embedder, and the Laya reranker through Varnick's own MLX port (ADR 0006).
- **No Clef.** Clef-flash ran in the pilots through Python MLX outside Varnick: a 9B model, 4-bit, about 7.2 GB at its peak, 0.2 to 1.1 s a call by request size on an M3 Ultra Mac (agent-lab clef-flash-local).

**Claude in Varnick, outside panes**
- **The text helper** (ADR 0029) runs the user's own `claude` on Haiku 5.5 through the bundled Bun and the Agent SDK:
  - one run for each text, with no conversation and no saved transcript;
  - no tools, except the web answer's search;
  - a 4 s deadline, 15 s for the web answer.
- **A kept-open conversation was passed over for Text generation** (`text-generation-ignores-the-claude-subscription`, option 04): one conversation for every request grows without end and lets each answer see unrelated ones.

**The rest**
- **Settings › Experimental** holds two switches, Problems board and Outline, each a `Settings` property in UserDefaults, off by default. The `!` list leaves out the command of a switch that is off. `CODING_STANDARDS.md` asks for a switch of its own for each experimental feature.
- **Commands take no argument.** `!listen`, `!transcript` and the rest each run one action.
- **Speaking.** `Speaker` plays a line on Varnick's own audio engine, inside the span that keeps Listening from hearing it, in the installed voice or ElevenLabs.
- **Notices** (`SessionNotifier`) come from Claude panes' turns only.

## Left to decide

- **The surface:**
  - a browser of Varnick's own in a pane (option 01);
  - the user's own browser and apps through Accessibility, under an exception the user approves for each task (option 02);
  - headless Chrome with a profile of Varnick's own, as in the pilots (option 03).
- **System 1:** Jev on TypeSafe, or Clef on this Mac (option 05), and what runs when neither is there.
- **System 2's channel:** the text helper as it is (a fresh `claude` for each message), or a conversation kept open for each task.
- **How a task starts:** a Command, a pane, or Hey Varnick (option 04).
- **What goes to the user on a real site,** and how a final submit is recognised there without the shop's button names.
- **The code checks against ADR 0037:** the answer's shape and the markers were word rules.
- **Which follow-up tests come before building,** and which run on what is built.
- **Whether the task's browser keeps its data,** a login included, after the pane closes.
