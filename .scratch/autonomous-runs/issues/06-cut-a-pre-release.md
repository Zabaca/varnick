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

- [x] One command produces a pre-release: version bumped in the manifest, changelog entry written, announcement composed, artifact built, tag written
- [x] The bump is derived from the tickets and diffs in the run, and the derivation is a pure function with its own assertions
- [x] The announcement reads as prose about what changed for the developer, and never as a list of commits
- [x] The changelog entry accumulates everything since the last promoted release
- [x] Cutting a second pre-release supersedes the first; exactly one is ever pending
- [x] The pure decisions live where they can be changed without a human merge, and are asserted headlessly
- [x] The artifact is written where the host looks for it, without switching what is currently served
- [x] A pre-release whose build fails leaves nothing pending, rather than a version bump with no artifact behind it

## Comments

### Inherited from 04 — the version fields it did not unify

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

### What 06 decided about those version fields

**A release bumps the root manifest and nothing else. It never writes
`src-tauri/**`.** That is the decision, taken rather than deferred: keeping every
release landable unattended is the property the whole feature exists for, and a
release forced to bump `tauri.conf.json` or `Cargo.toml` would wake the developer
every night.

The cost is accepted and named: the bundled app's version stops tracking the
window's. Closing it is the one-line `"version": "../package.json"` change 04
identified, filed as **ticket 14** — Fence, human-merged once, and after it no
release ever touches `src-tauri/**` again. The four private workspace manifests
stay at `0.0.0`, which means "unversioned" rather than "disagreeing", because
nothing is published.

The argument is in
`docs/adr/0022-a-pre-release-is-cut-from-the-changelogs-pending-block.md`.

### Inherited by 07, 08 and 09 — what is now on disk and who owns it

**The store gained two things beside `.varnick/builds/`.**

```
<clone>/CHANGELOG.md                     committed; the accumulator
<clone>/.varnick/pending-release.json    gitignored; the one pending pre-release
```

`CHANGELOG.md` is the ledger and there is deliberately no second one. Entries are
`## v0.0.1 — pending` while nobody has promoted them and `## v0.0.1 — 2026-08-04`
once somebody has, at most one pending, always first, header is everything above
the first `## `. Read it with `changelogEntries` / `pendingEntry` /
`lastPromotedVersion` from `packages/core/release.ts` rather than with a regex of
your own — the writer and the reader share one expression on purpose, and a
second reading of that heading is a pending entry the next cut cannot find, which
silently restarts the accumulation.

`.varnick/pending-release.json` is what a band reads: version, artifact id, tag,
`cutAt`, the announcement text, and the notes. `parsePendingRecord` answers `null`
for absent, unparseable and shaped-wrong alike, the way `servedArtifactId` does.

**08 — promoting.** Three things, and the first is the cheap one people miss:

1. **Promotion is a one-line edit to the changelog** — `pending` in the heading
   becomes the date. Nothing else about the entry changes. Everything downstream
   keys off that: the accumulation restarts, the version base moves, and last
   night's notes stop coming back even though their tickets stay ticked for ever.
   `promotedNoteIds` is what enforces the last part.
2. **Then move the markers** — `served` to `record.artifact`, and `previous` to
   whatever `served` named a moment ago. The artifact is already in the store; a
   cut deliberately never pointed at it. `RESTART_VARNICK` already exists.
   **`previous` is ticket 07's and it is written, never inferred** — mtime says
   when an artifact was *built*, not when it was last served, and a pre-release
   can sit unpromoted for weeks. So the promotion is the thing that writes it;
   read 07's module for the call rather than composing the marker text here.
   Both markers parse through one function, `markedArtifactId`, renamed from
   `servedArtifactId` by 07 for that reason.
3. **Then `clearPendingRecord(cloneRoot)`**, exported from `release-cut.ts` for
   exactly this and the only other thing that may touch that file.

Do those in that order. A `served` written before the changelog is a window
running a build the file still calls pending, and a `served` moved before
`previous` is a fallback pointing at the build that just failed.

**07 — falling back.** Nothing here reads or writes `served`, so 07's branch in
`packages/core/scripts/serve.ts` is untouched and still yours. Two facts that
bear on it: a cut writes an artifact named for its version and leaves `served`
alone, so the store legitimately holds artifacts nothing points at; and two cuts
at the same level reuse the same id, so the store does **not** grow one directory
per night. Reaping is therefore about promoted builds — N-1 — and not about
pre-releases piling up. 06 deletes nothing from the store, on purpose: deleting a
build the developer might be inspecting is not a thing to do while they are
asleep.

07 landed that pruning: `ARTIFACTS_KEPT = 4`, newest-first at launch, sparing
`served`, `previous` and whatever is currently being served regardless of age.
Four was sized to leave room for an unpromoted pre-release plus a spare, so a
cut is not pruned out from under the developer overnight — but the store is
bounded now, and nothing here should assume otherwise.

**09 — the skill.** The command is `bun run release <feature-slug>`, and the slug
has no default because a release that guessed which queue it was releasing would
announce the wrong night's work. Two behaviours the skill's prose should state
rather than rediscover:

- **Which tickets land in the changelog is read from their acceptance boxes.** A
  ticket is in the release when every `- [ ]` is `- [x]` and there is at least
  one. So a parked ticket must keep unticked boxes, and the skill must not tick
  boxes for work it did not finish — that is the only thing standing between a
  parked ticket and a line claiming it shipped. Driven and asserted: the driver
  plants a parked ticket beside a landed one and checks only one reaches the
  entry.
- **A run with nothing landed exits non-zero and cuts nothing.** That is a real
  night, not an error, and the skill should report it as one rather than retrying.

The announcement each ticket contributes is its own `**What to build:**`
paragraph, so the quality of the release notes is the quality of that paragraph.
A ticket that takes something away should carry an `**Accepted consequence:**`
line — it is the one sentence in a ticket that moves the version number, and it
is what would have caught ticket 05, whose diff reads entirely as additions.
