---
problem: spoken-requests-cant-see-the-screen
title: Option 01, then Apple's text recognition on a screenshot of the window, on this Mac, when the tree has nothing that fits
summary: Option 01 as it stands, plus one fallback. When option 01's Jev call finds the thing isn't among the window's elements, or Chrome hides its page, Launchy captures the focused window alone into memory and runs Apple's on-device text recognition on it. The short lines of text it finds, with their boxes, become a second list for the same Jev call. This reaches Chrome pages, canvas apps and remote desktops without any model looking at an image, and the screenshot never leaves the Mac or reaches the disk. The recognised lines can go to TypeSafe under option 01's gate, and that is more of the window's text than option 01 sends. It needs Screen Recording as well as Accessibility.
status: shipped
---

## Solution

Everything in option 01 holds. This option adds one step after option 01's choice, and only when the choice found nothing:

1. Launchy captures the focused window alone, not the display, so other windows and the desktop aren't in the image. The capture stays in memory.
2. Apple's Vision text recognition reads the window and returns each line of text with its box.
3. Lines short enough to be a label (a button's, a link's, a tab's) become candidates, described as "text on screen" with their words.
4. They go to option 01's Jev call, under the same gate, with `present` deciding as there. A pick Jev finds present is pointed at, with the arrow ringing the text's box.

The image is dropped as soon as the text is read. It is never written to disk, never logged and never sent.

## Trade-offs

- **It reaches what the tree can't.**
  - Chrome's page content, without the command-line flag.
  - Apps drawn on a canvas, remote desktops, virtual machines, and games' menus.
  - Controls an app forgot to label, when they carry visible text.
- **It still misses icons.** A gear, a trash can or a share symbol has no text, so it is found only through option 01's tree.
- **No model reads the image.** Text recognition is Apple's, built into macOS, on this Mac. It adds no dependency and no download.
- **More of the window's text can reach TypeSafe.** The recognised lines are what the window shows: a mail's subjects and senders, a document's headings, a chat's names. The length cut keeps out paragraphs but not short private lines. They go to TypeSafe on a miss, under option 01's gate (the filter on TypeSafe and a key). Option 01 already sends the text beside each control; this sends every short line in the window. The ADR and Settings say so.
- **A second permission.**
  - Screen Recording is granted the way Accessibility is, with the same ad-hoc rebuild problem.
  - Like option 01's grant, it is Launchy's own. The capture runs in Launchy's process, never from a pane. Pane processes are checked as themselves (measured for zmx panes on 2026-10-09), but Launchy's own binary run from a shell probably carries the grant (`sessions-cant-see-or-act-on-the-screen`).
  - Recent macOS versions ask again from time to time whether an app may keep recording, and show a capture indicator. Unverified on macOS 26.
- **Slower on a miss only.** The capture, recognition at the accurate level and a second choice add an estimated 0.5 to 1.5 s, unmeasured, and only after the tree found nothing.
- **Boxes, not controls.** The arrow rings the text, which may be beside the control it labels: a checkbox's label rather than its box. Close enough to point, not to click.

## User Stories

1. As a Launchy user, I want "where's the Sign in button" answered with an arrow inside a Chrome page, without restarting Chrome with a flag.
2. As a Launchy user, I want to know that Launchy looks at a picture of my window only on this Mac, and only when it couldn't find the thing otherwise.
3. As a Launchy user, I want to be told what text from my screen may reach TypeSafe, and to keep it all on this Mac by choosing the filter On this Mac.
4. As a Launchy user, I want everything else as in option 01.

## Implementation Decisions

**Everything not below** is as in option 01.

**Turning it on**
- No new switch. With Point at the screen on, its row also shows Screen Recording's state, with a button to ask for it and open the pane.
- Without Screen Recording, the fallback is skipped and option 01's answer stands.
- The detail text adds that a picture of the window is read on this Mac when the window's controls don't have it, and which recognised text may go to TypeSafe.

**When it runs**
- After option 01's Jev call gives `present` under 0.5, or the window had no elements.
- At once, without a choice, when the focused app is Chrome and its web area is empty. (Amended 2026-10-09 in review: in Chrome the page's text is read first, from inside the empty web area only. One Jev call then chooses among the toolbar's elements and those lines together.)
- Never for a request that option 01 answered.

**The capture**
- The focused window alone, through ScreenCaptureKit's single-window capture, at the display's scale. Launchy's own overlay and panel are excluded.
- In memory only. It is dropped once the text is read: never written, logged or sent.
- (Amended 2026-10-09 in review.) The capture and the recognition together give up after 2 s, so a stalled capture can't hold a spoken request. That is a miss, with option 01's answer.

**The recognition**
- Vision's text recognition at the accurate level, in the transcriber's language, off the main actor.
- **Kept lines:** at most 6 words and 60 characters, the shape of a label rather than a paragraph, at most 150 in reading order.
- Each line's box is converted from the image's coordinates to the screen's, through option 01's single conversion.
- (Amended 2026-10-09, the user's decision.) Typed text is kept out where Launchy can place it, and accepted where it can't. That is [ADR 0021](../../../adr/0021-a-window-whose-tree-lacks-the-thing-is-read-from-a-screenshot-on-this-mac.md), Typed text can go.
  - **Dropped:** a line whose centre is inside a field the walk met (secure fields included, by frame only) or inside the app's focused entry field. Those fields are shifted to where the window is in the capture.
  - **May still go:** short typed text in a field Launchy can't place.

**Choosing**
- Option 01's call, gate and `present` rule, with no Gemma pick.
- The list is the kept lines, each described as "text on screen" and its words. The tree's elements, already refused, aren't sent again.
- Unmeasured: the eval measured Accessibility lists only. Check recognised lines with `--ask --app` on Chrome pages before relying on option 01's figures here.
- What goes to TypeSafe adds these lines, under the gate.

**Pointing and the note**
- The arrow rings the line's box.
- The note is "Here's 'Sign in'.": the words, quoted, since there is no role. "What is this" uses the line under the pointer when there is one.

**Logs, command line, state**
- The timing line adds the capture's and recognition's durations, the kept-line count, and whether the fallback ran. The text itself is never logged.
- `--ask --app` prints the same for the fallback.
- No new saved state. macOS keeps the Screen Recording grant.

## Testing Decisions

- The line filter (a recognised line in, a candidate or nothing out) and the box conversion are pure seams.
- **By hand, after a restart,** with Screen Recording granted:
  - In Chrome, ask for a button inside the page. The arrow lands on its text.
  - In a canvas app or a remote desktop window, ask for a visible label.
  - Ask for an icon-only control that the app left unlabelled. Launchy says it can't see it.
  - Revoke Screen Recording. Option 01's answer stands and nothing breaks.
  - Launchy's log holds no recognised text. No image file appears in Application Support or the temporary folder.
- **Hand check:** whether macOS 26 asks again for Screen Recording after some weeks, and whether its capture indicator shows for a single-window capture. Record what the user sees.

## Out of Scope

- Any model looking at the image (option 03, option 04).
- Capturing more than the focused window.
- Recognising icons or pictures.
- Keeping or showing the screenshot.

## Further Notes

- **Accepted by the user on 2026-10-09,** relayed by the coordinator, as written, after option 01 shipped.
- **Changed while it was built (2026-10-09):**
  - **The reviewer:** a 2 s limit on the capture and recognition together, and in Chrome one combined Jev call of the toolbar's elements plus the page's lines inside the web area.
  - **The user:** short typed text in fields Launchy can't place may go to TypeSafe, with the drops above as mitigations. Recorded in ADR 0021.
- **Builds on option 01.** It can't stand alone. It also stacks with option 04: text recognition first, Claude only when this finds nothing too.
- **ADR:** [0021](../../../adr/0021-a-window-whose-tree-lacks-the-thing-is-read-from-a-screenshot-on-this-mac.md). It amends ADR 0019: a screenshot is read on this Mac, never stored or sent; its short lines go to TypeSafe under the same gate; Screen Recording is added.
- **Verified:** nothing in Launchy captures the screen today. **In the SDK, not tried here:** single-window capture in ScreenCaptureKit (macOS 14), and line-level text recognition with boxes in Vision. **Unverified:** the latency, recognition quality on small UI text at Retina scale, and macOS 26's re-prompts.
