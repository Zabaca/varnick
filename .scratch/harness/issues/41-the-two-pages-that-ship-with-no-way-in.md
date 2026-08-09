# 41 — The two pages that ship with no way in

**What to build:** All three renderings are reachable from the window, so `#/bare` and `#/states` are surfaces a developer uses rather than surfaces that exist.

**Blocked by:** None.

**Status:** done.

**Realizes:** no state path.

## Why this exists

CLAUDE.md says the bare page and the states page *ship* — that they are product
code and not scaffolding. They do ship. Nobody could get to them.

`BarePage.tsx:112` and `StatesPage.tsx:28` each render a three-link nav. The app
opens on `#/designed`, which renders no nav at all, and nothing else changes the
hash. So the two pages that can navigate are exactly the two you cannot reach,
and the one you always have is the one with no way out. The developer who owns
this repository had never seen `#/states`.

## Why the menu rather than a link on the chat

A nav bar on the designed rendering would put developer chrome in the product.
The whole argument for three renderings is that the designed one is the app —
adding a route switcher to it makes it a demo of itself.

The native menu is where this belongs for the same reason Reload and Restart are
there (ticket 35): it is outside the webview. A window wedged badly enough to be
worth escaping is a window whose links do not work either.

## What it does now

A separator and three items under **View**, beside Reload and Restart:

- **Chat** — ⌘1 — `#/designed`, the app
- **Bare** — ⌘2 — `#/bare`, the design-free behavioural surface
- **States** — ⌘3 — `#/states`, the coverage-checked card grid

Each sets `window.location.hash`, which is what `App.tsx` already listens to, so
the route switch costs no reload and no state.

Labels are the product words rather than the route words. `#/designed` is a file
name; **Chat** is what the thing is, and CONTEXT.md is the authority on which of
those two a person should be reading.

- [x] All three renderings reachable from a cold window
- [x] The chat carries no developer chrome
- [x] `cargo test` green

Found by the developer: *"what is #states — i've never seen it"*.
