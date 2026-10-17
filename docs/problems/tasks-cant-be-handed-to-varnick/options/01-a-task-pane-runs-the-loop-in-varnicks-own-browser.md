---
problem: tasks-cant-be-handed-to-varnick
title: A Task pane, a browser of Varnick's own where the harness runs the loop, Jev chooses each step and Claude writes and steers
summary: The first slice, behind a Tasks switch in Settings › Experimental. `!task`, or the split picker's Task tile, opens a Task pane. It is a browser of Varnick's own, whose website data is empty when the pane opens and gone when it closes, with a column of steps beside the page. The user opens a site and types the task, such as finding a fact on it ("how much is delivery to Canada") or filling its forms ("create an account for Robin Vale"). Varnick carries it out on the pilots' design. The harness owns the loop: a best-first frontier that peeks at every link, a value bank for forms, checks in code and rules for getting stuck. Jev picks each step from a list the harness writes and acts at 0.7. Claude, through the user's own Claude Code, writes the values and steers when Jev is unsure, seeing the harness state and the trail. It reads and acts inside the page, never on the screen, so it needs no permission. The user types passwords, codes and card numbers into the page, ticks terms and allows every form submit. A click or a key in the page pauses the task, and Stop ends it. Short lines are spoken at milestones. Without Jev, Claude makes Jev's choices, more slowly. Recommended. Rough effort is a spike of one or two days, then about three weeks.
status: shipped
---

## Solution

### Starting a task

- **The Tasks switch** in Settings › Experimental, off by default. With it off, the command and the tile aren't listed, no task can start, and a running task stops at its next step.
- **`!task`** opens a new tab holding one Task pane. The split picker's **Task** tile adds one beside other panes. Both are listed only while the switch is on.
- **The pane opens with its address bar focused,** as a new Browser pane does. The user opens the site, then types the task in the **task line** under the address bar and presses ↩.
- **A task starts on the page the pane shows.** "Find the price of the 1.7 L kettle on this site" means the site in the pane. Varnick doesn't guess an address from the task's words. With nothing loaded, the task line says to open the site first.
- **One task runs at a time on this Mac.** `!task` while one runs shows its pane.
- **When a task ends, the pane stays, with its browsing intact.** The user can carry on by hand, or type another task. A second task in the same pane keeps the first one's login and cart, so "create an account" can be followed by "find my order".

### What the user sees

The Task pane is the page, with a column of **steps** beside it, newest at the bottom. The user watches the page change as the task goes.

- **Each step is one line,** written by Varnick from what happened, never by a model:
  - "Opened Kettles (Jev 0.82)";
  - "Peeked at 12 links";
  - "Backed up from Gift cards: no number";
  - "Asked Claude: unsure between Help and Delivery";
  - "Filled 6 fields";
  - "Phone fixed: digits didn't match";
  - "Read 'Delivery to Canada costs $15'".
- **Who acted** is marked on each line: Jev, Claude, a rule of the harness, or the user.
- **A step that waits on the user** stands out and says what is needed, with its buttons:
  - "Type your password in the page, then Resume";
  - "Tick the terms box if you agree";
  - "Submit Shipping details? Allow / I'll do it".
- **The pane's tab title** carries the state: running, needs you, done, stopped, or gave up.
- **At the end:**
  - a finding task shows the text that passed, marked in the page and quoted in the steps;
  - a form task shows the page it ended on;
  - either way, how many Jev and Claude calls it took and how long.
- **Spoken lines,** with Speak progress on in the pane (on by default):
  - "Started", "I need you: your password", "Found it: Delivery to Canada costs $15", "Done", "Stopped" and "I'm stuck on Help";
  - "Opening Kettles" as Jev moves from page to page, only while the Task pane isn't on screen. A newer line replaces one not yet begun, so lines never pile up.
  - Each line is filled in from the step's facts (a link's own label, the passing text when it is short). Jev never writes one.

### How the loop runs

The harness owns the loop. Each turn it reads the page, writes System 1's state and its list of possible actions, and asks Jev one call. Every one of Jev's choices, and every one of Claude's replies, goes through the harness, which carries it out or refuses it.

**System 1's state, what Jev reads:**
- the task;
- the page's actions, each with an id and its label: links (links inside text blocks included), buttons, and "go back", "ask Claude", "the task is done" and "read text block N as the answer";
- each link's preview score;
- the value bank's meanings and values, never a password;
- what Claude suggested or hinted, and the alarms it wrote;
- the last few decisions;
- whether Claude is thinking.

