---
problem: custom-apps-must-be-written-first
title: A catalog of apps in the repo, shipped in each release, that a switch in Settings › Apps copies into the user's own apps
summary: Accepted by the user on 2026-10-10 (the contributor sign-off question stays open). A top-level `apps/` folder in this repo holds the catalog, one ordinary custom app per folder, with an optional skill and a one-line description; Scratch moves there, with its skill, and leaves this repo's project apps. `make build` and `make app` copy the catalog into Varnick's resource folder, so a person can turn on only reviewed code from their own release, and nothing is fetched to find apps. Settings › Apps lists it with one switch per app, off by default. On copies the app into `~/.varnick/custom-apps/<name>/` with a marker saying Varnick put it there, and links its skill into `~/.claude/skills/` when that name is free. Off moves only that copy to the Trash and removes only that link. A newer release refreshes an installed app at launch when no pane runs it. A user's own app of the same name is never touched. Packages install with Bun at the first pick, as for any custom app, from the committed lockfile. Contributions are pull requests that add a folder, accepted under rules in CONTRIBUTING. Rough effort is four days, plus under an hour of the user's time for the hand test.
status: shipped
---

## Solution

The catalog is a folder of this repository, `apps/`, with one folder per app. Each entry is an ordinary custom app (a `varnick.json` and its entry file, with a `package.json` and `bun.lock` if it has packages), plus an optional skill and a one-line description. Scratch moves there from this repo's project apps, with its skill.

The catalog ships inside each build. `make build` copies it into the build folder, as it copies the Phone page, and `make app` copies it into Varnick.app. Varnick reads it from its resource folder, so the app and a checkout build share one path. A person can turn on only what was reviewed and released with the Varnick they run, and nothing is fetched to list apps or to turn one on.

**Settings › Apps** is a new section with one row per catalog app: its icon, name and description, what it fetches, and a switch, off by default.

- **On** copies the app into the user's apps, `~/.varnick/custom-apps/<name>/`, with a marker file saying Varnick put it there. It shows in the split picker in every project, like any app the user made. If the app has a skill, Varnick links it into `~/.claude/skills/<name>`, by the same rule as the `custom-apps` skill's link: only when nothing is there.
- **Off** removes only what Varnick installed. The copy goes to the Trash, and the link is removed only if it is Varnick's link to that copy.
- **A newer release** refreshes an installed app at launch, when no pane runs it.
- **A user's own app of the same name** is never overwritten, and the switch says why it can't turn on.

Once on, the app is an ordinary user app: no special case in the picker, the runner or the restore. Its packages install the way every custom app's do today, with Bun at the first pick, from the lockfile committed beside it.

Contributions are pull requests that add a folder to `apps/`. CONTRIBUTING gains the rules an app must meet to be accepted, and an accepted app ships in the next release.

## Trade-offs

- **Reviewed code only.** What a switch installs came in this release, through a merged pull request. The cost is that a new app reaches people only with a release.
- **Nothing new leaves the Mac to find or install apps.** Packages still come from the npm registry at an app's first pick, as they do today for any custom app with packages. The privacy doc says so for the first time.
- **No new runtime path.** An installed catalog app is a user app, so the picker, the runner, restore, ports and logs are unchanged. The new code is the copy, the link, the refresh and one Settings section.
- **The installed copy is Varnick's.** A refresh replaces it, so an edit made in it is lost at the next update that changes the app. It goes to the Trash, not away. To change a catalog app, copy it under another name, which makes it the user's own. The row and the guide say so.
- **Updates can wait.** An app whose pane stays open (kept running in zmx) isn't refreshed until a launch where no pane runs it.
- **A project's app of the same name still hides it** in that project, by the existing rule. Settings can't see every project, so the guide says it.
- **First pick needs the network** for an app with packages. Offline, the pane shows Bun's error, and reload tries again, as today.

## User Stories

