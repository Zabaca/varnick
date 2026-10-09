---
title: Hey Launchy can't see or point at what is on the screen
description: The user wants to ask Hey Launchy about something in front of them ("where's the Allow button", "which one is the save button", "what is this") and have Launchy notice that the request is about the screen, find the thing, point at it with a big arrow and a sign, and say the sign's note aloud. Today a spoken request can only search History, Bookmarks and Claude sessions, and its answer is only heard. Launchy reads nothing of other apps' windows and draws nothing over them.
impact: A question about the screen gets either the off-topic line ("I only look up your pages, bookmarks and Claude sessions.") or an answer from a History or sessions search that has nothing to do with it. Which of the two happens, and how often, is unmeasured; the eval below counts it. The user is left to hunt for the control themselves, at the moment a pointing hand would help most, in an unfamiliar dialog, a crowded toolbar or a setting buried in a pane.
severity: low
evidence: The user's request of 2026-10-09, relayed by the coordinator with the directions below. The code was read on 2026-10-09 at 0b9249d. The reference project big-arrow-on-the-screen (MIT) and TypeSafe's Choice and API docs were also read on 2026-10-09. An eval in agent-lab comparing Jev and Gemma on screen requests is running, and its results are pending (section below).
status: open
---

## What the user asked (2026-10-09)

Through Hey Launchy (ADR 0015, 0016, 0017), a request about something on the user's screen should be noticed for what it is. Launchy should then look at the screen and point at the thing with a big arrow and a note on a sign, as big-arrow-on-the-screen does. That tool is a Swift command line whose arrow is click-through, never takes focus and ends by itself. Launchy should say the note aloud, as it answers today.

## The user's direction so far (not final decisions)

The coordinator relayed these on 2026-10-09. The options start from them, but none is accepted.

- **Noticing.** Jev's `source` question gets a `screen` choice, and it still carries only the request text, as ADR 0016 says. Gemma's decide prompt gets the same choice.
- **Looking.** Launchy reads the front window's Accessibility tree first (labels, roles, frames) rather than a screenshot, because macOS gives exact frames and the tree is text only.
- **Choosing the element.** Jev picks which element the request means. It is asked a choice question whose options are the candidate elements, and its probability doubles as confidence. A low one means no arrow and a spoken "I can't see that". Gemma on this Mac is the alternative and the fallback. Asking Jev sends the elements' labels to TypeSafe, which ADR 0016 refused to do for rows. The starting point is to gate that call as ADR 0016 gates the decide step: only with the relevance filter on TypeSafe and a key saved.
- **Pointing.** Launchy draws the arrow itself, in its own process, rather than running bigarrow. The sign carries the note.
- **ADR 0015 is reversed on purpose.** Its rule that a request is "answered only aloud: nothing is shown or opened" stops holding for these requests, so the chosen option needs a new ADR.
- **Not answered yet: may a screenshot ever leave this Mac?** Option 01 takes no screenshot. Options 02 and 03 read one on this Mac, and option 04 sends one to Claude.

## Today

All of this was read in the code at 0b9249d, unless it is marked otherwise.

**The decide step** (`SpokenRouter.swift`, `SpokenText.swift`)
- Jev gets two questions in one call, and the request text is its only state:
  - `source`: history, bookmarks or sessions;
  - `action`: answer, open, start or other.

  Their shared context tells Jev that Launchy "answers by searching one of three places".
- When `action` puts "other" at 0.5 or more, the request ends with "I only look up your pages, bookmarks and Claude sessions."
- The thresholds `offTopicFrom` and `alsoSessionsFrom` were measured on the pinned `jev-1.13.0` with these exact questions, so changing the questions changes what the thresholds mean (where-it-breaks, Listening and spoken requests).
- Gemma's decide prompt offers the same three sources and says "Every request is a search, so always choose one source".

**What Launchy sees of other apps: nothing.**
- No Accessibility API (`AXUIElement`, `AXIsProcessTrusted`) and no screen capture is used anywhere in `Sources/` or `Packages/`.
- The global shortcuts use Carbon, which needs no Accessibility permission (`HotKey.swift:3`).

**What Launchy draws: only its own windows.**
- `LauncherPanel` (`main.swift:10-43`) is a borderless, nonactivating, floating panel that can become key. It hides when it loses key, unless it is pinned or a dialog of Launchy's is up.
- The app runs as an accessory, with no Dock icon.

**A spoken answer is only heard.**
- `Speaker` renders the speech and plays it on Launchy's own audio engine, inside the span `SpeechSpans` uses to keep Launchy from hearing itself.
- The glossary's **Spoken request** says "nothing is shown or opened".

**Permissions and signing**
- `make build` signs ad hoc, with the identifier `com.zabaca.launchy` (`Makefile:48`).
- The build's designated requirement is its code hash alone: `codesign -d -r-` on the current build prints `cdhash H"…"`. So a privacy grant recorded for one build should not match the next one.
  - This is inferred, not verified: the privacy database can't be read without Full Disk Access.
  - `runs-only-from-a-checkout` already records the same thing for the Keychain prompt (`Keychain.swift:4-5`), and its option 01 (Developer ID signing) would fix it.
