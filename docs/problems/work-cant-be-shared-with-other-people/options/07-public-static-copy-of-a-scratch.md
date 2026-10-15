---
problem: work-cant-be-shared-with-other-people
title: A public link to a built, static copy of a Scratch, uploaded to the user's own Cloudflare storage
summary: The Share button builds the Scratch's page with Vite, shows what the build holds, and uploads it to R2 on the user's own Cloudflare account, served by a small Worker at a link of the same shape as option 04's. Publishing again replaces it at the same link; Unpublish removes it; an expiry is optional. It works with the Mac off and exposes no dev server at all, but it is a snapshot, which the user said is not what they want: viewers see no change until it is published again. Kept as a short alternative, not recommended. Rough effort is about three days.
status: proposed
---

## Solution

- **Build.** Share runs a production build of the page from its area into a temporary folder.
- **The confirm.** It lists the built files with sizes, data files first, and says that anyone with the link can read them, until it is unpublished or expires.
- **Upload.** The files go to a bucket on the user's account under the link's id, and a Worker serves them at `https://<id>.<links domain>/`. The control calls are keyed as in option 04.
- **Publish again** replaces the files at the same link. **Unpublish** deletes them, and the link answers 410. An expiry is chosen as in option 04, or none.

## Trade-offs

- **Not live.** Viewers see what was published, and a change shows only after Publish again. The user asked for live.
- **Less exposed.** Only built output is served, so there are no `/@fs/` reads, no dev server and no Vite file-read bugs. Source maps are off unless asked for. Files are served only if the page imports them or they sit in its `public` folder.
- **Works with the Mac off,** and loads fast from storage.
- **Builds can fail** where the dev server works, such as a page that reads a file by a path only the dev server serves. The confirm then shows the build's error.
- **Storage and requests** cost a little on the user's account (R2 is reported available there, not checked here).

## User Stories

1. As the user, I want to publish a Scratch's page to a link that stays up with my Mac off.
2. As the user, I want to publish it again to the same link after changes, and to unpublish it.
3. As the user, I want to see what will be published before it is.

## Implementation Decisions

- **The build is the app's.** The manifest's `public` entry (option 04) also names a build command, so Varnick knows nothing of Vite.
- **The same switch, links domain and key as option 04,** if both are built. The Worker serves from storage instead of a connector.

## Testing Decisions

- **A built page** loads from the link with the Mac asleep.
- **Publish again** replaces it, and Unpublish gives 410.
- **No map files** are served unless asked for.

## Out of Scope

Live updates (option 04).

## Further Notes

- **Not a rival to option 04 but a later addition to it.** A Freeze button on a live link would publish this copy at a link of its own, for when the Mac must be off.
