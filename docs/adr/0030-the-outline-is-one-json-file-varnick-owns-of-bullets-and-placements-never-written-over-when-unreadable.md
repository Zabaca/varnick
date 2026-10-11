# The outline is one JSON file that Varnick owns, of bullets and placements, never written over when it can't be read

The Outline (`CONTEXT.md`) keeps its bullets in `outline.json` in the support folder, on this Mac only. The file is one JSON object: a `version`, the id of the top bullet, every bullet by id (its text, note, completion, dates and the placements of its children), and the view's own state (`zoom`, `showsCompleted`). A bullet is kept once, and each spot where it shows is a placement in its parent's list, so a mirror is a bullet with two or more placements and no placement is the original. A row on screen is a path of placement ids, never a bullet id. The format is final from the first ticket, placements included, although nothing nests or mirrors yet, so a later ticket needs no change of version. Problem and option: `docs/problems/no-outline-in-varnick/`, option 01.

The rules that keep the file safe:
- **A file that can't be read is never written over.** Not JSON, not decoding, or naming a top bullet that isn't there: the outline says so, offers Reveal in Finder and Start a new outline (which renames the file to `outline.unreadable-<date and time>.json`), and nothing is written meanwhile. This is the device file's rule: what the user may want to repair is never replaced.
- **A newer version is never written over either.** An older build would drop the fields it doesn't know and write the rest back, so any new field raises the version.
- **A file that reads but breaks a rule is repaired in memory:** a placement naming a missing bullet or putting a bullet inside itself is dropped, and a bullet left with no placement goes under "Recovered". The file itself changes at the next edit.
- **Saved on change:** half a second after the last change, atomically (a temporary file in the same folder, mode 0600, renamed), at once when the outline closes, and at Quit. The app is stopped by signal on a restart, so that loses at most the last half second. `outline.previous.json` holds the file as it was before the launch's first write.

## Considered Options

- **Putting the outline in `sessions.json`:** rejected. That file decodes as one value and falls back to empty on any failure, which would take every open tab down with a bad outline, and the reverse.
- **A nested tree, a bullet inside its parent's JSON:** rejected. A mirror would be two copies, and an edit in one would have to find the other.
- **A database table:** rejected. The search store is a cache that can be rebuilt, which the user's own writing is not, and a plain file can be repaired by hand.
- **Writing a copy of the repaired tree at load:** rejected. Reading changes nothing on disk, so opening the outline can't lose a file the rules misread.

## Consequences

- **Local only.** Nothing reaches a paired Mac or the phone, and the relay and the launch snapshot never read the file. Ids and placements would let a later sync merge by bullet.
- **A hand edit made while Varnick runs is overwritten** at the next save: the file isn't watched.
- **Anything unreachable from the top bullet is dropped when the tree is saved.** Deleting a placement drops whatever was only under it.
- **A bullet's text is never logged.** Logs and `Varnick --outline-check <file> [<out>]` give counts and reasons.
