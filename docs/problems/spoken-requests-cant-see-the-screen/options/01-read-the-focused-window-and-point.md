---
problem: spoken-requests-cant-see-the-screen
title: Read the focused window's Accessibility tree, let Jev or Gemma pick the element, and point at it with an arrow
summary: With a new switch, Point at the screen, a spoken request routed to `screen` is answered from the Accessibility tree of the app that has focus. Launchy lists that window's labelled controls with their frames, and Jev picks the one the request means (Gemma does when the relevance filter isn't on TypeSafe with a key, or Jev fails). A confident pick gets a big click-through arrow and a sign, drawn by Launchy itself, while Launchy says the sign's note. No screenshot is taken. Only the request and the controls' roles and labels reach TypeSafe, and only with the filter on TypeSafe. Chrome's web pages are out of its reach.
status: proposed
---

## Solution

**Point at the screen** is a new switch under Hey Launchy in Settings › Listening, off by default. While it is on, a spoken request can go to a fourth place, the screen, beside History, Bookmarks and sessions. The steps are Hey Launchy's own, with a different read and answer:

1. **Decide.** Jev's `source` question and Gemma's decide prompt gain `screen`. A request whose likeliest source is `screen` goes down this path; the others are answered as today.
2. **Look.** Launchy walks the Accessibility tree of the app that has keyboard focus, its focused window first. It keeps the elements a person points at (buttons, fields, menus, tabs, links and the like) that have a label and a frame on screen. The element under the mouse pointer is kept too, so "what is this" can mean it.
3. **Choose.** Jev gets the request and the candidates' roles and labels as one choice question, with "none of these" as an option. A pick at or above the threshold is pointed at, and anything below it is "I can't see that on your screen." Gemma chooses when Jev isn't used, from a numbered list.
4. **Point and say.** Launchy draws a big arrow at the element, with a ring round it and a sign holding the note ("Here's the Allow button."), and says the note. The arrow is click-through and never takes focus, and it goes by itself a few seconds after the speech.

Nothing is clicked, opened or focused. The panel, when it is open, stays as it was.

## Trade-offs

