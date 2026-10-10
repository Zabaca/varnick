---
problem: custom-apps-must-be-written-first
title: Run catalog apps straight from Varnick's resource folder, without copying them
summary: Not recommended. The catalog ships in the release as in option 01, but a switch only records the app's name in Settings. The picker gains a third source, the switched-on catalog apps, run from Varnick's own resource folder. There is no copy to keep in step and no refresh. But the bundle is read-only and sealed, so packages can't be installed beside the app, and Bun finds packages from the entry file's folder upwards. A release replaces the folder under servers kept running in zmx, and so does every checkout build. The loader, restore and the app runner each get a case for a third kind of app, against the user's wish that Scratch be an ordinary custom app. Rough effort is five days.
status: proposed
---

## Solution

`apps/` ships in the build and the bundle, as in option 01. Settings › Apps has the same switches, but on stores the app's name in a list in UserDefaults and copies nothing. The picker lists the project's apps, then the user's, then the switched-on catalog apps, each hiding the next by folder name. A catalog app runs from the resource folder. Its packages go to a folder of Varnick's own under Application Support, since the bundle can't be written.

## Trade-offs

- **No copy to keep in step.** A new release is the new version, with nothing to refresh.
- **Packages can't sit beside the app.** The bundle is sealed by its signature, and in Applications a standard account can't write to it. Bun resolves packages from the entry file's folder upwards, so packages installed elsewhere aren't found without a module path setting. Whether Bun honours one is not checked here. Failing that, the app's files are copied next to its packages, which is option 01 with more steps.
- **A release replaces the folder under running servers.** App servers outlive Varnick in zmx, and an update replaces Varnick.app while they run. A checkout build replaces its build folder's copy at every `make build`, and so at every Upgrade.
- **A third kind of app.** The loader, restore, the app runner's folder and the data folder's owner each gain a case, and the `custom-apps` contract a third place. Scratch becomes a special kind, not an ordinary user app.
- **A new UserDefaults key** that can disagree with what the user sees.
- **A user can't copy and change it in place,** which is clearer: the catalog's copy is never theirs.

## User Stories

1. As a person, I want a catalog app to be exactly the version of the Varnick I run, with nothing to update.

## Implementation Decisions

- **The switch:** a list of app names in UserDefaults, with a Settings property and a row per app.
- **The loader:** a third source after the user's apps, read from the resource folder and filtered by that list.
- **Packages:** installed into a per-app folder under Application Support. The runner points Bun at it, or copies the app's files beside it.
- **Skills:** linked into the bundle's copy, relinked when the app moves, as the `custom-apps` skill's link is.

## Testing Decisions

- As option 01's harness, plus the loader's three sources and the runner's module path, and a hand test of a Scratch pane kept running across an update of the app.
- **Rough effort,** about five days, most of it in the runner and the update case.

## Out of Scope

- As option 01.

## Further Notes

The option's one gain, no copy, is undone by the packages, which need a writable folder beside the app's files. Option 01's copy is that folder.
