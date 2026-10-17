---
problem: pane-kinds-are-built-in
title: Custom apps are local web servers Varnick runs, and Scratch becomes one
summary: A custom app is a folder with a small manifest and a Bun entry file, found in the focused pane's project or in the user's folder each time the split picker opens, and listed there after the built-ins. Picking one runs `bun run <entry>` in the new pane's zmx session with a port and a few environment variables, and shows the server in a web pane. Scratch is rewritten in Bun as the first custom app, kept in this repo; it serves a scratch area inside the project, and a project skill tells Claude about it. Launchy keeps no Scratch code. A `custom-apps` skill, written with the feature and reachable from any project, teaches agents what a custom app is and how to build and test one.
status: shipped
---

## Solution

A **custom app** is a local web server the user writes. It lives in a folder of its own with a manifest, `launchy.json`, giving its name, icon, picker key and entry file. Launchy looks for apps in two places: the focused pane's project, under `.launchy/custom-apps/<name>/`, and the user's home, under `~/.launchy/custom-apps/<name>/`. It reads both each time the split picker opens, as it reads agents and projects each time a prompt starts (ADR 0002), and lists the apps after Claude, Terminal and Browser.

Picking an app makes a web pane, as picking Browser does. Launchy runs `bun run <entry>` in the app's folder, inside the new pane's zmx session, with `PORT` and a few `LAUNCHY_` variables in its environment, and points the pane at that port. There is no Launchy API for an app to call: everything an app knows comes from its environment. Closing the pane ends the server. A saved app pane comes back after a restart, reconnected to its running server or running its app again.

There is no sandbox. An app runs with the user's own rights, as any script in their repo does. Today people build apps for themselves, so anything bad an app does only affects its author. Sharing, selling and installing other people's apps, with the security that needs, comes later with a marketplace.

Scratch is the first custom app. It is rewritten from Deno to Bun and moves into this repo's `.launchy/custom-apps/scratch/`. Opened beside a Claude pane, it serves that pane's **Scratch area**, a gitignored folder inside the project at `.launchy/scratch/<pane id>/`, through Vite with hot reload. Claude learns about it from a project skill instead of an appended system prompt, and needs no `--add-dir` because the folder is inside the project. Launchy keeps no Scratch code: the Vite server, its port and pid files, the orphan handling, the extra Claude flags and the pane that opened by itself all go. The per-pane folder Scratch shared with the SessionStart hook's file stays in Launchy under a neutral name.

A `custom-apps` skill teaches agents what a custom app is and how to make, run and test one with Bun. The builder writes it as part of this work, so it describes what was built, and it is part of done. It is committed in this repo and linked into the user's skills by `make install`, so an agent in any project can find it. The builder agent's definition points to it for work on custom apps.

## Trade-offs

- **A pane tool no longer needs Launchy changed.** A new app is a folder with a manifest and a Bun file, and it shows in the picker the next time the picker opens. No rebuild, no restart.
- **Claude sessions stop paying for Scratch.** No appended system prompt and no extra directory on every Claude pane. In projects that have Scratch, a skill's one-line description is all a session carries until Claude uses it.
- **Scratch is no longer everywhere.** Today every Claude session in every folder has a scratch area. After this, only projects that contain the app, or users who put it in `~/.launchy/custom-apps/`, have Scratch. Out of the box that is this repo only.
- **A page no longer opens its pane by itself.** Writing `index.html` used to open a browser pane beside Claude. Now the user opens Scratch from the split picker; the skill has Claude ask for that when the scratch area is new. Keeping the old behaviour would need either Scratch-specific code in Launchy or a way for an app to open a pane, which is a Launchy API.
- **No sandbox.** Picking an app runs its code with the user's rights, and so does restoring its pane. A cloned repo's apps appear in the picker; picking one is as trusting as running that repo's own scripts. Listing apps runs nothing: Launchy only reads manifests.
- **Bun becomes a requirement for apps,** not for Launchy. Without `bun` on the login shell's `PATH`, an app pane shows the shell's error and nothing else breaks.
- **Deno's permission model is given up.** It was never in use: Scratch ran with `-A`, which grants every permission.
- **App servers always run in zmx,** whatever Keep sessions running says (ADR 0004 put Claude and terminal panes behind that setting until a reattached screen is checked; a server has no screen). This deletes Scratch's own survival logic. Without Launchy's zmx binary an app runs directly in its pane's terminal and ends with Launchy, as terminal panes do.
- **First use installs packages.** An app with a `package.json` and no `node_modules` gets `bun install` before its first run. For Scratch that is two installs, the server's and the pages', each a few seconds and needing the network.
- **Agents can build apps without reading Launchy's source,** from the skill. In exchange the skill has to change whenever the contract does, and the link `make install` makes is one more thing installed outside the repo.
- **Running Claude sessions from before keep the old prompt.** Sessions kept in zmx across the upgrade still believe pages open by themselves, until they end.

