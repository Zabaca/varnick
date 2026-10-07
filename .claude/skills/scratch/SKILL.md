---
name: scratch
description: Scratch, a live page the user watches in a pane beside this session. Use when the user wants to see, visualize, prototype or try out UI, a chart, a diagram or a page.
---

# Scratch

Scratch is a custom app (`.launchy/custom-apps/scratch/`): a Vite dev server with hot reload and React Fast Refresh, serving a folder you write into. The user opens it beside your pane and sees the page change as you edit.

## Show the user something

1. **Find your pane id.** It is `$LAUNCHY_PANE_ID`; if that is empty, the name of the folder that holds `$LAUNCHY_SESSION_FILE` (a pane from an older Launchy has only that). If both are empty you aren't in a Launchy pane: tell the user Scratch needs a Launchy Claude pane and that they can ask there. Stop.
2. **Make the area** `<root>/.launchy/scratch/<pane id>/`, where `<root>` is `$LAUNCHY_PROJECT`. If `$LAUNCHY_PROJECT` is empty (this pane started before Launchy set it), `<root>` is the git top level of the folder this session started in, else that folder (`git -C <start folder> rev-parse --show-toplevel`); don't take it from a folder you have `cd`'d into since, a worktree included. If the area is missing, create it, then write `<root>/.launchy/scratch/.gitignore` containing `*` if that file is missing, so nothing here reaches git.
3. **Write the page** in the area (below), `index.html` last: its appearance is what replaces the placeholder.
4. **Ask the user to open Scratch** when you created the area in step 2, or can't tell they have it open: split this pane from the picker (⌃⌘⇧E or ⌃⌘⇧O) and choose Scratch (S). The page doesn't open by itself. Done when you have asked once; the pane then serves your page within a second of `index.html` existing.

## The page

- `index.html` loads `./main.tsx` with a module script. React 19 and react-dom are installed: import from `"react"` and `"react-dom/client"`. Plain HTML, TS and CSS work too.
- Keep `main.tsx` to mounting, `createRoot(...).render(<App />)`. Put components in `App.tsx` and other files that export only components: Fast Refresh then swaps edits in place and keeps state (clicks, inputs). An edit to `main.tsx`, or to a file that also exports non-components, reloads the whole page.
- Iterate by editing files in place.
- Other npm packages: install before you write the import, since Vite keeps its "Failed to resolve import" error up after a later install. In `<root>/.launchy/scratch/` run `bun add <package>`. If that folder has no `package.json` yet, don't wait for the user to open Scratch: write `{}` to `<root>/.launchy/scratch/package.json` first (without it `bun add` edits the nearest `package.json` above, usually the project's own), then run `bun add react react-dom <package>`. Scratch then skips its own install, so React must be in that file. If a page already imports a package you installed afterwards, `touch` the importing file.
- Scratch's own Vite serves the page, so it needs no server of yours and no check that it shows. Read `.vite.log` in the area only when the user reports a problem.
