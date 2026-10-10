---
problem: name-taken-by-another-launcher
title: Rename everything on one branch, and migrate each Mac with a script run by hand, so that the app never knows the old names
summary: The same measurement, rename, protocol bump, docs, GitHub renames, Ryzen cutover, going public and cleanup as option 01. The difference is where each Mac's data is moved. Instead of a first-launch migration inside Varnick, a one-time script is run by hand from a terminal with Launchy stopped. It ends the old zmx sessions, exports and imports the settings domain with the one key renamed, moves the support folder, copies the web data, checkpoints and renames the database, removes the old LaunchAgent and binary, then runs make install. Varnick's code holds only the new names. A guard in make run and make install refuses to start Varnick while the old settings domain exists and the new one doesn't, so it can't come up with an empty identity. Option 01's build guard and the Linux installer's guard stay.
status: proposed
---

## Solution

Everything in option 01, except its first-launch migration and its stop, restart and install guards. In their place:

- **A migration script.** It is committed, run once per Mac from Terminal.app with Launchy stopped, and removed by the cleanup ticket. In order, it:
  1. refuses if a Launchy or Varnick process is running;
  2. lists zmx sessions with the checkout's zmx and ends every old-named one (the panes', the page's, the upgrade's and the installs'), confirming from a listing that came back;
  3. exports `com.zabaca.launchy` and imports it as `com.zabaca.varnick`, renaming `heyLaunchy`, only when the new domain is empty;
  4. renames the support folder, then removes the moved relay link, the stale socket and the old `scratch` link;
  5. copies WebKit's folder to the new id's;
  6. checkpoints the database's WAL with `sqlite3` and renames the file;
  7. boots out the old LaunchAgent, removes its plist, and removes Launchy's binary and good copy;
  8. prints the grants, keys and checks still to do, as option 01's runbook lists them.
- **The app** drops its existing settings migration (the executable-named domain) and gains nothing in its place.
- **A start guard.** `make run` and `make install` refuse while the old domain exists and the new one doesn't, and point to the script.
- **Kept from option 01:** the build guard, so Upgrade can't cross, and the Linux installer's guard.

## Trade-offs

- **Varnick's code holds no old name.** Only the script and three Makefile guards do, and the cleanup removes them all. In option 01, the app's entry point carries the migration until cleanup.
- **The steps are visible and can be dry-run:** the script can print what it would do before doing it.
- **The order depends on the user running the script first.** The start guard catches `make run` and `make install`. It doesn't catch a binary started any other way, or a peer's Restart: that runs the restart script, which the guard doesn't cover, though the build guard leaves no new build to restart into.
  - A Varnick started on an empty domain gets a new identity. Its relay, once its link exists, answers `unlisted`, so paired Macs drop it until the script has run and a hello brings it back. Option 01 can't get there.
- **Settings change underneath a cache.** `defaults import` while preferences are cached is a second way of changing settings. The script must run with neither app running, which step 1 enforces.
- **Shell, not Swift.** Ending sessions and handling the database move into shell, beside the app's own Swift for the same jobs (the sweep's confirmed end, the store's opening). Two codes do one thing for a while.

## User Stories

Option 01's stories 1 to 13, and:

14. As the user, I want to read and dry-run the migration before it touches my Mac, so that I know what it will do.

## Implementation Decisions

- **Names, the code rename, the docs, the GitHub renames and the Ryzen's cutover:** as option 01.
- **The script's steps:** as Solution. Each step is skipped when its target exists, so a second run does nothing. With `--dry-run` it prints and changes nothing. It never logs a setting's value.
- **The settings copy** uses `defaults export` and `defaults import` of the whole domain, then renames the one key.
- **The database** is checkpointed (`PRAGMA wal_checkpoint(TRUNCATE)`) before its rename. If it can't be opened, the script stops there.
- **The start guard's test:** the old domain has keys and the new one has none.
- **The Mac runbook** is option 01's, with steps 4 and 5 replaced: run the script, then `make install`.

## Testing Decisions

- **The script's dry run and real run** on a temporary home, with made-up domain names passed in. A temporary home doesn't move settings, which is why the names are parameters.
- **Old-named zmx sessions** are made in a throwaway absolute `ZMX_DIR`, as option 01 describes.
- **The database step** runs on a copy whose WAL holds a write.
- **The start guard** is checked with a made-up old domain.
- **The rest** as option 01.

## Out of Scope

As option 01.

## Further Notes

- **Open:** as option 01. The checkout's folder could be renamed by the script, but the recommendation is still a separate step later.
- **Siblings:**
  - for the script's shape, the installer's halves: they print markers and are judged by them, and refuse early;
  - for the database, the store's own open;
  - for ending sessions, `Zmx.endConfirmed`'s rule.
- **Tickets, a sketch:** option 01's, with ticket 3 being the script, the start guard and the build guard instead of the first-launch migration and its guards.
