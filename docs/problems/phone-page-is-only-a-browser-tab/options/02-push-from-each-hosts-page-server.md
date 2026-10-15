---
problem: phone-page-is-only-a-browser-tab
title: Option 01, plus Web Push from each host's page server, routed by where the user is
summary: Option 01, plus standard Web Push, sent only when the user isn't at the Mac driving the session. Each host's page server watches the turns of its own Claude panes and decides by sessions-finish-unnoticed option 01's table, so the Mac and the phone use one rule. It routes each notice by the pane's controller. A Mac whose user is present gets its own notice (that problem's option 01) and the phone stays quiet. If that Mac locks, sleeps or goes idle while the notice still stands, the push goes then. A Mac that is away or can't be told, and the phone in control, get the push after a 10-second settle. Each Mac reports whether its user is present (input idle time, screen locked or display asleep) to the hosts it follows, on the status requests it already sends every 5 s. The push goes from the host to Apple's or Google's push service, encrypted end to end, padded to one size, and holds ids and the kind of notice, never session content. The phone's worker reads the title over the tailnet when it can. Each host has its own signing key (in the Keychain on a Mac, an owner-only file on a headless host) and its own subscriptions. One protocol bump. Rough effort is six and a half days on top of option 01.
status: proposed
---

## Solution

### One rule, two halves

**When** something is worth telling the user is `sessions-finish-unnoticed` option 01's table, applied to the turn words `tabs` reports:

| From | To | Notice |
|---|---|---|
| working or background | waiting, not from Esc or Deny | **Done** |
| any other word | permission, question, plan or input | **Needs you**, saying which |
| working or background | failed (that option's new word) | **Stopped on an error**, with the kind |
| anything | working or background | none; drops a standing notice |
| permission, question, plan or input | waiting | none; drops it too (answered, denied or Esc) |

- **The first word read for a pane is its starting point.**
- **Background stays silent** until it drains.

**Where** the notice goes depends on the pane's **controller**: the Mac or device in its control label, or the host when the label names nobody.
- Control is a handoff with one keyboard, so the controller is the only place the session can have been typed into since it was taken.
- That makes the controller where the user last drove the session, and on paired Macs it can differ from the host. A session on host A driven from Mac B has B as its controller.

| The controller | Mac notice (`sessions-finish-unnoticed`) | Push to the phone |
|---|---|---|
| A Mac whose user is **present** | on that Mac, unless the pane is on screen there | none while it stays present; sent when it turns away with the notice still standing |
| A Mac whose user is **away** | on that Mac, waiting for their return | after the settle |
| A Mac that **can't be told** (no report for 20 s, or its client detached) | whatever that Mac does | after the settle |
| A **device** (the phone) | none: the host's pane shows a card | after the settle |

- **Present** means:
  - the screen is unlocked;
  - the display is awake;
  - the Mac's own login session is the active one;
  - the last keyboard, mouse or trackpad input was under 2 minutes ago.

  Anything else is **away**.
- **The settle** is 10 seconds. A notice still standing then is pushed. It absorbs a turn that flickers and the up to 5 seconds a presence report takes.
- **A device with the pane open gets no push for it.** Open means its terminal or its live view, which the page holds only while visible. That holds in every row.
- **Each subscription has switches** for Needs me, Done and Errors, all on by default.

The Mac half (the notice on the controlling Mac, quiet when the pane is on screen) is `sessions-finish-unnoticed` option 01's, unchanged. This option is the phone half.

### Presence: how the host learns where the user is

- **Each Mac's Varnick reads its own presence:**
  - the seconds since the last input;
  - whether the screen is locked, the display asleep, or its login session switched away.

  It needs no permission (inferred).
- **For itself as a host,** it writes those facts to a small owner-only file for its page server. It writes on every change, and at least every 10 s while it runs.
- **For the hosts it follows,** it adds the same facts to the `status` request it already sends every 5 s. A Mac sends that request to each host it has a pane on, which includes every host where it is in control of a session.
  - The host's relay writes them to that Mac's own presence file, beside the host's.
  - Only a listed Mac's report is taken. A device's is ignored.
- **The facts are raw: idle seconds and away flags.** The page server alone turns them into present or away, so the threshold lives in one place.
- **A report older than 20 s means "can't be told":** the Mac is asleep, Varnick isn't running, the link is down, or it runs an older build. A controller with its client detached (Last controlled on) counts the same. Both lean toward pushing.
- **What it costs.** Presence never leaves the user's own machines. It goes over the SSH link that already carries the status requests, and never into a push.

### What a push carries, and what the phone shows

**The payload** holds:
- a version;
- the tab's id and the pane's id;
- the kind of notice;
- for an error, its kind's word ("rate limit").

It holds no title, prompt, folder, project or screen. Every payload is padded to one size, and every push is sent alike: one-hour TTL, high urgency, no Topic. So Apple and Google see that a push went, when, and to which browser, and nothing that tells one kind from another.

**The notification.** The worker knows its host's name, since it is served with it (option 01). On a push it asks the host for the tab, with a 3-second deadline, over the tailnet, as the page itself asks.

| The tab is read | Title | Body |
|---|---|---|
| yes | the session's title, as the board shows it | "Needs permission · Mac Studio" |
| no (off the tailnet, the host asleep, slow) | "Mac Studio" | "A session needs permission" |

The wordings are `sessions-finish-unnoticed` option 02's:
- "Needs permission", "Has a question", "Plan to approve" and "Waiting on an MCP server";
- "Done";
- "Stopped on an error: rate limit".

The title never passes through a push service.

**A tap** focuses the app's open window, or opens one, at the tab and pane (`#t=…&p=…`). Off the tailnet that is option 01's note.

**One notification per pane.** A newer notice for a pane replaces its notification and alerts again. A notification goes when:
- the page opens that tab, which closes the tab's notifications;
- the user swipes it away.

A push can't withdraw one, since every push must show a notification.

**The badge.** On iOS the app's badge is the number of its standing notifications, cleared when the app opens. Android shows its own dot.

### Turning it on

Home gets a Notifications section at its foot, per host like everything on the page. It is in one of four states:
- **Not here.** In Safari on an iPhone, outside the installed app, it shows option 01's add-to-Home-Screen hint.
- **Off.** A switch. Turning it on asks the phone's permission, from that tap, then subscribes.
- **Blocked.** The permission was refused, and it says where the phone's settings allow it again.
- **On.** The three switches, Send a test, and Turn off.

The page checks its subscription at each load. If it was made with a key the host no longer has, the page subscribes again without asking.

### iOS and Android

| | Android Chrome | iPhone Safari |
|---|---|---|
| Push without installing | yes, in a tab | no; the Home Screen app only (iOS 16.4 and later) |
| Permission | after a tap, per host | after a tap inside the installed app, per host |
| Push service | Google's | Apple's |
| Badge | Android's own dot | the number |
| Tested | the page in a tab | nothing yet; the whole page is new ground |

### Away from the host's network

- **Pushes come wherever the phone is,** Tailscale on or off: the host reaches the push service over its own internet connection.
- **Titles and taps need the tailnet.**
- **A host that is asleep or offline sends nothing.** A push is held at most an hour by the push service, then dropped.

## Trade-offs

- **The phone buzzes only when the user is away from the Mac driving the session,** or drives it from the phone. That covers a session the phone started and every session on a headless host.
- **Presence is a guess at attention.**
  - A user reading a long answer for two minutes without touching anything counts as away, and the phone buzzes.
  - A user present at a Mac that isn't the controller (they walked to the Air without taking over) counts as away from the session, and the phone buzzes (open question 3).
- **It leans toward pushing.** Every case where a host can't tell (an asleep Mac, an older build, a dropped link) pushes rather than stays silent.
- **Presence reaches a host only from Macs that follow it.** A Mac with no pane on that host never reports to it, which is only a gap when the user is at a Mac that isn't the controller.
- **Set up per host.** One permission per host. On an iPhone, one installed app per host (option 03 is the single-app alternative).
- **A third party carries every push.** It can't read the payload, but sees when and how often, from which address, to which phone. This is the page server's first request outside the tailnet.
- **A signing key per host that must never change,** since every subscription is bound to it.
  - On a Mac it rests in the Keychain, and sits in the server's environment while the server runs.
  - On a headless host it is an owner-only file, as the proxy's TLS key is.
- **One protocol bump,** for the Esc mark, the presence report and the controller's id for the host's own page server. Every Mac and the headless host run one commit.
- **New couplings.** The page server reads the dates of Varnick's turn files and the presence files, rather than running a relay every few seconds.
- **Needs the Mac half for errors.** "Stopped on an error" needs `sessions-finish-unnoticed` option 01's failed word, and the order below builds that first.

## User Stories

1. As the user at my Mac, I want a session I drive from that Mac to notify me there and not buzz my phone.
2. As the user who walked away (screen locked, display asleep or idle for two minutes), I want the phone to get the notice that is still standing on my Mac, so that the session doesn't wait for my return.
3. As the user driving a session on one Mac from another, I want the Mac I drive it from to be the one that notifies, and the phone to buzz only when I'm away from it.
4. As the user away from my desk, I want a notification on my phone when a session waits on a permission dialog, a question, a plan or an MCP request, when it finishes, and when it stops on an API error with the kind.
5. As the user, I want a session the phone started, or one on the headless host, to notify the phone.
6. As the user, I want no notification for the session I have open on the phone.
7. As the user, I want the notification to name the session when my phone is on the tailnet and only the host when it isn't, so that no session text goes through Apple's or Google's servers.
8. As the user, I want to tap a notification and land on that tab and pane.
9. As the user, I want one notification per session, the latest, and a session's notifications gone when I open its tab.
10. As the user, I want to turn notifications on for each host's page, with a switch for each kind and a test, and off again.
11. As the user on an iPhone, I want the page to tell me to add it to the Home Screen first.
12. As the user, I want a device I remove from a host to stop getting its notifications at once.
13. As the user, I want notifications to keep working across Varnick restarts, rebuilds and upgrades without subscribing again.
14. As the user, I want to see in Settings which of my devices get notifications from this Mac.

## Implementation Decisions

### Web Push in the server

- **Written in the server with the platform's own crypto,** since the page takes no npm package. That means VAPID tokens (ES256), the RFC 8291 `aes128gcm` encryption and padding.
- **A pure module,** checked against RFC 8291's worked example and a token verified with the public key.
- **Where a push may go.** Only to an endpoint that is https on port 443 at a known push service: Google's, Apple's, Mozilla's or Microsoft's. Redirects aren't followed.
  - Without this, a listed device could make the server send requests to any address, the host's localhost and the tailnet included.
  - In loopback mode, any local process could do the same by posing as a device.
- **What happens to each send.** It has a 10-second deadline.
  - Gone (404, 410) drops the subscription.
  - Too many or a server error is retried once after its Retry-After or 30 s, then dropped.
  - Anything else is logged by status.
- **Caps.** At most one push per pane per settle, and 60 per device an hour. Past that, pushes are dropped and counted in the log.
- **The token's contact (`sub`)** is Varnick's public site address, the same on every install.
- **Logs** hold the device's name, the kind, the status and the time. Never the endpoint, the payload, a title, presence or the key.

### The key

- **One P-256 key pair per host.** Only the public key reaches the page, from a GET under `/api/`.
- **On a Mac.** Varnick makes the key when it first starts the server with the page on, and keeps the private key as a Keychain item of its own.
  - It gives the key to the server in its environment.
  - The server's session gets a label with the public key's fingerprint, so a different key restarts the server.
  - A build signed ad hoc may be asked for Keychain access after a rebuild, as for any key Varnick keeps.
- **On a headless host.** The server makes the key at its first start and keeps it as an owner-only file in its own owner-only folder, beside the proxy's certificate.
- **If the key is lost,** a new one is made. Subscriptions carry the fingerprint of the key they were made for, so old ones are dropped and the pages subscribe again at their next open.

### Subscriptions

- **Where they are kept.** One owner-only file in the page server's owner-only folder, written only by the page server. Nothing goes in UserDefaults or `sessions.json`, and a missing file means none.
- **What each holds:**
  - the device's id;
  - the endpoint and its two keys;
  - the key fingerprint;
  - the three switches;
  - when it was added, and the last success and failure.
- **At most four per device.** The same endpoint again replaces its entry.
- **When one is dropped:**
  - the device is no longer listed, checked at every send;
  - the push service says it is gone;
  - the page turns it off;
  - the key changed.
- **The routes:**
  - read the public key and this device's state;
  - subscribe with switches;
  - turn off;
  - send a test.

  All of them sit behind the existing Host, caller, Origin and fetch-site checks.

### Presence

- **Varnick reads it.** A presence reader in Varnick gives idle seconds (the system's seconds since the last input event of any kind) and one away flag: screen locked, display asleep, or login session not active.
  - It learns of the lock and sleep from the system's notifications, and reads idle time when it reports.
  - It is one small type with no UI. Its first use is this option. `sessions-finish-unnoticed` can use it later if wanted.
- **One file per Mac, each with one writer and written whole by rename:**
  - the host's own presence file, written by its running Varnick;
  - a peer's presence file, written by the host's relay when that peer's `status` request carries presence.
- **On a headless host,** only the relay writes them, since it has no user of its own.
- **The page server reads the controller's file** when a notice stands, and reads the dates of all of them on its 2-second tick, so a Mac turning away is seen within seconds.

### Watching turns

- **Only while a subscription exists.**
- **Turn file dates.** The server keeps the Claude panes of its last `tabs` listing and reads the date of each one's turn file every 2 s. The folder holding the pane folders comes in its environment, from Varnick or the installer.
- **When it asks `tabs`,** as the host itself:
  - when a turn date or the saved tabs changed;
  - every 15 s while a pane is in background or a notice stands;
  - every 60 s otherwise.

  One ask serves both this and the port proxy when both want one.
- **The rule** is a pure function, with these inputs:
  - the old and new word, and the Esc mark;
  - the controller: the host, a listed Mac, a device, or unknown;
  - whether its client is attached;
  - its presence facts and their age;
  - whether each device has the pane open;
  - the switches;
  - the time since the notice.

  It returns push now, wait, or drop. The table half must say the same as `sessions-finish-unnoticed` option 01's Swift rule, as `mayBeListed` is kept in both languages.

### The protocol

One bump (27), Swift and the server's version together:
- **`status` requests from a Mac gain an optional presence field:** idle seconds and the away flag. A device's is ignored.
- **`tabs` gains, for a waiting Claude pane, a mark when the waiting came from the user's Esc or Deny.**
- **The relay tells the host's own id the controller's id** in `tabs`, not only its name. It is the host's own page server, which already reads the device list and the paired Macs. A device is still told only its own id.

### The Mac's Settings and the installer

- **Settings.** Under Serve the phone page, each listed device says whether it gets notifications from this Mac. That is read from the subscription file as a count, never an endpoint.
- **The installer.** It gives the unit the panes folder. The key, the subscriptions and the presence files sit in folders it already gives.

### Documents

- An ADR amending ADR 0011: the page server pushes to the vendors' push services outside the tailnet, with a key per host and subscriptions per device. It also records the payload rule, and the routing by controller and presence.
- The privacy doc:
  - what a push carries, what Apple and Google see, and where the key lives;
  - that each Mac tells the hosts it follows whether its user is present.
- where-it-breaks:
  - the payload is a privacy surface;
  - the endpoint allowlist;
  - the key never changes;
  - every push shows a notification;
  - the page server reads turn and presence files;
  - a missing or stale presence report must push, never silence.
- CONTEXT.md:
  - the **Phone page** entry mentions notifications;
  - a **Presence** entry: whether the user is at a Mac, as its idle time and lock say.

## Testing Decisions

- **`bun test`:**
  - the encryption against RFC 8291's example;
  - a token verified with its public key;
  - padding;
  - the endpoint allowlist;
  - the rule over every row of both tables;
  - present to away while a notice stands;
  - a stale report;
  - a detached controller;
  - a device with the pane open;
  - each switch;
  - the subscription file's drops;
  - the notification text with and without a title.
- **Swift, once a test target exists:** the presence report's encoding, and the relay writing a listed peer's report and ignoring a device's.
- `make build` passes. The protocol versions match.
- **By hand, after the user restarts Varnick, with the Android phone subscribed:**
  - **Present at the host Mac:** a dialog in a session driven from that Mac gives a Mac notice and no push, even after two minutes of typing elsewhere.
  - **Lock that Mac** with the notice standing: the push arrives within about 15 s.
  - **Walk away** without locking: the push arrives about two minutes after the last input.
  - **Paired Macs:** a session hosted on one Mac and driven from another. Present at the driving Mac: no push. Lock it: push. Put it to sleep: push within about 30 s.
  - **The phone in control,** with the app closed: a notice pushes after 10 s. With its terminal open on that pane: nothing.
  - **The headless host:** a session there driven from an idle Mac pushes.
  - **The title and taps:** the title with Tailscale on, the generic text with it off, and a tap landing on the tab.
  - **Remove the device:** the next notice doesn't come.
  - **Restart and rebuild:** no subscribing again, and nothing for turns already waiting.
- **On an iPhone, if one is at hand,** the same in the Home Screen app, plus the badge and the hint in Safari.

## Out of Scope

- One app and one subscription for every host: option 03.
- Notifying a Mac that isn't the controller when the user is there (open question 3).
- Escalating by time while the user is present at the controlling Mac.
- Actions on the notification, and withdrawing a notification by push.
- Notifications for terminals and other pane kinds.
- Declarative Web Push on iOS 18.4 and later.

## Further Notes

### Asked by the user, 2026-10-14

"If I'm on my Mac and the session was interacted with on the Mac, it doesn't buzz the phone." The coordinator relayed it with three asks:
- notify on the Mac the user drives the session from, not the host;
- push when the last interaction was from the phone, or that Mac is idle or locked;
- consider a Mac notice first and a push later.

The routing above is that. The escalation is by absence (the Mac turns away), not by time.

### What is detectable today, verified at 904d138

- **Detectable:**
  - **The controller** of every Claude pane, and whether it has a client attached. This is in `tabs`, but a host's own page server is told only its name.
  - **Which pane is on screen** on a Mac: the panel key, a tab shown and its focused pane. Known in process only.
  - **Which pane a device has open,** from the page server's sockets.
  - **A Mac's reports to a host.** A Mac with any pane on another host already sends that host `status` every 5 s, whatever the board shows.
- **Not detectable today:**
  - **Idle time, screen lock and display sleep.** Nothing in Varnick reads them. Public system calls and notifications give them, expected without a permission (inferred).
  - **When and from where a session was last typed into.** Neither zmx nor Varnick records it. The controller stands in for it: with one keyboard per session, the controller is the only place it could have been typed into since it was taken.
  - **Whether the user is at a Mac that isn't the controller.** A Mac reports only to hosts it has a pane on.
  - **Whether a Mac notice was seen.** Never sent anywhere, and not needed with escalation by absence.

### Considered within this option

- **Escalating by time** (a push N seconds after a Mac notice, even with the user present). Rejected: it buzzes the phone at the desk, which the user asked against.
- **The controlling Mac decides and asks the host to push.** Two deciders, since the host must still decide for the phone and for a Mac that can't be told, and a new request carrying a push from Mac to host.
- **The host asks each Mac for its presence.** A headless host has no way to reach a Mac, and the Mac already reports every 5 s.
- **Varnick's Mac app sends pushes.** Not chosen, for three reasons:
  - a headless host has no app;
  - a card on the host is silent;
  - Web Push would be written twice.
- **Asking `tabs` every 5 s** (about 17,000 Varnick processes a day on a Mac).
- **The title in the encrypted payload, and a push app such as ntfy.**

### Records

Accepting this needs the ADR above.

### Build order, with `sessions-finish-unnoticed`

1. **This problem's option 01** (install). It is page-only, so it can run beside step 2.
2. **`sessions-finish-unnoticed` option 01:** Mac notices, the shared table in Swift, and the failed word the phone needs.
3. **This option.** The presence reader and report, the protocol bump, Web Push, routing and the page.
4. **`sessions-finish-unnoticed` option 02,** starting with its check: banners on the user's own Macs, which run checkout builds that are bare executables. Its option 03 banners reach only an installed Varnick.app.
5. **`sessions-finish-unnoticed` option 04, later.**

### Open questions

1. **Escalate by absence, not by time?** Recommendation: by absence.
2. **Away after 2 minutes without input, at once on lock, display sleep or a switched session?** Recommendation: yes.
3. **When the user is present at a Mac that isn't the controller, push or notify that Mac?** Recommendation: push. Notifying that Mac needs every Mac to follow every host's turns and report to it, for a case a Take over already fixes.
4. **A 10-second settle in place of the 30 s and 60 s grace.** Presence now says where the user is, so the grace's guess isn't needed. Recommendation: yes.
5. **Mac banners through `sessions-finish-unnoticed` option 02 (the notifier app, check first) rather than 03?** The user's Macs run checkout builds. Recommendation: 02, unless the user moves their Macs to the installed app.

The user accepted on 2026-10-14 (relayed): the title read over the tailnet, one app per host, Varnick's site as the token's contact, and all switches on by default.

### Verified and inferred

- **Verified at 904d138:**
  - the detectable list above;
  - how the page is served;
  - that `tabs` carries turns and the page drops them;
  - that the relay hides the controller's id from the host's own id;
  - that the follow loop sends `status` every 5 s while any pane is on a peer;
  - that checkout builds are bare executables and only `make app` makes a bundle;
  - where keys live;
  - that the server's environment isn't on its command line.
- **Inferred:**
  - the browser and push-service behaviour in the problem;
  - that idle time and lock state need no permission;
  - that a worker's fetch passes the fetch-site check;
  - that iOS allows a 3-second fetch in a push event.