- **Whether a grant to Launchy reaches its zmx panes is inferred, not measured.** macOS gives a process the grants of its responsible app.
  - **Observed in the eval, in a pane on the user's Mac on 2026-10-09:** with Keep sessions running on, a pane's shell and Claude run under zmx, a daemon whose parent is launchd. The chain is the shell, then Claude, then zmx: the copy beside Launchy's binary, parent pid 1.
  - **The first check proves nothing either way.** `AXIsProcessTrusted()` was false in that pane, but Launchy had no Accessibility grant then either: its switch was off in System Settings. So the result shows nothing about whether a Launchy grant reaches the pane.
  - **Attributing the pane's processes to zmx** is the eval's inference from zmx's parent pid. The user has granted zmx Accessibility temporarily, so the eval can recheck.
    - A true result there would show that zmx is the responsible process.
    - That makes "a Launchy grant doesn't reach zmx panes" likely, but still not measured.
- **The product rule, whatever the recheck finds:**
  - The Accessibility read runs in Launchy's own process, under Launchy's own grant.
  - zmx is never granted. Anything run from a pane (`bigarrow --element`, a helper script) would need that, and if zmx is the responsible process, its grant reaches every Claude session it hosts, with the power to read and drive any app's UI.
  - The eval's temporary grant to zmx is the one exception, made for the recheck.
- **Panes outside zmx are another matter.** With Keep sessions running off, or zmx missing, a pane runs as Launchy's direct child, through SwiftTerm (`ClaudeSession.startInTerminal`). Keep sessions running is off by default (`Settings.swift`), so on a new install that is every pane. Neither Launchy nor SwiftTerm disclaims responsibility for its children: no such call is in `Sources/`, `Packages/` or SwiftTerm's checkout. So those panes probably do get Launchy's grants. This is inferred, and option 01 has the hand check.

**Text generation** (`TextGenerator.swift`; ADR 0012)
- Gemma 4 E2B (`mlx-community/gemma-4-e2b-it-4bit`, at a pinned revision) is loaded through MLX's language-model factory, which is text only.
- The installed checkpoint also holds a vision tower (658 of its 2,511 weights) and an image processor config (`Gemma4ImageProcessor`, 280 image tokens, 16-pixel patches). This was checked on this Mac's copy.
- The pinned mlx-swift-lm (3.32.3) ships an `MLXVLM` library.
  - It has Gemma 4 and its processor, and it names this same model repository among its configurations.
  - Launchy doesn't link it.
  - Its processor scales an image to about 645,000 pixels and keeps its shape: roughly 1,000 × 640 for a 16:10 window.
- Whether Gemma 4 E2B can say *where* something is in an image is unverified.

**TypeSafe's Choice** (from the docs)
- A Choice takes up to 255 options.
- Its probabilities sum to 1, and its confidence measures how concentrated they are.
- The docs advise a "none of the above" option when the list might not hold the answer.

**What may leave the Mac today** (where-it-breaks)
- With the relevance filter on TypeSafe and a key saved:
  - a spoken request's text, for the decide step;
  - its search words and the title, site and own description of 20 pages, for the filter.
- Otherwise nothing goes to TypeSafe.
- Nothing from another app's window is read, let alone sent.
- No Launchy feature sends anything to a cloud language model.

## The reference: big-arrow-on-the-screen

This is MIT-licensed Swift for macOS 14 or newer. What matters here comes from its README and sources, and these are its claims, not checked here:

- **The overlay** is one panel per display:
  - borderless and nonactivating;
  - it ignores the mouse and can never become key;
  - it sits at the screen-saver window level, on every Space and over full-screen apps.

  Drawing needs no permission.
- **Finding an element by label** walks the app's Accessibility tree breadth first, focused window first, within a depth, node and time budget. It ranks labels by exact, prefix and substring match.
- **Web content:**
  - Electron apps build their web content's tree only when asked to (`AXManualAccessibility`).
  - Chrome refuses that request and the older attribute too. It exposes a page's content only when started with `--force-renderer-accessibility` or while VoiceOver runs; its authors verified this on 2026-10-08.
  - Chrome's own toolbar is always in the tree.
- **The permission** goes to the responsible app, which for a command-line tool is the terminal that runs it.

## Measured: Jev and Gemma on screen requests (pending)

The `eval` agent started an eval on 2026-10-09 in agent-lab, the user's evaluation repository. It measures two things:

1. **Routing.** Does a `screen` choice in Jev's `source` question, and in Gemma's decide prompt, catch screen requests without pulling History, Bookmarks and sessions requests away from their sources? And what happens to `action`'s "other"?
2. **Choosing.** Given a request and a list of Accessibility elements, how often does each model pick the right one? Does Jev's probability separate right picks from wrong ones? That sets the threshold for "I can't see that".
3. **The pane's responsible process.** `AXIsProcessTrusted()` is rechecked in a pane while zmx holds a temporary grant (Today › Permissions and signing).

Results: _pending. They go here when they land, with the agent-lab experiment's name and commit._ Figures from the user's own screens stay in `.scratch/spoken-requests-cant-see-the-screen/`.

## Left to decide

- **May a screenshot leave this Mac?** The options are:
  - none at all (01);
  - one read on this Mac, by text recognition (02) or by Gemma (03);
  - one sent to Claude (04).
- **Who chooses the element, and from what threshold.** The starting point is Jev when the filter is on TypeSafe with a key, and Gemma otherwise. The eval sets the threshold, or argues for another split.
- **What reaches TypeSafe.** The labels and roles of the controls in the user's front window are a new kind of data for TypeSafe. They aren't History or sessions, but they are whatever the window shows: a mail's subject as a link, a document's name as a tab.
- **The permission.** Every option needs Accessibility, and options 02 to 04 also need Screen Recording.
  - Each grant goes to a build that the next rebuild may not match.
  - Its reach into Launchy's panes is inferred both ways: probably not into sessions in zmx (pending the eval's recheck), probably yes into panes started outside zmx.