1. As a person who downloaded Varnick, I want to find apps I can turn on in Settings, so that I learn what custom apps are without writing one.
2. As that person, I want each app's row to say what it does and what it fetches, so that I know before I turn it on.
3. As that person, I want to turn Scratch on with one switch, and see it in the split picker in every project.
4. As that person, I want Claude in any project to know how to show me a page in Scratch once it is on, so that I don't have to explain it.
5. As that person, I want turning an app off to remove only what Varnick installed, and to put it in the Trash, so that nothing of mine is lost.
6. As a person with an app of my own called `scratch`, I want Varnick to leave it alone and tell me why Scratch can't turn on.
7. As a person with a skill of my own of the same name, I want Varnick to leave it alone, and still install the app.
8. As a person with Scratch on, I want the next release to bring Scratch's newer version by itself, without breaking a Scratch pane I have open.
9. As a person, I want a catalog app to run only reviewed code from the release I installed, with nothing downloaded to find it.
10. As a person who wants a different version of a catalog app, I want to copy it under another name and change it freely.
11. As a contributor, I want written rules for an app to be accepted, so that I know what review looks for before I open a pull request.
12. As a maintainer, I want a check that catches a broken catalog entry before a release is made.
13. As the user, I want Scratch to stay an ordinary custom app, and this repo to use it through the same switch as everyone else.

## Implementation Decisions

**The catalog**
- **A top-level `apps/` folder,** with one folder per app. The folder's name is the app's identity: the installed folder, the skill link and a restored pane all go by it. Names use lowercase letters, digits and dashes.
- **Each entry is an ordinary custom app.** If it has packages, it has a `package.json` and a committed `bun.lock`, and no `node_modules`. An optional `skill` folder holds a skill named as the app.
- **The manifest gains two optional fields,** read only by Settings › Apps:
  - `description`, one sentence;
  - `network`, what the app fetches or sends and where to, shown on the row. An app whose only fetch is its packages says so.

  The loader already ignores fields it doesn't know (verified: it reads only `entry`, `name`, `icon` and `key`), so a user's app may carry them too. The `custom-apps` skill's manifest table lists them.
- **`make check-apps`** checks every entry offline:
  - the manifest parses and names an entry file that exists;
  - the folder's name follows the rule;
  - a `bun.lock` sits beside any `package.json`, and no `node_modules` is tracked;
  - no `trustedDependencies`, so packages' install scripts stay off;
  - a `skill` folder holds a `SKILL.md` whose name is the app's;
  - no manifest key is C, T or B, or another entry's.

  `make app`'s guard runs it, so a release never ships a broken entry. The lockfile's sync with `package.json` needs the network to check (`bun install --frozen-lockfile`), so it is part of review, not of the build.

