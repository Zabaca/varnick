# Surfaces

Each subdirectory here is one Surface — a built thing with its own place in the
window. Core discovers them from the filesystem at load time and imports them
dynamically, so adding one never requires editing Core, and one that fails to
load fails alone.

A Surface is a directory with an `index.tsx` in it that default-exports a
component. The directory name is the Surface's name — `recent-notes` shows as
"Recent notes". Nothing else is needed and there is nothing to register; a
directory without that file is not a Surface, so helpers can live beside one.

If a module does not compile, that Surface shows the reason and offers a retry,
and everything else — the other Surfaces, and the conversation you would use to
fix it — keeps running.

This directory is Userspace. The agent writes here freely. See
`docs/adr/0002-core-userspace-boundary.md` and
`docs/adr/0004-core-never-statically-imports-userspace.md`.
