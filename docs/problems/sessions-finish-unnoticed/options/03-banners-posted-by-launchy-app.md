---
problem: sessions-finish-unnoticed
title: Option 01, plus macOS notifications Varnick posts itself once it runs as Varnick.app
summary: Option 01, plus a macOS notification for each notice, posted by Launchy in its own process, but only when it runs from an app bundle. Today no Launchy runs from one; runs-only-from-a-checkout's options 02 to 04 would make Launchy.app. Every one of those options keeps the checkout build, which the user's Macs run, a bare executable, and there Launchy never touches the notification center (expected to end the process) and keeps option 01's menu bar mark and sound. One process, Launchy's own name and permission entry, no helper and no messages between processes. Banners, clicks, withdrawal and the permission prompt are as in option 02. Rough effort is a day and a half on top of option 01, once Launchy.app exists.
status: proposed
---

## Solution

Option 01's notices, rules and Settings switches stand unchanged. Option 02's banners are posted by Launchy itself, with no notifier app:
- the title and body;
- one banner per pane, replaced and withdrawn as notices are;
- a click opening the pane;
- the permission asked at the first banner;
- Settings showing the system's answer.

**Only from an app bundle.**
- **In a bundle.** At launch Launchy checks whether its main bundle is an app bundle. If it is, Launchy becomes the notification center's delegate before launch finishes, so a click that launched it is received, and posts banners for notices.
- **Outside one.** If it isn't, Launchy never calls the notification center. It shows option 01's menu bar mark and plays its sound. Settings › Claude says "Notifications need Launchy.app" under the switches.

**Where the bundle comes from** isn't decided here. runs-only-from-a-checkout's options 02 to 04 make Launchy.app for installing. If that problem also has `make build` wrap the checkout build in a bundle, this option reaches the user's own Macs with no change.

## Trade-offs

- **The simplest delivery.** One process, Launchy's own name and permission entry, and clicks handled in process. No second bundle to build or sign, and no messages between processes.
- **Waits on another problem.** Banners arrive only with Launchy.app, about a week and a half away if runs-only-from-a-checkout's option 02 is accepted. They reach the user's own Macs only when those run the app.
  - The user's own Macs upgrade from checkouts (ADR 0013), so until runs-only-from-a-checkout settles how they run, they get option 01 only.
  - A Mac that moves to the app trades Upgrade from origin/main for that problem's update story.
- **Signed apps keep permission.** A Developer ID signature, which every Launchy.app option has, keeps the permission across updates as macOS does for any signed app.
- **Option 01's own limits stand.**

## User Stories

1. As a person running Launchy.app, I want a notification naming the session when a turn finishes, needs me or stops on an error, posted under Launchy's own name.
2. As a person running Launchy.app, I want a click on it to open that session's pane, even when the click is what started Launchy.
3. As the user running a checkout build, I want Launchy never to crash over notifications, and to be told in Settings that banners need Launchy.app.
4. As the user running a checkout build, I want the menu bar mark and sound meanwhile.
5. Option 02's stories 5 to 10 and 12, unchanged.

## Implementation Decisions

- **The bundle check** is one test of the main bundle's location: an app bundle's path ends in ".app". It runs before anything touches the notification center, and nothing else may.
- **The delegate** is set in the app delegate's will-finish-launching, the one point early enough for a click that launched the app.
- **Withdrawing at launch.** Every banner left from the last run is withdrawn at launch, as in option 02.
- **Documents.** where-it-breaks gains the rule that Launchy never touches the notification center outside an app bundle. The README says banners need Launchy.app.

## Testing Decisions

- Option 01's tests and checks.
- **A checkout build** after `make build` and a restart: no crash, no prompt, and the Settings note shows.
- **Launchy.app,** once it exists: option 02's checks by hand. Also a click on a banner while Launchy isn't running starts it and opens the pane.

## Out of Scope

- Everything option 01 and option 02 leave out.
- Making the checkout build a bundle: runs-only-from-a-checkout's to decide.

## Comments

**2026-10-17, at the user's ask.** The notice switches moved from Settings › Claude to their own Settings › Notifications section. Where this option says Settings › Claude, read Settings › Notifications.