## User Stories

1. As someone building a tool for myself, I want to drop a folder with a manifest and a Bun server into my project, so that it shows up in the split picker without changing Launchy.
2. As someone building a tool for myself, I want to keep personal apps in my home folder, so that they're available in every project.
3. As a Launchy user, I want a project's app to win over my own app of the same name, so that a project can ship the version it needs, as it can with agents.
4. As a Launchy user, I want a new or edited app to show in the picker the next time I open it, so that there's no setup or restart.
5. As a Launchy user, I want to pick an app by its key, or by arrows and ↩, so that it's as quick as picking a terminal.
6. As a Launchy user, I want apps whose keys clash with each other or with C, T or B to still get a key, so that every app is quick to reach.
7. As an app author, I want my server told its port, its pane, the project it was opened in and a folder for its own data, so that it can do its job without asking Launchy anything.
8. As an app author, I want my app's packages installed the first time it runs, so that a fresh clone works.
9. As an app author, I want to see what my server printed when it crashes, and to run it again, so that I can fix it.
10. As a Launchy user, I want closing an app's pane to stop its server, so that nothing I closed keeps running.
11. As a Launchy user, I want app panes to come back after a restart with their server still running when sessions are kept, so that a restart doesn't interrupt them.
12. As a Launchy user, I want an app pane whose app I deleted to be gone after a restart, so that I don't get a pane that can't work.
13. As a Launchy user, I want Quit to stop app servers when Keep sessions running is off, as it stops Scratch's servers today.
14. As a Launchy user, I want to open Scratch beside a Claude pane and see the page Claude builds there, live, so that I can try out UI as I do today.
15. As a Launchy user, I want two Claude panes in one project to each have their own Scratch page, so that they don't overwrite each other.
16. As a Launchy user, I want Scratch's files kept out of git without editing the project's ignore file, so that experiments never get committed.
17. As Claude in a Launchy pane, I want a skill to tell me where my scratch area is and how to build in it, so that I can use it when the user wants something visual.
18. As Claude in a Launchy pane, I want to ask the user to open Scratch when my scratch area is new, so that they see what I build.
19. As a Launchy user, I want `/clear` and `/resume` to keep working in panes that were running before the upgrade, so that the change doesn't lose track of my conversations.
20. As an agent working in any project, I want a skill that tells me what a custom app is and how to build and test one, so that I can make one for the user without reading Launchy's source.
21. As the user, I want that skill to describe the contract as built, and to change when the contract does, so that agents never build against a contract that isn't there.
22. As a Launchy builder agent, I want my definition to point me to that skill when work involves a custom app, so that I start from the contract.

## Implementation Decisions

**An app's folder and manifest**
- An app is a folder whose name identifies it, holding `launchy.json`. The manifest gives `entry`, the file Bun runs, relative to the folder, and optionally `name` (shown in the picker; defaults to the folder name), `icon` (an SF Symbol name; defaults to a generic symbol) and `key` (one character). A folder without a readable manifest that names an entry is skipped silently, as an agent file without a name is.
- The folder may hold a `package.json`, a lockfile and anything else the app needs. What the app ignores in git is its own business: Scratch ships an ignore file for its `node_modules`.

```json
{ "name": "Scratch", "icon": "scribble.variable", "key": "s", "entry": "server.ts" }
```