- **Exact and cheap.** macOS gives each element's frame, so the arrow lands on the control, not near it. Reading a window's tree is local and takes a fraction of a second for most apps (estimated, not measured). No image is made, and none can leave the Mac.
- **It sees only what the app exposes.**
  - Native apps, System Settings and system alerts that take focus are well covered.
  - Electron apps (Slack, VS Code, Claude's desktop app) are covered once asked to build their web tree.
  - Chrome's page content is out of reach unless Chrome runs with `--force-renderer-accessibility`. In Chrome a request finds the toolbar and nothing inside the page, and Launchy says so.
  - Icon-only controls are found when the app gave them a description (most native ones), and missed otherwise.
- **A new kind of data reaches TypeSafe.** With the filter on TypeSafe and a key saved, the roles and labels of the focused window's controls go there with the request. Those labels hold whatever the window shows: a mail's subject as a link, a file's name as a tab, a contact's name as a button. ADR 0016 refused to send rows, and ADR 0017 then sent page rows for the filter. This sends the screen, so it gets its own line in Settings, the README and SECURITY.md, and its own ADR. With the filter On this Mac or off, Gemma chooses and nothing leaves.
- **A permission, and its reach.**
  - Launchy needs Accessibility. While builds are signed ad hoc, a rebuild may silently stop the grant from applying, until the user removes and re-adds Launchy (unverified; hand check 1). `runs-only-from-a-checkout` option 01 would make the grant stick.
  - **Sessions in zmx don't get the grant.** The eval measured this: a pane under zmx isn't trusted, and macOS attributes it to zmx.
  - **Panes started outside zmx probably do get it** (Keep sessions running off, or zmx missing), since they are Launchy's own children (unverified; hand check 2). Accessibility lets a process read and drive any app's UI, so a session started with Skip permissions in such a pane could do that without asking. Settings says so plainly, and it is the user's call (open question 1).
  - **The grant must stay Launchy's.** Granting zmx instead, so that a tool in a pane could read the screen, would hand that power to every hosted session.
- **ADR 0015's promise changes.** A spoken request can now draw on the screen. It still never opens, clicks, types or moves focus, and a misheard request costs an arrow that goes by itself.
- **The decide questions change.** Adding `screen` changes Jev's measured `source` and `action` probabilities, so `offTopicFrom` and `alsoSessionsFrom` are re-measured (the eval in the problem). With the switch off, the questions are today's, unchanged.
- **Latency, estimated.** Jev's decide takes about 0.3 s, the tree read 0.1 to 1 s, and Jev's choice about 0.3 s. With Gemma choosing instead, about 0.5 s more. The draw is instant. Decide, read and choose all run during the hold (ADR 0017), so most of this overlaps the wait for the user to finish.

## User Stories

1. As a Launchy user, I want to say "Hey Launchy, where's the Allow button" and see a big arrow on it while Launchy says "Here's the Allow button", so that I find it at a glance.
2. As a Launchy user, I want "which one is the save button" answered with an arrow on the right one when the toolbar has several icons.
3. As a Launchy user, I want "what is this" to name the control under my pointer, with its help text when it has one.
4. As a Launchy user, I want the arrow never to take my focus or block my clicks, and to go away by itself.
5. As a Launchy user, I want to hear "I can't see that on your screen" rather than see an arrow on the wrong thing.
6. As a Launchy user, I want to be told when the thing is inside a Chrome page Launchy can't read, rather than hear only that it can't see it.
7. As a Launchy user, I want this off until I turn it on, and Settings to say what it sends, what permission it needs and what that permission reaches.
8. As a Launchy user, I want my requests about pages, bookmarks and sessions answered exactly as before.
9. As a maintainer, I want `Launchy --ask` to run a screen request against a named app and print what it saw and picked, so that I can tune the questions and the threshold.

## Implementation Decisions

**Turning it on**
- **Point at the screen** goes in Settings › Listening, below Hey Launchy. It is off by default, stored in UserDefaults like the other switches, and needs Hey Launchy on.
- Its row shows whether Launchy has Accessibility, checked each time Settings shows it. Without it, a button asks macOS for it (the system prompt adds Launchy to the list) and opens Privacy & Security › Accessibility.
- **The detail text** says:
  - that Launchy draws an arrow on the screen;
  - what goes to TypeSafe, and when;
  - that a rebuild may need the grant again;
  - that the grant is Launchy's own: sessions kept running in zmx don't get it, and panes started without Keep sessions running may (hand check 2).
- **With the switch off,** Jev's questions and Gemma's prompt are today's, byte for byte.
- **Asked without the permission,** Launchy says "I need Accessibility permission to see your screen. It's in Settings, under Listening." It draws nothing.

**Deciding**
- With the switch on, Jev's `source` question gains `screen`. Its rubric: something the person can see on their screen right now, such as a button, a field, a menu, a tab, an icon or a setting; "where is", "which one is", "what is this".
- The shared context names four places.
- `action`'s "other" rubric names the screen among the things that are not "other".
- The model stays pinned. The new questions are measured, and the thresholds re-set, before the switch ships (the eval in the problem).
- Gemma's decide prompt gains `screen` and two examples ("where's the Allow button", "what is this").
- The off-topic line becomes "I only look up your pages, bookmarks, Claude sessions and what's on your screen."
- `screen` is taken when it is the likeliest source. Sessions are never added beside it, and no search runs.

**Looking**
- **In Launchy's own process,** under Launchy's own grant. The read never goes through a helper, a script or bigarrow run in a pane. Those run under zmx, which would need a grant of its own, and that grant would reach every Claude session zmx hosts.
- **Off the main actor,** within named limits, tuned by hand: a time budget (1 s), a node limit (3,000), a depth limit (30), and a short timeout per Accessibility call, so a hung app costs only the budget.
- **Which app.** The application that has keyboard focus, as the system-wide Accessibility element reports it. A system alert that takes focus is its own app, so it is read. When Launchy itself has focus, the frontmost other app is read; Launchy's own windows are never read.
- **Walk order.** Breadth first: the focused window (its sheets and dialogs are inside it), then the app's other windows, then the top level of its menu bar.
- **Electron apps** are asked to build their web content's tree (`AXManualAccessibility`), and the first such request waits a moment. The app keeps that tree until it quits, which costs it some memory. Chrome's refusal is harmless.
- **A candidate** is an element that:
  - has a frame of nonzero size on a display;
  - has a label: its title, else its description, else, for a text field, its placeholder;
  - has a role a person points at: buttons and menu buttons, pop-ups, checkboxes and radio buttons, links, tabs, toolbar items, menu bar items, text and search fields, sliders, and images with a description.

  Disabled elements count, marked "dimmed".
- **Never read into a candidate:** an element's value (what a field holds), static text, or anything of a secure text field.
- **The element under the pointer** is a candidate whatever its role, when it has a label, marked "under the pointer".
- Labels are cut to 80 characters. Duplicates (same role, label and frame) are dropped. At most 150 candidates are kept, in walk order (a Choice takes 255).
- **Chrome with an empty web area** is noted, so that a miss is answered "I can't see inside pages in Chrome."

**Choosing**
- **Jev, under the decide step's gate:** the filter on TypeSafe and a key saved. One more call, on the same pinned model:
  - a choice question whose options are the candidates, each described by its role, its label and its markers (dimmed, under the pointer, in a dialog), plus `none`: nothing listed is what the request means;
  - the request text as the only state;
  - the 1.5 s timeout the decide step uses.
- **The pick** is pointed at when it isn't `none` and its probability is at or above `pointFrom`. That threshold starts at 0.5 and is set from the eval. Anything below gets "I can't see that on your screen."
- **Ties.** Two candidates with the same label share the probability. The earlier one in walk order is taken (a dialog's button before the window's), and the threshold applies to their sum.
- **Gemma** chooses when the gate is closed, Jev fails, the reply has no answer or the timeout passes.
  - It gets the request and the numbered candidates, and replies with a number, or 0 for none. Greedy, a few tokens.
  - It gives no probability, so its number is taken as is. 0 or an unreadable reply is "I can't see that on your screen."
  - It runs where Text generation runs, by the interactive place rule. With a server, the candidate list goes to the user's own server.
- **Before drawing,** the chosen element's frame is read again, since the window may have moved during the hold. If the element is gone, nothing is drawn, and Launchy says it can't see it any more.

**Pointing**
- **One overlay window,** made when first needed and kept. It covers the display that holds the element, is borderless and nonactivating, can never become key or main, and ignores the mouse. It sits on every Space and over full-screen apps, at a level above Launchy's own floating panel.
- **Focus.** Showing it never activates Launchy or moves focus. An open panel keeps key and stays shown.
- **What it draws:**
  - a ring round the element's frame;
  - a thick arrow ending at the ring;
  - a rounded sign at the arrow's tail holding the note.

  The sign goes on the side with the most room and never covers the element. It is one colour with a white edge and a shadow, sized to read from a step back, and it fades in.
- **Coordinates.** Accessibility frames are global with a top-left origin, and AppKit's have a bottom-left one from the main display. They are converted in one place.
- **How long it shows.** From just before the speech starts until 8 s after it ends (a named constant). A new spoken request, or turning Point at the screen, Hey Launchy or Listening off, removes it at once. Nothing on it is clickable, and it doesn't follow a window that moves.
- **Whose code.** It is Launchy's own, after bigarrow's overlay recipe. Any code copied from bigarrow keeps its MIT notice.

**The note**
- **A fixed sentence, with no Text generation:**
  - "Here's the Allow button.", with the role in words and the label as the app gives it;
  - for the element under the pointer, "That's the Share button.", plus its help text when it has one, cut to one sentence.
- The sign shows the sentence, and Launchy speaks it through `Speaker`, as every answer is spoken. It goes into the transcript as a `[launchy]` line, as other answers do.
- **Misses are spoken with nothing drawn:** "I can't see that on your screen.", the Chrome sentence, the permission sentence.

**Speculating** (ADR 0017)
- The tree read and the choice run in `prepare` while the request is held, as the search and the filter do.
- A partial request's candidates may go to Jev and be discarded, as a partial request's pages may today.
- The arrow is drawn only after the hold ends.

**Privacy and logs**
- **To TypeSafe,** only with the filter on TypeSafe and a key saved:
  - the request text, for the decide step, as now;
  - for a screen request, the request and the candidates' roles, labels and markers.

  Never a value, static text, a window title, an app's name, a frame or an image.
- **Never logged:** the request, the labels or the pick.
- **The timing line** adds the read's duration, the candidate count, who chose, and the miss's kind (none, below the threshold, no permission, Chrome, gone).
- **Docs.** The README, SECURITY.md, the Settings text and where-it-breaks's list of what goes to TypeSafe and to a model server all add the candidates.

**Command line**
- `Launchy --ask <file> --app <name>` reads that app's focused window for a screen request, instead of the app with focus, which is the terminal. It prints:
  - the candidate count;
  - the pick's role and label;
  - Jev's probability or Gemma's number;
  - who chose, and each step's time.

  It draws nothing.
- With `--draw`, it also shows the arrow for 8 s, to check placement.
- Request files and output are personal: keep them out of the repo.

**State**
- One new UserDefaults key, for the switch. `sessions.json` is unchanged.
- macOS keeps the Accessibility grant.

## Testing Decisions

- There is no test target. These pure steps are the seams for a first test once there is one:
  - an element's attributes in, a candidate or nothing out;
  - Jev's reply in, a pick or a miss out;
  - the coordinate conversion, for displays left of and above the main one;
  - the sign's placement: the element's frame, the display and the sign's size in, the sign's frame out.
- **`--ask --app`** on a dozen made-up requests against System Settings, Finder, an Electron app and Chrome, to tune the rubric and `pointFrom` alongside the eval.
- **By hand, after the user restarts Launchy,** with Listening, Hey Launchy and Point at the screen on:
  - In System Settings, ask "where's the search field". The arrow lands on it, the note is spoken, and focus stays in System Settings.
  - In an app with an icon toolbar, ask "which one is the share button". Then hover a control and ask "what is this".
  - With the panel open and text typed in it, ask again. The panel stays shown, its field keeps focus and the text is unchanged.
  - In Chrome, ask about a button inside the page. Launchy says it can't see inside pages in Chrome.
  - Ask about something that isn't on screen. Launchy says it can't see that, and draws nothing.
  - With a second display, and with an app in full screen, the arrow appears over the right app.
  - Ask about a page you visited. It is answered from History, as before.
  - Launchy's log holds no request, label or pick.

**Hand checks for the builder.** These are unverified. Run them with the user, and keep anything personal in `.scratch/spoken-requests-cant-see-the-screen/`.

1. **The grant across a rebuild.** Grant Accessibility, then `make build` and restart. Does Settings still show it granted? If not, the detail text says how to re-grant it.
2. **The grant's reach outside zmx.** Panes in zmx are already measured as not trusted. After the grant:
   - turn Keep sessions running off;
   - open a terminal pane, which then runs as Launchy's direct child;
   - run a one-line Accessibility trust check there.

   If it says trusted, Settings and SECURITY.md say so, and the user decides (open question 1).
3. **System prompts.** Trigger a real permission prompt (a new app asking for the microphone) and ask "where's the Allow button". Is the prompt the app with focus, and does it expose its buttons?
4. **Latency.** Time about ten requests from the end of speech to the arrow, warm, with Jev and with Gemma choosing. A median well over 4 s goes back to the user.

## Out of Scope

- Clicking, pressing, typing or focusing anything for the user.
- Screenshots of any kind (options 02 to 04).
- Chrome's page content, beyond saying it can't be read.
- Apps other than the one with focus ("where's the mute button in Zoom" while another app is in front).
- Several arrows for one request, an arrow that follows a moving window, and a click to dismiss it.
- Follow-up requests ("no, the other one"). Each request stands alone, as ADR 0015 says.
- Running the read from a pane or a helper, and granting zmx anything (see Looking).
- Keeping panes started outside zmx from inheriting Launchy's grants. If hand check 2 finds they do, that is a problem of its own: it would change what the microphone grant reaches in those panes today, too.

## Further Notes

- **Open questions, with recommendations:**
  1. If the grant reaches panes started outside zmx, is that acceptable?
     - Keep sessions running is off by default, so on a new install every pane is Launchy's direct child. With it on, sessions run in zmx and don't get the grant.
     - Recommended: accept it, with a plain line in the switch's detail and in SECURITY.md naming Keep sessions running.
     - Raise the disclaim change as its own problem rather than block on it.
  2. Should the Jev choice wait for the eval's threshold? Recommended: yes. Build behind the switch with 0.5, and set `pointFrom` from the eval before turning it on.
- **ADR, on acceptance (0018).** Spoken requests can point at the screen: Launchy reads the focused window's Accessibility tree, and draws an arrow that never takes focus and ends by itself. It amends ADR 0015 ("nothing is shown") and ADR 0016 (Jev gets the screen's labels, under the same gate), and adds Accessibility to what Launchy asks for.
- **Glossary, proposed:**
  - **Arrow**: what Launchy draws over the screen to point at the thing a **Spoken request** asked about: a big arrow with a sign holding the spoken note, click-through, gone by itself. _Avoid_: highlight, cursor, annotation.
  - **Spoken request**'s entry changes from "answered aloud from History, Bookmarks and Sessions, and only aloud: nothing is shown or opened" to also answering about the screen with an **Arrow**, still never opening or clicking anything.
