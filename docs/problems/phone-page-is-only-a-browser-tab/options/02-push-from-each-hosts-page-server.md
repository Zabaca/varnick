---
problem: phone-page-is-only-a-browser-tab
title: Option 01, plus Web Push from each host's page server for the sessions it hosts
summary: Option 01, plus standard Web Push. Each host's page server watches the turns of its own Claude panes, whoever is in control of them. When a turn finishes, stops on a dialog or fails, and is still unanswered after a short grace, the server pushes to every subscribed device that doesn't have that pane open. It decides by sessions-finish-unnoticed option 01's table and uses its option 02's wording. The push goes from the host to Apple's or Google's push service, encrypted end to end. It is padded to one size and carries only ids and the kind of notice, never session content. The phone's worker then reads the session's title over the tailnet when it can, and shows a generic notification when it can't. Each host has its own signing key (in the Keychain on a Mac, an owner-only file on a headless host) and its own subscriptions. The phone turns notifications on per host, inside the installed app on an iPhone and in any Chrome tab on Android. One protocol bump, for the Esc mark on a turn. Rough effort is five days on top of option 01.
status: proposed
---

## Solution

### Who sends

**The session's host, and only it.** Each host's page server pushes for the Claude panes of its own open tabs. That covers a session the host itself, a paired Mac or a device is in control of, and every session on a headless host, which has no Varnick app.

A session has one host, so it raises one push however many Macs show it. The phone turns notifications on in the page of each host it cares about.

### When

The rule is `sessions-finish-unnoticed` option 01's table, applied to the turn words `tabs` reports, from the previous word to the new one:

| From | To | Notice |
|---|---|---|
| working or background | waiting, not from Esc or Deny | **Done** |
| any other word | permission, question, plan or input | **Needs you**, saying which |
| working or background | failed (once that word exists) | **Stopped on an error**, with the kind |
| anything | working or background | none; drops a notice waiting out its grace |
| permission, question, plan or input | waiting | none; drops it too (answered, denied or Esc) |

- **The first word the server reads for a pane is its starting point.** That covers a server start, a pane it hasn't seen before and a host that answers again.
- **Background stays silent** until the work drains and the turn reaches waiting.
- **Grace.** A notice is pushed only if it still stands after its grace: 30 s for Needs you and an error, 60 s for Done. A dialog answered at a Mac within the grace sends nothing.
- **The pane open on the phone stays quiet.** A device that has the pane open, its terminal or its live view, gets no push for it. The page holds those open only while it is visible.
- **One notice per pane.** A newer one replaces a notice still in its grace.
- **A switch for each kind.** Each subscription has switches for Needs me, Done and Errors, all on by default.

### What a push carries, and what the phone shows

**The payload** holds:
- a version;
- the tab's id and the pane's id;
- the kind of notice;
- for an error, its kind's word ("rate limit").

It holds no title, prompt, folder, project or screen. Every payload is padded to one size, and every push is sent alike: one-hour TTL, high urgency, no Topic. So Apple and Google see that a push went, when, and to which browser, and nothing that tells a Done from a Needs you.

**The notification.** The worker knows its host's name, since it is served with it (option 01). On a push it asks the host for the tab, with a 3-second deadline, over the tailnet, as the page itself asks.

| The tab is read | Title | Body |
|---|---|---|
| yes | the session's title, as the board shows it | "Needs permission · Mac Studio" |
| no (off the tailnet, the host asleep, slow) | "Mac Studio" | "A session needs permission" |

The wordings are option 02's of `sessions-finish-unnoticed`:
- "Needs permission", "Has a question", "Plan to approve" and "Waiting on an MCP server";
- "Done";
- "Stopped on an error: rate limit".

The title therefore never passes through a push service. It shows only when the phone could open the session anyway.

**A tap** focuses the app's open window, or opens one, at the tab and pane (`#t=…&p=…`). Off the tailnet that is option 01's note.

**One notification per pane.** A newer notice for a pane replaces its notification and alerts again. A turn that moved on can't withdraw one, because every push must show a notification. So a notification goes when:
- the page opens that tab, which closes the tab's notifications;
- the user swipes it away.

**The badge.** On iOS the app's badge is the number of its standing notifications, cleared when the app opens. Android shows its own dot.

