---
name: custom-apps
description: Custom apps for Varnick, local Bun web servers that open in a pane from the split picker. Use when making, changing or debugging a custom app, writing a `varnick.json`, or working in a `.varnick/custom-apps` folder.
---

# Custom apps

A custom app is a local web server the user writes, in a folder of its own. Varnick lists it in the split picker (⌃⌘⇧E / ⌃⌘⇧O), runs it when picked, and shows it in a web pane. There is no Varnick API to call: everything the app knows comes from its environment. For why it is shaped this way read `adr-0005.md` in this folder; for the term, **Custom app** in `CONTEXT.md` in this folder (both are links into the Varnick repo, whose root is `"$(readlink ~/.claude/skills/custom-apps)/../../.."`).

## Make one

1. Make `<project>/.varnick/custom-apps/<name>/` (this project only) or `~/.varnick/custom-apps/<name>/` (every project).
2. Write `varnick.json` and the entry file below.
3. Run the entry by hand (see Test). Done when `curl` returns the page and the printed variables are the ones you set.
4. Ask the user to open the picker in a Varnick pane. Done when the app's tile is there; no restart is needed.

Minimal app, `varnick.json`:

```json
{ "name": "Hello", "icon": "hand.wave", "key": "h", "entry": "server.ts" }
```

`server.ts`:

```ts
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT),
  fetch: () =>
    new Response(
      `<h1>Hello</h1><pre>${JSON.stringify(
        Object.fromEntries(
          Object.entries(process.env).filter(([k]) => k === "PORT" || k.startsWith("VARNICK_")),
        ),
        null,
        2,
      )}</pre>`,
      { headers: { "content-type": "text/html" } },
    ),
});
console.log(`listening on ${server.url}`);
```

## The contract

**Where apps are found.** The picker reads `<project>/.varnick/custom-apps/` and `~/.varnick/custom-apps/` each time it opens. The project is the git repo (a folder with `.git`, directory or file, so a worktree is its own project) containing the focused pane's folder; outside any repo it is that folder, which has no project apps. A repo at the home folder has none either; its apps are the user's. An app is a subfolder of those. A project app hides a user app with the same folder name.

**The catalog.** Apps that ship with Varnick are in the `apps/` folder of its repository (the public one, Zabaca/varnick), and the user turns each on in Settings › Apps, which copies it into `~/.varnick/custom-apps/<name>/` with a hidden `.varnick-catalog` marker file and links its `skill` folder, if it has one, as `~/.claude/skills/<name>`. An app turned on this way is an ordinary user app: edit nothing in it, since an update replaces it; to change one, copy it under another name. A catalog entry is an ordinary app plus an optional `skill` folder, a `bun.lock` beside any `package.json`, and `description` and `network` in its manifest; the rules are in CONTRIBUTING's "Contributing an app", and `make check-apps` checks what it can.

**Manifest.** `varnick.json` in the app's folder:

| Field | Required | Meaning |
|---|---|---|
| `entry` | yes | File Bun runs, relative to the app's folder |
| `name` | no | Shown in the picker; defaults to the folder name |
| `icon` | no | SF Symbol name; defaults to `puzzlepiece.extension`, also used when the name is no symbol |
| `key` | no | One character that picks the app in the picker |
| `description` | no | One sentence, shown on the app's row in Settings › Apps (catalog apps) |
| `network` | no | What the app fetches or sends, and where to, shown on that row. A catalog app whose only fetch is its packages says so |

`description` and `network` are read only by Settings › Apps; the picker and the runner ignore them, so a user's own app may carry them too.

**Picker order and keys.** Claude, Terminal and Browser, then the project's apps, then the user's, each group sorted by name. Built-ins keep C, T and B. Apps are keyed in that order by their `key`, matched in either case, so project apps win clashes.

**How it runs.** Varnick runs an interactive login shell (`zsh -l -i`, so `~/.zshrc` puts `bun` on `PATH`) in the app's folder, inside the pane's zmx session: `bun install` first if the folder has a `package.json` and no `node_modules` (`bun install --frozen-lockfile` in Varnick's own installed copy of a catalog app, whose `.varnick-catalog` marker names its own folder, so the lockfile decides the versions; a copy you renamed installs plainly), then `bun run <entry>`. One server per app pane; two panes of an app run two servers. Varnick passes a minimal environment, nothing inherited from itself: the base set (`TERM`, `COLORTERM`, `LANG`, `HOME`, `USER`, `LOGNAME`, `ZMX_*`) and these, to which the login shell adds whatever `~/.zprofile` and `~/.zshrc` export (tokens included, so don't dump `process.env` into a page):

| Variable | Holds |
|---|---|
| `PORT` | The port to listen on, at 127.0.0.1 |
| `VARNICK_PANE_ID` | The app pane's id, a lowercase UUID |
| `VARNICK_SPLIT_FROM` | The id of the pane that was focused when the app was picked, the one the app's pane was split from |
| `VARNICK_PROJECT` | The project path, as above |
| `VARNICK_APP_DATA` | A folder for the app's own data, made before the app runs, under `~/Library/Application Support/Varnick/app-data/`: `user/<folder name>` for a user app, `<repo folder>-<hash of the repo path>/<folder name>` for a project app |