**Jev's call each turn:** a choice among the listed actions, a yes-or-no on whether the task is done, and a yes-or-no for each live alarm, in one request.
- **At 0.7 or more, the harness acts on the choice.** Below that, it asks Claude and waits.
- **Jev's scores of content only order things:** previews, text blocks, field mappings. They never decide that a fact was found.

**The frontier:**
- On each page, the harness fetches every same-site link in the page's body, at most 30, never a button, a form or the header and footer. It does this in parallel, with the pane's own cookies, cached by address.
- Jev scores each preview as a ranking.
- The harness follows the best link not yet explored. It looks deeper on a page that only links onward, and backs up to the next branch after a failed landing or a failed read, within depth 3 and 8 follows.
- **On a page where several links score near the top, it peeks before clicking even when Jev is confident.** That is the fix proposed for the dead-end regression. Its exact rule is set by follow-up test 1 below.

**Reads:**
- **The shape of the answer is asked of Jev once, when the task starts:** a number (an amount, a price, a duration, a count), a date, or none.
- **Code checks a read against that shape.** A how-much task passes only a text with a number.
- A read that fails tries the page's other text blocks, in Jev's order, before the harness leaves the page.
- **A read with no shape to check goes to Claude:** "does this text state the answer?".

**Forms:**
- **When the task starts, Claude writes the value bank in the background,** from the task's own words. It is keyed by meaning ("full name", "postcode"), and a correction replaces the entry with the same meaning.
- **"Only you" for anything only the user can give.** Claude marks a password, or the choice to accept terms, that way.
- **Filling:**
  - a field whose id is in the bank is filled by the harness;
  - Jev maps a new field, a select or a radio to a bank entry, or to "no entry";
  - "no entry", or a mapping under 0.7, sends that field alone to Claude, in the background.
- **After each fill the harness reads the field back.** Phone and postcode digits are compared in code. Names, addresses and options get a yes-or-no from Jev.
- **After a submit with errors,** only the failed fields and their messages go to Claude.
- **Jev waits** only when it is about to submit with a value still coming.

**Rules for getting stuck:**
- the same page for 3 steps bars the action that kept it there, and goes back;
- a loop bars the way into it, unless that is the only way into a flow;
- a link back to the same page is never offered.

**Budgets:** 40 System 1 turns, 20 Claude messages and 5 minutes for a task. Past any of them the task stops as "gave up", says why, and leaves the page to the user.

**System 2's state, what Claude is shown when it wakes:**
- the task;
- the harness state: jobs in flight, the bank, the checks and their results, barred actions and why, alarms that fired;
- the whole trail: every page in order, what was done there and what it led to;
- the page whole the first time it sees it, then only what changed;
- Jev's scores.

**When Claude wakes:**
- **When Jev asks,** by its choice or by falling under 0.7. Jev waits for this one.
- **On a harness signal:** no progress, a loop, or a budget nearly spent. Jev carries on meanwhile.
- **When an alarm it wrote fires.** Jev carries on.
- **For an undecided read.**
- **For values,** at the start and for fields. These run in the background.

**What Claude can write back:**
- **Guidance:** one listed action, which the harness marks "Claude suggests this" before Jev decides again, plus a one-line hint.
- **An action of its own, or a wait:** "a fix is coming".
- **A field fix,** or bank entries.
- **An alarm, for a surprise only.** Jev reads each new alarm against the plan, and one that only describes the expected path is dropped.
- **A yes or no** on an undecided read.

A reply about a page Jev has already left becomes a hint, not an action.

### What goes to the user

- **Passwords, one-time codes and card fields are typed by the user, in the page.**
  - The harness recognises them from the field itself: its type, or its autocomplete purpose (a current or new password, a one-time code, any card field).
  - A field that was ever of password type stays one, so a "show password" button doesn't expose it.
  - The harness never reads, logs or fills their values, and the snapshot both models read says only "a password field, filled" or "empty".
- **Terms:** a checkbox Claude marked "only you" is left for the user to tick.
- **Every form submit asks, except a search box's:** "Allow" lets the harness press it, and "I'll do it" waits for the user to press it in the page.
  - That asks more often than "the final submit" alone. On a real site, recognising the final one isn't measured (follow-up test 5), and the pilots' own rule was the shop's button names.
  - A checkout over three pages asks three times.
