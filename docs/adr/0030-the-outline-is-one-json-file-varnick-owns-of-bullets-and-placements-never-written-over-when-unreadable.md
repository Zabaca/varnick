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

- **Local only** (amended 2026-10-20 by [ADR 0046](0046-the-phone-page-shows-a-macs-outline-to-its-listed-devices-and-edits-it-through-the-apps-model.md): the Phone page of that Mac shows and edits the Outline for a listed device). Nothing reaches a paired Mac, and the relay and the launch snapshot never read the file. Ids and placements would let a later sync merge by bullet.
- **A hand edit made while Varnick runs is overwritten** at the next save: the file isn't watched.
- **Anything unreachable from the top bullet is dropped when the tree is saved.** Deleting a placement drops whatever was only under it.
- **A bullet's text is never logged.** Logs and `Varnick --outline-check <file> [<out>]` give counts and reasons.
- **Amended 2026-10-11: Varnick's own copy** (the clipboard form of copied bullets, `OutlineClipboard`) is versioned apart from this file: JSON with `version: 1`, holding no ids, in the pasteboard type `com.zabaca.varnick.outline`. A paste reads it only when it knows the version, and otherwise falls back to the indented text beside it. It never reaches the file, and the file's version is unchanged.
- **Amended 2026-10-11: Local only holds for the file and for every Mac and device,** not for a session that reads the outline. With Panel access on, a Claude session in a pane can read the bullets and notes (`outline_read`), which go to Anthropic with the session and stay in its transcript on this Mac (ADR 0031). Reading loads the file as showing the outline would and never writes it.
- **Amended 2026-10-20: local only has a second exception, a listed device's Phone page** ([ADR 0046](0046-the-phone-page-shows-a-macs-outline-to-its-listed-devices-and-edits-it-through-the-apps-model.md)). The Outline's bullets and notes reach the Phone page of the Mac that keeps the file, over the tailnet, for the user's listed devices, which also change it through the app's model; the page holds them in memory alone. The file, its format and its version are unchanged, a paired Mac and a headless host still get nothing, and a bullet's text is still never logged.
