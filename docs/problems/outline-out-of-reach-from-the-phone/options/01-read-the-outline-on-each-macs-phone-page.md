---
problem: outline-out-of-reach-from-the-phone
title: Read a Mac's Outline on its Phone page
summary: A Mac host's Phone page gets an Outline button beside Voice mode. It opens that Mac's Outline, read-only, with breadcrumbs, notes, completed bullets struck through and mirrors marked. The phone can zoom, collapse and show completed bullets in a view of its own, which is never saved and never changes the Mac's view. The Mac's app lists the rows from its own model with the tree's rules, so the page decides nothing about the tree. A headless host has no Outline and no button. The Outline's text crosses the tailnet to the phone, which changes ADR 0030's "local only". One new relay request means one protocol bump.
status: proposed
---

## Solution

On a Mac host's Phone page, Home gets an **Outline** button beside Voice mode. It opens that Mac's Outline:

- **The header** holds the breadcrumbs (Home, then each bullet the phone has zoomed through), Show completed and Refresh.
- **The title.** When the phone has zoomed in, the zoomed bullet's text is the title, and the bullets nested under it follow.
- **Each row** is indented by its depth and shows:
  - its dot, its text, and its note if it has one (two lines; tap to see the rest);
  - a triangle when bullets are nested under it;
  - a ring around the dot when the bullet is a mirror or is collapsed;
  - a line through it, dimmed, when it is completed.
- **Moving around.** Tapping a dot zooms into its bullet, and a crumb zooms out to that bullet. The phone's Back button zooms out one level, since the zoom is in the page's address. Tapping a triangle collapses or opens that bullet.

**The view belongs to the phone.** It starts at Home, with the Mac's saved collapse and the Mac's Show completed. Zooming, collapsing and Show completed on the phone change nothing on the Mac: the file and the Mac's own view stay as they were.

**It only reads.** Nothing on the phone can change the Outline.

**The Mac's app lists the rows.** The page asks for the rows of a zoom, sending the phone's opened and closed bullets and its Show completed. The app works them out with the tree's own rules on a copy of the tree that is never saved. The page draws what it gets back.

**When it reads:** when the view opens, when the page comes back into view, on Refresh, and at each zoom. It never polls.

**Which outline.** Each Mac's page shows that Mac's Outline. A headless host has none, so its page has no button. A Mac whose Outline is switched off says so in the view.

## Trade-offs

- **The phone can't add, change or check off anything.** Writing a thought down away from the desk, probably the most common use, still happens in another app. Options 02 and 03 add edits.
- **The Outline's text leaves the Mac for the first time,** to the phone over the tailnet (Privacy, below). This changes ADR 0030's "local only" and every doc that repeats it.
- **Out of date until it reads again.** An edit made on the Mac shows on the phone at the next read: coming back to the page, a zoom or Refresh. Nothing is pushed to the phone.
- **Each Mac's page shows only its own Outline.** If the Outline is on in more than one Mac, each one is on its own page, reached through Other hosts. Showing one Mac's Outline on every page would mean one host's page reaching another Mac, the hop ADR 0011 turned down.
- **No filter, and tags are plain text.** The tree could filter for the phone later, as one more field; this option leaves it out.
- **One protocol bump** for the new request. Every Mac, the headless host and each page must run one commit, as for every new request so far.

## User Stories

1. As the user, I want an Outline button on my Mac's Phone page, so that my lists are on my phone.
2. As the user, I want to zoom into a bullet and back out with the crumbs or Back, so that I can read one part of a big outline on a small screen.
3. As the user, I want to collapse and open bullets on the phone without changing how they show on my Mac, so that tidying the phone's view costs the desk nothing.
4. As the user, I want to show or hide completed bullets on the phone, so that I can see what's left.
5. As the user, I want completed bullets struck through and mirrors marked as they are on the Mac, so that the phone reads the same.
6. As the user, I want to see a note under its bullet and tap to read all of it, so that the details are there when I need them.
7. As the user, I want the phone's view to read again when I come back to it, so that what I see is what the Mac holds.
8. As the user, I want a headless host's page not to offer an Outline it doesn't have, and a Mac with the Outline off to say so.
9. As the user, I want my bullets to travel only between my Mac and my phone over my tailnet, never logged and never kept on the phone, so that the Outline stays private.

## Implementation Decisions

### Which outline

- **Each Mac's page shows that Mac's own Outline,** as Voice mode on a Mac's page talks to that same Mac. The page asks its own host's relay and no one else (ADR 0011).
- **A headless host has none.** Its page hides the button, going by the hello it already reads, as it does for Voice mode. Its relay refuses the request, saying it needs a Mac.

### The request

- **One new relay request, `outlineRead`.** A Mac's relay forwards it to the running app over its socket, as it does Voice mode's, and the app answers it on the main actor.
- **Only a listed device may ask.** The app checks the asker against the device list, as Voice mode does. A paired Mac is refused: its Varnick has no view of another Mac's Outline, so allowing it would only add another reader.
- **What it sends:**
  - the zoom, as a row path, or Home;
  - the bullets the phone has opened or closed, as row paths (at most a few hundred);
  - Show completed;
  - where a continuing read starts.

  Row paths are made of placement ids, which hold no text.
- **When it is refused.** It is refused in the Outline's own words while the switch is off, while the file is unreadable or from a newer Varnick, and while the app is starting. The first read in a launch loads the file, as a session's read does, and nothing in it writes the file.
- **What the reply holds:**
  - the crumbs, each with its text cut short as a crumb's is;
  - the title;
  - the rows in order, each with: its path, its depth, its text, its note (cut, with the full length given), whether it is completed, whether bullets are nested under it and whether they show, and how many placements its bullet has;
  - how many rows are left.