- **`where-it-breaks.md` items this touches:**
  - Listening and spoken requests: the Jev body (anything added is a privacy change needing the ADR, README and SECURITY.md), the pinned model and its thresholds, speculation in `prepare`, and speech only through `Speaker.speak`.
  - Search store: what goes to a model server, now also the candidate list.
  - Focus and keys: the overlay can never become key, so the panel's `resignKey` rule is untouched.
  - New entries:
    - the overlay's level and click-through;
    - the one coordinate conversion;
    - the tree read's limits off the main actor;
    - what a candidate may never hold;
    - the read staying in Launchy's process, with zmx never granted.
- **Considered:**
  - **Code matching alone** (bigarrow's exact, prefix and substring match on the request's words). It is private and instant, but "where do I approve this" never matches "Allow", and "what is this" has no words to match.
  - **Reading the tree on every request and asking Jev both questions in one call.** It saves one round trip, but sends the screen's labels for requests that aren't about it.
- **Verified in the code or on this Mac:**
  - the decide questions, gate, thresholds and off-topic line;
  - that no Accessibility or screen capture API is used;
  - `LauncherPanel` and the accessory app;
  - the ad-hoc signature and its code-hash requirement;
  - no responsibility disclaim in Launchy or SwiftTerm;
  - that a pane runs as Launchy's direct child when zmx isn't used;
  - the Choice limit of 255, from TypeSafe's docs.
- **Measured in the eval (agent-lab, 2026-10-09):** a pane under zmx isn't trusted for Accessibility, and macOS attributes it to zmx.
- **Inferred, not measured:**
  - every latency figure;
  - the grant lost at a rebuild, and its reach into panes outside zmx;
  - how system prompts expose their buttons;
  - bigarrow's claims about Chrome and Electron.
