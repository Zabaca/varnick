---
title: Varnick tracks work by Claude session, while the user works in tabs
description: The user works in tabs. A tab of panes is one piece of work, and a Claude session is one kind of pane in it, beside terminals, web pages, custom apps, files and the Transcript. Varnick is built around Claude sessions instead. The board has a card per Claude pane. Done, Completed and Recent hold sessions, and search lists sessions. Another machine's work opens one session at a time, and only its Claude panes can be reached at all.
impact: Marking a tab of three Claude panes done takes three Dones, and its terminals and pages stay open. Completed and Recent can't bring a tab back, only one session in a fresh tab. The board scatters a tab across cards. Search finds a conversation but not the tab it belongs to. A tab on another machine can't be opened whole, and its terminals, dev servers and pages can't be reached from another Mac or the phone. Each new feature built on sessions widens the gap. Sharing done marks between machines shipped two days before this was written, keyed by session, and already has to be redone.
severity: high
evidence: The user's words of 2026-10-12, relayed by the coordinator, with four decisions (below). Code read at 0d1d161 (main). Nothing was run, and no Tailscale command was run.
status: open
---

## What the user wants (2026-10-12)

Tabs and panes are what Varnick centres on: Tab › Pane. A Claude session is one kind of pane. The others are a terminal, a web page, a custom app (Scratch among them), a file and the Transcript.

## Decided by the user, 2026-10-12

No option reopens these.

1. **Done belongs to the tab.** Done marks on sessions go away. They are not kept beside the tab's. Completed lists tabs.
2. **Remote sharing shares whole tabs with their panes,** so a tab can be reopened as a whole from another device.
3. **Search shows sessions grouped under their tab,** and opening any of them opens that tab.
4. **Remote web and custom-app panes are reached through a reverse proxy on each host that routes by port.** It listens on the host's Tailscale address and maps port N to localhost:N. It uses `tailscale cert` for the machine's name, so one certificate serves every port. It lives in a process each host already runs. Rejected, with the user's reasons:
   - **Routing by path prefix:** root-relative URLs break, and every app shares one origin, so storage and cookies leak between apps.
   - **Routing by subdomain:** Tailscale's MagicDNS and certificates have no wildcards.
   - **One `tailscale serve` per pane:** not needed.
   - **Pixel streaming:** WKWebView has no frame-stream API, so it would need headless Chromium with CDP's screencast, and it costs latency and bandwidth. It stays a possible later option, only if logged-in browser state ever has to be shared.

**What the code says about decision 4** (verified unless marked; option 04 has the detail):
- **The relay doesn't run between requests.** Each request is a process of its own that exits after its one reply, or when its stream ends for `watch` and `attach`. Only one process runs all the time on both kinds of host: the Phone page server. On a Mac it runs in its own zmx session and outlives Varnick. On the headless host it is a systemd user unit, installed with `--page`. On a Mac, Varnick itself runs too. Option 04 recommends the Phone page server, and asks the user to confirm.
- **Cookies ignore ports.** Routing by port gives each app its own origin, so its local storage and IndexedDB are its own. But a cookie set by one port is sent to every port on the same name. That is already so for the apps on 127.0.0.1 today (from the cookie standard, not tested here).

## Today

Verified in the code at 0d1d161 unless marked.

**Tabs**
- **A tab gets a new id at every launch.** The saved tab has no id: its layout, focused pane, name and whether the file tree shows.
- **A pane never moves between tabs.** Tabs can only be reordered. A tab is removed when its last pane closes.
- **Where new tabs come from.** Every way of starting or opening work adds a new tab:
  - a prompt here;
  - a prompt sent to another machine;
  - opening another machine's open session;
  - resuming from Recent or search.

  On a Mac host, a session started or resumed for another Mac or for the phone gets a one-pane tab of its own, in the background. On the headless host there are no tabs: each session is one flat record.