**Where apps come from**
- The project is the git repo containing the focused pane's folder: the nearest folder upward with a `.git` directory or file. A worktree is therefore its own project, as `git rev-parse --show-toplevel` sees it. A pane outside any repo has no project apps, and its project is its own folder.
- Apps are read from `<project>/.launchy/custom-apps/` and `~/.launchy/custom-apps/`, project first. A project app hides a user app with the same folder name, as a project agent hides a user agent (ADR 0002). Each group is sorted by name.
- They are read from disk each time the picker opens, on the main thread, as agents are: a few directory listings and small files.

**The split picker**
- The picker lists Claude, Terminal and Browser, then the project's apps, then the user's. Each app tile shows its icon and name.
- Keys: the built-ins keep C, T and B. Each app in list order takes its manifest key if it is one character not already taken; otherwise the first free digit from 1 to 9; past that it has no key and is reached by arrows. Keys match case-insensitively. Project apps come first, so they win clashes.
- Terminal stays the default selection. Tiles wrap onto more rows once a row is full. The picker is an overlay, so the panel's height doesn't change.

**Running an app**
- Launchy runs the app in its folder through a login shell, as Scratch's server is started today, so `bun` is on `PATH` (verified: a login shell finds `~/.bun/bin/bun`, version 1.3.14). If the folder has a `package.json` and no `node_modules`, the shell runs `bun install` first. Then `bun run <entry>`. The entry goes in as its own argument, outside the script string, as claude's arguments do.
- It runs in the pane's zmx session, named and labelled like every other pane's, from the pane's own terminal, which stays hidden behind the web view. That is how terminal panes start today, so creating, reconnecting, noticing the end and killing all reuse the pane machinery.
- One server per app pane. Two Scratch panes run two servers.

**Environment**
- Built like a Claude pane's: the minimal terminal environment, with `PATH` rebuilt by the login shell and nothing inherited from Launchy. Then:
  - `PORT`: the port to listen on, on 127.0.0.1.
  - `LAUNCHY_PANE_ID`: the app pane's id, a lowercase UUID.
  - `LAUNCHY_SPLIT_FROM`: the id of the pane the app's pane was split from, the one focused when the app was picked.
  - `LAUNCHY_PROJECT`: the project path, as above.
  - `LAUNCHY_APP_DATA`: a folder for the app's own data, one per app name under Launchy's support folder, created before the app runs and shared by its panes and projects.
