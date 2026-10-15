---
problem: sessions-finish-unnoticed
title: Option 01, plus macOS notifications posted by a small notifier app beside Launchy
summary: Option 01, plus a macOS notification for each notice. Launchy is a bare executable, which can't use the notification center, so the notifications are posted by a small app bundle that `make build` assembles beside the binary, as it puts zmx there. The banner names the session and what it needs. Clicking it opens that pane, and clearing the notice withdraws it. macOS asks permission once, at the first notification. Without permission, option 01's menu bar mark and sound carry on. The first ticket checks whether Launchy's own binary can post after all; if it can, there is no notifier app and Launchy posts itself. This works on the checkout builds the user's Macs run today, and in a Launchy.app later. Rough effort is about a week, option 01 included.
status: accepted
---

## Solution

Option 01's notices, rules and Settings switches stand unchanged. This option adds a banner for each notice.

**First, a check.** A throwaway executable built like Launchy (bare, with an Info.plist linked in, signed with Developer ID and the hardened runtime as Launchy is) asks the notification center for its settings, and nothing more. Whatever it finds, nothing is ever posted from it.
- If it gets an answer, Launchy posts its notifications itself, in process, and the notifier app below isn't built.
- If it raises the exception the problem describes, Launchy never touches the notification center, and the notifier app posts for it.

The rest assumes the second outcome, which is the expected one.

**The notifier app.**
- **What it is.** A small app with no window and no Dock icon, built from the same package.
- **Where it goes.** `make build` puts it in an app bundle beside Launchy's binary, with its own bundle id and the display name "Launchy". It moves into place by rename, like zmx.
- **When it runs.** Launchy starts it, hidden and never activated, the first time it has a banner to post. The notifier quits when Launchy quits.
- **What posts.** Only the notifier talks to the notification center, so System Settings › Notifications lists one entry, "Launchy", which is the notifier's.

**A banner.**
- **Its title** is the session's title as the board shows it, with "on" and its Mac when it runs on another one.
- **Its body** is what the notice says: "Needs permission", "Has a question", "Plan to approve", "Waiting on an MCP server", "Done" or "Stopped on an error: rate limit".
- **Its identity** is the pane, so a newer banner for a pane replaces the older one, as notices do.
- **Its sound** is the system's default. The user can turn sound, banners or alerts off for Launchy in System Settings, as for any app. While banners are allowed, option 01's own sound isn't played, so there is one sound, not two.

**Withdrawal.** When option 01 clears a pane's notice, its banner is withdrawn from Notification Center: the turn moved on, the pane came on screen, the pane closed, or the category was switched off. When Launchy starts, every banner left from its last run is withdrawn, since what they said is no longer known to hold.

**A click** on a banner tells Launchy which pane:
- Launchy shows the panel, closes the board or Settings if open, switches to the pane's tab and focuses the pane.
- If the pane has closed since, the panel opens on the session board.
- If Launchy isn't running, the click does nothing.

**Permission.**
- **When macOS asks.** At the first banner Launchy would post, not at launch, so the question comes with a reason in front of it.
- **What Settings shows.** Settings › Claude shows the system's answer beside the three switches:
  - allowed;
  - not asked yet;
  - turned off, with a button that opens System Settings' Notifications pane.
- **When it is denied or off,** option 01's menu bar mark and sound do the job alone.

## Trade-offs

- **Banners on the user's Macs now.** Every runs-only-from-a-checkout option keeps the checkout build bare, so posting from Launchy itself would leave the user's own Macs without banners for as long as they run checkouts. The notifier doesn't wait on that problem.
- **Banners where cmux has them.** They are on the lock screen, in Notification Center's history, and in Focus filters, and they name the session.
- **A second executable to build and sign.**
  - It needs its own Info.plist, a bundle step in the Makefile, and signing in step with Launchy's: Developer ID and the hardened runtime where the building Mac has the identity, else ad hoc (ADR 0022).
  - An Upgrade (ADR 0013) can rebuild the notifier under a running Launchy, so the messages between them have a frozen shape that only gains optional fields.
- **Messages between processes.** Launchy and the notifier talk through distributed notifications.
  - Any process of the same user can read them, so a session's title passes where other local programs could see it. Those programs can already read Claude Code's transcripts.
  - Any of them could also post a click, which at worst brings a pane on screen.