- **Splits don't follow the host.** A split makes a fresh pane on this Mac in the focused pane's folder. It copies the folder and never the host. Splitting a tab whose focused pane runs on the Ryzen makes a local session in the Ryzen's folder path, in the same tab. What happens then is unverified.
- **The search's Tabs section** has one row per tab. The row shows the focused pane, with "N panes" when there are more.
- **A tab's ⌘⇧R name** names its conversation in search only while the tab has one pane.

**The board, Done and Completed**
- **The board has one card per Claude pane on this Mac,** then each paired machine's open sessions, then the ended cards, then Completed. A card's id is its pane's. The Problems tab's chips and Panel access's card ids rely on that.
- **Done is a session's.** On the board, a pane's Done button or the Mark session done key (⌘⇧D) closes that one pane. The session goes to Completed. The rest of its tab stays open.
- **Done marks are shared between machines by session.** This is ADR 0028, which shipped in 47f7ec3 as option 01 of `done-marks-stay-on-one-mac` (protocol 20):
  - the `done` request names a session;
  - the host's `sessions` listing and Recent entries carry each session's mark;
  - the headless host keeps the mark on the session's record.
- **What is saved.** Completed holds up to 20 session records. The ended cards hold session records with no cap. The paired machines' sessions this Mac listed are kept as remembered records.

**Recent and search**
- **Recent lists ended sessions.** These are conversations, including those a `/clear` or `/resume` left behind. ↩ resumes one in a new one-pane tab.
- **Search lists sessions by conversation.** ↩ shows the pane that has the conversation, or resumes it in a new tab.
- **Other machines' sessions reach search** through `rows`, which has no tab.

**Other machines**
- **What a host lists.** It lists only its Claude panes that run there, one entry per session (`sessions`). Its Recent lists sessions (`recent`).
- **Take over, release and end are per session.**
- **Attaching works on any pane's zmx session by name, whatever its kind.** But a terminal pane's client exiting closes the pane and kills its zmx session. Only a Claude pane goes to a card. So taking over a host's terminal from another machine would end it.
- **Which panes run in zmx:**
  - terminal panes, only while Keep sessions running is on;
  - an app's server, always (when zmx is there);
  - web, file and Transcript panes, never.
- **A pane of another machine is always a Claude pane.** A terminal ignores the host. The headless host starts only claude. The Phone page lists sessions and Recent, and its terminal is a session's.

**Custom apps**
- **An app listens on 127.0.0.1 at exactly its `PORT`,** by the contract in the `custom-apps` skill. Its pane loads `http://127.0.0.1:<port>/`.
- **Scratch, the catalog's one app, is a Vite 6.4.3 dev server on 127.0.0.1.**
  - Vite serves its client and modules from root paths, and its hot-reload socket goes back to the page's own host and port.
  - Since 6.0.9 Vite refuses requests whose Host header isn't localhost, an IP or one of its `allowedHosts`.

  Both points come from Vite's documentation, not from this repo, and neither was tested.

## Overlap with other problems

- **`sessions-hosted-only-on-macs`** (option 01 accepted). The headless host is a host like any other here. Its remaining ticket, `rows`, is what option 02 adds a tab to. Option 03 gives it tabs of several panes, terminals included.
- **`sessions-finish-unnoticed`** (all proposed). Its notices are per session, and its option 04 puts a dot on board cards. With a card per tab, a notice names the tab and the session, opening it opens the tab, and the dot is the tab card's.
- **`closed-lid-pauses-sessions`** (all proposed). Nothing changes, but a tab hosted on a laptop sleeps whole with the lid. On other devices its card says the host isn't reachable.
- **`orchestration-lives-in-one-session`** (all proposed). Its option 04 has a lead session open its agents as panes. That option would have to say whether they open in the lead's tab or in tabs of their own, since each tab is then one board card.

## Records this changes

- **ADR 0028, the done-mark one, is superseded** by option 01 once that is accepted. Two ADRs are numbered 0028: that one, and the one on ElevenLabs voices. This problem doesn't renumber them.
- **CONTEXT.md:**
  - **Session**, now "what Recent lists";
  - **Recent**;
  - **Session board**;
  - **Tab**, which gains an id, a host and a done mark;
  - **Take over**, **Release** and **Card**, which become per tab in option 03.