- **Bounded,** as a session's read is: a cap on the number of rows and on the bytes, well under a reply line's limit, then a Show more that continues the read. A note longer than the cut is read whole by a read of its own row. The numbers are the planner's to set in the build, against the line limit, and a test checks them.
- **The tree lists the rows.** The app applies the phone's zoom, opened and closed bullets and Show completed to a copy of the tree, lists the rows that copy shows, and drops it.
  - The copy is never saved or published.
  - The Mac's Outline view, its rows and its caret are untouched.
  - The page never works out which rows show, so the tree's rules stay in one place.
- **A zoom that has left the tree** opens at Home, as it does on the Mac, and the view says so.

### The page

- **A view of its own,** opened from Home's button and reached by its own address (`#outline`, with the zoom in it), as Voice mode's is. Back zooms out one level, and at Home it leaves the view.
- **The phone's view state** stays in the page:
  - the zoom in the address;
  - the opened and closed bullets in memory, for the visit;
  - Show completed with the page's other preferences.

  None of it holds a bullet's text, and it reaches the Mac only as a read's parameters.
- **When it reads:** on opening, on coming back into view, on Refresh, at each zoom, and on opening a collapsed bullet whose rows it hasn't read. Never on a timer: Home has none either.
- **The page's server** checks a read's parameters and shapes the reply in a module of its own with no I/O, so `bun test` runs it, as Voice mode's module is. The route is a GET and goes through the page's same-site checks.

### Privacy

This is the decision the option asks of the user: **the Outline's text reaches the phone.**

- **Its way to the phone:**
  1. the app on the Mac;
  2. the relay, a process on the same Mac;
  3. the page's server, on an owner-only socket on the same Mac;
  4. `tailscale serve`, over HTTPS on the tailnet;
  5. the phone's browser.

  Nothing leaves the tailnet.
- **The phone holds it only in the page's memory,** while the view shows. The worker caches nothing and the replies are `no-store`, as now. No bullet's text goes into the page's storage, a push or a notification.
- **Nothing on the way logs it.** The server's access line has the path without its query. The app and the relay log the request's kind, counts and duration only, as ADR 0030 requires.
- **Whoever can use the page can read the Outline:** the user's listed devices. On a Mac whose page listens on loopback (ADR 0011), that also means any program on that Mac, as is already true of that Mac's sessions.
- **Anyone who sees the phone can see it,** on its screen and in its app switcher's picture, as with every other view of the page.

### Documents

- **A new ADR, with the next free number.** It records that:
  - a Mac's Phone page reads that Mac's Outline through the app's model;
  - the tree lists the rows, on a copy;
  - the text goes to listed devices over the tailnet, and nothing on the way keeps it.

  It amends:
  - ADR 0030's "Local only", and its amendment saying local only holds "for every Mac and device";
  - ADR 0031's "Nothing reaches a paired Mac, the phone or TypeSafe", under `outline_read`;
  - ADR 0011: the page now shows the Outline.
- **`CONTEXT.md`.**
  - The Outline's "kept in a file on this Mac and nowhere else" changes to: kept on this Mac, and shown on its Phone page.
  - The Phone page's entry lists the Outline on a Mac host.
- **`docs/privacy-and-security.md` and the README,** where they say the Outline is kept on this Mac only.
- **In the app,** the `!outline` row's detail and the Outline switch's detail, which both say "kept on this Mac".
- **`docs/agents/where-it-breaks.md`:**
  - The outline: a second caller that lists rows from a copy of the tree.
  - Phone page: the route and the request, and that nothing of the text is kept or logged.
  - The protocol's number.

## Testing Decisions

- **No test target.** Run `make build` and then `bun test` in the page's folder. The rest is checked by hand after the user restarts Varnick.
- **`bun test`** covers the server's new module (the parameters it refuses, the replies it shapes, the caps). `protocol.test.ts` holds the page's protocol number to the relay's.
- **`--outline-check`** gains the phone's listing, run on a throwaway file. It covers a zoom, opened and closed bullets, Show completed, and a zoom that has left the tree. It checks that the tree is unchanged afterwards, the counts, and that a reply at the caps fits in a line. It prints no bullet's text.
- **By hand on the phone,** done by the user after a restart on every Mac and the headless host:
  - the button shows on a Mac's page and not on the headless host's;
  - the view with the Outline switch off;
  - zoom, Back, the crumbs, collapse and Show completed;
  - none of those changes the Mac's own view;
  - an edit made on the Mac shows after coming back to the page;
  - Show more on a long outline;
  - an unreadable file gives its reason.

## Out of Scope

- Any edit from the phone (options 02 and 03).
- The filter, and tapping a tag.
- One Mac's Outline on another host's page, and syncing Outlines between Macs.
- Pushing the Mac's changes to an open view.
- A paired Mac reading another Mac's Outline.
- Keeping any of the Outline on the phone for when the Mac can't be reached.

## Further Notes

- **Sibling: Voice mode on the phone** (ADR 0043). It is a request only a Mac can answer, which the relay forwards to the app and a headless host refuses. It has a view of its own with its own address, and a server module with no I/O.
- **Seam: a session's read** (`outline_read`) already loads the file without showing the Outline, and reads the model, never a text view. This read works the same way, returning structured rows for a page where a session's read returns text.
- **Options 02 and 03 build on this one.** If either is built after this one ships, it adds a request and raises the protocol again.
- **The protocol number** is the next one after whatever is in use at build time. 33 belongs to `phone-cant-mark-a-tab-done`'s option 03 (accepted, not built), so this would be 34 if that one ships first. The new ADR's number works the same way.
