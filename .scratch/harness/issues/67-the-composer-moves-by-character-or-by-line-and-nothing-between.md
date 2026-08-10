# 67 — The composer moves by character or by line, and nothing in between

**What to build:** ⌥f and ⌥b move the caret by word in the composer, and ⇧⌥f / ⇧⌥b extend the selection.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path. Two pure functions and one keystroke branch.

## Measured

Typing ⌥f in the composer inserts `ƒ`. Typing ⌥b inserts `∫`. Neither moves the
caret, and neither is noticed at the time: the glyphs are small, the field is
dark, and the developer finds them after sending.

⌥→ and ⌥← already move by word, because the platform does that for every text
field on the system. So the composer is not missing word motion — it is missing
the *bindings a terminal-shaped developer reaches for*, and reaching for them
does not fail cleanly, it edits the draft.

## What to build

**Two pure functions in `domain.ts`:**

```
wordBoundaryForward(text: string, caret: number): number
wordBoundaryBackward(text: string, caret: number): number
```

Emacs semantics. Skip any run of non-word characters in the direction of travel,
then skip the run of word characters that follows. At either end, return the
caret unchanged — a motion at a boundary is a no-op, never a wrap.

A word character is `\p{L}`, `\p{N}` or `_`, matched with the Unicode flag. A
prompt holding accented text or CJK then moves the way the language reads rather
than the way ASCII does.

`domain.ts` because it has zero imports by design and `drive.ts` already imports
it — the highest seam available, and it needs no new one.

**One branch in the composer's `onKeyDown`**, and it does no arithmetic:

- matches on `event.altKey && event.code === 'KeyF'` / `'KeyB'`
- `event.code`, not `event.key` — ⌥f arrives as `ƒ`, and the binding is about the
  physical key
- `preventDefault` unconditionally on a match; that is what stops the glyph
- calls the function, assigns `selectionStart`/`selectionEnd` on the field
- `event.shiftKey` extends rather than moves: the anchor stays, the head travels
- sits **above** the slash-menu branch, so a menu that has no use for these
  motions does not swallow them

Word motion crosses a newline. A multi-line draft's last word on one line and
first on the next are one motion apart.

## Testing

`drive.ts`, against a table of drafts: both ends, a multi-line draft, a run of
punctuation between words, a leading run of spaces, and a non-ASCII word. The
boundary cases are the point — ⌥f at the end of a draft returning the same index
is the assertion that stops a wrap bug nobody would think to look for.

The keystroke branch itself is a component and is not driven headlessly; keeping
it down to *read, call, assign* is what makes that acceptable.

## Out of scope

The rest of the Emacs motion set — ⌃a, ⌃e, ⌃k, ⌥d. Only the two the developer
reached for. How far this composer imitates a terminal is a separate decision and
should be made deliberately rather than one binding at a time.
