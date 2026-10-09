---
title: Hey Launchy can't see or point at what is on the screen
description: The user wants to ask Hey Launchy about something in front of them ("where's the Allow button", "which one is the save button", "what is this") and have Launchy notice that the request is about the screen, find the thing, point at it with a big arrow and a sign, and say the sign's note aloud. Today a spoken request can only search History, Bookmarks and Claude sessions, and its answer is only heard. Launchy reads nothing of other apps' windows and draws nothing over them.
impact: A question about the screen gets either the off-topic line ("I only look up your pages, bookmarks and Claude sessions.") or an answer from a History, Bookmarks or sessions search that has nothing to do with it. With today's questions, Jev gave about 1 of 40 made-up screen requests the off-topic line and sent the rest to a search (the eval below). The user is left to hunt for the control themselves, at the moment a pointing hand would help most, in an unfamiliar dialog, a crowded toolbar or a setting buried in a pane.
severity: low
evidence: The user's request of 2026-10-09, relayed by the coordinator with the directions below. The code was read on 2026-10-09 at 0b9249d. The reference project big-arrow-on-the-screen (MIT) and TypeSafe's Choice and API docs were also read on 2026-10-09. An eval in agent-lab compared Jev and Gemma on screen requests on 2026-10-09 (section below). After option 01 shipped (merge 63807cc), a spoken request on 2026-10-09 for a name shown in Launchy's own open panel got "I can't see that on your screen", since Launchy's own windows are never read; the transcript is kept locally.
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
- **Measured 2026-10-09: macOS attributes every pane process to Launchy, zmx-hosted ones included.**
  - **How:** a process run from a zmx-hosted pane appeared in the privacy service's log (`com.apple.TCC`) with Launchy named as responsible and its own binary as the binary. It was denied only because the Launchy on disk had been rebuilt after the grant. Details are in `sessions-cant-see-or-act-on-the-screen`, Today.
  - **So a grant to Launchy reaches every session in its panes,** Skip-permissions ones included, and a grant to zmx or to any executable in a pane is never consulted. The effect is measured too: with Launchy granted on a signed build (ADR 0022), both grants read true from a pane, and still did after a rebuild.
  - **Two earlier readings are wrong:**
    - first, "zmx panes are attributed to zmx", read from the eval's recheck;
    - then, "each process is its own", from macOS's private responsibility lookup, which misled.
  - **Unexplained:** why the eval's recheck turned true about 20 minutes later in the same shell, after the user granted zmx alone, with Launchy's switch off in a screenshot.
  - **The fix is `panes-share-launchys-permissions`,** now severity high.
- **The product rule stands:** the Accessibility read runs in Launchy's own process, under Launchy's own grant. zmx is never granted, though a grant to it isn't consulted.

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
- **The permission** goes to the responsible app, which for a command-line tool is the terminal that runs it. A Launchy pane's processes were later measured to be attributed to Launchy (Today › Permissions and signing).

## Measured: Jev and Gemma on screen requests

The `eval` agent ran this on 2026-10-09 in agent-lab, the user's evaluation repository: the screen-pointing experiment, at commit 20fb286.
- **Setup:**
  - Jev was the pinned `jev-1.13.0`.
  - Gemma was the pinned checkpoint, through Python MLX, not Launchy's Swift.
  - Launchy's questions and prompt were read at 60547d6.
  - The requests were made up by the experimenter.
  - The windows were the focused windows of Calculator, TextEdit, Finder and five System Settings panes, cleaned of personal rows.

**Routing** (92 requests: 40 about the screen, 31 for the three old sources, 11 confusers, 10 off-topic; Jev over 3 repeats)
- **With today's questions,** no screen request can go to the screen. About 1 of 40 gets the off-topic line, and the rest are searched.
- **Adding `screen` to `source`** sends 40 of 40 there, with Jev and with Gemma alike, and leaves the old sources where they were (Jev 28 of 31, before and after).
- **But Jev's `action` then reads "point at the wifi switch" as off-topic,** with "other" at 0.90 to 0.92 in every repeat, so Launchy would refuse it.
- **A `point` action before "other",** with "other" naming the screen (the eval's arm J4p), fixes it: none of the 40 screen requests is flagged, and all 10 off-topic ones are.
- **Off-topic must be read before the source,** since "set a timer" and "send a message" take `screen` as their source. Launchy already reads it first.
- **Gemma's warm decide takes about 0.17 s, against Jev's 0.11 s.** The 1.77 s measured for ADR 0016 was mostly Gemma loading in a fresh `--ask` process. A spoken request pays that load again after 10 idle minutes.

**Choosing** (125 requests over 8 windows: 97 whose target is there, 28 whose target isn't; one Jev call per request)

| With the window's whole visible list (29 to 72 elements), each described by label, kind, groups and the text beside it | right / 97 | wrong / 97 | absent pointed at / 28 | p50 |
|---|--:|--:|--:|--:|
| Jev, pointing when its `present` yes-or-no is 0.5 or more | 87 (95 counting the control's own row text) | 10 | 1 | 117 ms |
| Gemma, numbered list, "0" for none | 72 | 24 | 13 | 105 ms |

- **Jev beats Gemma in every cell,** by 8 to 25 points.
- **Gemma's reply probability can't say "not there":** it saturates, with AUROC 0.74.
- **Jev's latency is flat from 10 to 100 elements;** its accuracy falls a little with size.
- **The text beside an element mattered most:** found in code, it added 10 to 19 points for both models. A switch's own label is only its state ("1"), so without the row's text neither model can tell one switch from the next. The enclosing groups added nothing.
- **The eval's recommendation:** Jev for choosing, with Gemma as the routing fallback only.

**The pane's responsible process: Launchy (corrected 2026-10-09).** The eval saw `AXIsProcessTrusted()` go from false to true in a zmx-hosted shell after the user granted zmx, and read it as zmx being responsible. The privacy service's log later named Launchy as responsible for a zmx-hosted pane's process. Why the eval's check turned true is unexplained (Today › Permissions and signing).

Figures from the user's own screens stay in `.scratch/spoken-requests-cant-see-the-screen/`.

## Left to decide

- **May a screenshot leave this Mac?** Answered by the user on 2026-10-09: yes, it may. Sending one to Claude stays possible, beside reading one on this Mac or taking none.
- **Who chooses the element.** Answered by the user on 2026-10-09, following the eval: Jev, with `present` at 0.5. Gemma never points, so without TypeSafe nothing is pointed at.
- **What reaches TypeSafe.** The eval's best result describes each element with the text beside it, so a screen request sends:
  - the window's title;
  - its elements' labels;
  - the text near its controls.

  That is a new kind of data for TypeSafe. It isn't History or sessions, but it is whatever the window shows: a mail's subjects in a list, a document's name in a tab, the account's name in a sidebar.
- **The permission.** Every option needs Accessibility, and options 02 to 04 also need Screen Recording.
  - With builds signed with Developer ID (ADR 0022), a grant survives rebuilds (measured 2026-10-09). Ad-hoc builds lost it.
  - Its reach into Launchy's panes:
    - Into every session in its panes, zmx-hosted ones included: the privacy service attributes them to Launchy (measured 2026-10-09).
    - Cutting that is `panes-share-launchys-permissions`.
- **Pointing on the local path (open, 2026-10-09).** The user's principle is that choosing TypeSafe is consent to send what a TypeSafe feature needs, and that keeping things private is the On this Mac setting. But with the filter On this Mac, nothing points:
  - Gemma never points (option 01, decided);
  - Point at the screen can't be turned on without the TypeSafe gate.

  So the private path has no pointing. No fix is proposed.
