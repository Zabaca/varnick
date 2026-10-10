---
problem: custom-apps-must-be-written-first
title: Fetch the catalog from GitHub at run time
summary: Not recommended. As option 01, except that Settings › Apps downloads the catalog's index and each app's files from the public repository when it shows, instead of reading a copy shipped in the release. A newly accepted app reaches people the day it merges, without a release. The cost is a request to GitHub each time the section shows, a section that is empty offline, and code merged to main running as the user before any release has carried it. Pinning what is fetched, so it can be checked, needs trust machinery that the release already gives option 01. Rough effort is six days.
status: proposed
---

## Solution

The catalog lives in `apps/` as in option 01, but Varnick.app doesn't carry it. When Settings › Apps shows, Varnick downloads an index of the catalog from the public repository, from main or from the newest release's tag, and lists it. Turning an app on downloads that app's files and installs them as option 01 does: a marked copy in the user's apps and a linked skill. Varnick looks for a newer version each time the section shows, and refreshes by option 01's rules.

## Trade-offs

- **New apps without a release.** An accepted app reaches people the day it merges, and a fix to one ships alone.
- **A request to GitHub each time the section shows,** made by Varnick itself. GitHub sees the Mac's address and that it runs Varnick. Of Varnick's own requests to GitHub, the privacy doc lists only a checkout's Upgrade, which the user presses; none comes from opening a Settings section.
- **Offline, nothing to show or turn on.**
- **Code that reached main but no release runs as the user,** with Varnick's macOS permissions. Fetching from the newest release's tag instead removes this, and with it the only gain over option 01, since the release could have carried the files.
- **Checking what was fetched needs new machinery.** A signed index or digests pinned in the release is needed, or a compromised download path serves any code. The release's signature and notarization already cover option 01's copy, as part of the bundle.
- **More code:** a fetcher, a cache, failure states and a privacy section of its own.

## User Stories

1. As a person, I want a newly accepted app without waiting for a Varnick release.
2. As a contributor, I want my accepted app to reach people the day it merges.

## Implementation Decisions

- **Where from.** The index and files come from the public repository over HTTPS, as raw files at a commit, so a download is one known version.
- **What is checked.** The index names each file's digest, and the index itself is pinned by a digest shipped in the release, or signed. Pinned, it can't change between releases, so the gain is lost. Signed, it needs a signing key outside the repository and a check in Varnick.
- **Otherwise as option 01:** the marker, on, off, refresh, names, Settings › Apps and the acceptance rules.

## Testing Decisions

- As option 01, plus a harness for the fetcher against a local server (made-up index, a bad digest, offline), and a hand test of the section offline.
- **Rough effort,** about six days: option 01's four, plus two for the fetcher, its checks and the privacy docs.

## Out of Scope

- A registry or store run by anyone but GitHub.

## Further Notes

Weighed against option 01, the gain is speed for new apps; the costs are a request that leaves every Mac that opens the section, and a trust path that the release already provides. With one app in the catalog, speed matters little. It can be reconsidered once outside apps arrive often enough that releases hold them back.
