---
problem: panes-open-only-by-hand-at-a-mac
title: The phone's Add pane offers a custom app, a page and a file as well as Claude and a terminal
summary: Accepted by the user on 2026-10-17 (relayed by the coordinator), extending option 03. On a Mac host, Add pane offers five kinds. App lists the custom apps of the shown pane's folder, Scratch among them. Page takes an address. File browses the shown pane's folder one level at a time. The page server sends the `start` a Mac sends for a split of another machine's tab, which protocol 32 already carries, and the phone shows the new pane as it shows any listed one. The relay lets a listed device ask `apps` and `files`, which it refuses today. No protocol bump: only the host that serves the page needs the build. A headless host keeps Claude and Terminal.
status: accepted
---

## Solution

**The kinds.** Add pane's row of kinds becomes Claude, Terminal, App, Page and File, on a Mac host. On a headless host it stays Claude and Terminal, since that host refuses the rest. The form asks the page server what to offer for the tab and the pane shown: the agents, as now, the apps, and whether pages and files are offered.

**How each is chosen.**
- **App:** a chip for each custom app the host lists from the shown pane's folder, by name, as the Mac's picker for another machine's tab lists them. With none, a line says no app is found there.
- **Page:** one address field. The host turns a bare address into http or https by its own picker's rule: `localhost`, `127.` and an address that starts with a digit get http, the rest https. Anything else is refused there.
- **File:** a list of the shown pane's folder, one level at a time: folders first, then files, without the names the file tree never lists. Tapping a folder goes into it, an Up row goes back, and tapping a file picks it. Up stops at the shown pane's folder. A folder with more entries than the host sends says so.

**The request.** `POST /api/split` takes the three new kinds with their one field each: the app's folder name, the address, the file's path. The server:
- keeps option 03's gates: the tab is listed, the phone controls it, the pane is one of its panes;
- checks an app against the host's `apps` for that pane's folder, and a file against that folder;
- refuses an address that isn't one line or is too long;
- refuses a page, an app or a file on a headless host, with that host's reason, before asking it;
- sends `start` naming the tab, the pane and side by side, of kind web with the address, app with the app, or file with the path and the pane's folder as the tree's folder;
- tells a lost answer for one of these kinds by the new pane's id in the tab's listing, since it has no session to ask about.

**On the host.**
- A page or an app goes beside the pane the phone showed, side by side, as a split from the controlling Mac does. An app is told it was split from that pane, so Scratch serves that pane's area.
- A file goes where the Mac's own file tree puts one: below the newest file pane of the tab, or beside the host's focused pane when there is none.

**What the phone shows.** The new pane becomes a switcher button, and the page switches to it once the host lists it, as it does after adding Claude or a terminal.
- **A page at an outside address:** a note naming the site, with Open, which loads it in the phone's browser. The phone doesn't frame it.
- **A page at the host's own address, and an app:** framed through the host's port proxy once the page server has looked at the pane. Until then the note says it hasn't looked yet, and the view frames the pane when the address comes.
- **A file:** a note with its text from the host: text only, up to 1 MB, inside the tab's folders.

**The relay.** A listed device may ask `apps` and `files`, which it refuses to devices today. The page server asks them only for a tab the phone controls, with the folder taken from the tab's listing, never from the page. The host keeps `files` inside the tab's folders, as for a Mac.

## Trade-offs

- **The whole of what the user asked,** with the host side already built: a Mac host takes a split of every kind from the machine in control, the phone included.
- **No protocol bump.** Every request and reply keeps its shape. Only the relay's rule for who may ask changes, and the page server only ever runs its own host's relay, built from the same commit. The host that serves the page needs the build; no other machine does. A host left on an older build keeps offering Claude and Terminal.
- **It widens what a device is answered.** `apps` gives app names; `files` gives the names in the tab's folders, not their contents. A listed device can already take a tab over and list a folder from its terminal, so nothing new is reachable. ADR 0011's rule is that a device is answered wherever a peer is, but for the search sync. `apps` and `files` were later kept for Macs with no reason recorded; that no device used them is a guess.
- **An outside page helps the Mac more than the phone.** The phone opens it in its own browser, so adding one mostly lays out the tab for when the user is back at the Mac. A page at the host's own address, a dev server say, is framed.
- **A file isn't beside the pane shown,** and on the host it takes the tab's focus in that tab's own layout, as a file picked in the tree of another machine's tab does today.
- **A custom app runs its code on the host,** as when the user picks it from the Mac's picker of another machine's tab: the list is the same.
- **The form grows** from two kinds to five on a 360 px screen.