- **Nothing is bought, sent or created without the user pressing Allow or the button.**

### Taking over and stopping

- **A click or a key in the page pauses the task** before its next action. The step reads "Paused: you're using the page".
- **Resume** hands it back. The harness reads the page again, notes in the trail that the user acted between the two pages, and carries on from where the page is now.
- **Stop,** a button in the pane and a key the panel doesn't already use, ends the task at once:
  - Jev's and Claude's calls in flight are cancelled;
  - both Claude conversations end;
  - the page stays as it is, for the user.
- **Closing the pane, its tab or Varnick ends the task,** as does turning off the switch.

### Without Jev

- **Jev is used as the other TypeSafe features use it:** only with the relevance filter on TypeSafe and a key saved.
- **Without it, Claude makes Jev's choices,** through the same harness, the same checks and the same gates. That covers every choice, every preview ranking and every field mapping, sent to the guidance conversation. The pane says "Without Jev: each step asks Claude".
- **The same happens when Jev fails mid-task** (an error, no answer in time, the allowance used up), from that step on.
- **This Mac's Gemma is not used in Jev's place,** even when it is the Text generation model. Its answer probabilities were measured not to separate right from wrong (the screen-pointing eval), so a 0.7 bar would mean nothing.
- **Clef on this Mac is option 05, later.**
- **Without Claude Code logged in, no task starts.** Claude is System 2 whatever Text generation is set to.

### What leaves the Mac

- **To TypeSafe, with Jev in use:**
  - the task;
  - each page's action labels;
  - previews (titles, headings, first lines);
  - text blocks being read;
  - field labels and the value bank's values;
  - Claude's hints and alarms.
- **To Anthropic, through the user's Claude Code:** the same, plus the trail, the harness state and whole pages.
- **To the site:** what the task types into it, as the user typing would.
- **Never to either model:** a password, a one-time code or a card field's value. Those are typed by the user and never read.
- **Nothing of the user's own browsers.** The pane's website data is its own and empty at the start, so no cookie or login of theirs goes to a site, and none of their History goes to a model.

## Trade-offs

- **For:**
  - **The design the pilots measured,** at the place it pays: long tasks on a site.
  - **No permission and no screen.** It works inside Varnick's own window, with no Accessibility, no Screen Recording, no posted events and no app brought forward. So it needs no exception to the user's rule, and works while the user uses the Mac.
  - **The user sees every step and can step in by touching the page.** Passwords are typed where they belong and never pass through a model.
  - **Nothing of the user's own browsing is at risk.**
- **A different engine from the pilots.** WebKit, not Chrome, and Varnick's own reading of the page, not Playwright's snapshot. The port has to be re-measured on the practice shop before its figures can be claimed.
- **No logins the user already has.** Every task starts logged out, which suits "create an account" and public facts but not "check my order on a site I use". Keeping data per site is later.
- **Slower and dearer without Jev.** The fallback is a Claude call per step, close to Claude alone, which the pilots measured at 4 to 36 calls a task.
- **Asks at every submit.** Safe, but a busy form flow asks often until follow-up test 5 allows something narrower.
- **New outflows.** Pages go to TypeSafe and Anthropic, and the user's details typed into a task go to both. The switch's text has to say so.
- **A real browser in Varnick's process tree.** WebKit's page processes already run for Browser panes. Nothing new is installed and nothing outlives Varnick.
- **Sites written for people may resist it:** script-built pages that a plain fetch previews empty, bot checks, and forms that ignore events made in script. Follow-up test 4 measures how often.

## User Stories

1. As the user, I want to type `!task`, open a shop, write "find how much delivery to Canada costs" and see the answer quoted, so that I don't click through the shop myself.
2. As the user, I want to watch each page the task opens and read why it went there, so that I can trust it or stop it.
3. As the user, I want to hear "I need you: your password" when the pane is hidden, so that I come back only when I'm needed.
4. As the user, I want to type my password into the page myself, so that no model ever sees it.
5. As the user, I want every form submit to wait for my Allow, so that nothing is bought, sent or created without me.
6. As the user, I want to click in the page and have the task pause at once, so that I can fix something by hand and then Resume.
7. As the user, I want Stop to end everything the task is doing, so that nothing goes on behind my back.
8. As the user, I want a task to use nothing of my own browsers, so that my logins and history stay out of it.
9. As the user, I want the task to keep going while I work in another app or another tab, so that handing it off saves me time.
10. As the user, I want to run a second task in the same pane after the first, so that "create an account" can be followed by "find my order".
11. As the user, I want tasks to work, more slowly, when Jev isn't available, and the pane to say so.
12. As the user, I want turning the Tasks switch off to stop everything at once and leave no command, tile or process behind.
13. As a builder, I want the harness's rules in a core that takes facts and returns decisions, with no web view or model in it, so that a check command can run it on recorded pages.