### Turning it on

Home gets a Notifications section at its foot, per host like everything on the page. It is in one of four states:
- **Not here.** In Safari on an iPhone, outside the installed app, it shows option 01's add-to-Home-Screen hint.
- **Off.** A switch. Turning it on asks the phone's permission, from that tap, then subscribes.
- **Blocked.** The permission was refused, and it says where the phone's settings allow it again.
- **On.** The three switches, Send a test, and Turn off.

The page checks its subscription at each load. If it was made with a key the host no longer has, the page subscribes again without asking, since the permission stands.

### iOS and Android

| | Android Chrome | iPhone Safari |
|---|---|---|
| Push without installing | yes, in a tab | no; the Home Screen app only (iOS 16.4 and later) |
| Permission | after a tap, per host | after a tap inside the installed app, per host |
| Push service | Google's | Apple's |
| Badge | Android's own dot | the number |
| Tested | the page in a tab | nothing yet; the whole page is new ground |

### Away from the host's network

- **Pushes come wherever the phone is,** Tailscale on or off, because the host reaches the push service over its own internet connection.
- **Titles and taps need the tailnet.** Without it the notification is the generic one, and a tap shows the offline note.
- **A host that is asleep or offline sends nothing.** A push is held at most an hour by the push service, then dropped, so a phone that was off doesn't get a pile of stale ones.

## Trade-offs

- **Every host and every controller.** A headless host pushes too, and so does a session the phone started and left. At the desk, the Mac's own notices (if `sessions-finish-unnoticed` is built) are separate, and the grace keeps the phone quiet for what the user answers there.
- **Set up per host.** One permission per host. On an iPhone that means one installed app per host (option 03 is the single-app alternative).
- **The grace is a guess at "away".** A Done left unread at the desk for a minute still buzzes the phone. Nothing on a host knows whether the user is at some Mac (open question 4).
- **A third party carries every push.** It can't read the payload, but it sees when and how often, from which address, to which phone. This is the page server's first request outside the tailnet. Today it reaches only the host's relay and Tailscale.
- **A signing key per host, and it must never change.** Every subscription is bound to it.
  - On a Mac the key rests in the Keychain. While the server runs it is in the server's environment, which the user's own processes can read, as they can read everything else of the user's.
  - On a headless host it is an owner-only file, as the proxy's TLS key is.
- **A protocol bump** for the Esc mark, so every Mac and the headless host run one commit.
- **The page server reads the dates of Varnick's turn files.** It does this so it doesn't run a relay every few seconds, and it is a new coupling to the pane folder's layout.
- **Errors come later.** "Stopped on an error" needs `sessions-finish-unnoticed` option 01's failed word. Until then a failed turn pushes Done.
- **Late by design.** A change is seen within about 2 s, but a push leaves only after the grace.

## User Stories

1. As the user away from my desk, I want a notification on my phone when a session on any of my hosts waits on a permission dialog, a question, a plan or an MCP request, so that it doesn't sit idle until I'm back.
2. As the user, I want a notification when a session finishes its turn, and when it stops on an API error with the kind, so that I can tell a rate limit from done.
3. As the user, I want no notification for something I answered at a Mac within a few seconds, so that my phone doesn't buzz while I'm at the desk working.
4. As the user, I want no notification for the session I have open on the phone.
5. As the user, I want the notification to name the session when my phone is on the tailnet, and to name only the host when it isn't, so that no session text goes through Apple's or Google's servers.
6. As the user, I want to tap a notification and land on that tab and pane in the host's page.
7. As the user, I want one notification per session, the latest, and a session's notifications gone when I open its tab.
8. As the user, I want to turn notifications on for each host's page, with a switch for each kind and a test, and off again.
9. As the user on an iPhone, I want the page to tell me to add it to the Home Screen first, since that is the only place iOS allows push.
10. As the user, I want a session the phone started, or one on the headless host, to notify like any other.
11. As the user, I want a device I remove from a host to stop getting its notifications at once.
12. As the user, I want notifications to keep working across Varnick restarts, rebuilds and upgrades without subscribing again.
13. As the user, I want to see in Settings which of my devices get notifications from this Mac.

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
- **Caps.** At most one push per pane per grace, and 60 per device an hour. Past that, pushes are dropped and counted in the log.
- **The token's contact (`sub`)** is Varnick's public site address, the same on every install, never the user's (open question 5).
- **Logs** hold the device's name, the kind, the status and the time. Never the endpoint, the payload, a title or the key.

