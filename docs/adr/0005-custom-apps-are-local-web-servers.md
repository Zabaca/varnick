# Custom apps are local web servers found on disk, and Scratch is one

A pane can now hold a custom app: a folder with a `launchy.json` manifest and a Bun entry file, in the project's `.launchy/custom-apps/` or the user's `~/.launchy/custom-apps/`. Launchy reads both each time the split picker opens, as it reads agents (ADR 0002), with the project's app hiding the user's of the same name. Picking one runs `bun run <entry>` in the pane's zmx session with `PORT` and `LAUNCHY_` variables, and shows the server in a web pane. Apps get no Launchy API and no sandbox: they run with the user's rights, and security waits for a marketplace that lets people share and install apps. Scratch, built into Launchy until now, moves out as the first app. It is rewritten from Deno to Bun, serves a scratch area inside the project, and is explained to Claude by a project skill. We chose this so that a pane tool no longer needs Launchy changed, and so that Claude sessions stop carrying a tool most of them never use. The problem and its options are in `docs/problems/pane-kinds-are-built-in/`.

## Considered Options

- **Keep Scratch built in, on Bun**: rejected. It fixes the runtime and nothing else: Launchy still owns one tool's process handling, every Claude session still carries its prompt, and the next tool still needs Launchy changed.
- **A manifest that adds directories and system-prompt text to every Claude pane in a project**: rejected. Sessions that never use the tool still pay for it, and Launchy would build claude's command line from project files. A skill gives the same guidance on demand.
- **Apps that can also be terminal commands**: rejected. A terminal pane already runs any command, and a second app shape doubles the contract.
- **Apps from the project only**: rejected. Tools wanted everywhere would be copied into every repo, unlike agents.

## Consequences

- The contract is written for app authors in one place, the `custom-apps` skill in this repo, which `make install` links into the user's skills so agents in any project find it. It changes with the contract.
- The manifest is a Launchy format of its own. ADR 0002 avoided one for agents because Claude Code already defines them; nothing defines an app.
- Scratch is no longer in every session: only in projects that contain it, or for users who put it in `~/.launchy/custom-apps/`. Writing `index.html` no longer opens a pane by itself; the user opens Scratch from the split picker.
- Bun is needed to run apps, not to run Launchy. Deno's permissions were never in use, since Scratch ran with `-A`.
- App servers run in zmx whatever Keep sessions running says, departing from ADR 0004's setting, which waits on how a reattached screen renders; a server has no screen. The launch sweep keeps restored app panes' sessions. With the setting off, Quit ends app servers.
- The SessionStart hook's file (ADR 0001) moves from the scratch area to a neutral per-pane folder of Launchy's. The old folder is renamed and linked once, so Claude panes still running from before keep reporting conversation changes.
- Claude and terminal panes get `LAUNCHY_PANE_ID`, and Claude panes `LAUNCHY_PROJECT`, the project path an app is given: together they are how Claude finds its scratch area.
- Launchy drops `--add-dir` and `--append-system-prompt` from every Claude pane, and Scratch's port, pid and orphan handling.