- Claude and terminal panes also get `LAUNCHY_PANE_ID`, their own id. The id stays with the pane across `/clear` and `/resume`, as the zmx session name does. Claude panes also get `LAUNCHY_PROJECT`, the same project path an app is given (the git repo holding the pane's folder, else the folder itself), set when the pane starts. That is how Claude finds its scratch area: `$LAUNCHY_PROJECT/.launchy/scratch/$LAUNCHY_PANE_ID/`.

**The app pane**
- It is a web pane on `http://127.0.0.1:<port>/`. Until the server listens it shows the web pane's "Waiting for … to start" page and retries, as it does today for any local address.
- The port is picked free when the pane is made and kept in the pane's saved record (`SessionRecord.appPort`), not its address, which follows navigation. Running the app again reuses that port if it is free; otherwise a new one is picked and the pane loads the app's root there.
- Its label is the page's title, else the app's name.
- When the server exits while the pane is open, the pane shows its hidden terminal, with what the server printed, and says the app exited. Reloading the pane runs the app again. The pane doesn't close by itself, unlike a terminal pane whose shell exits, so a crash on start leaves its output readable.
- A plain split (⌘⇧E, ⌘⇧O) from an app pane makes a blank browser pane, as from any web pane.

**Saving and restoring**
- The pane's record gains two optional fields: the app's folder name, and the id of the pane it was split from. Older saved files have neither and load as before.
- An app pane is restored only if its app can still be found from the pane's folder, project first then user, as a file pane is restored only while its file exists.
- A restored app pane stays dormant until first shown, like every pane. Then it reconnects to its running server if its zmx session is still there, or runs its app again with the same environment.

**zmx, the setting and the launch sweep**
- App servers run in zmx whenever Launchy's zmx binary is present, whatever Keep sessions running says. Without the binary, the app runs directly in the pane's terminal, like a terminal pane without zmx, and ends when Launchy stops: the closed terminal hangs it up (inferred).
- The launch sweep keeps the sessions of restored app panes, whatever the setting, and kills sessions that no restored pane owns, as today. A restored app pane is never swept while it might reconnect.
- Closing an app pane kills its session, as closing a zmx pane does, including a restored pane that was never shown.
- Quit with the setting on leaves app servers running, like the panes. With the setting off, Quit ends them, as it stops Scratch's servers today, and does so before Launchy exits. A Launchy stopped by a signal can't do that, so with the setting off a restored app pane reconnects to the server it left.

**Each pane's Launchy folder**
- What was Scratch's per-pane folder becomes a neutral one, `panes/<pane id>` under Launchy's support folder. It holds the SessionStart hook's file for a Claude pane (ADR 0001). An app pane's port is not kept here but in its saved record (`SessionRecord.appPort`).
- On the first launch after this change, Launchy renames the old `scratch` folder to `panes` and leaves a link under the old name. Claude sessions kept running in zmx from before have the old path in their environment, and their hook keeps writing the conversation file Launchy reads. The same launch deletes the shared files built-in Scratch put at that root (`package.json`, `vite.config.ts`, `deno.lock`, `node_modules`), once; a pane's own folder is never touched. The old Deno servers stop serving pages then, since the Vite they run lived in the deleted `node_modules`. The rename and link can go once no pane from before the change is running.

**Scratch, the app**
- It lives in this repo at `.launchy/custom-apps/scratch/`: the manifest above, a `package.json` with Vite and the React plugin (today's versions), its lockfile, an ignore file for `node_modules`, and a TypeScript entry.
- The entry starts Vite through Vite's JavaScript API rather than through `bunx --bun vite`. The manifest already names one file to run, and the entry has work to do before Vite starts (folders, ignore file, packages, placeholder), so Vite's configuration lives in that file and no separate config file is shared. That Vite runs under Bun is inferred, not run here; the first ticket confirms it.
- Its scratch root is `<project>/.launchy/scratch/`. On start, Scratch makes sure the root has an ignore file that ignores everything (`*`), so the project's own ignore file needs no edit. It also makes sure the root has a `package.json` with React, React DOM and their types, as today's shared root has, and runs `bun install` there when `node_modules` is missing. Page packages therefore live in the project's scratch root, apart from the server's own packages in the app folder, and Claude can add to them without touching the committed app.
- The scratch area is `<root>/<LAUNCHY_SPLIT_FROM>/`, created if missing. Vite serves it as its root, on `PORT`, with React Fast Refresh. Page imports resolve from the scratch root's packages, and Vite may read the scratch root and the app folder. Vite's log goes to `.vite.log` in the area, as today.
- Until the area has an `index.html`, Scratch serves a placeholder naming the area and saying it is waiting for Claude. The page replaces it by itself once `index.html` is written.
- Opened beside something other than a Claude pane, Scratch still works: it serves an area no Claude writes to, and the placeholder says so.

**Scratch and Claude: the skill**
- A project skill in this repo, named for Scratch, replaces the appended system prompt. Its description triggers on wanting to see, visualize, prototype or try out UI, a chart, a diagram or a page.
- Its body says the scratch area is `$LAUNCHY_PROJECT/.launchy/scratch/$LAUNCHY_PANE_ID/`. A pane started before `LAUNCHY_PROJECT` existed has none, so for it the skill says the git top level of the folder the session started in, else that folder. Claude creates the area and the root's ignore file if they are missing, and when it had to create the area it asks the user to open Scratch beside this pane from the split picker. The rest carries over today's guidance: `index.html` loading `./main.tsx`; React 19; keep `main.tsx` to mounting so Fast Refresh keeps state; edit in place; don't start a server; add packages to the scratch root's `package.json` and run `bun install` there; read `.vite.log` only when the user reports a problem.
- A pane's id is `LAUNCHY_PANE_ID`, else the name of the folder holding `LAUNCHY_SESSION_FILE`, which a pane started before `LAUNCHY_PANE_ID` existed still has. With neither, Claude isn't in a Launchy pane, and the skill says Scratch needs one.
- The area sits inside the project, which is Claude's working folder, so Claude needs no `--add-dir`. A Claude pane started in a subfolder of the repo would get a permission prompt for the scratch root (inferred), but Claude panes start in a project root or the default folder.

**What leaves Launchy**
- The Scratch module, the `--add-dir` and `--append-system-prompt` arguments on every Claude pane, the pane that opened by itself when a server started, the orphan pass at launch, and the server stop at Quit. Launchy has nothing named Scratch except the one-time rename above.

**The custom-apps skill**
- A skill named `custom-apps`, kept in this repo's project skills, so every agent working on Launchy has it with no install step. `make install` links it into the user's skills folder, and `make uninstall` removes that link, so agents in other projects find it too. Linking rather than copying keeps one source. That Claude Code follows a linked skill folder is inferred; the hand check below confirms it.
- It is the reference for building an app, the single place the contract is written for app authors. For why the contract is shaped this way it points to ADR 0005, and for the term it points to **Custom app** in `CONTEXT.md`, rather than repeating either. Those pointers have to resolve when the skill is read through the link from another project, not only from inside this repo (a relative path from the linked folder may not, since tools resolve `..` by name: inferred).
- It covers:
  - **What a custom app is** and the contract: where apps are found and which wins a name clash; the manifest's fields, which are required and their defaults; how picker keys are assigned; every environment variable (`PORT`, `LAUNCHY_PANE_ID`, `LAUNCHY_SPLIT_FROM`, `LAUNCHY_PROJECT`, `LAUNCHY_APP_DATA`) and what it holds; how the app is run (login shell, `bun install` when `node_modules` is missing, `bun run` of the entry in the app's folder); one server per pane; running in zmx, and what survives a restart, what closing the pane does, what a crash shows and what reload does; when a pane is restored.
  - **How to make one with Bun:** a minimal example, a manifest and an entry that serves a page on `PORT`, that works as written.
  - **How to test one in Launchy:** where to put it so it shows in the picker with no restart; running the entry by hand with the variables set, outside Launchy; reading the server's output, in the pane after a crash or from its zmx session while it runs; leaving restarts to the user, as `CLAUDE.md` says.
  - **The gotchas,** at least: listen on 127.0.0.1 and exactly `PORT`; `bun` must be on the login shell's `PATH`; `bun install` runs only when `node_modules` is missing, so after adding a package run it by hand; ignore `node_modules` in the app's folder; a manifest with no entry is skipped silently; a clashing key becomes a digit; the server keeps running across reloads, so a change to server code needs the pane closed and the app picked again; a restored pane runs the app again with the same environment, so per-pane state belongs under the pane id; the data folder is shared by every pane and project of the app; the pane it was split from may not be a Claude pane; no sandbox, so the app runs with the user's rights.
- It follows the writing-for-agents rules: a description that front-loads custom apps and names the branches that should reach it (making, changing, debugging an app, a `launchy.json`, a custom-apps folder), steps that end on checkable criteria, and reference grouped by topic.
- **Part of done.** The builder who implements custom apps writes the skill in the same work, from what was built, starting with the first ticket that runs an app, and the reviewer checks it against the code. The ticket that changes a part of the contract updates the matching part of the skill. When the work ships, the skill describes the shipped contract.
- **Builder agent.** The launchy-builder definition gains one pointer: load the `custom-apps` skill when work involves a custom app or the app contract, and update it with any change to the contract. A pointer only, as the repo's rule for agent files asks; the content stays in the skill.

**Docs**
- ADR 0005 records the extension point, the removal of built-in Scratch and the departures from ADRs 0001 and 0004.
- `CONTEXT.md` gains **Custom app**, and **Scratch area** is redefined for the app.
- The coding standards' advice about flags after `--add-dir` goes, since Launchy no longer passes it. The builder updates where-it-breaks with the app pane's zmx rules.

## Testing Decisions

- There is no test target. The pure steps are the seams for first tests once one exists: assigning picker keys from the built-ins and the manifests; merging project and user apps by folder name; finding a folder's project by walking up to a `.git`; and choosing which sessions the launch sweep keeps.
- By hand, after `make build` and a restart, with Keep sessions running on:
  - A throwaway app in `~/.launchy/custom-apps/` with a manifest and a ten-line Bun server shows in the picker without a restart, with its icon, name and key. Editing its manifest's name shows on the next open.
  - Give two apps the same key, and one the key `t`: they get digits, and C, T and B still pick the built-ins.
  - An app with the same folder name in the project and in `~/.launchy` shows once, as the project's.
  - Picking the app shows "Waiting for …", then the page. The server's environment (print it from the app) has every variable above with the right values.
  - An app whose server throws on start: the pane shows the error output, and reload runs it again after a fix.
  - ⌘W on the app pane: its zmx session leaves the listing and the port is free.
  - Restart with an app pane open: the pane comes back on the same server, without a "Waiting for …" page. Delete the app's folder and restart: the pane is gone and its session swept.
  - Turn the setting off. Quit from the menu bar: the app server is gone. Restart with `make run` instead: the restored pane reconnects to it.
  - In this repo, split Scratch from a Claude pane and ask Claude for a page: the skill fires, the page appears in place of the placeholder, edits hot-reload and keep state. Nothing under `.launchy/scratch/` shows in `git status`.
  - Scratch on a fresh clone with no `node_modules` installs both sets of packages and comes up.
  - Two Claude panes in one project, each with its Scratch: separate areas, separate pages.
  - A Claude pane running in zmx from before the change: `/clear` in it still moves the pane to the new conversation after the upgrade.
  - After `make install`, a fresh Claude session in another project lists `custom-apps`. Asked to make a hello app in that project, it builds one from the skill alone that shows in the picker and runs. The skill's pointers to ADR 0005 and `CONTEXT.md` open from there.
  - Every manifest field, variable and rule the skill states matches the code.
  - The two Deno servers running today: they stop serving pages at the first launch after the upgrade; kill them once by hand afterwards (`pkill -f 'deno run -A npm:vite'`) to free their ports, since nothing tracks them any more.

## Out of Scope

- Sandboxing, permissions and any security model for apps. That comes with a marketplace for sharing, selling and installing apps.
- A Launchy API for apps to call: opening panes, reading sessions, sending text to a pane.
- Terminal-UI apps. A terminal pane already runs any command.
- Opening an app's pane by itself when something happens, such as Scratch's page appearing.
- Runtimes other than Bun.
- Re-running `bun install` when a `package.json` changes. Launchy installs only when `node_modules` is missing; after that, the app's author runs it.
- Moving old Scratch pages into projects, or cleaning up the per-pane folders.
- Shipping Scratch to other projects. To have it everywhere, link the app folder into `~/.launchy/custom-apps/` and the skill into `~/.claude/skills/`.
- A settings view for apps, or icons other than SF Symbols.
- Shipping the `custom-apps` skill to anyone but this user, as a plugin or otherwise. That comes with the marketplace.

## Further Notes

- **Why Bun.** The user chose Deno for its security features and is switching to Bun for its developer experience. Scratch already ran Deno with every permission granted, so no protection is lost. Bun 1.3.14 is installed at `~/.bun/bin` and found by a login shell (checked 2026-10-03).
- **Read in the code (main at ca9bf48).** The split picker's three kinds are a fixed list rendered by the picker and driven by the model's picker key handling. Every pane already owns a terminal view, even web and file panes, so an app pane can run its server in its own terminal. The web pane already retries a local address until its server answers. A file pane is dropped at restore when its file is gone, which is the rule app panes copy. Agents merge project and user folders with project names winning, which is the rule apps copy.
- **zmx 0.8.1's help** lists `run` for sending a command to a session without attaching, but labels can only be applied in one step by `attach`, which is why an app pane attaches from its hidden terminal like any other pane.
- After the upgrade, the two `deno run -A npm:vite` servers running today are no longer tracked and stop serving pages at the first launch. They hold their ports until killed by hand, once.
