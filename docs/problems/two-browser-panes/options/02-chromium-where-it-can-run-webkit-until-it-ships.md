---
problem: two-browser-panes
title: "Chromium serves every page pane where it can run, WebKit stands in until the framework ships inside Varnick.app and the hand check passes, then WebKit's page path goes"
summary: One Browser pane, drawn by Chromium, built in nine small merges. The engine starts the first time a page needs it, with no restart. Until the last merge a page pane gets Chromium when the engine can run on this Mac (the framework is there, it hasn't failed in this process, and a Settings › Experimental switch is on) and WebKit otherwise, so the installed app and a Mac whose engine failed still show pages. CDP is reworked before the user's logins move in, WebKit's cookies are carried over once, and what a page asks of its pane (dialogs, menus, new windows, downloads) is answered by Varnick. Once Varnick.app carries the framework and the user's hand check passes on it, WebKit's page path is deleted; a file pane's rendered Markdown stays on WebKit.
status: in-progress
---

## Solution

**One Browser pane, drawn by Chromium.** The split picker's Chromium tile goes, and Browser is Chromium: the address bar's pages, `pane_open`'s `page`, `find_open` beside a session, custom apps, Scratch, and the pages of another machine's tab. A saved Chromium pane comes back as a Browser pane. A file pane's rendered Markdown stays on WebKit.

**No restart.** The engine starts the first time a page pane is on screen and needs it, on any Mac, and stays until Varnick quits (it can't be started twice in a process). A Mac that never shows a page never pays its 200 MB.

**WebKit stands in until Chromium ships.** While the work is under way a page pane gets Chromium when the engine can run here and WebKit when it can't:

| The page gets | When |
|---|---|
| Chromium | The framework is beside Varnick (a checkout) or inside it (the app, from step 8), Pages in Chromium is on, and the engine hasn't failed to start in this process |
| WebKit | Any of those is not so: an installed app before step 8, the switch off, or a start that failed |

The choice is made when the pane's page is made, and a pane keeps its engine until it closes. A page showing the engine's failure moves to WebKit at its Reload. A WebKit page can't be driven, and `pane_read` says so and why.

**Everything a page pane does today keeps working in Chromium**: the title, the address (a page's own history changes too), the address bar, ⌘L and ⌘R, the waiting card and its retries while a dev server or an app starts, the host's reason and retry for a proxied page, an app's output when its server exits and Reload running it again, focus, keys, restore after a restart, and light or dark as the system is.

**What a page asks of its pane is answered by Varnick,** never by the engine's own windows or modal alerts: dialogs, the context menu, new windows and popups, downloads (the answers recommended below are the user's to confirm).

**Driving a page** goes through what the user chooses for CDP (below), changed before the user's logins move into Chromium.

**Logins come along once** (recommended): at the first engine start on a Mac where WebKit holds cookies, they are copied into Chromium's profile.

**Then WebKit's page path goes,** with the switch, once Varnick.app carries the framework and the user has checked it by hand.

## Trade-offs

- **For:** every step is merged and checked on its own, and none leaves a page pane blank: before step 8 the installed app shows pages in WebKit as it does today, and a Mac whose engine fails at start falls back. The riskiest piece, the start without a restart, lands first and alone, on the Chromium tile, before any page depends on it. CDP is settled before real logins sit behind it.
- **Against:** two engines live in the code for the length of the work, and a page behaves a little differently depending on which it got (a WebKit page can't be driven). Every behaviour carried in steps 5 and 6 is written for Chromium beside the WebKit code it replaces, and deleted from WebKit only at step 9. Nine merges, each needing the user's restart to check. The switch is one more state to reason about while it exists.

## User Stories

1. As the user, I pick Browser in the split picker and the page opens in Chromium, with no restart, on a Mac that has never shown one.
2. As the user, a page I had open comes back after a restart, at the address I left it on, the address a single-page site moved to included.
3. As the user, my custom apps and Scratch open in Chromium, the pane waits while the server starts, shows what the server printed if it exits, and Reload runs it again.
4. As the user viewing a tab of another Mac, its pages at the host's localhost load through the host's port proxy in my Chromium, with the host's reason when they can't.
5. As the user, the sites I was logged into in Varnick's pages are still logged in after the change.
6. As a session, `pane_read` on any Chromium page pane gives me what I need to drive the page the user sees, and on a page that fell back to WebKit it tells me it can't be driven.
7. As the user, a site's "Sign in with Google" popup opens as a pane beside the page and closes when the site closes it, and a link that opens a new window opens a Browser pane beside this one.
8. As the user, a file I download lands in my Downloads folder, marked by macOS as downloaded, and the pane says where it went.
9. As the user, a page's `alert()` never freezes Varnick.
10. As the user of the installed app, pages work before and after the app carries Chromium.
11. As the user, while Chromium is experimental I can turn it off for new pages in Settings › Experimental.
12. As the user, Resources shows what Chromium costs, in one row.
13. As the user, nothing on this Mac can read my Varnick logins through an open debugging port, except as I chose for CDP.

## Implementation Decisions

### Order of the work

Each step is its own branch and merge, with `make build` and the `make check-*` targets clean, and is checked by hand by the user after a restart, which is the user's to make. Step 1 first, once the removal of Tasks (under way on 2026-11-12) has merged, since it touches the same web pane code; 2 and 3 before 5; 2 before 4; 8 and the user's check of it before 9.

1. **The engine starts when a page wants it, with no restart.** On the Chromium tile only; Browser panes stay WebKit. Start at launch and the restart message go.
   *Checked by hand:* with `chromiumStartsAtLaunch` deleted from Varnick's defaults before the restart, Resources shows no Zebkit helper after launch; the Chromium tile opens a page with no restart and the log has one "Chromium … started" line; a Chromium pane restored in the tab on screen loads at launch, and one restored in a hidden tab starts nothing until that tab shows; picking the tile and at once opening the menu bar menu, the folder picker (a modal panel) or dragging a pane or a divider crashes nothing and the page shows once that ends; then ten minutes of typing in a Claude pane beside a loaded page leaves no "Chromium pump took" line but those of a menu or drag.
2. **CDP as the user chooses** (below), before any real login moves in. The recommendation is a short spike of zebkit's credentialed endpoint, then that endpoint or CDP on demand.
   *Checked by hand:* with a Chromium pane open and no session reading it, `lsof` lists no listening port of Varnick's but those it had before; a session's `pane_read` gives an endpoint, and a client drives the page through it; for CDP on demand, the port is gone after the idle time (a shorter time set for the check) and comes back at the next read.
3. **What a page asks of its pane, on the Chromium tile.** Dialogs, the context menu, new windows and popups, downloads, as below.
   *Checked by hand:* on test pages, `alert`, `confirm`, `prompt` and a "leave this page?" page get WebKit's answers with Varnick responsive throughout; a right-click shows the menu and every item works, a menu left open for a minute freezes no Claude pane; a `target=_blank` link and `window.open` from a click open a Browser pane beside; a sign-in popup (a site's Google sign-in) opens beside, completes and closes itself; a download lands in Downloads under a free name, `xattr` shows `com.apple.quarantine` on it, and the pane says where; keys, the mouse, ⌘C, ⌘V and ⌘A, and a Japanese input method work in a field of the page.
4. **WebKit's logins carried over once,** if the user wants it (below).
   *Checked by hand:* be logged into two sites in a WebKit Browser pane, one of them using `__Host-` cookies. After the restart, open a Chromium page first, before any WebKit page or app pane: the log has one "Chromium logins:" line, with counts only and WebKit's count above 0, and the page waits at most about 3 s; both sites are logged in. Wait 60 s and restart: both are still logged in, and the log says the copy is confirmed. Restart again at once: still logged in, and the log has no copy line. Also restart straight after the first copy, with no wait, and see both still logged in after the next start (the copy is retried if the write was cut off). With only one site's cookies in WebKit, log out of it in a Chromium pane before the confirming restart: it must not come back after it, and the log says the copy is confirmed and the check cookie removed. Whether macOS asks about the keychain after a signed rebuild, and after an ad hoc one.
5. **Browser panes in Chromium.** The Chromium tile goes, the switch arrives, and the address bar's pages, `pane_open`'s `page` and `find_open` beside open in Chromium where it can run.
   *Checked by hand:* the cases of story 1, 2 and 6; a single-page site's route change shows in the address bar and survives a restart; a dark Mac shows a site's dark theme; switching tabs hides the page and showing it again redraws it; the strip's lists, the split picker and a pane drag's veil draw above the page; a click on the page focuses its pane, and ⌘⇧H/J/K/L, ⌘W and ⌘L work with the page holding the keyboard; with the switch off, a new page opens in WebKit and an open Chromium page stays.
6. **Apps, Scratch and proxied pages in Chromium,** with the load failure and its retries.
   *Checked by hand:* a page at a localhost port before its server starts says it is waiting and appears by itself once it runs; Scratch opens beside a Claude pane and reloads as Claude writes; an app whose server is killed shows its output and Reload runs it again; a page of another Mac's tab at that Mac's localhost loads through its proxy, says the host's reason when the host's Phone page server is stopped, and loads at once when it is back.
7. **Resources and screen reading count Chromium.** Resources gives the engine's helpers a row of their own; a spoken screen request with Varnick's panel in front over a Chromium page reads the page (a session's `look` never reads Varnick's own windows).
   *Checked by hand:* Resources' Chromium row appears with the first page and its total matches Activity Monitor's for this Varnick's helpers; a spoken screen request about a page in the panel answers from the page's text.
8. **The framework inside Varnick.app.** `make app` copies it into the bundle and signs it for notarization (built and verified locally 2026-11-13; notarization not tried, hand check not done).
   *Checked by hand:* `make app` notarizes; on a Mac, the installed app opens a Browser pane in Chromium, a custom app and Scratch, survives a restart with them, and Gatekeeper raises nothing for the helper.
9. **WebKit's page path deleted,** after the user's go-ahead on step 8's check. **Built 2026-11-13 on James's go-ahead given ahead of step 8's check** (see "Step 9, as built").
   *Checked by hand:* every check of steps 3, 5 and 6 again on the installed app, and a file pane's rendered Markdown still shows. Since step 9 these checks are one list, ordered by what is likeliest to fail, in where-it-breaks ("By hand, the whole browser"), which absorbs the list of each of steps 1 to 8.

### The engine's start

- **Where.** Varnick's application object starts the engine as it dispatches an event, when a page has asked and no run of the main run loop is under way. A count of the main run loop's entries and exits, kept from launch by an observer in the common modes, says so. zebkit's pump counts entries and exits too (ADR 0048); which modes it counts is unverified, so a run in a mode outside the common ones would be missed by Varnick's count. A main-queue block, a timer, an observer, a SwiftUI update and any loop opened inside them are inside a run, so the start waits for the next dispatch. This is what the user's harness showed on 2026-11-12: a start from the application's event dispatch worked, one from a main-queue block crashed.
- **Never waiting on the user.** When a page asks, an application-defined event of Varnick's own is posted, so the next dispatch comes at once even with nobody at the Mac. Its fields never match the event by which zebkit leaves its wait.
- **Loops of their own** (inferred from how AppKit runs them; the hand check covers both). A menu's tracking loop doesn't dispatch through the application, so a start asked during one waits until it closes. A modal panel dispatches between runs, so the engine may start while one is up.
- **What goes.** Start at launch, the precondition that forbids a late start, and the meaning of `chromiumStartsAtLaunch`, which is no longer read (nothing deletes it). The page's "restart Varnick" message goes, except after a start that failed, which stays final for the process.
- **Cost.** About 200 MB from the first page until Varnick quits.

### Which engine a page gets

- Decided once per pane, when its page is made (the table in Solution). The rule is a pure function of three facts, so a harness can check it.
- **Saved state.** No new field. The `chromium` mark on saved records is still decoded and means nothing from step 5; it is never written again. An older build reading the file shows those pages in WebKit. One new UserDefaults key for the switch, and one that says WebKit's cookies have been copied (step 4).
- **The switch** (Settings › Experimental, "Pages in Chromium"), on by default wherever the framework is. Off, new page panes open in WebKit; a running engine stays until the restart. Removed at step 9.
- **Step 5 built it so** (ADR 0048, "Which engine a page gets", has the rule, the files and what is unverified). **A deliberate, temporary departure from step 5 as written above, ended by step 6 (see "Step 6, as built" below):** until step 6, a page opened at a local address stays in WebKit, with a custom app's page and a page of another machine's tab (`pane_open`'s `page` is to open Chromium where it can run, but the waiting card and its retries are WebKit's alone, and step 6's hand check owns them). Its cost was that a session's `pane_open page` at `localhost` got a WebKit page it couldn't drive, while a user typing the same address into a Chromium pane got no waiting card. Where the option was silent, step 5 decided: `pane_open`'s `chromium` kind is no kind but is accepted as `page` for sessions started before; a pane the engine couldn't start moves to WebKit at its Reload, as Solution says; the engine is chosen again at each restore from the last address; the address of a page's own history changes is read from the engine once a second, since neither its load nor its navigation events carry it; fullscreen is denied, as WebKit's was; light and dark came with the engine's `appearance.follow`, which the tile never set.

### What carries over (steps 5 and 6)

- **Title and address** from the engine's title and load events, and a page's own history changes through the engine's navigation events. The address bar shows and saves them as today.
- **The failure card** is the pane's own view over the page, with today's texts and intervals: a local address waits and tries every 1.5 s, a proxied page gives the host's reason and tries every 3 s, and at once when the host lists the address again; a finished load clears it, and a load stopped by a new one is not a failure.
- **App panes** keep their output view and Reload's rerun of the server; **proxied pages** keep the card-then-page rule, the test of which addresses a host's listing may send the page to, and "a page that has loaded stays".
- **Light and dark** follow the system through the engine's startup setting.
- **`pane_read`** gives what step 2 chose for every Chromium page; its text and where-it-breaks' "What the tools do not promise" say that a page pane can now be read and driven.

### Step 6, as built

Where step 6 decided what the option left open or differs from its text (ADR 0048, "Apps, Scratch, proxied pages and the failure card", has the mechanics and what is unverified):
- **Chromium's own error page can't be turned off, and the failure card covers it only for the two addresses that have a text to give**: a local address and a page through the port proxy of the pane's host. Any other address that fails shows Chromium's page (the lead's decision of 2026-11-13, for the user to confirm at the end test), since a code is not words and the page has them; WebKit's card for such an address (the system's description, no retry) stays while WebKit exists. So the carry-over above ("today's texts and intervals") holds for those two, and a public page's failure text changes to the engine's.
- **The card is a view of the pane's own inside `ChromiumPage`, not a SwiftUI overlay**: it is moved above the engine's view when it shows, which is the thing the hand check has to see.
- **A failure is read from the engine's navigation result** (main frame, not Chromium's abort code, the latest navigation), not from its load events, which say only "failed or stopped"; ADR 0048 has the rule, the event order it assumes and the checks.
- **`PageEngine.choose` no longer reads the app, the host tab or the address:** it is the three facts, and `pane_open`'s `app` kind says whether its page is drivable as `page` does.

### What a page asks of its pane (step 3)

Recommended, each the user's to confirm:
- **Dialogs** are answered as WebKit answers them today, by Varnick's handler: `alert` returns, `confirm` is false, `prompt` is null, "leave this page?" leaves. The engine's own system alert, whose modal loop would run inside a pump, never shows. A card in the pane for them can come later.
- **The context menu** is shown by Varnick after the pump has returned, with the engine's own items. Inspect Element is not offered (below).
- **New windows.** A link or `window.open` opens a Browser pane beside this one. A popup linked to its opener (a sign-in) becomes a pane beside it, linked, and closes when the page closes it. The engine never makes a window of its own.
- **Downloads** go to the user's Downloads folder under a free name, marked with macOS's quarantine by Varnick, and the pane says where; a download that can't be saved is cancelled and the pane says why.

Decisions 3 to 6 of Further Notes (new windows and popups as panes, downloads to Downloads with quarantine, dialogs answered silently, Inspect Element dropped) were taken as recommended on 2026-11-13: James was shown them as the defaults and told the builders to keep going, and overrode none. Built with two additions the option didn't state: a pane's focus goes to a pane its page's window opened, and closing a pane cancels the downloads it has in flight.

### CDP (step 2)

`cdp_listen` chooses only the bind address and the port: nothing in zebkit 0.4.0 limits who connects. Four ways, the user's to choose:

| | What | For | Against |
|---|---|---|---|
| A | As the prototype: CDP from the engine's start until quit, no auth | Nothing to build | Any process on the Mac can read every cookie of the profile and drive any logged-in page, all the time. Chrome stopped allowing remote debugging on its default profile in 2025 for this reason (from memory, not checked here) |
| B | CDP on demand: served at a session's `pane_read` of a page pane, stopped 30 minutes after the last such read and when the last page pane closes | Small; the clients sessions use today keep working | No auth while it is open, and a session still driving when the idle time ends is cut off unless it read again, since Varnick can't see clients. Verified in the 2026-11-13 spike that the engine serves again after a stop, repeatedly in one run |
| C | zebkit's Playwright endpoint instead of CDP: its address holds a random token and refuses a request with an Origin header, and only `pane_read` gives it | A real credential, from the engine itself | Sessions use Playwright's `connect`, not CDP clients. The 2026-11-13 spike found it can't reach a view the host made |
| D | No endpoint: Varnick drives pages itself inside the engine, behind tools of its own that know the caller, as Panel access does | Nothing reachable from outside Varnick | The largest build: a new tool surface for reading and acting in pages |

**B, taken 2026-11-13** by this option's own rule below ("if C doesn't show the panes' pages, B") after the spike (notes kept locally) showed that zebkit's token endpoint can't reach a view the host made, so C is out. James was shown this and said to keep going. B was built as step 2; ADR 0048 has what it does, the spike's evidence and what it leaves open. D (`zebkit_automation_call` inside Varnick, no port, behind tools that know the caller) remains a possible end, not decided or built.

**Recommended (before the spike):** a spike of C (a page pane open, Playwright's `connect` to the endpoint, list the contexts and pages). If it shows the panes' pages, C; else B. Never A once real logins are in the profile.

### Logins and the profile (step 4)

- **Today** WebKit's default store holds whatever the user logged into in Varnick's pages, shared by every page and app pane. Nothing moves it: without step 4 every site asks the user to log in again.
- **Recommended, taken as recommended on 2026-11-13** (decision 2 of Further Notes: James was shown it as the default and said to keep going; the answer on clearing WebKit's store at step 9 is the recommendation too, leave it on disk): at the first engine start on a Mac where WebKit holds cookies, every WebKit cookie (HttpOnly ones too) is copied into Chromium's profile once. Local storage and IndexedDB don't move, so a site that keeps its login there asks again. WebKit's store is left as it is. **Built as step 4** in-process, with no port: the engine runs `BrowserContext.cookies` and `BrowserContext.addCookies` through `zebkit_automation_call` with no view. The option's "over CDP for the moment of the copy where it can't" is **not built**: that route starts being built if the hand check shows the in-process write didn't persist (the sites logged out after a restart made 60 s or more after the copy, with the log saying the copy reached Chromium). The first pages wait for the copy for up to 3 s. The copy is **confirmed at a later start** by a cookie of Varnick's own, written last on a made-up host and deleted once found, and retried only when that cookie is missing: it is copied at most three times and the fourth start gives up, so a restart that cuts off Chromium's unflushed write loses nothing for good, and a logout in Chromium is never undone. A WebKit store that reads empty is never taken for "nothing to copy" before the third start (the rule changed from "a Mac whose WebKit store is empty at that start is marked done"). The mapping (session cookies stay session cookies; a Secure cookie with no policy gets `None`, a non-Secure one none), the rule that a cookie Chromium holds is never replaced, the failure rules and what is unverified (above all, that the call reaches the persistent profile before any page exists) are in ADR 0048.

- **Chrome's logins** (the prototype that copies one site's cookies from Chrome) are not part of this option.
- **One profile** for every page and app pane, as WebKit's store is today: a session's `pane_open` `page` loads with the user's cookies, and whatever step 2 opens reaches every site's cookies. zebkit's contexts are in memory only, so nothing persistent per tab or project exists; out of scope.
- **Cookie keys.** The engine's default keeps the cookie key in the macOS keychain, which may ask after an ad hoc rebuild (unverified; the hand check). Its file storage avoids the keychain but keeps the key beside the cookies.

### Resources and screen reading (step 7)

Built as ADR 0048's step-7 bullet says: the helpers are one row, "Chromium's helpers", and the engine starts with its page accessibility on only when Accessibility is granted and Point at the screen is on. Whether the page then shows in Varnick's own tree is unverified and is the first by-hand check.

### The framework in Varnick.app (step 8)

Built and verified locally on 2026-11-13 (the signature, not a run); notarization not tried, and the installed-app hand check not done. ADR 0048 ("Where the framework sits", "Signed with Varnick's identity") has the layout, the signing and what is unverified; `docs/releasing.md` has the trial and the check.

- Copied into the bundle's `Contents/Frameworks` by `make app`, where `ChromiumEngine.frameworkURL` looks in a bundle. Signed inside out, never with `--deep`: the helper with the hardened runtime, the secure timestamp and an entitlements file (`allow-jit`), then the framework, then the bundle. A checkout is signed the same way minus the timestamp, so its restart tests the entitlement.
- The app grows by 143 MB on disk; the zipped app is 140.2 MB and the zipped framework 61.0 MB; the disk image's size is unmeasured.
- **The notices and licences carry zebkit's LGPL-2.1 and Chromium's notices (unverified what zebkit ships for them). Open release blocker, James's to resolve:** the archive ships no licence or notice file, so a release must not ship the framework until `LICENSES/` carries the LGPL-2.1 text, the source offer the LGPL requires and Chromium's third-party notices (`docs/releasing.md`, Before you start).
- **After step 9, on this evidence:** an installed app would have a working browser if notarization accepts the app and the helpers run from `Contents/Frameworks` with the one entitlement; none of those is known. If one fails, step 9 must not land, because WebKit's fallback is what it deletes.

### Step 9

Deletes WebKit's page view and its navigation handling, WebKit's half of the failure card, the mouse monitor's web view case (a file pane's view is found by its file pane), Resources' WebKit page process for page panes (a file pane's stays), the fallback and the switch. An ADR amending ADR 0048 is written when this option is accepted; CONTEXT.md's Browser pane becomes Chromium and its Chromium pane entry folds into it; where-it-breaks gains a Chromium section (the start, the pump, the wait, the endpoint) for the rules that today live only in the code and ADR 0048; `docs/privacy-and-security.md` says what step 2 and the downloads do.

### Step 9, as built

James's go-ahead, in his words of 2026-11-13: "i've already decided to remove webkit's page. so no need to wait on me". The option reserved this step for his word after step 8's hand check; he gave it ahead of that check, knowing that nothing built since step 1 has run inside Varnick and that he will test everything once, at the end. **So no step of this option had been hand-checked when step 9 landed.** The step 8 rule that step 9 must not land if the installed app fails its check is set aside by that decision; the way out below takes its place. ADR 0048 ("WebKit's page path is gone") has the mechanics and what is unverified; where-it-breaks has the rules and the one hand list.

What the build decided where the option was silent:
- **What a page pane says when Chromium can't run** (the framework isn't in this Varnick, the engine failed to start, or the user turned it off): its own note, in words, with what to do (restart Varnick after a failed start, which can't be retried in a process; use a build that has the framework; delete the off setting), never a blank pane. A session's `pane_read` and `pane_open` are told the same. Reload on such a pane asks the engine again, so it starts the engine at once after the off setting is deleted.
- **The way out of a start that crashes Varnick at every launch** is a defaults key the user writes from a terminal outside Varnick, `chromiumOff`, which keeps the engine from starting (pages then say it is off) and works on an installed app, where the framework is sealed. It is hidden, written only by the user, and documented once, in where-it-breaks, as the first step of the hand list. The switch and its stored value are gone (the stored value is dropped at launch).
- **The engine rule and its check** are deleted rather than reduced: with one engine nothing is left to choose.
- **Unchanged:** the wire, the saved state (the old `chromium` mark still decodes and means nothing), the headless host and the relay, `kind: chromium` accepted as `page`, WebKit's cookie copy (it reads WebKit's own store, which still exists, and a Mac that upgrades straight to this build is copied as before), and a file pane's rendered Markdown, which stays on WebKit.

**What is left, so the option stays in-progress until it is done** (the merge of step 9 does not finish it): every hand check (steps 1 to 9, one list in where-it-breaks); the notarization trial of the framework in the app, not tried; and the licence notices that must travel with the framework, which block any release that ships it (James's to resolve).

## Testing Decisions

- No test target: `make build`, the `make check-*` targets, then the hand checks above, each after a restart the user makes. No agent restarts Varnick, runs the built binary past settings code, or clicks or types on the screen.
- Pure rules get a harness compiled alone, as other parts do: which engine a page gets, the failure card's message and retry interval for an address. The run-loop depth count gets none: as built in step 1 it is one clamped counter beside a direct question to the run loop, with no rule of its own to check (ADR 0048 has the measurement).
- The start without a restart is checked only by hand, in the real app: a harness proved the principle, not Varnick's loops.

## Out of Scope

- Find in the page, zoom keys, and back and forward buttons: the Browser pane has none today (the engine's context menu has Back and Forward).
- Inspect Element, unless the user wants it back (Further Notes).
- Copying logins from Chrome.
- A profile per tab or per project.
- Passkeys, saved passwords, a page's notifications (the engine refuses them by default) and the camera (Varnick has no camera entitlement).
- The phone and the headless host, which this leaves as they are.

## Further Notes

**What it leaves broken, step by step.** For the installed app, nothing: it shows pages in WebKit until step 8 and in Chromium after. Since step 9 a Mac whose engine fails to start, or whose Varnick has no framework, shows pages that say so and what to do, with no other engine behind them. The headless host is unchanged throughout: it has no browser, lists no page pane, and its relay never loads the framework; a Mac viewing another Mac's tab shows its pages in its own engine, whichever that is.

**Decisions that are the user's** (8 below was answered by step 9 as it describes; the rest are as the steps recorded):
1. CDP: decided, B (see CDP above); D stays a possibility.
2. Carry WebKit's cookies over once (recommended: yes)? And clear WebKit's store at step 9, or leave it on disk (recommended: leave it)? Taken as recommended on 2026-11-13 (see Logins and the profile).
3. New windows and popups as panes beside the page (recommended), in the default browser, or dropped as today?
4. Downloads to the Downloads folder with quarantine (recommended), or refused as today?
5. Dialogs answered silently as WebKit does today (recommended for now), or a card in the pane?
6. Inspect Element: dropped (recommended), or offered by opening Chrome's DevTools on the page while an endpoint is served?
7. The Pages in Chromium switch while WebKit stands in (recommended: on by default)? Built on by default in step 5, and gone with step 9.
8. Delete WebKit's page path at the end (this option), or keep it as a fallback for good (option 03)? Answered 2026-11-13: delete (see "Step 9, as built").
9. Varnick.app 143 MB larger, and 200 MB of memory from the first page until quit: acceptable? Built so, and still the user's to accept at the end test.

**Answered by the code, not the user's:** where the engine starts (between runs of the main run loop, at an event's dispatch); light and dark (the engine's startup setting); the failure card's texts and intervals (today's); the saved state (no new field, the `chromium` mark ignored); Resources (one row for the helpers: the C API gives no process per page).

**Unverified, to settle in the steps that need them:** page-history address changes reaching the engine's navigation events; Chromium's view answering the Edit menu and input methods; overlays drawing above the page; Chromium's accessibility tree inside Varnick; the keychain asking after a rebuild; `addCookies` reaching the persistent profile with no view in the engine yet (step 4); the framework working from the bundle's Frameworks folder (zebkit's source says it does; the prototype's crash with the host elsewhere is unexplained); the helper's entitlements under the hardened runtime (`allow-jit` alone is built); whether the engine marks downloads with quarantine itself.
