# 07 — Keep the previous build and fall back automatically

**What to build:** a build that will not start does not take away the tool the
developer would use to fix it. The host keeps the previously served artifact on
disk, and if the one it has been switched to fails to come up, it falls back to
it and says so.

This is the argument ADR-0004 makes for a Surface, one level out. A broken
Userspace module must not leave a window with no chat; a broken build must not
leave a developer with no varnick. The cost is one extra artifact on disk and it
is the difference between a bad night and a bad morning.

This touches the host and lands through a human merge.

**Blocked by:** 05 — The main window is served from a built artifact.

**Status:** ready-for-agent

- [ ] The previously served artifact is retained when a new one is switched to
- [ ] An artifact that fails to start causes the host to serve the previous one instead, without the developer intervening
- [ ] The fallback is visible rather than silent — the window says which build it is running and that it fell back
- [ ] Which artifact to serve, and whether to fall back, is decided by a pure function with its own assertions
- [ ] Retention is bounded, so artifacts do not accumulate for the life of the clone
