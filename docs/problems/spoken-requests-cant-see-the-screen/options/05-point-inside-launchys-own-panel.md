---
problem: spoken-requests-cant-see-the-screen
title: When the panel has focus, read it like any other window, then the app behind it
summary: Option 01 skips Launchy's own process when it picks the window to read. So with the panel open and a session's name on it, "where is Kestrel on my screen" reads the app behind the panel and answers "I can't see that on your screen." This option stops skipping it. With the panel focused, Launchy reads the panel's own Accessibility tree through the same walk and the same Jev `target` and `present` call as any window. If `present` is under 0.5, it reads the frontmost other app as today. Session, project and page names in the panel go to TypeSafe like any window's labels, under the user's principle of 2026-10-09: choosing TypeSafe is consent to send what a TypeSafe feature needs. No registry and no local matching. Three things need checking first: how good the SwiftUI panel's tree is, reading its own process from the detached read, and which window to try first.
status: accepted
---

## Solution

`ScreenReader.focusedApplication` returns Launchy itself when the panel has focus, instead of falling through to the frontmost other app. The rest is option 01's path, unchanged:

1. The walk reads the panel's focused window, off the main actor, within option 01's limits. The listing rule, labels, beside-text and never reading a field's value all apply.
2. One Jev call, `target` and `present`, over the panel's elements, with "Launchy" as the window's title.
3. `present` at 0.5 or more: the Arrow points at the element in the panel. Otherwise Launchy reads the frontmost other app, exactly as option 01 does today, and asks again.

## Trade-offs

- **Small.** A change to which process is read, and a second read when the panel didn't have the thing. No new module, no state registry, no frames from SwiftUI.
- **Same accuracy model as every other window.** Jev reads the panel's labels as it reads System Settings'. Paraphrase works ("the session about the reranker"), since Jev, not word matching, picks.
- **The panel's names go to TypeSafe.** Session titles, project and folder names, Mac names, page titles in results, and problem titles on the board are what the panel shows, so they are in its labels.
  - ADR 0016 and 0017 kept session and project names from TypeSafe. The user's principle of 2026-10-09 (recorded in those ADRs) is that choosing TypeSafe is consent to send what a TypeSafe feature needs, and that privacy is the On this Mac setting.
  - With the filter On this Mac, nothing points at all (option 01; the problem's open question), so nothing is sent.
- **Unknowns, checked before building:**
  - **The SwiftUI panel's tree.** Rows may come through as groups of text without a role a person points at, or with labels that don't name the row. The eval measured AppKit and SwiftUI system windows, not Launchy's.
  - **Reading its own process.** Accessibility requests to Launchy are answered on its main thread. The read runs detached while the main actor awaits it, so the main thread should be free to answer, but a slow answer costs the walk's budget. Unmeasured.
  - **Which window first.** The panel first matches what floats in front. But a request about the app behind ("the Allow button") then pays a wasted Jev call, about 0.12 s, or more on a Chrome page.
- **What the panel's tree may hold beyond rows.** A web pane's page and a custom app's page expose their content through WebKit's tree, so their visible text would be read as any browser's is. A terminal pane is very likely absent: SwiftTerm's Mac accessibility is an empty stub. Inferred.

## User Stories

1. As a Launchy user with the panel open, I want "where is Kestrel on my screen" to point at the Kestrel tab or row.
2. As a Launchy user, I want "which one is the session about the reranker" pointed at in the session list or on the board.
3. As a Launchy user, I want "where's settings" or "where's the pin" to point at Launchy's own controls.
4. As a Launchy user with the panel open over another app, I want a request about that app still answered from that app.

## Implementation Decisions

- **Which process.** `focusedApplication` no longer skips Launchy's own pid. When the system's focused application is Launchy and its panel is visible, Launchy is read. When the panel is hidden or pinned behind other windows, the frontmost other app is read, as today.
- **The read.** Option 01's `ScreenReader.read`, on Launchy's own pid, from the detached task. Launchy's own Arrow overlay is never listed: it ignores the mouse and isn't the focused window.
- **The fallback.** `present` under 0.5 on the panel reads the frontmost other app and asks Jev again. The timing line names both reads.
- **The order** starts as the panel first, the thing the user is looking at, and is a named choice to flip if the checks say so.
- **Privacy text.** Point at the screen's detail, the README and SECURITY.md say that with the panel open, its names (sessions, projects, Macs, pages) go to TypeSafe like any window's. That follows ADR 0016's amended line.

## Testing Decisions

- **Before building, a spike:** `Launchy --ask --app` run against the running Launchy while the panel shows. `--app` looks only among regular apps today, and Launchy runs as an accessory, so the spike lets it name Launchy. It checks:
  - the list of elements and their descriptions: are tabs, session rows, result rows, board cards and the pin listed, with labels a person would use;
  - the read's time with the main thread idle and while the panel is busy.

  Too few or unusable elements sends this back to the user with the dropped design below.
- **By hand, after a restart:**
  - with tabs open, ask for one by name;
  - with the empty field, ask for a Recent session by what it was about;
  - after a `?` search, ask for a result;
  - ask "where's the pin";
  - with the panel over System Settings, ask for a switch there.

  Each points at the right thing, and the panel keeps key and its state.

## Out of Scope

- Frames from SwiftUI's layout, and any state registry (the dropped design).
- Terminal text inside panes.
- "Which session needs me" (a question about **Turn**, for `sessions-finish-unnoticed`).

## Further Notes

- **Seen 2026-10-09, after option 01 shipped (merge 63807cc).** With the panel open and a session's name on it, a request for that name "on my screen" got "I can't see that on your screen". The request and the name are the user's and are kept locally.
- **Accepted by the user on 2026-10-09,** relayed by the coordinator, as this simple version.
- **Rewritten 2026-10-09 at the user's direction,** after the principle that choosing TypeSafe is consent to send what a TypeSafe feature needs.
- **Considered and dropped: targets from Launchy's own state** (this option's first version).
  - A registry of every pointable view's frame from SwiftUI's layout.
  - The user's names matched on this Mac, by words and by the session ranking, and never sent.
  - Only Launchy's own control names, and page rows TypeSafe had already judged, went to Jev.

  Dropped because its reason, keeping session and project names from TypeSafe, no longer holds under the principle. That left a registry and a weaker word matcher for no gain. It comes back if the spike finds the panel's tree unusable.
- **ADR:** an amendment line to ADR 0019, on acceptance: Launchy's own panel is read like any other window.
- **Verified in the code:**
  - `focusedApplication` skips Launchy's own pid and falls back to the frontmost other app's window;
  - `--app` matches regular apps only, which Launchy, an accessory, isn't;
  - the read runs detached;
  - SwiftTerm's Mac accessibility service is an empty stub.
- **Inferred:** the panel's tree quality, answering its own Accessibility requests in time, and WebKit panes exposing their text.
