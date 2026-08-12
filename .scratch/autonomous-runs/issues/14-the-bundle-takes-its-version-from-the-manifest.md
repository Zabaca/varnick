# 14 — The bundle takes its version from the root manifest

**What to build:** the bundled application's version stops being a second number
somebody has to remember. `src-tauri/tauri.conf.json` reads the root manifest
instead of storing a copy, so a release bumps one field and everything that
carries a version follows.

Today three files carry one: `package.json`, which is what the window shows and
what a release bumps; `src-tauri/tauri.conf.json`, which versions the bundle;
and `src-tauri/Cargo.toml`, which versions the crate. Only the first moves. A
release that moved the other two would have to touch `src-tauri/**`, which is
protected — so it could not land unattended, and "a release edits data and never
edits Core" would become "a release wakes the developer" every single night.

Tauri accepts `"version": "../package.json"` in `tauri.conf.json` and reads the
number out of it. That is one line, and after it the field is frozen for ever.

**This is a Fence change and lands through a human merge**, which is exactly why
it is its own ticket rather than a line inside ticket 06. Ticket 04's author
surveyed the five files that carry a version and declined to unify them, writing
that up under "Inherited from 04" in **ticket 06's** Comments rather than in
ticket 04's own file, which says nothing about any of this. Ticket 06 then took
the decision, which was to leave `src-tauri/**` alone and say so. Authored, checked
and left pending is the right outcome here — it is a two-minute decision at
breakfast, and the alternative is a landable ticket turned into a parked one.

`Cargo.toml`'s version is a separate question and probably a different answer:
nothing publishes the crate, so `0.0.0` there means "unversioned" in the ordinary
sense rather than disagreeing with anything. Decide it explicitly rather than
bumping it by reflex.

**Blocked by:** 06 — Cut a pre-release from the command line.

**Status:** ready-for-agent

- [ ] `src-tauri/tauri.conf.json` takes its version from the root manifest rather than storing one
- [ ] Bumping the root manifest alone changes what the bundled app reports, with no other file edited
- [ ] `bun tauri dev` still launches, and a release still never writes anything under `src-tauri/**`
- [ ] Whether `Cargo.toml` follows is decided explicitly and written down, rather than left as a third number nobody named
- [ ] Story 35 — "the version has exactly one source" — is true of the shipped artifact and not only of the window

## Comments

### From 06 — why this exists and what 06 did instead

The gap was recorded — in this ticket's ancestor, ticket 06's Comments, by ticket
04's author — and left open. Ticket 06 took the decision rather than repeating
the observation: **a release bumps the root manifest and
nothing else, and never touches `src-tauri/**`.** That keeps every release
landable unattended, which is the property the whole feature exists for, and it
accepts a real cost — the bundled app's version stops tracking the window's until
this ticket lands.

`docs/adr/0022-a-pre-release-is-cut-from-the-changelogs-pending-block.md` has the
argument under "The version fields this does not unify". The four private
workspace manifests (`packages/core`, `packages/harness`, `packages/userspace`,
`packages/lint`) are deliberately out of scope: nothing is published, so `0.0.0`
there is not a disagreement.
