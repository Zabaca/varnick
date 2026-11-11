# A Chromium pane embeds zebkit and serves CDP, so a session can drive the page the user sees

A session couldn't read or drive a Browser pane: `pane_read` gave its kind and title, and acting meant clicks at screen coordinates. The **Chromium pane** is a second web pane kind whose page is Chromium 157, from [zebkit](https://github.com/ikey4u/zebkit) 0.4.0 (Chromium as a library, LGPL-2.1), attached to the pane's own NSView under the Browser pane's address bar. The engine serves the Chrome DevTools Protocol on 127.0.0.1, and `pane_read` on a Chromium pane gives the endpoint and the pane's target, so a session drives the same page the user is looking at. Built as a prototype at the user's word of 2026-11-11, with no problem file. A standalone app proved it first: nodriver ran a Google search and a Google sign-in step in it.

- **One engine per process.** zebkit starts once and never again after it stops. Varnick `dlopen`s `Zebkit.framework` the first time a Chromium pane shows, so a build without the framework runs (the tile isn't listed), `--mcp` never maps it, and the 133 MB library stays out of a Varnick that opens none. Every Chromium pane shares the engine, its profile (`chromium-profile` in Varnick's support folder) and its CDP endpoint, on a port the system picks at each start.
- **The framework sits beside the binary.** Its helpers crash at start when the host executable is anywhere else. `make build` fetches the release, pinned by SHA-256 like zmx and Bun, into `.build/release`. It isn't in `Varnick.app` yet.
- **Signed with Varnick's identity.** The hardened runtime's library validation refuses the package's ad-hoc framework, so the build signs its helper and then the framework with the same identity. Neither gets the hardened runtime: the helper runs the renderers, whose V8 needs JIT.

## Considered Options

- **Linking the framework:** passed over. Varnick would fail to start without it, and every launch would map it.
- **Off-screen views drawn by Varnick:** passed over for now. `attach_native` puts the page in the pane as a subview, with the system's own input, and needs no event forwarding.

## Consequences

- **A session can read and act in a logged-in page.** It goes to Anthropic with the session, as a terminal's screen does. `docs/privacy-and-security.md` and where-it-breaks ("What the tools do not promise") say so.
- **CDP has no password.** Any process on this Mac can drive the profile while the engine runs, as with Chrome's `--remote-debugging-port`.
- **Accepted gaps of the prototype:** no switch in Settings › Experimental (the tile shows whenever the framework is there); popups open as zebkit's own window, not as a pane; `pane_open` has no Chromium kind; the helpers aren't counted in Resources.