Claude and terminal panes get `VARNICK_PANE_ID` too, their own id, which stays with the pane across `/clear` and `/resume`, and Claude panes also get `VARNICK_PROJECT`, the same project path an app is given for that pane's folder. Both reach Claude's Bash tool. An app serving a Claude pane's files finds them under `VARNICK_PROJECT` by that pane's id, which `VARNICK_SPLIT_FROM` gives it. A Claude pane started before a Varnick build that sets `VARNICK_PROJECT` has no such variable until it restarts, and one older still has no `VARNICK_PANE_ID`: its id is the name of the folder holding its `VARNICK_SESSION_FILE`. Scratch's layout is in its skill, which is linked as `~/.claude/skills/scratch` while Scratch is on in Settings › Apps (its source is `apps/scratch/skill/SKILL.md` in the Varnick repo).

**The pane.** A web pane on `http://127.0.0.1:$PORT/`. Until the server listens it shows "Waiting for … to start" and retries. Its label is the page's title, else the app's `name`. The port is chosen when the pane opens and kept with the pane, so it is the same after a restart if nothing else holds it.

**Lifetime.** The server runs in zmx whatever Keep sessions running says. Closing the pane (⌘W or ×) kills the server, also for a pane restored after a restart and not yet shown. If the server exits while the pane is open, the pane shows what it printed and says it exited; reload (⌘R) runs the app again on the same port if that is free, else on a new one. Quitting Varnick from its menu stops every app server when Keep sessions running is off and leaves them running when it is on. Varnick stopped by a signal (`make run`) leaves them running either way.

**Restore.** App panes are saved with the others and come back after a restart, but only if the app can still be found from the pane's folder (project first, then user): delete the app and its pane is gone and its server killed. A restored pane waits until first shown. Then, if its zmx session is still running, it reconnects to that server and keeps its port. Otherwise it runs the app again with the same `VARNICK_PANE_ID`, `VARNICK_SPLIT_FROM` and, if it is free, `PORT`; if the port is taken it takes a new one and loads the app's root there.

## Test

- **Outside Varnick.** From the app's folder, with a clean environment like Varnick's and the variables set: `env -i HOME="$HOME" PATH="$PATH" PORT=47321 VARNICK_PANE_ID=test VARNICK_SPLIT_FROM=test VARNICK_PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" VARNICK_APP_DATA="$(mktemp -d)" bun run server.ts`, in the background on a free port (change 47321 if it is taken), then `curl http://127.0.0.1:47321/` and kill the server. `VARNICK_PROJECT` is the project's root, not the app's folder; an app that serves a Claude pane's files needs `VARNICK_SPLIT_FROM` set to that pane's id. Make a demo app in a temp folder, not in the user's real `~/.varnick/custom-apps`: every Varnick picker lists that folder.
- **In Varnick.** The picker re-reads disk each time it opens, so a new app or an edited manifest shows on the next open. Pick the app and check the page.
- **Output.** After a crash the pane shows it. While running, everything the server printed is in `~/Library/Application Support/Varnick/app-logs/<app pane id>.log`, one file per app pane, emptied when the server starts and deleted when the pane closes: `ls -t` that folder, and the newest is usually the app just picked. The file's name is the pane id; `zmx list` also shows the app's session, `varnick-<pane id>`, on the row whose cmd contains `varnick-app`. To read that session with Varnick's zmx, use the app's pane id, not yours: `ZMX_DIR=/tmp/zmx-$(id -u) "$(readlink ~/.claude/skills/custom-apps)/../../../.build/release/zmx" history varnick-<pane id>` (the path needs `make install`'s link; inside the Varnick repo use `.build/release/zmx`).
- **Restarts** end every Claude session open in Varnick, possibly yours. Leave them to the user; none is needed to test an app.

## Gotchas

- Listen on `127.0.0.1` and exactly `PORT`.
- A folder with no readable `varnick.json`, or with no `entry`, is skipped silently.
- A `key` that is taken or is not one character becomes the first free digit 1 to 9; past nine the app has no key and is reached by arrows.
- `bun` must be on the `PATH` an interactive login shell builds (`~/.zshrc` counts); otherwise the pane shows the shell's error.
- `bun install` runs only when `node_modules` is missing. After adding a package, run it by hand.
- Ignore `node_modules` in the app's folder (an app in a project's repo commits its own `.gitignore`).
- A server keeps running across pane reloads, so a change to server code needs the pane closed and the app picked again.
- The pane it was split from may not be a Claude pane.
- The data folder is shared by every pane of the app in that project (or by every pane of a user app, in every project); per-pane state belongs on disk in `$VARNICK_APP_DATA/$VARNICK_PANE_ID/` (nothing removes it when the pane closes), since a restart either keeps the old process or runs the app again, and memory survives only the first.
- No sandbox: an app runs with the user's rights, and picking one runs its code. A cloned repo's apps appear in the picker.
- Listing runs nothing; Varnick only reads manifests.
- A Vite server started from the entry through `createServer` works under Bun, but give it real paths (`realpathSync`) for `root`, `cacheDir` and `fs.allow`: `VARNICK_PROJECT` can go through a link (`/tmp`, `/var`), Vite resolves modules to real paths, and a link in `fs.allow` leaves the page blank. Working example: the catalog's Scratch, `apps/scratch/server.ts` in the public Varnick repository (github.com/Zabaca/varnick), or `~/.varnick/custom-apps/scratch/server.ts` while Scratch is on in Settings › Apps.