## Implementation Decisions

### The switch

- A `Settings` property written to UserDefaults, off by default, with its row in Settings › Experimental. The Outline's switch is the sibling.
- The row's text names the outflows: TypeSafe when relevance runs there, and Anthropic through the user's Claude Code. It also says what the user does: passwords, terms, every submit.
- The harness reads the switch before every step, as Screen access reads its own before every call.

### The pane

- **A new pane kind, Task,** next to Browser in the split picker, and a new Command, `task`. Each is listed only while the switch is on.
- **The web view gets a website data store of its own, made for the pane and not persistent,** so it shares nothing with Browser panes or with another Task pane, and is gone when the pane closes.
- **It keeps the Browser pane's address bar.** The task line, the steps column and the pane's controls are new.
- **A Task pane is not saved.** A restart ends it, and the tab is restored without it. A tab holding only a Task pane isn't restored. `sessions.json` gains nothing.
- **Task panes aren't listed to paired Macs or the phone in this slice.** Where a tab's listing is built has to leave them out (inferred, not checked in the code).
- **A paused or waiting task raises no Notice in this slice.** The spoken line and the tab title carry it. Notices are later.

### Reading and acting in the page

- **All page work runs as scripts in an isolated script world of the web view's own,** so the page's scripts can't see or change them.
- **The snapshot** lists:
  - links (links inside text blocks included, the bug the pilots' parser had until hybrid-browser-7);
  - buttons;
  - form fields with id, label, placeholder, name, autocomplete purpose, type, whether required, options, current value and error;
  - text blocks with their landmark, so the header and footer can be left out of reads.
- **Secret fields are never read,** by the field rules under "What goes to the user". The snapshot carries only whether such a field is filled. That redaction is done in the snapshot itself, before any model, log or step line sees the page.
- **Acting is done through the page:**
  - a click on the element;
  - for typing, the field's value set the way the page's own frameworks read it, then its input and change events;
  - a choice of option.

  Nothing is posted to the system or the window, and no app is brought forward. Whether a page's own programmatic focus can take the panel's keyboard is a question for the spike.
- **Peeks are plain GET fetches with the pane's cookies,** from the data store's cookie store, cached by address for the task, at most 30 a page and 6 at a time per site.

### The harness

- **The harness core is Foundation only.** It takes facts (a snapshot, Jev's answers, Claude's replies, the user's actions) and returns the next decision. Its pieces:
  - the frontier and its budgets;
  - the rules for getting stuck;
  - the read checks;
  - the value bank and its replacement by meaning;
  - the digit comparison;
  - the gates;
  - the trail;
  - the two states and their texts.
- **The page, Jev and Claude sit behind three seams,** so the check command can feed it recorded pages and recorded answers.
- **The reference implementation is the harness of agent-lab's hybrid-browser-13, at 9dbca12.** Its constants are this design's: the 0.7 bar, depth 3, 8 follows, 30 peeks, the 3-step no-progress rule.
- **Two departures from it:**
  - the answer's shape is asked of Jev, not read from the task's words, and there is no marker list (ADR 0037's rule, carried over to tasks);
  - every submit asks, where the pilot asked only at the shop's named buttons.

  Follow-up test 3 checks the first before it is built.

### System 1 (Jev)

- **One call each turn,** shaped like the spoken route's: one shared state and many named questions.
  - Pinned to one Jev version, since the 0.7 bar and the rankings are measured on fixed questions. A change of version or wording is a change to re-measure.
  - The questions' wording is the pilots' own, kept in one place.
- **A deadline of 1.5 s a call,** as the route has. A miss counts as a Jev failure for that step: the step goes to Claude, and after three failures in a row the rest of the task does.

### System 2 (Claude)

- **The text helper gains a conversation mode.** The input stays open, each line is the next user message, and a `result` is sent for each.
  - Same levers as today: no tools, no settings, hooks or memory, no saved transcript, the reminders filter.
  - Haiku 5.5 at low effort, as the pilots ran.
- **Two conversations per task, values and guidance,** as in the pilots. Each is told the other's replies since its last message.
- **Both end with the task,** or when Varnick stops them. A helper that dies mid-task fails the step, and the next wake starts a new conversation from the full state.
- **Why the passed-over option doesn't apply here.** `text-generation-ignores-the-claude-subscription` passed over a conversation kept open because one conversation for every request grows without end and mixes unrelated requests. A task's conversation is one task's, and is meant to see its own earlier steps.
- **The deadline is per message,** 15 s like the web answer's. A miss pauses the task with "Claude didn't answer" and Resume and Stop.
- **The prompts and reply shapes are the pilots'** (guide, act, wait, fix a field, explore, a yes or no on a read, alarms), kept in one place, as a contract with the eval.

### Spoken lines

- Through `Speaker`, as spoken answers are, in the user's voice setting, inside the span that keeps Listening from hearing Varnick.
- Milestone lines always, while Speak progress is on. Page-change lines only while the pane isn't on screen. A line that hasn't started is replaced by a newer one; whether `Speaker`'s queue can drop a line that hasn't started is unverified.

### The log

- Each step's kind, who acted, the probability and the duration, and the task's counts at the end.
- Never a page's address or title, a label, a value, the task's text or a model's reply. That follows Screen access's and Panel access's logs.

### Records to write when accepted

- An ADR: Varnick carries out tasks in a browser of its own, with Jev choosing and Claude steering, and with new outflows to TypeSafe and Anthropic. It amends ADR 0029 with the text helper's conversation mode.
- `CONTEXT.md`: **Task** and **Task pane**. _Avoid_: agent (a Claude Code definition), computer use (avoided for Screen access), automation.
- `docs/privacy-and-security.md`: "TypeSafe, through Tasks", "Anthropic, through Tasks", and Tasks under "What can act as you".
- `where-it-breaks.md`: a Tasks section, with the secret-field rules first.

### The spike (first ticket)

A throwaway app, or Varnick run by the user. Nothing in it starts a daemon or a LaunchAgent, and no Claude session runs Varnick for it.

1. **Hidden panel:** does a web view keep loading pages and running page timers while the panel is hidden? WebKit slows hidden views. If it stops, the pane needs a window of its own that stays off screen.
2. **Script-world acting on five real sites:** a click and typing that a page's own form code accepts (React and Vue forms included), and whether the page's own focus calls take the panel's keyboard.
3. **The conversation mode,** with the user's own `claude`: the time to the first word for a second and a tenth message, against a fresh run.
4. **Secret fields:** a "show password" toggle, autofill, and a password field inside a frame.

## Testing Decisions

- **A check command for the harness core,** as the Outline has its own. It runs the core on recorded made-up pages and recorded model answers. It checks:
  - the frontier's order and its backing up;
  - the stuck rules, including that the only way into a flow is never barred;
  - the read checks per answer shape;
  - the bank replacing a corrected entry;
  - the digit comparison (a masked "(150) 355-5014" fails against "+1 503 555 0142");
  - that every secret field reaches neither state, nor the trail, nor a step line;
  - that every submit but a search asks.
- **By hand after a restart,** by the user:
  - with the switch off, no `!task` and no tile;
  - on, a finding task on a public site;
  - a form task on a site made for practising automation, up to its submit, which waits for Allow;
  - a click in the page pauses the task, Resume carries on, and Stop ends it with no Claude process left (Resources shows none);
  - with the pane hidden, the spoken lines;
  - with the relevance filter On this Mac, the "Without Jev" note, with each step asking Claude.
- **Follow-up tests in agent-lab,** from the loop's open questions. Each is its own experiment, on made-up or public sites, and none creates an account on a real site.
  - **Before building:**
    1. **Peek despite confidence.** On the practice shop's five tasks, peek whenever a page has two or more links near the top score, even when Jev is confident. It passes if the dead end is back near 5 s and no other task is lost.
    2. **Jev itself.** The same five tasks with Jev in Clef's place: its real time per call at the loop's request sizes, and whether 0.7 still separates right from wrong. It needs a TypeSafe allowance. It decides whether option 05 is needed first.
    3. **No word rules.** The answer's shape from a Jev question at the start, with no marker list. It passes on the same outcomes as hybrid-browser-13.
  - **Alongside the build,** on WebKit through Playwright's WebKit build, the engine closest to the pane's:
    4. **Real sites, read only.** Finding tasks on 15 to 20 public sites, against Claude alone. It measures:
       - previews of script-built pages;
       - link counts against the 30-peek cap;
       - load times;
       - bot checks.
    5. **Recognising a submit.** On recorded real form pages, how often a Jev question would tell a final submit, a terms box or a payment step from an ordinary "Next", against hand labels. It decides whether "every submit asks" can narrow.
  - **After:**
    6. **Larger samples.** 20 or more tasks, 5 runs an arm, with intervals.
    7. **Cutting Claude's blocking time.** Jev keeps exploring its best branch while Claude thinks, with the page Claude is likely to suggest prepared in advance. Measured as time to done.
    8. **The fallback.** Claude in Jev's place through this harness, against Claude alone. It shows whether the stated fallback is at least as good as Claude alone.

## Out of Scope

- **Starting a task by voice.** Option 04.
- **The user's own browser or native apps,** which need the screen. Option 02.
- **Clef on this Mac.** Option 05.
- **Logins kept per site across panes,** and the user's saved details (name, address) offered to tasks.
- **Notices on the menu bar for a task that needs the user.**
- **Several tasks at once.** Task panes on paired Macs or the phone.
- **Claude writing a spoken answer.** The spoken line quotes the passing text when it is short.
- **Refactor worth raising:** the three Jev callers each build their own request. A shared TypeSafe client would serve this one too, but this slice adds a fourth caller in the same shape rather than reworking the others.

## Further Notes

- **Measured against inferred.** Every figure here is the pilots'. What this option inherits as measured: the frontier, the read checks for numbers, the value bank, the digit check, the stuck rules, the 0.7 bar on Clef, the informed guidance. What is new and unmeasured:
  - WebKit and Varnick's own snapshot;
  - Jev's own speed and bar;
  - a shape asked of Jev;
  - asking at every submit;
  - real sites.
- **Why this surface.** Options 02 and 03 weigh the other two. In short, this one needs no exception and no permission, lets the user watch and type their own password, and adds nothing to install. It gives up the user's existing logins, and the Chrome engine the pilots used.
- **Suggested order:** follow-up tests 1 to 3, then the spike, then the build with tests 4 and 5 alongside.

## Decisions made while building (2026-10-15)

Recorded at the coordinator's direction after the first slice was reviewed. They add to the sections above and, where they differ, win.

- **Below 0.7, System 1 asks Claude and waits,** however often. The pilots' rule that acts on System 1's best option after two asks in a row is not built. Claude's own suggestion, or a "continue", lets one choice below the bar stand for a step; the budgets end a task that asks forever.
- **The two Claude conversations (values and guidance) are each told the other's replies** since their last message.
- **System 1's state includes** the preview scores of the page's links, the bank's meanings and values (a value only the person gives is shown as "(the person's)", and a secret is never in it) and whether Claude is working on values in the background.
- **A per-step log line** with the step's kind, who acted, the probability and the time, and nothing it said (no address, label, value or text). The spoken "I'm stuck on <page title>" is said when the no-progress or loop rule fires.
- **Gates cover links as well as buttons** on a page with a form, and any link with no real address (`#`, `javascript:`, a link in a button's role). A submit the page makes itself as a field is filled is held and gated. A search box is a form with role search, a search element, or a form whose only text field is a search input.
- **Deferred to a later ticket:** Claude's alarms (a surprise wakes it), and waking Claude on harness signals (no progress, a loop, a budget nearly spent). The pilots found alarms noisy, and the harness's own rules got a task unstuck better than Claude did.
- **The reference implementation is hybrid-browser-15, not -13** (agent-lab, later, and it fixed the wizard). Follow-up tests 1 and 3 ran in agent-lab hybrid-browser-14 (`19d53ca`): no word rules passed (the answer's shape asked of System 1 matched the marker list's outcomes on the tasks that read), and peeking even when System 1 is confident partly passed (the dead end came down from 13 and 24 s to 9.6 s, not to the 5 s target; hybrid-browser-15's peek on every page load made it 7.8 and 8.8 s).
- **Fine as built:** giving Jev up after three failures in a row, and eight answer shapes (the pilots' seven and "none, an action" for a task that reads nothing out).
- **Shipped,** marked 2026-10-17: the merge of 2026-10-15 built this option less the deferred ticket above (Claude's alarms, and waking Claude on harness signals), which is neither written nor built.
