---
problem: bookmarks-not-searchable
title: Bookmarks as their own source
summary: Bookmarks get their own search rows, one per URL with source `bookmark`, built beside history entries instead of inside them; a page that is both visited and bookmarked shows as two results.
status: rejected
reason: Option 01 shipped instead. There bookmarks join history entries, so a page shows once, where this option shows a page both visited and bookmarked twice.
---

## Solution

Each sync also reads the Bookmarks file in every Chrome profile folder it already walks for History. It writes one search row per bookmarked URL with its own source, `bookmark`, next to the History rows. Grouping of History entries is not touched. A bookmark row is built from its name, host, folders and fetched page description, and is embedded like a History entry. Bookmarks mirror Chrome, so deleting, renaming or moving one there shows up in search after the next sync (within a minute).

## Trade-offs

- **History entry building is untouched.** A bookmark's identity is simply its URL, and deleting it removes only its own row, with no link to the History archive, which only grows.
- **Pages that are both visited and bookmarked show twice.** Launchy opens results in the default browser. When that browser is Chrome, opening a bookmark records a visit, so every bookmark used through Launchy gets a History twin at the next sync. Duplicates grow with use, and both copies use up places among the top 20 the reranker judges.
- **A bookmark row is thinner.** It doesn't carry the search terms or URL variants pooled on the History entry for the same page unless it copies them in by URL. Copying them starts a merge anyway.
- **Hiding the History twin leads back to option 01 by a longer route.** The twin's row would disappear and come back with a new id each time the bookmark is added or removed.
- **It isn't much smaller.** It touches the same places as option 01: reading the file, the fetch list, the embedding list and its cleanup of old embeddings, the search refresh, the signature and the badge. It saves only the change to entry grouping.

## User Stories

1. As a Launchy user, I want a page I bookmarked years ago and never reopened to come up when I search its name, so that what I saved on purpose is findable.
2. As a Launchy user, I want searching a folder name to bring up the bookmarks filed in it, so that I can find a page by where I put it.
3. As a Launchy user, I want bookmarks badged apart from History, so that I can tell a saved page from one I only visited.
4. As a Launchy user, I want a bookmark I delete in Chrome to leave search within a minute, so that search follows what I keep.
5. As a Launchy user, I want renaming or moving a bookmark in Chrome to show in search, so that names and folders stay current.
6. As a Launchy user, I want bookmarks from every Chrome profile, so that bookmarks behave like History.
7. As a Launchy user, I want a bookmark to a local dev server or a sign-in page to be findable, even though History leaves those out as noise, because I saved it on purpose.
8. As a Launchy user with the embedding model downloaded, I want bookmarks matched by meaning as well as by keyword, so that they behave like History entries.

## Implementation Decisions

**Reading Chrome's bookmarks** (same as option 01)
- The sync reads the Bookmarks file of every profile folder it walks for History, in the same pass. The file is parsed in place. History needs a copy because Chrome locks it; the Bookmarks file isn't locked.
- Only `url` nodes become bookmarks. Folder names come from every folder between the bookmark and its root. Chrome's three top-level roots (bookmarks bar, other, mobile) are left out because they are generic. Identify the roots by their position under `roots`, not by name.
- When a URL is filed in several folders, its copies pool their folders. If the copies' names differ, the most recently added copy's name wins.
- `date_added` is a string of microseconds since 1601, like History's times. `"0"` means unknown.
- Only schemes that can't open outside Chrome are skipped, using History's scheme list. History's noise filters (sign-in, OAuth, localhost, search result pages) are not applied.
- A bookmark with an empty name uses its URL as its name.

**Archive** (same as option 01)
- A new archive table, `bookmarks`, has one row per profile and URL: profile, url, name, folders (newline-separated), date added.
- It mirrors Chrome. A profile's rows are replaced only after its file is read and parsed. If the file can't be read or parsed, that profile keeps its previous rows. If the file is missing, the profile has no bookmarks. `pages` is not touched.

**Bookmark rows**
- One row per URL across profiles, keyed `bookmark:` plus the URL. That key can't collide with History's `chrome:` keys, and it keeps the row's id stable across syncs.
- Source `bookmark`, with its own badge name ("Chrome bookmark"), symbol and colour.
- The title is the bookmark's name.
- The description is the fetched page description for that URL, shared with History by URL, plus the URL itself.
- Tags hold the profiles plus the folder names, with spaces turned into underscores the same way profile names are.
- The date shown is the date added.
- The embedding is stored under the row's key beside History's entry keys. Each sync drops stored embeddings whose key isn't among the current entries, so that cleanup has to count bookmark keys as current. Otherwise it deletes every bookmark embedding on every sync.
- Bookmark URLs that have never been fetched join the description fetch list after visited pages.
- One transaction writes History and bookmark rows together, and removes stale rows of both kinds.

**Ranking**
- No boost for bookmarks. Today rank comes only from keyword and semantic matching; visit counts are never used to rank. A boost is a follow-up if checks show bookmarks buried.

**Sync**
- The archive signature also covers bookmarks, so adding, deleting, renaming or moving one rebuilds the search rows. Without the embedding model, a signature change is the only thing that triggers a rebuild.

**Panel**
- The search field placeholder names bookmarks as well as History. Check that it still fits beside the `>` and `!` hints.

## Testing Decisions

- There is no test target. Reading the bookmarks is a pure step (the file's JSON in, the bookmarks out), and it is the seam for a first test once a test target exists.
- By hand, after the user restarts Launchy and a sync has run:
  - Search the name of a bookmark never visited: it shows with the bookmark badge.
  - Search a folder name: its bookmarks come up.
  - Delete a test bookmark in Chrome: within a minute it is gone.
  - Open a bookmark from Launchy and search again after the next sync. Expect two results, and confirm the doubling is acceptable.
  - Run a second sync and check that bookmark embeddings were not dropped. The `--search` command-line flag prints which results matched by meaning.

## Out of Scope

- Hiding the History twin of a bookmarked page (that is option 01).
- Bookmarks from other browsers, a ranking boost, a bookmarks-only filter, editing bookmarks, a setting to leave bookmarks out.
- Renaming the `favorites` table and its store to match the glossary.

## Further Notes

- **Glossary, open question.** The term **Bookmark** is not in the glossary yet. Option 01 has the proposed entry. Under this option a search row is either History or a Bookmark, never both, which makes the term simpler.
- This option suits a later source with nothing to merge into (a second browser's bookmarks, for instance) better than option 01 does.
