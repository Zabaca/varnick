# A catalog of apps ships in each release, and a switch copies an app into the user's own

Custom apps (ADR 0005) were useful only to someone who wrote one, and Scratch, the best of them, lived in Varnick's own repository. Varnick now has a **Catalog**: the `apps/` folder of the repository, one ordinary custom app per folder, which `make build` and `make app` copy into the release's resource folder. Settings › Apps lists it with a switch per app, off by default. Turning one on copies the app into `~/.varnick/custom-apps/<name>/` with a marker file saying Varnick put it there, and links its skill into `~/.claude/skills/<name>` when nothing is at that path. Turning it off moves the copy to the Trash and removes the link if it is Varnick's. A newer release refreshes an installed copy at launch, when no pane runs it. The switch's state is the marker on disk, not a saved setting. Once on, an app is one of the user's custom apps, so the picker, the runner and the restore are unchanged. The problem and its options are in `docs/problems/custom-apps-must-be-written-first/`.

Three decisions: the catalog ships in each release, a switch copies an app into the user's apps, and the copy's marker is the switch's state. [ADR 0005](0005-custom-apps-are-local-web-servers.md) stays as written, as a record: the user's own folder was already where apps were found, and the catalog is a way to put an app there.

## Considered Options

- **Fetch the catalog from GitHub at run time** (option 02): rejected. Varnick would make a request of its own each time the section shows, the section would be empty offline, and code merged to main would run as the user before any release carried it.
- **Run catalog apps straight from the bundle** (option 03): rejected. The bundle is read-only and sealed, so packages can't be installed beside an app. A release or a checkout build would replace the folder under servers kept running in zmx, and the loader, restore and runner would each need a case for a third kind of app.
- **List the user's own apps with switches too** (option 04): left for later. It needs a new rule in the loader and restore and a list kept in UserDefaults.
- **A saved list of switched-on apps instead of the marker:** rejected. It would be a second record of what the disk already says, and the two could disagree after a hand deletion.
- **Shipping each app's installed packages in the bundle:** rejected. Notarization rejects unsigned native binaries, and signing them is work for little gain while the packages install at the first pick from a committed lockfile.

## Consequences

- **Only reviewed code reaches a switch.** What a switch installs came in this release through a merged pull request. A new app reaches people with the next release.
- **The installed copy is Varnick's.** A refresh replaces it, and an edit made in it is lost at the next update that changes the app (it goes to the Trash first). To change an app, copy it under another name.
- **Updates can wait.** A copy a pane runs is refreshed at a later launch, and turning an app off is refused while a pane runs it.
- **The npm registry is asked at an app's first pick,** as for any custom app with packages. The privacy doc says so for the first time.
- **A project's app of the same name still hides the installed one** in that project, by ADR 0005's rule.
- **Contributions are pull requests that add a folder to `apps/`,** under the rules in CONTRIBUTING. Whether a sign-off (a DCO line, or a contributor agreement) is asked is decided before the first outside app is merged.