**Shipping**
- **`make build`** copies `apps/` into the build folder beside the Phone page's copy, the same way: an `rsync` with `--delete` that leaves out `node_modules` and `.DS_Store`.
- **`make app-bundle`** copies it into the bundle's Resources the same way.
- **Varnick reads the catalog from its resource folder** in both cases, so the app and a checkout build take one path. A checkout build's catalog is its last `make build`'s.
- **Never `node_modules` in the bundle.** Notarization would meet unsigned native binaries (Scratch's packages hold three). The bundle's signature seals the copied files, as it does the Phone page's.

**The switch's state**
- **Read from disk, not saved.** An app is on when `~/.varnick/custom-apps/<name>/` exists and holds Varnick's marker naming that catalog entry. There is no UserDefaults key and no field in the sessions file.
- **The marker** is a hidden file in the installed folder. It holds the entry's name and a digest of the entry's files as shipped. The picker reads only `varnick.json`, and Bun ignores the marker.
- **The section reads the folders each time it shows,** as Open at login reads its status (`OpenAtLoginRow`).

**Turning an app on**
1. **A folder of that name without the marker** is the user's own app. The switch stays off, and the row says a custom app of theirs has that name. Varnick never writes into it.
2. **Copy** the entry into a hidden folder in `~/.varnick/custom-apps/`, which the picker skips (verified: hidden names are skipped), and write the marker. Then rename it into place, refusing if the name appeared meanwhile.
3. **Link the skill** at `~/.claude/skills/<name>` to the installed copy's `skill` folder, only when nothing is at that path (a dangling link counts as something). If something else is there, the app is still on, and the row says the skill wasn't linked and why.
4. **Fetch nothing.** The first pick installs packages, through the runner every app uses. Turning on is instant and works offline.

**Turning an app off**
- **Refused while a pane runs it.** Any open pane whose app has that folder name counts, a project app of the same name included, which errs on the safe side. The row says to close its panes first. A server whose folder is gone would break on its next file read, since Vite reads some of its files on request (inferred).
- **The link is removed** only if it is a link to the installed copy's `skill` folder.
- **The folder goes to the Trash.** Varnick never deletes an app folder; it moves it to the Trash. That is one rule for off and refresh, and an edit made in the copy is recoverable.
- **The app's data folder is kept,** so turning it on again finds its data. The guide says where the data lives.

**Refreshing an installed app**
- **At launch,** after the saved tabs are restored, and off the main thread: each installed copy whose marker's digest differs from its catalog entry's.
- **When no restored pane runs it,** a new copy is made in a hidden folder. If the lockfile's bytes are unchanged, the old copy's `node_modules` moves across, so nothing is fetched again. Then the old copy goes to the Trash, and the new one is renamed into place.
- **When a pane runs it,** the row says the update waits for its panes to close, and the next launch tries again.
- **An app no longer in the catalog** stays installed, and the section still shows it, with its switch, so that it can be turned off. Varnick removes nothing behind the user's back.

**Settings › Apps**
- **A section after Claude,** with the symbol custom apps default to.
- **One row per catalog app,** built like Open at login's row: the app's icon and name, its description, its `network` line, and the switch, with any refusal or failure in orange.
- **The section says:**
  - these apps come from Varnick's catalog, reviewed in its repository and shipped with this release;
  - once on, an app is one of the user's custom apps, shown in the split picker in every project;
  - it runs with the user's rights, and its panes have Varnick's macOS permissions;
  - it needs Bun.
- **A last line** says how to make an app of one's own (ask Claude in a session to make a custom app), with a button that shows the user's apps folder in Finder.
- Settings is fixed-size and scrolls, so the panel's height doesn't change.

**Dependencies**
- **Installed with Bun at the first pick,** by the runner every app uses, into the installed copy's folder. A lockfile in step with `package.json` gives the reviewed versions, each checked against the lockfile's integrity hash (Bun's documented behaviour, not run here). Review makes sure the two are in step.
- **Offline,** the first pick fails in the pane with Bun's message, and reload tries again, as for any app today. Once installed, the app runs offline, except that Scratch's first start in each project fetches its page packages.
- **Scratch's page packages get exact versions** in the `package.json` it writes for each project, instead of caret ranges, so that fetch is pinned too.
- **The npm registry request is a privacy item** (Docs, below). It goes to the registry Bun is set to use, which is the npm registry unless the user changed it.
- **Vendoring is not chosen.** Shipping the installed packages in the bundle would mean:
  - signing the native binaries with the Developer ID, the runtime and the timestamp, since notarization rejects unsigned code;
  - finding out whether Bun can load addons signed by another team (unknown);
  - about 35 MB per app in every download;

  and Scratch would still fetch its page packages in each project.

**Moving this repo's Scratch**
- **Scratch and its skill move into the catalog,** and this repo's project app and project skill go. This repo then uses Scratch through the switch like everyone else, and there is one copy of each file.
- **The skill works from any project.**
  - It says Scratch is a catalog app turned on in Settings › Apps, and names no path in this repo.
  - Step 4 names Scratch in the picker, with S or the key the picker shows.
  - Nothing else in it depends on this repo: the pane id, the project and the scratch area come from the environment.
- **The `custom-apps` skill's two Scratch pointers** stop being paths into a checkout:
  - Scratch's layout points at its skill, linked as `~/.claude/skills/scratch` while Scratch is on;
  - the working example points at the catalog's Scratch in the public repository, and at the installed copy while Scratch is on.
- **The comment at the top of Scratch's server** names its skill's new place.
- **The pre-rename build is unaffected.** It reads only the old folder names, which main no longer has (verified). Moving Scratch changes nothing for it.
- **At the cutover,** if this has merged, the check that a custom app opens starts by turning Scratch on in Settings › Apps.
- **A Scratch pane open across the restart that brings this in** closes once: its app is gone until the switch is on. Its page stays on disk in the project, under the Claude pane's id (verified: the area is named by the pane it was split from). So turning Scratch on and splitting from the same Claude pane shows the same page.

**Names and precedence**
- **A project's app** with a catalog app's name hides the installed copy in that project. This is the existing rule, unchanged; the guide says it.
- **A user's own folder** of that name blocks the switch (above).
- **A skill path already taken** leaves the app on and the skill unlinked (above).
- **Picker keys** follow the existing rule. `make check-apps` keeps the catalog's keys apart from the built-ins' and from each other.

**Contributing an app** (a new CONTRIBUTING section)
- **A pull request that adds one folder** to `apps/`. It ships in the next release after it merges.
- **The rules an app must meet:**
  - it is an ordinary custom app, and passes `make check-apps`;
  - it listens on 127.0.0.1 and exactly `PORT`, and opens no other listening socket;
  - its packages are pinned by a committed `bun.lock` that `bun install --frozen-lockfile` accepts, and anything it installs at run time takes exact versions;
  - its packages' install scripts stay off;
  - it declares every network use in `network`, sends no telemetry, and loads no code from the network at run time;
  - it uses no macOS permission (screen, accessibility, microphone, camera), since its pane would get Varnick's grants;
  - it reads and writes only its data folder and what its purpose needs in the project;
  - it carries no secrets or personal data, and nothing on the public-repo list;
  - it ships under the repository's licence, FSL-1.1-ALv2, and its packages' licences allow that use;
  - its skill, if any, is named as the app and follows the repository's rules for writing skills.
- **Review** reads every file and the lockfile's diff, and runs the app outside Varnick, as the `custom-apps` skill's Test says.

**Code**
- **One new type for the catalog's file work,** Foundation and CryptoKit only. It lists entries, installs, removes and refreshes. It takes every place as a parameter: the catalog folder, the user's apps folder, the skills folder, the Trash as a closure, and the app names that open panes run. A harness then compiles it alone, as it does the installed app's start pieces (`InstalledApp.linkSkill`, Move to Applications' `Places`).
- **The Settings section** and the launch refresh call it. The launch refresh runs after the delegate exists, so after the rename's migration and the account lock.

**What it can break** (where-it-breaks)
- **App panes.** A restored pane finds its app by folder name, so an installed copy must never be missing or half-written under a pane that runs it. That is why staging is hidden, the rename is the last step, and off and refresh wait for panes to close.
- **Signing.** The bundle must hold no `node_modules`. The copy must leave out `.DS_Store`, as the bundle's other copies do.
- **The installed app.** The skill link follows the `custom-apps` link's rules, and nothing on the start's early path may touch the catalog.
- **Checking by hand.** A temporary `HOME` doesn't move everything, so the harness passes every folder in and never touches the real `~/.varnick/custom-apps`, `~/.claude/skills` or Trash.
- **Saved state:** none. No new saved field and no UserDefaults key.

**Docs**

With the code, on the branch:
- **The guide** gains a Custom apps section for both kinds:
  - the catalog and its switches;
  - making one's own by asking Claude;
  - where apps live, and the project-over-user rule;
  - that an installed copy is Varnick's, and how to change it;
  - where app data lives;
  - Bun;
  - that apps run with the user's rights and Varnick's macOS permissions.

  The Requirements line on Bun points to it.
- **The README** names the catalog in one line.
- **CONTRIBUTING** gains "Contributing an app" (above).
- **Privacy and security:**
  - under What leaves your Mac, the npm registry through custom apps: what is fetched and when (a catalog app's first pick; Scratch's first use in each project; any app of the user's with packages), and that the registry sees the package names and the Mac's address;
  - under What can act as you, custom apps run as you, with Varnick's permissions, and catalog apps are reviewed but not sandboxed;
  - under Downloads are pinned and checked, the catalog's lockfiles.
- **CONTEXT.md** gains **Catalog**: the custom apps that ship with Varnick, reviewed in its repository, which the user turns on one by one in Settings › Apps; a catalog app, once on, is one of the user's custom apps. _Avoid_: marketplace, store, built-in app. **Custom app** becomes one the user builds or turns on from the Catalog.
- **A new ADR** once accepted records three decisions: the catalog ships in each release, a switch copies an app into the user's apps, and the copy's marker is the switch's state. It links ADR 0005, which stays as written, as a record.
- **where-it-breaks** gains a Catalog apps entry with the rules above, and the Signing entry notes the catalog copy.
- **The `custom-apps` skill** gains the two manifest fields, a line on the catalog under where apps are found, and the new Scratch pointers.

## Testing Decisions

- **`make build`** finishes clean and leaves the catalog in the build folder without `node_modules`, with a made-up `node_modules` folder in the working tree's Scratch to prove the exclusion.
- **`make check-apps`** passes on the catalog, and fails with one line each on made-up broken entries in a temporary copy: no entry, a missing `bun.lock`, a tracked `node_modules`, a bad name, `trustedDependencies`, a clashing key.
- **The bundle,** where the signing identity is usable: `make app-bundle CHECK_BUILD=1` on a committed branch holds the catalog in Resources without `node_modules`, and `codesign --verify --deep --strict` passes. It sends nothing to the notary service.
- **A throwaway harness** compiles the catalog type alone with `swiftc`, against temporary folders, with the Trash as a closure that moves into a temporary folder. It covers:
  - on into an empty folder, with the skill linked;
  - on refused by a user's folder of that name, which is left byte for byte;
  - on with the skill path taken by a folder, and by a dangling link: the app on, the path untouched;
  - off removing only a marked folder and only Varnick's own link;
  - off refused while a pane runs the app;
  - refresh doing nothing for an unchanged digest;
  - refresh replacing a changed entry, and carrying `node_modules` across only when the lockfile is unchanged;
  - refresh waiting while a pane runs the app;
  - a leftover hidden staging folder not listed by the picker's loader, and cleared at the next on;
  - an installed app no longer in the catalog left in place.

  The harness never runs the app binary and never touches the real `~/.varnick`, `~/.claude/skills` or Trash.
- **Scratch outside Varnick,** by the `custom-apps` skill's Test, from a temporary copy of the catalog entry and a temporary project: `bun install`, the server answers `curl`, and the pages' `package.json` it writes has exact versions. This needs the network.
- **By hand, by the user, after a restart:**
  - Settings › Apps shows Scratch off;
  - on: Scratch is in the picker in another repo, and Claude there, in a session started afterwards, shows a page;
  - off while its pane is open is refused, and off after closing it puts the copy in the Trash and removes the link;
  - a user folder named like a catalog app blocks the switch;
  - turning on and picking with the network off shows Bun's error in the pane, and reload with the network back runs it.

  About an hour.
- **Effort:**
  - the catalog type and its harness, a day and a half;
  - Settings › Apps, most of a day;
  - the Makefile copies and `check-apps`, half a day;
  - moving Scratch and the two skills, half a day;
  - the docs, a day.

  Four days in all.

## Out of Scope

- **Fetching the catalog at run time** (option 02), and **listing the user's own apps with switches** (option 04).
- **Headless hosts and peers.** A headless host shows no panes, and a catalog app is a pane on the Mac that shows it. Each Mac has its own switches. A Scratch pane beside a session that runs on another Mac serves this Mac's folder, so it doesn't show that session's page. That is true today and unchanged (inferred from Scratch's server, which serves a folder on its own Mac).
- **Enforcing the acceptance rules in code,** a sandbox, or declared permissions. The rules are kept by review.
- **Installing packages at switch-on,** with progress shown in Settings (Further Notes).
- **Freezing the app runner's install to the lockfile for every app.** That would change the contract for the user's own apps.
- **varnick.com's copy,** a follow-up once a release carries the catalog.
- **A second catalog app.**
- **The `.launchy` leftovers in checkouts,** which are the rename's cutover steps.

## Further Notes

**Why this option.** It is the smallest change that gives every person Scratch and a reviewed path for more apps. Turning an app on makes it an ordinary user app, so the runner, the picker and restore stay as they are, and Scratch stays an example, not a built-in. Shipping in the release keeps code that runs as the user to what was reviewed and notarized alongside Varnick. It adds no network request of Varnick's own.

**Weighed inside this option**
- **Packages installed at switch-on rather than at first pick.** This would show progress and failures in Settings, and leave the first pick instant. But Varnick would run Bun through the login shell outside a pane. App panes run it inside a pty, where the shell's startup files are known to behave; outside one, they may not (inferred). It would also make a network request when the user only flipped a switch. It can be added later without changing anything else here.
- **A UserDefaults list of switched-on apps instead of the marker.** That would be a second record of a fact the disk already holds, and the two could disagree after a hand deletion. Reading the disk follows how apps and agents are found (ADR 0002, ADR 0005).
- **A separate repository for the catalog.** One repository keeps the review, the licence and the release in one place. A separate one would only help a catalog that ships apart from Varnick, which is option 02.
- **Running catalog apps straight from the bundle,** option 03.

**Open questions, each with a recommendation**
1. **A sign-off for contributions** (a DCO line, or a contributor agreement). The repository has no rule for any outside contribution today (verified in CONTRIBUTING). The recommendation is to decide before the first outside app is merged, not as part of this option.
2. **The section's place.** Recommended: after Claude, named Apps, with the custom apps' default symbol.
3. **An app dropped from the catalog.** Recommended: it stays installed and listed, with its switch, until the user turns it off (above).
4. **Exact versions for Scratch's page packages.** Recommended: yes, the React versions current when Scratch moves, since the acceptance rules ask the same of every app.
