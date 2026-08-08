# Surfaces

Each subdirectory here is one Surface — a built thing with its own place in the
window. Core discovers them from the filesystem at load time and imports them
dynamically, so adding one never requires editing Core, and one that fails to
load fails alone.

This directory is Userspace. The agent writes here freely. See
`docs/adr/0002-core-userspace-boundary.md` and
`docs/adr/0004-core-never-statically-imports-userspace.md`.
