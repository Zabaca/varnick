---
problem: phone-page-is-only-a-browser-tab
title: Option 02, but one installed app and one subscription receive every host's pushes
summary: Option 02's rule, payload and sending, with one subscription for all hosts. The phone installs and subscribes on one Mac's page, its home. That Mac's Varnick hands the subscription, and the signing key it was made for, to every host it pairs with. Each host then pushes for its own sessions to that one subscription. On an iPhone that means one Home Screen app and one permission for every host. In exchange, the home's private key is copied to every host, and the relay needs a way to take a request that isn't on its command line. Notifications for the other hosts can't name the session, since the home's worker can't read another host's page. A tap on one opens that host's page in the browser rather than in the app. Not recommended now. Rough effort is three to four days on top of option 02.
status: proposed
---

## Solution

**The home.** The phone subscribes on one Mac's page, as in option 02. That Mac is its home for notifications, chosen by where the user turned them on. A headless host can't be the home, because it has no peer list of its own to hand the subscription out from.

**Handing out.**
- **What goes out.** The home's Varnick sends each host it pairs with the subscription, the home's signing key and the device's id, in a new request. It sends them again when either changes, and a withdrawal when the device or the subscription goes.
- **What each host does with it.** It keeps the key and the subscription beside its own, as option 02 keeps them, and pushes for its own sessions to them. Option 02's rule, payload, padding and caps apply unchanged.

**The request can't ride the relay's command line.** A peer request is the relay's argument on the receiving host, where other accounts can see a command line while it runs. So the relay gets a second way in that reads the request from its standard input, for this request alone.

**On the phone.**
- **A push from the home's own sessions** is option 02's notification.
- **A push from another host** says its host's name, which the payload then has to carry, and no title. The home's worker can't read another host's page: the pages send no cross-origin headers, by rule.
- **A tap on another host's push** opens that host's page in the browser. On Android it opens in Chrome, or in that host's own app if it is installed. On an iPhone it opens in Safari, outside the Home Screen app (inferred).

## Trade-offs

- **One app, one permission.** That is the main gain, and it matters most on an iPhone with several hosts.
- **The key spreads.** The home's private key sits on every paired host, the headless one included, and anyone who can read any one of them can push to the phone as the home. Option 02's keys never leave their host.
- **A second way into the relay,** for one request, and a protocol bump for it.
- **Unequal notifications.**
  - Other hosts' notifications can't name the session.
  - A tap on one leaves the installed app.
  - The host's name rides in the payload, encrypted but no longer only ids.
- **It hangs on the home.** Unpairing the home, or losing its key, stops every host's pushes until the phone subscribes again.

## User Stories

1. As the user on an iPhone with several hosts, I want one Home Screen app and one permission that bring every host's notifications.
2. As the user, I want a notification from any host to say which host, and a tap to open that host's page.
3. Option 02's stories 1 to 4, 6, 8, 11 and 12, across every host from one subscription.

## Implementation Decisions

- **The subscription and the key go out from the home's Varnick.** They don't go from its page server, which doesn't talk to peers. The home reads them from the server's files: on a Mac the key is already Varnick's (option 02).
- **How they travel.** The request travels over the existing SSH link, with its body on the relay's standard input.
- **How a receiving host keeps them.** It stores them beside its own, marked as another host's, and drops them when that host withdraws them or is unpaired.
- **The payload gains the host's name.**
- **The title stays the home's alone.** Other hosts' pushes show the generic text, so the rule against cross-origin headers stands.

## Testing Decisions

- Option 02's, plus:
  - a host given the home's subscription pushes for its own session;
  - unpairing the home stops it;
  - a request on standard input is refused on the command line and accepted on standard input.
- **By hand:** one app on the phone receives a push from the home and from a second Mac. The second Mac's opens in the browser on that Mac's page.

## Out of Scope

- A headless host as the home.
- Titles for other hosts' sessions.
- Moving the home.

## Further Notes

- **Why not now.** Option 02 gives every host's pushes at the price of one permission per host, which on Android is a tap. The user's phone is Android. This option's gain is mostly for an iPhone with several hosts, and its costs (a key on every host, a second way into the relay, unequal notifications) are paid by everyone. It can be built on option 02 later without undoing it.
- **A hub page** that lists and acts on every host was rejected in ADR 0011. This option shares only the push, not the page.
