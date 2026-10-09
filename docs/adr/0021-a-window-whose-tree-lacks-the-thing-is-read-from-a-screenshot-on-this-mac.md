# A window whose Accessibility tree lacks the thing is read from a screenshot, by text recognition on this Mac

A spoken request about the screen still reads the focused window's Accessibility tree first (ADR 0019). When that fails, Launchy captures the focused window alone, into memory, and runs Apple's on-device text recognition on it. The tree fails when:
- Jev finds the thing isn't among the listed elements (`present` under 0.5);
- the window lists nothing;
- or Chrome hides its page.

The short lines it finds are the shape of a label: at most 6 words and 60 characters, at most 150 of them. They go to the same Jev call, `target` and `present`, under the same gate, each described as "text on screen" with its words. A line Jev finds present (0.5 or more) gets the **Arrow**, ringing the line's box. No model looks at the image. The image is dropped once the text is read, and is never written, logged or sent.

The user accepted this on 2026-10-09 so that requests reach what the tree can't: Chrome's pages without its accessibility flag, canvas apps, remote desktops and unlabelled controls that carry text. This amends ADR 0019, whose "No screenshot is taken" now holds only for the tree's step. The problem and its options are in `docs/problems/spoken-requests-cant-see-the-screen/`; this records option 02.

## What goes to TypeSafe

Only on a miss of the tree, and only under ADR 0019's gate (Point at the screen on, which needs the relevance filter on TypeSafe with a key):
- the request;
- the window's title;
- the recognised short lines' words.

That is more of the window's text than ADR 0019 sends. It is every short line in the window, not only the text beside a control: a message list's subjects and senders, a document's headings, a chat's names. Never the image, a box, a longer line or the tree's elements a second time. Settings, the README and SECURITY.md say so.

## Typed text can go

The user decided this on 2026-10-09. A picture shows what a person typed as well as what an app wrote, and text recognition can't tell the two apart. So ADR 0019's promise that what a field holds never goes doesn't hold for this step. Launchy drops what it can place:
- **What is dropped:**
  - lines whose centre lies inside a field the tree's walk met: text fields, text areas, combo boxes, search fields and secure fields;
  - lines inside the field that has focus in the app, even when the walk didn't reach it.

  The fields are read where the window was during the walk, and shifted to where the window is in the capture.
- **What can still go:** typed text of 6 words or fewer, in a field Launchy can't place. That covers:
  - a Chrome page's fields;
  - canvas apps, remote desktops and virtual machines;
  - fields past the walk's limits;
  - a field that moved within the window after the walk.

  Such text goes with the other lines, under the same gate.
- **Secure fields' frames are now read,** so that what lies in them is dropped. Only where the field is gets read, never anything in it, and the frame stays on this Mac. ADR 0019 read nothing of a secure field.

## The permission

Launchy now also needs Screen Recording. Without it the fallback is skipped and the tree's answer stands. The grant follows ADR 0019's rules for Accessibility:
- The capture runs only in Launchy's process, never from a pane, and zmx is never granted.
- While builds are signed ad hoc, a rebuild may stop the grant from applying.
- Panes started outside zmx probably share it (`panes-share-launchys-permissions`). (Superseded: see the correction of 2026-10-09 in ADR 0019, which holds for this grant too. Every pane process, zmx-hosted ones included, is attributed to Launchy, so every session in its panes can capture the screen while Launchy holds Screen Recording.)

## Considered Options

- **Gemma 4 E2B looking at the screenshot (option 03)** and **Claude looking at it (option 04)**: not built, and still proposed. Option 03 waits on a spike. Option 04 may stack after this one, since the user answered that a screenshot may leave this Mac.
- **Capturing the whole display**: rejected. Other windows and the desktop would be in the image and in its text.
- **Sending every recognised line, paragraphs included**: rejected. The length cut keeps a document's or a mail's body out of the call.

## Consequences

- Icons without text are still missed. The arrow rings a line of text, which can sit beside its control: a checkbox's label rather than its box.
- The eval measured Jev on Accessibility lists only (ADR 0019). How well it picks among recognised lines is unmeasured, and `--ask --app` on Chrome pages is the first check.
- A miss of the tree now costs a capture, a recognition and a second Jev call. That is estimated at 0.5 to 1.5 s, unmeasured, and paid only on a miss.
- The fallback runs where the tree's step runs: during the hold (ADR 0017), in the speculative run. So a partial request's recognised lines may reach Jev and be discarded, as its element descriptions may. The image is never kept for a later run.
- macOS may show its capture indicator, or ask again after some weeks whether Launchy may keep recording. This is unverified on macOS 26.
- Anything added to what this call carries is a privacy change, as for ADR 0019's call.
