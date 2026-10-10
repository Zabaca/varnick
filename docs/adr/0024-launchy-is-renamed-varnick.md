# Launchy is renamed Varnick

The project was called Launchy until 2026-10-09 and is called Varnick from then on, in the code, the docs, the agents and the skills, on every machine the user owns and on GitHub. The reason is that Launchy is also the name of a long-established cross-platform keystroke launcher that runs on macOS, and the repository was about to be published under it. The name is also the bundle id macOS ties privacy grants and Keychain items to, so it was renamed everywhere in one change, before the repository goes public and while only the user's own Macs and the Ryzen need moving. The problem and its options are in `docs/problems/name-taken-by-another-launcher/`; this records option 01.

A passage written under the old name keeps it. Read it through the table below: wherever a dated record says Launchy, it means Varnick, and its identifiers are the right-hand column's.

## The names

| Was | Becomes |
|---|---|
| Launchy, launchy, LAUNCHY | Varnick, varnick, VARNICK |
| `com.zabaca.launchy` (bundle id, signing identifier, LaunchAgent label, settings domain, Keychain service) with `.transcript` and `.screen-text` | `com.zabaca.varnick` with the same suffixes |
| the app's source folder and executable target, the `Launchy` binary and its good copy, the entitlements file, the LaunchAgent template, the `sign-launchy` target | the same with Varnick |
| the package `LaunchyPeer` and its folder, the relay `launchy-peer` | `VarnickPeer`, `varnick-peer` |
| `~/Library/Application Support/Launchy`, `~/Library/Logs/Launchy.log` | `…/Varnick`, `Varnick.log` |
| `~/.launchy` (a Mac's user apps; the headless install root), a project's `.launchy/`, `launchy.json` | `~/.varnick`, `.varnick/`, `varnick.json` |
| zmx: `launchy-<uuid>`, `launchy=1`, `launchy-control`, `launchy-origin`, `launchy-phone-page` and its `launchy-page…` labels, `launchy-upgrade`, `launchy-build-exit=`, `launchy-install-<slug>`, `launchy-app` | the same with varnick |
| the systemd unit `launchy-phone-page.service` | `varnick-phone-page.service` |
| pane files `.launchy-turn` (with `.askers`, `.before`), `.launchy-stop`, `.launchy-session.json`, `.launchy-conversations` | `.varnick-…` |
| every `LAUNCHY_*` variable; the work marker `LAUNCHY-WORK`; the git key `branch.<b>.launchy-option` | `VARNICK_*`, `VARNICK-WORK`, `varnick-option` |
| the setting `heyLaunchy`; "Hey Launchy" | `heyVarnick`; "Hey Varnick" |
| the MCP server `launchy` (ADR 0023) | `varnick` |
| `db/launchy.sqlite` | `db/varnick.sqlite` |
| the `launchy-*` agents (`launchy-builder` and the rest in `.claude/agents/`); transcript lines' answer source `launchy` | `varnick-*`; `varnick` (old transcripts keep theirs) |
| six ADR file names: 0007, 0009, 0012, 0013, 0022 and 0023 | the same with `varnick` (`varnicks` for 0007 and 0009's `launchys`) |
| the GitHub repository Zabaca/launchy | Zabaca/varnick; the unrelated project that held that name is now Zabaca/varnick-deno, archived |

The wire protocol moved from 18 to 19 with the rename, so a machine on either side of it answers the other "another version" before reading anything.

## Left on purpose

- **The relevance checkpoint's keys** `launchy_format` and `launchy_question`. They are keys in a file this repository does not make, and a comment in the code says so.
- **Problem slugs and everything under `docs/problems/`,** such as `panes-share-launchys-permissions`. The Problems board, branch ties, work records and `work_history` key on the slugs, and problems are dated records. The only edit there is a link to a renamed file.
- **Dated passages in these ADRs:** measurements, acceptance dates, dated amendments and corrections, the considered options' reasoning, and the heading of a dated change. Their present-tense neighbours (titles, the decision as it stands, consequences that describe today, identifiers and paths) are renamed.
- **Transcript files already written,** whose answer lines say `[launchy]`. Nothing reads the source back.
- **The checkout's folder,** until it is renamed as its own step once every machine runs Varnick. Paths into it keep the old folder name until then.
- **Short-lived references,** removed by the cleanup once every machine runs Varnick: the first-launch migration, the refusal on a Mac not yet moved, and the guards that keep a Mac still on Launchy from crossing by itself. A few strings wait for a measurement or a re-embedding and are marked in the code where they sit.

## Considered Options

- **Migrate each Mac with a script (option 02):** not chosen. The app moving its own data at its first launch cannot run out of order; a script run beforehand can.
- **Keep running sessions alive across the rename (option 03):** not chosen. It costs far more than ending every session once at each machine's cutover, and conversations resume when their panes are first shown (ADR 0001).
- **Keep the name:** rejected. A later rename would break every clone, link and install made in between, and searches would lead to the other launcher.

## Consequences

- Every session on a machine ends once, at that machine's cutover, as a zmx pin bump does (ADR 0004). macOS asks for every permission again under the new bundle id (ADR 0022), and the two saved keys are entered again.
- Machines on different names cannot see each other, so the cutover is all machines in one sitting, the Ryzen first.
- A search for the old name over the tree finds only what is listed above, so it is a check on a change that missed a rename.
