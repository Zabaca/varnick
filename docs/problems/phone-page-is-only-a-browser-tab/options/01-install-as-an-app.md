---
problem: phone-page-is-only-a-browser-tab
title: Each host's Phone page installs as an app, with an offline note and no push
summary: Each host's page server serves a web app manifest named for the host, icons made from the Fold mark, and a service worker that handles only page loads. A load that fails gets its own note ("Can't reach Mac Studio: is Tailscale on, and is the Mac awake?") instead of the browser's error. Nothing else is cached. Android Chrome then offers Install, and an iPhone can Add to Home Screen. Either way the page opens standalone, without the browser's bars. One app per host, since each host is its own origin. No push, so no key, no third party and no protocol change. Option 02 builds push on this. Rough effort is a day, plus checking the terminal in a standalone window on both phones.
status: accepted
---

## Solution

**The manifest.** The page server serves a manifest, written per request like the home page's loopback note, so it carries the host's name:
- the name "Varnick · <host>" and the short name "<host>";
- the start address and scope `/`;
- `standalone` display, any orientation;
- the page's own background and theme colours, dark and light;
- the icons.

The home page links it, and adds the iOS tags: `apple-touch-icon`, a Home Screen title and standalone capability.

**Icons.** The Fold mark as PNGs at 180 (iOS), 192 and 512, and a 512 maskable one with the mark inside the safe zone. They are made once and kept with the page, beside the vendored xterm.js. Every host serves the same icons, and the name tells the hosts apart on the Home Screen.

**The service worker.** At the page's root, so its scope is the whole page. It has one job: when a page load (a navigation) fails on the network, it answers with its own note, naming the host and saying what to check, with Try again. It is served with the host's name written in, as the manifest is.
- **It doesn't touch any other request:**
  - not the page's scripts, CSS or the vendored files;
  - not `/api/*`;
  - not the websockets, which a service worker never sees anyway.
- **It caches nothing from the server.** Replies are `no-store` and carry prompts and titles. A cached copy of the page's code could also talk to a newer server.
- **The note is built inside the worker,** so it needs no cache of server replies at all.

**Install prompts.**
- On Android Chrome, the page catches the install event and shows an Install button at the foot of Home, once, until it is used or dismissed.
- In Safari on an iPhone, outside the installed app, Home shows a one-line hint: "Add to Home Screen from the Share menu to open this page as an app."
- Neither shows inside the installed app.

**Content policy.** It gains `manifest-src 'self'`, `img-src 'self'` and `worker-src 'self'`. The unlisted page's policy is unchanged, and an unlisted device still gets 403 for every file, the manifest and the worker included.

## Trade-offs

- **An app per host.** Each host is its own origin, so a user with three hosts that serve the page installs three apps, each named for its host. That is ADR 0011's "each host stands alone", carried over.
- **Full screen gives the terminal more rows.** Without the address bar, the terminal gets a few more rows on a phone, which is where the page is most cramped.
- **It also means new ground for the terminal.** The keyboard rules were tuned in a Chrome tab. In a standalone window on Android, and anywhere on iOS, they are untested. Getting them right on iOS may take more than this option's day, and is the biggest unknown here.
- **An offline note instead of a dead page.** The app can't do anything without the tailnet, but it says why.
- **No cost on the hosts.** No protocol change, nothing new in Varnick's Mac app or the installer, and no new state.
- **No push.** The request's second half needs option 02. On iOS push needs this option first anyway.

## User Stories

1. As the user, I want to install a host's Phone page on my phone's Home Screen, so that I open it like an app.
2. As the user, I want the installed page to open full screen, so that the terminal has the whole screen.
3. As the user with several hosts, I want each installed page named for its host, so that I can tell them apart.
4. As the user, I want the installed page to say it can't reach the host, and why that might be, when the tailnet is off or the host is asleep, so that I don't stare at a browser error.
5. As the user on Android, I want an Install button on the page, so that I needn't find it in Chrome's menu.
6. As the user on an iPhone, I want the page to tell me how to add it to the Home Screen.
7. As the user, I want nothing of my sessions kept on the phone by the app, so that installing it stores no prompts or titles.

## Implementation Decisions

- **Served like the rest.** The manifest and the worker are served by the page server's file list, through the same Host check and caller check as every file. An unlisted device gets neither.
- **Written per request.** The manifest and the worker are written per request from a template with the host's name, as the home page's loopback note is. The host's name comes from the relay's hello, as the page's header already uses it.
- **The worker's script is the only thing it adds to the browser.** It registers from the page at load, scope `/`. A new build changes its bytes, and the browser updates it as usual.
- **Navigations only.** The worker answers only navigations, and only after the network failed. Every other fetch passes untouched, so the port proxy's frames (other ports, so other origins) and the websockets are unaffected.
- **Install UI.** The install button and the iOS hint are page code with a pure rule beside the existing ones: installed or not, platform, dismissed or not. The dismissal is kept in the page's local storage, per host as everything is.
- **Icons are files in the page's folder,** checked by digest like the vendored files, so a build that drops one fails `bun test`.
- **Documents.**
  - CONTEXT.md's **Phone page** entry says it installs as an app per host.
  - where-it-breaks' Phone page section says the worker answers failed navigations only and caches nothing from the server.
  - The privacy doc says the app keeps no session content on the phone.
  - No ADR: nothing about the architecture changes.

## Testing Decisions

- `bun test`:
  - the install rule;
  - the manifest and worker templates for a host name with quotes and non-ASCII;
  - the content policy naming the three new sources;
  - the icons' digests.
- `make build` passes. The page server restarts on the new files' digest, as it does for any page change.
- **By hand, after the user restarts Varnick, on the Android phone:**
  - Chrome offers Install, and the app opens standalone with the host's name.
  - In the app, the terminal:
    - the key bar stays on one line;
    - the keyboard takes no rows;
    - Gboard typing, a swipe to scroll and rotation work.
  - Turn Tailscale off and open the app: the offline note shows, and Try again loads the page once Tailscale is back on.
  - An unlisted browser on the tailnet still gets the unlisted page, and no worker registers for it.
- **On an iPhone, if one is at hand:**
  - Add to Home Screen gives the icon and a standalone window.
  - The same terminal checks, which are the first the page has ever had on iOS.

## Out of Scope

- Push: option 02.
- One app for every host: option 03 (push), or a hub page (rejected in ADR 0011).
- Working offline with cached sessions, lists or screens.
- Shortcuts in the manifest (a New session long-press), share targets and file handlers.
- Fixing iOS-only terminal problems beyond what the by-hand check finds small. A larger iOS problem gets a problem of its own.

## Further Notes

- **No service worker at all** would still let Android install, since Chrome dropped that requirement. But the app would show the browser's error off the tailnet, and option 02 needs the worker anyway. So it is in from the start.
- **Caching the page's own code** (an app shell) for instant starts was left out. It would open on a screen that can do nothing without the host, and could run old code against a newer server after an upgrade.