### The key

- **One P-256 key pair per host.** Only the public key ever reaches the page, from a GET under `/api/`.
- **On a Mac.** Varnick makes the key when it first starts the server with the page on, and keeps the private key as a Keychain item of its own.
  - It gives the key to the server in its environment.
  - The server's session gets a label with the public key's fingerprint, so a different key restarts the server, as the page's digest does today.
  - A build signed ad hoc may be asked for Keychain access after a rebuild, as for any key Varnick keeps.
- **On a headless host.** The server makes the key at its first start and keeps it as an owner-only file in its own owner-only folder, beside the proxy's certificate. The installer gives the unit that folder, as it does now.
- **If the key is lost,** the host makes a new one. Every subscription is stored with the fingerprint of the key it was made for, so the old ones are dropped and the pages subscribe again at their next open.

### Subscriptions

- **Where they are kept.** One owner-only file in the page server's owner-only folder, written only by the page server. Nothing goes in UserDefaults or `sessions.json`, and a missing file means no subscriptions.
- **What each holds:**
  - the device's id;
  - the endpoint and its two keys;
  - the key fingerprint;
  - the three switches;
  - when it was added, and the last success and failure.
- **At most four per device** (Chrome, Safari and the installed app are separate). The same endpoint again replaces its entry.
- **When one is dropped:**
  - the device is no longer listed, which is checked at every send, so removing a device stops it at once;
  - the push service says it is gone;
  - the page turns it off;
  - the key changed.
- **The routes:**
  - read the public key and this device's state;
  - subscribe with switches;
  - turn off;
  - send a test.

  All of them sit behind the existing Host, caller, Origin and fetch-site checks. The changes are POSTs with JSON.

### Watching turns

- **Only while a subscription exists,** so a host nobody subscribed to does nothing new.
- **Turn file dates.** The server keeps the Claude panes of its last `tabs` listing and reads the date of each one's turn file every 2 s. The folder holding the pane folders comes in its environment, from Varnick or the installer.
- **When it asks `tabs`,** as the host itself:
  - when a date changed, or the saved tabs did;
  - every 15 s while a pane is in background or a notice waits out its grace;
  - every 60 s otherwise.

  One ask serves both this and the proxy when both want one.
- **The rule** is a pure function: the old and new word, the Esc mark, whether the device has the pane open, the switches and the time since the notice. It returns push, drop or nothing. It is the table above, and when `sessions-finish-unnoticed` option 01 is built in Swift, the two must say the same, as `mayBeListed` is kept in both languages.

### The protocol

`tabs` gains, for a Claude pane whose waiting turn came from the user's Esc or Deny, a mark saying so. The reader already knows this. It is an optional field, sent to devices too.

That bumps the protocol: Swift and the server's version together, every Mac and the headless host on one commit.

### The Mac's Settings and the installer

- **Settings.** Under Serve the phone page, each listed device says whether it gets notifications from this Mac. That is read from the subscription file as a count, never an endpoint.
- **The installer.** It gives the unit the panes folder, and nothing else new: the key and the subscriptions sit in the folder it already gives.

### Documents

- An ADR amending ADR 0011: the page server pushes to the vendors' push services outside the tailnet, with a key per host and subscriptions per device, and the payload rule.
- The privacy doc's Phone page section: what a push carries, what Apple and Google see, and where the key lives.
- where-it-breaks:
  - the payload is a privacy surface, and a field added to it is a privacy change;
  - the endpoint allowlist;
  - the key never changes once made;
  - every push shows a notification;
  - the page server reads turn file dates.
- CONTEXT.md's **Phone page** entry mentions notifications.

## Testing Decisions

- **`bun test`:**
  - the encryption against RFC 8291's example;
  - a token verified with its public key;
  - padding to one size;
  - the endpoint allowlist (localhost, a tailnet address, http, another port, a redirect);
  - the rule over every row, the Esc mark, the grace, the pane open on the device and each switch;
  - subscription file reads with bad entries, the cap, and drops for an unlisted device and a changed key;
  - the notification text with and without a title.
