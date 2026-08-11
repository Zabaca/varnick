# 04 — The window shows the version it is running

**What to build:** the header stops saying `v0.0.0`. It says the version of the
build the developer is actually running, read from the root manifest when the
renderer is built, so there is exactly one place the number is true.

Today the version is a literal passed to the header component. That makes a
release a change to Core — a release that can fail typecheck, and a number that
can disagree with the manifest without anything noticing. Everything in the
release chain depends on this being data instead.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] The version reaches the header from the root manifest rather than from a literal in a component
- [ ] It is resolved when the renderer is built, not read at run time from a file the webview cannot see
- [ ] Changing the manifest's version and rebuilding changes what the window shows, with no source edit
- [ ] The states page and the live chat show the same version, because they render the same component
- [ ] An assertion covers the resolution, so a build that loses the version fails rather than showing a placeholder
