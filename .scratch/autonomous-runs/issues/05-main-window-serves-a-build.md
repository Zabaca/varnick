# 05 — The main window is served from a built artifact

**What to build:** work landing in the live tree stops reloading the window the
developer left open. The main window serves a built artifact instead of a dev
server watching the clone, so nothing under it moves while they are away.

Today a change under Core sends a full reload to the window. That is deliberate
and correct while the live tree is what the window renders — hot-swapping the
module that owns the Session would remount the machine holding the conversation.
It stops being correct once merges land unattended, because then the reload
happens all night, to a window nobody asked to reload.

The dev server stays for Previews, which is where hot reloading is still what
the developer wants, and where the work now happens.

This ticket also establishes where built artifacts live and which one the host
serves — the convention the release chain builds on.

This touches the host and lands through a human merge.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] The main window is served from a built artifact, and no watcher is attached to the clone it was built from
- [ ] Editing a Core file in the live tree does not reload the open window
- [ ] A Preview still runs from a dev server, and hot reloading inside a Preview is unchanged
- [ ] Where artifacts live, and which one is currently served, is a fact something else can read — the release chain needs to write into it and switch it
- [ ] The existing hot-update decision is left in place and its assertions still pass, since what changes is what calls it
- [ ] The lost behaviour is recorded rather than left to be discovered: live Surface hot reloading no longer works in the main window, and does work in a Preview
