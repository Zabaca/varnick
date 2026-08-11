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
