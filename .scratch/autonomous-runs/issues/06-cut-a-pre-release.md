# 06 — Cut a pre-release from the command line

**What to build:** one command turns a finished queue of tickets into something
the developer can accept in the morning — a version, a changelog entry, an
announcement, a build and a tag. Running it twice does not leave two pending
pre-releases to choose between; the newer supersedes the older.

The version bump is inferred from the tickets and their diffs, starting from
0.0.1 and following pre-1.0 conventions. The announcement is written from the
tickets rather than from commit messages, because commit messages say what
changed in the code and tickets say what changed for the developer. The
changelog accumulates from the last **promoted** release, not the last
pre-release, so three nights nobody promoted produce three nights of notes.

The decisions here — which bump, which entry, which pre-release supersedes
which, which artifact should be served — are pure and belong where they can be
asserted headlessly and improved without a human merge. Only spawning the build,
writing the tag and switching the served artifact are impure.

**Blocked by:** 04 — The window shows the version it is running; 05 — The main window is served from a built artifact.

**Status:** ready-for-agent

- [ ] One command produces a pre-release: version bumped in the manifest, changelog entry written, announcement composed, artifact built, tag written
- [ ] The bump is derived from the tickets and diffs in the run, and the derivation is a pure function with its own assertions
- [ ] The announcement reads as prose about what changed for the developer, and never as a list of commits
- [ ] The changelog entry accumulates everything since the last promoted release
- [ ] Cutting a second pre-release supersedes the first; exactly one is ever pending
- [ ] The pure decisions live where they can be changed without a human merge, and are asserted headlessly
- [ ] The artifact is written where the host looks for it, without switching what is currently served
- [ ] A pre-release whose build fails leaves nothing pending, rather than a version bump with no artifact behind it

## Inherited from 04 — the version fields it did not unify

Ticket 04 made the **window's** version data: it is read from the root
manifest's `version` field when the renderer is served or built, and
`VARNICK_VERSION` in `packages/core/src/version.ts` is the single source of the
number for Core. Bumping the root manifest is therefore all a release has to do
to change what the header shows.

That is not all a release has to do to change what the *product* is, and 04 did
not close the gap. Five files carry a version and only one of them moved:

| File | What it versions | Landable unattended? |
|---|---|---|
| `package.json:3` | the window, via 04 | yes — it is data, and not a lifecycle script |
| `src-tauri/tauri.conf.json:4` | the bundled app | **no — Fence** |
| `src-tauri/Cargo.toml:3` | the Rust crate | **no — Fence** |
| `packages/core/package.json:3` | a private workspace package | yes |
| `packages/harness`, `packages/userspace`, `packages/lint` | private workspace packages | mixed — harness is Fence |

**This is a decision for 06, not an oversight to repeat.** The spec says a
release "edits data and never edits Core", and the reason that matters is that a
release must not need a human. But a release that bumps `tauri.conf.json` or
`Cargo.toml` needs exactly that: both are under `src-tauri/**`, which is on the
protected list in the spec's own predicate and is never merged unattended. So
either the bundle version stops being bumped per release, or it is derived from
the root manifest rather than stored, or a release that touches it is a
Fence-pending outcome by construction.

Tauri can take `"version": "../package.json"` in `tauri.conf.json`, which makes
the manifest the one source for the bundle too and would leave the field frozen
forever after. That is the shape worth taking, and it is a **one-line Fence
change that a human merges once** — after which no release ever touches
`src-tauri/**` again. 04 deliberately did not make it, because doing so would
have turned a landable ticket into a parked one.

The four private workspace packages are harmless today: nothing is published, so
`0.0.0` there means "unversioned" in the ordinary npm sense rather than
disagreeing with anything. They are listed because story 35 asks for the version
to have exactly one source, and "one source" should be a decision that was taken
rather than a count that happens to be low.
