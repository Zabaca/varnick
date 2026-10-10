---
title: A custom app has to be written before it is useful, and Scratch stays in this repo
description: Custom apps (ADR 0005) are a public feature that people who download Varnick barely hear of. The guide names them only as a reason to install Bun, and varnick.com in one phrase. Nobody gets a useful app without writing one. Scratch, the most distinctive app (Claude shows a live page beside its session), exists only inside Varnick's own repository, as a project app and a project skill, so no other user can have it. There is also no way for other people to offer an app to everyone.
impact: The feature that lets Varnick's panes hold anything stays invisible to people who download Varnick. Scratch, its best demonstration, reaches nobody outside this repo. Apps people write for themselves stay on their own Macs.
severity: mid
evidence: Code and docs at f856715, read on 2026-10-10. Scratch's installed packages measured on a copy installed in a checkout on 2026-10-04. Nothing was built or run.
status: open
---

## What the user wants (2026-10-10)

- Scratch stays an example of an ordinary custom app, not a special built-in.
- An accepted list of custom apps, a **catalog**, that people can easily turn on from a new **Settings › Apps** section, with one switch per app, off by default. Scratch is the first entry.
- Later, other people contribute apps, and the maintainers accept them in.

## Today

Verified at f856715 unless marked.

- **Where apps come from.** The split picker reads two folders each time it opens: the project's `.varnick/custom-apps/` and the user's `~/.varnick/custom-apps/`. An app is a folder in one of them with a `varnick.json` naming an entry file. A project app hides a user app with the same folder name. Hidden folders are skipped. A restored app pane finds its app again by folder name from the pane's folder, project first, and closes if it is gone.
- **How an app runs.** Picking an app runs the account's login zsh in the app's folder, inside the pane's zmx session. If the folder has a `package.json` and no `node_modules`, it runs `bun install` first (not frozen to the lockfile), then `bun run <entry>`. Whatever the install fetches is fetched at that first pick.
- **What an app is told.** The `custom-apps` skill holds the contract for app authors. `make install` links it into `~/.claude/skills/` from a checkout, and Varnick.app links its own copy at each start. Either link is made only when nothing is there, and a link Varnick didn't make is left alone.
- **What the published app carries.** Varnick.app holds the `custom-apps` skill and nothing else of apps: not Scratch, not its skill. The skill's two pointers to Scratch (its layout, and its server as the working example) are paths into a checkout, so from the app's copy they lead nowhere.
- **Scratch.**
  - It is a project app of this repo with a project skill beside it.
  - It runs a Vite dev server with the React plugin over a folder in the project, one per Claude pane.
  - Its own packages (Vite and the React plugin) are pinned by a committed `bun.lock`, which carries an integrity hash for every package.
  - On its first start in a project, it writes a `package.json` for the pages with caret ranges for React and runs `bun install` there. So each project's first use fetches unpinned packages from the npm registry.
  - Its installed packages came to about 35 MB, with three native binaries: esbuild's executable, and Rollup's and fsevents' addons (measured on 2026-10-04).
- **The docs.** The guide mentions custom apps once, under Requirements, as a reason to install Bun. varnick.com mentions "app panes" once, also as a reason for Bun. The privacy and security doc says nothing about custom apps or the npm registry. CONTRIBUTING has no path for an app.
- **The Mac that runs Varnick from this checkout** still runs the pre-rename build until the user's cutover. That build reads `.launchy/custom-apps/` and `launchy.json` (read in the code before the rename commit). Main has neither, so that build already lists no Scratch from this repo, and moving Scratch within the repo changes nothing for it.

## Unverified

- Whether Bun runs a dependency's install scripts when nothing trusts it. Bun's documentation says it doesn't by default.
- Whether Claude Code picks up a skill linked into `~/.claude/skills/` in sessions already running, or only in sessions started afterwards.
