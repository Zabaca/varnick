---
problem: bookmarks-not-searchable
title: Bookmarks join history entries
summary: Each Chrome bookmark folds into the search entry for its page, so a page shows once whether it was visited, bookmarked or both; a bookmark never visited becomes an entry of its own.
status: shipped
---

## Solution

Each sync also reads the `Bookmarks` and `AccountBookmarks` files (the latter holds a signed-in profile's account-synced bookmarks; a profile may have either or both, and a URL in both is one bookmark) in every Chrome profile folder it already walks for History, then folds the bookmarks into the entries history builds. If a bookmarked page is already in History, its entry gains the bookmark's name, its folders and a bookmark badge. A bookmark that was never visited becomes its own entry, built from its name, host, folders and fetched page description. Keyword search, embeddings, ranking, the preview and opening all reuse the existing pipeline. Bookmarks mirror Chrome, so deleting, renaming or moving one there shows up in search after the next sync (within a minute).

## Trade-offs

- **One result per page.** Launchy opens results in the default browser. When that browser is Chrome, opening a bookmark records a visit, so the page enters History at the next sync. Here that visit lands on the same entry and the same search row (same id). With a separate source it would become a second result.
- **The entry carries both histories.** A bookmarked page that was also visited keeps its pooled search terms, URL variants and visit counts.
- **It changes the core of the sync.** Today entries are built by grouping on title and host. Bookmarks add a second way to join an entry, by URL, and each entry gains bookmark fields. This is more invasive than adding rows beside history.
- **A row can be History, a bookmark, or both,** so the badge has to say which. This can't be reused for a source that has no History to join.
- **The merge rarely applies today.** On this Mac 587 of 598 bookmarks are not in History, so almost all new entries are bookmark-only at first. The merge starts to matter as bookmarks get opened through Launchy.

## User Stories

1. As a Launchy user, I want a page I bookmarked years ago and never reopened to come up when I search its name, so that what I saved on purpose is findable.
2. As a Launchy user, I want searching a folder name to bring up the bookmarks filed in it, so that I can find a page by where I put it.
3. As a Launchy user, I want a page I both bookmarked and visit to show as one result, so that results aren't doubled.
4. As a Launchy user, I want a bookmarked result to show a bookmark badge and its folders in the preview, so that I can tell why it came up.
5. As a Launchy user, I want a bookmark I delete in Chrome to leave search within a minute (unless I also visited it, in which case it stays as History), so that search follows what I keep.
6. As a Launchy user, I want renaming or moving a bookmark in Chrome to show in search, so that names and folders stay current.
7. As a Launchy user, I want bookmarks from every Chrome profile, so that bookmarks behave like History.
8. As a Launchy user, I want a bookmark to a local dev server or a sign-in page to be findable, even though History leaves those out as noise, because I saved it on purpose.
9. As a Launchy user with the embedding model downloaded, I want bookmarks matched by meaning as well as by keyword, so that they behave like History entries.

## Implementation Decisions

**Reading Chrome's bookmarks**
- The sync reads the Bookmarks file of every profile folder it walks for History, in the same pass. The file is parsed in place. History needs a copy because Chrome locks it; the Bookmarks file isn't locked.
- Only `url` nodes become bookmarks. Folder names come from every folder between the bookmark and its root. Chrome's three top-level roots (bookmarks bar, other, mobile) are left out because they are generic: on this Mac 458 bookmarks sit under "Bookmarks Bar". Identify the roots by their position under `roots`, not by name.
- Bookmarks are one per profile and URL. When a URL is filed in several folders, its copies pool their folders. If the copies' names differ, the most recently added copy's name wins (no names differ on this Mac).
- `date_added` is a string of microseconds since 1601, like History's times. `"0"` means unknown.
- Only schemes that can't open outside Chrome are skipped, using the same scheme list History uses (bookmarklets, `chrome:` and the rest). History's noise filters (sign-in, OAuth, localhost, search result pages) are not applied, because a bookmark was saved on purpose.
- A bookmark with an empty name uses its URL as its name.

**Archive**
- A new archive table, `bookmarks`, has one row per profile and URL: profile, url, name, folders (newline-separated), date added. It is created alongside the other archive tables, so existing databases gain it at the next launch.
- Unlike `pages`, it mirrors Chrome rather than only growing, because deleting a bookmark is deliberate and History expiring isn't. A profile's rows are replaced only after its file is read and parsed. If the file can't be read or parsed, that profile keeps its previous rows. If the file is missing, the profile has no bookmarks.
- `pages` stays the archive of visits and keeps growing as it does now.

**Entries**
- History entries are built as today. After that, each bookmark joins one entry, checked in this order:
  1. the entry holding its URL (as any variant);
  2. the entry with the same title-and-host key;
  3. otherwise a new entry with the bookmark's URL and name and zero visits.
- An entry gains a bookmarked flag, its pooled folders, its profiles from bookmarks and the earliest date added. Its grouping key stays as history made it.
- A bookmarked entry is titled with the bookmark's name, since the user chose that name or saw it when saving. When the History title differs, it goes into the searchable description, so the History title still matches.
- Embedding text adds the folders as one line. On this Mac only the handful of bookmarked visited entries get re-embedded.
- Bookmark-only entries get page descriptions like any entry: fetched without cookies, most-visited first, so after visited pages. Here that is about 8 syncs once History's own backlog is drained.

**Search rows**
- The row key stays `chrome:` plus the entry's URL, so every existing row keeps its id. A bookmark-only entry keeps its row after it is visited, as long as its URL is still the entry's most-visited one. History variants already behave this way.
- The source is `bookmark` when the entry is bookmarked and `chrome` otherwise. It gets its own badge name ("Chrome bookmark"), symbol and colour, so a never-visited bookmark never shows as "Chrome history".
- Tags hold the profiles plus the folder names, with spaces turned into underscores the same way profile names are. The preview splits tags on spaces into chips. In keyword ranking, tags weigh 4 against 10 for the title and 1 for the description.
- The shown date is the last visit, or the date added for a bookmark that was never visited.

**Ranking**
- No boost for bookmarks. Today rank comes only from keyword and semantic matching; visit counts are stored but never used to rank. So a bookmark competes on the same terms as a visited page, and its folder names give it more text to match. A boost is a follow-up if checks show bookmarks buried.

**Sync**
- The archive signature also covers bookmarks, so adding, deleting, renaming or moving one rebuilds the search rows. Without the embedding model, a signature change is the only thing that triggers a rebuild.

**Panel**
- The search field placeholder names bookmarks as well as History. Check that it still fits beside the `>` and `!` hints.

## Testing Decisions

- There is no test target. Reading the bookmarks is a pure step: the file's JSON goes in, and the bookmarks come out with roots skipped, folders pooled, dates converted and schemes filtered. That step is the seam for a first test once a test target exists.
- By hand, after the user restarts Launchy and a sync has run:
  - Search the name of a bookmark never visited: it shows with the bookmark badge, and the preview shows its folders and date added.
  - Search a folder name: its bookmarks come up.
  - Open a bookmark from Launchy. After the next sync it is still one result, not two.
  - Delete a test bookmark in Chrome. Within a minute it is gone, unless it was visited, in which case it is back to "Chrome history".
- The `--search` command-line flag prints ranked results with their source, which helps check ranking and duplicates without the panel.

## Out of Scope

- Bookmarks from other browsers.
- A ranking boost for bookmarks.
- A bookmarks-only filter or prefix.
- Editing bookmarks from Launchy.
- A setting to leave bookmarks out of search.
- Sending folder names to the TypeSafe reranker, which sees only title and host.
- Renaming the `favorites` table and its store to match the glossary. That's worth doing as its own change.

## Further Notes

- **Glossary, open question.** The term **Bookmark** is not in the glossary yet. A proposed entry: "A page saved in Chrome's bookmarks, searched alongside **History** whether or not it was visited. Launchy follows Chrome, so a bookmark deleted there leaves search. _Avoid_: Favorite, saved page." Added to the glossary.
- The TypeSafe reranker judges only title and host. A bookmark matched only by its folder name can be demoted below the relevant results, but it is never dropped.
- Assumptions: Chrome replaces the Bookmarks file whole, so reading it while Chrome runs is safe. Chrome may translate the root folder names into the user's language. The full-text tokenizer splits on underscores, so each word of a folder name matches on its own.