- **Permission across rebuilds.** Signed with Developer ID (ADR 0022), the notifier is known to macOS by team and bundle id, so its permission is expected to survive rebuilds, as Launchy's Accessibility and Screen Recording did (measured 2026-10-09). For notifications this is unverified.
- **Option 01's own limits stand.** One Mac per session, a peer read every 5 s, and the failed word read from the transcript.

## User Stories

1. As the user, I want a macOS notification naming the session when a turn on any of my Macs finishes, so that I see which one without opening Launchy.
2. As the user, I want a notification for a session waiting on a permission dialog, a question, a plan or an MCP request, saying which, so that I know what it needs before I open it.
3. As the user, I want a notification when a turn stopped on an API error, with the kind, so that I can tell a rate limit from an outage.
4. As the user, I want to click a notification and land on that session's pane with focus in it.
5. As the user, I want a notification gone from Notification Center once the session has moved on or I have looked at it, so that what's left there still needs me.
6. As the user, I want one notification per session at a time, the latest, never a stack of old ones for the same session.
7. As the user, I want macOS to ask me about notifications when Launchy first has one to show, so that I know what I'm agreeing to.
8. As the user, I want Settings to say whether notifications are allowed and take me to System Settings when they aren't.
9. As the user who said no to notifications, I want the menu bar mark and sound to keep working.
10. As the user, I want to control sounds and banners for Launchy in System Settings, as for any app.
11. As the user, I want notifications to keep working after `make build`, Upgrade and Restart Launchy without being asked again.
12. As the user, I want no leftover notifications from before a restart.

## Implementation Decisions

- **The check comes first,** as its own ticket, in a throwaway folder, and is never run inside Launchy. It also tries the deprecated older API's default center, for the record only. Nothing is built on that API, which is deprecated since macOS 11.
- **Launchy's side.**
  - One place sends the notifier four kinds of message: post, withdraw one, withdraw all, and ask for the permission state. It receives two: a click, and the permission state.
  - Option 01's notifier calls it when it raises or clears a notice.
  - With the notifier, Launchy's own process never touches the notification center at all.
- **The notifier's side.** It is the notification center's delegate from launch, so a click that started it is received.
  - It asks for authorization (alert and sound) before its first post.
  - It reports the permission state when asked, and when the user changes it.
- **Starting it.** Launchy starts the notifier through the workspace with "don't activate" and its own process id as an argument. It holds messages until the notifier says it is listening. The notifier watches for that process to end and quits then.
- **Its bundle id** is Launchy's with a suffix, and its display name is "Launchy". It is signed with the same identity and the same rules as Launchy's binary.
- **The headless host and Linux** don't build it. The relay's package is unchanged.
- **In a Launchy.app,** the notifier would be embedded in the bundle, or replaced by option 03's posting in process. runs-only-from-a-checkout decides when it gets there.
- **Documents.**
  - The Makefile's comment says why there is a second bundle.
  - where-it-breaks gains three rules:
    - Launchy's own process never touches the notification center outside an app bundle;
    - the messages between Launchy and the notifier have a frozen shape;
    - the notifier is built and signed with Launchy.
  - The README's privacy section says what a notification shows.

## Testing Decisions

- Option 01's tests and checks, plus the following.
- **The check's outcome** is written into this option's ticket before any notifier code.
- `make build` passes. The notifier bundle is beside the binary, and a strict verify of its signature passes.
- **By hand, after the user restarts Launchy:**
  - **The first prompt:** the first notice asks for permission once. Allowing it shows the banner.
  - **Banners:** a banner for Done, for each dialog, and for Stopped on an error.
  - **Clicks:** a click opens the pane. A click on a closed pane's banner opens the board.
  - **Withdrawal:** answering a dialog in the pane withdraws its banner.
  - **One sound:** no doubled sound.
  - **Denied:** turning notifications off in System Settings leaves the menu bar mark and sound. Settings says notifications are off.
  - **A rebuild:** after `make build` and Restart Launchy, notifications post without a new prompt, and the old run's banners are gone.

## Out of Scope

- Everything option 01 leaves out.
- **Time Sensitive notifications** that break through Focus. They need an entitlement an ad-hoc build can't carry (inferred).
- **Actions on the banner,** such as Allow or Deny for a permission dialog from Notification Center.
- **Banners on a Mac that shows the session only on a card.**

## Further Notes

- **Why a separate app.** `osascript`'s `display notification` is the one other way a bare executable posts today. It posts as Script Editor, a click opens Script Editor, and nothing can be withdrawn.
- **If the check finds the bare binary can post,** this option becomes option 03's in-process posting without waiting for an app bundle. Then it costs about a day and a half on top of option 01, not three.