- `make build` passes. The protocol versions match.
- **By hand, after the user restarts Varnick, on the Android phone in Chrome and then in the installed app:**
  - Turn notifications on: one permission prompt, and Send a test arrives.
  - A dialog in a session on the Mac, left 30 s: Needs you arrives with the session's title. Answered within 10 s: nothing.
  - A prompt that finishes, left a minute: Done. Esc mid-turn: nothing.
  - Tap: the app opens on that tab and pane, and that tab's notifications go.
  - The pane open on the phone: nothing for it.
  - Tailscale off on the phone: a push still arrives, generic. Tap: the offline note.
  - A session the phone started, then the app closed: it notifies.
  - A session on the headless host: it notifies from that host's page.
  - Remove the device in Settings: the next notice doesn't come.
  - Restart Varnick and rebuild: notifications go on without subscribing again, and nothing comes for turns already waiting.
- **On an iPhone, if one is at hand,** the same in the Home Screen app, plus the badge and the hint in Safari.

## Out of Scope

- One app and one subscription for every host: option 03.
- Actions on the notification (Allow, Deny, a reply).
- Withdrawing a notification when a turn moves on.
- Knowing whether the user is at a Mac (open question 4), and sharing "seen" between a Mac's notices and the phone's.
- Notifications for terminals and other pane kinds, and for sessions with no pane on their host.
- Declarative Web Push on iOS 18.4 and later.

## Further Notes

### Considered within this option

- **Varnick's Mac app sends,** from `sessions-finish-unnoticed` option 01's notifier, which knows what is on screen. Not chosen, for three reasons:
  - a headless host has no app;
  - a session a device controls shows a card on its host, which option 01 keeps silent;
  - Web Push would be written twice, in Swift and in the server.
- **The Mac in control sends.** The page its push opens lists only that Mac's own sessions, not a session hosted elsewhere.
- **Asking `tabs` every 5 s.** That is a Varnick process every 5 s on a Mac, about 17,000 a day, for a change seen two seconds sooner than the turn file dates give.
- **The title in the encrypted payload.** It would name the session off the tailnet too, but session text would then ride Apple's or Google's service, encrypted (open question 2).
- **A push app such as ntfy, Pushover or Telegram.** It needs another app and account, its server reads the text (ntfy has no end-to-end encryption), and the user asked for the page itself to notify.

### Records

Accepting this needs the ADR above. If option 01 is built first, this is its second set of tickets.

### Open questions

1. **One app per host, or one for every host (option 03)?** Recommendation: per host. It is ADR 0011's shape, keeps each key on its own host, and on Android costs only a permission per host.
2. **Where the session's title comes from?** Recommendation: read over the tailnet when the push arrives, so no session text reaches a push service. The alternative is the title in the encrypted payload, which names the session off the tailnet too.
3. **The grace: 30 s for Needs you and errors, 60 s for Done?** Recommendation: yes, fixed, and changed only if it proves wrong in use.
4. **Stay quiet while someone uses the host Mac** (its keyboard and mouse idle time, which a page server can read on a Mac without a permission)? Recommendation: not now. It doesn't help when the user sits at another Mac, and the grace may be enough. Add it if the phone buzzes at the desk.
5. **The token's contact.** Recommendation: Varnick's public site address, the same for every install. It is in the clear to Apple and Google, so never the user's address.
6. **Switches on by default?** Recommendation: all three, as `sessions-finish-unnoticed` option 01 has them.

### Verified and inferred

- **Verified at 904d138:**
  - how the page is served;
  - that `tabs` carries turns to a device and the page drops them;
  - that the proxy asks `tabs` as the host gated by a file's date;
  - where keys live today;
  - that the server's environment isn't on its command line;
  - the page's fragment routes.
- **Inferred:**
  - every browser and push-service behaviour in the problem's "What the browsers and push services do";
  - that a worker's fetch to its own page passes the fetch-site check;
  - that iOS gives a push event time for a 3-second fetch;
  - that turn file dates catch every change but the background drain and Esc, which the 15 s and 60 s asks catch.