## User Stories

1. As the user on my phone, I want to add Scratch beside a session in a tab I control, so that I can watch what it draws there.
2. As the user on my phone, I want to add another of my custom apps from the same list the Mac offers.
3. As the user on my phone, I want to add a page by its address, so that a dev server on the host is framed beside the session, or a site is in the tab when I'm back at the Mac.
4. As the user on my phone, I want to pick a file from the shown pane's folder and read it beside the session.
5. As the user, I want the new pane shown once it is added.
6. As the user on a headless host, I want Add pane to offer only what that host can add.

## Implementation Decisions

- **The sibling** is the Mac's split picker for another machine's tab: Claude, Terminal, Browser with an address, and the host's apps from the focused pane's folder. A file is the Mac's file tree of another machine's tab, one level at a time, with a pick that opens on the host. On the phone it is option 03's form and flow.
- **The parser** gains the three kinds. A kind takes only its own field, and a field of another kind is refused, as a terminal with a prompt is now. An address is one line, at most a URL's usual length, with no control characters. A path is absolute and inside the shown pane's folder as the listing gives it.
- **The lists** come from the server, which takes the folder from the tab's listing: the apps with the agents in one ask, and a folder level in another. Both are under the gates of Add pane.
- **The page** keeps no value for next time, as now. The switch to the new pane after Add covers every kind, not only one that runs.
- **No saved state.** The host saves the pane as any split.
- **Docs:**
  - ADR 0034's bullet on the phone (every kind on a Mac host) and ADR 0035's "splits from afar" (the phone too).
  - where-it-breaks › Peers: `files` and `apps` are for listed Macs and devices.
  - where-it-breaks › The tab view on the phone. That section holds its Add pane and Restart paragraphs twice, the second copy in older wording; the builder drops the older copy.
  - The guide.

## Testing Decisions

- **`bun test`:**
  - The parser for each kind: what it reads, and the refusals.
  - The flow against a fake relay: a headless host refused before asking, an unknown app, a file outside the folder, and a lost answer found in the listing.
  - The rules for which kinds the form offers.
  - The folder list's Up stopping at the start folder.
- **Build:** `make build` for the page server's and the relay's copies in the app.
- **By hand, after the user restarts Varnick,** on a Mac host, with a tab taken over on the phone:
  - Add Scratch: it is framed on the phone and serves the shown pane's area.
  - Add a page at a dev server on the host: it is framed. An outside page shows its note with Open.
  - Add a file picked two folders down: its text shows, and on the Mac it sits in the file column.
  - On a headless host, the form offers Claude and Terminal only.
  - On a tab the phone doesn't control, there is no +.

## Out of Scope

- The Website pane (the Tasks switch's), which works only on the Mac it runs on, as the Mac's picker for another machine's tab says.
- Choosing where the pane goes, or a split top and bottom.
- Searching for a file rather than browsing to it.
- Closing one pane from the phone.

## Further Notes

- **Verified in the code at b3e7356:**
  - The split request carries kind web with an address, app with an app's folder name, and file with a path and the tree's folder, since protocol 26.
  - The Mac's socket takes `start` of every kind from a listed device. The host checks the asker controls the tab for a page, an app and a file, as for Claude and a terminal.
  - The relay refuses `apps` and `files` to a device. The commit that made `apps` Mac-only, a review of the port proxy, gives no reason.
  - The headless host answers `apps` with none and refuses a page, an app or a file in a split.
  - The host gives a page, an app and a file the id the asker chose, so a listing finds it.
  - The tab view frames a proxied page or app and shows an outside page as a note with a link. It reads a file pane's text through the host, and frames a pane again when its proxied address appears. Today it switches to an added pane only when the pane runs, so a page, an app or a file would not be shown.
  - The port proxy carries websockets.
- **Inferred, not tested:** Scratch's live updates work through the proxy on the phone.
- **Open decisions, each with the recommendation first:**
  - **The file picker.** Recommended: browsing the shown pane's folder, Up stopping there. Else: Up to any of the tab's folders, or a path typed in a field, which is slow on a phone.
  - **Where the control check for `apps` and `files` lives.** Recommended: the page server, with the host's folder rule in the relay, as for `file` today. Else: the relay also checks a device controls the tab, which costs it a read of the tab's sessions at each folder level.
  - **After Add.** Recommended: switch to the new pane, as option 03 does. Else: stay on the pane shown, as a session's own `pane_open` leaves focus.
