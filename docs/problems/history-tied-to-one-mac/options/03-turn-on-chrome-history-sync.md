---
problem: history-tied-to-one-mac
title: Turn on Chrome's history sync for each account, and build nothing
summary: Chrome already writes the other devices' visits into each Mac's History for an account that syncs history, and Launchy already reads them. Turning history sync on in Chrome for the other accounts brings their pages over with no change to Launchy.
status: abandoned
reason: Option 01 shipped and brings every paired Mac's pages with no Chrome sync, including the profiles sync can't reach and pages Chrome has expired.
---

## Solution

In Chrome on each Mac, turn on History in the sync settings of every profile signed in to a Google account that both Macs use: the work account, the agent account and the second work account. The personal account syncs history already. Chrome then writes the other Mac's visits into the local History file. Launchy's next sync reads them as this Mac's pages, embeds them and fetches their descriptions. No code changes.

## Trade-offs

- **Nothing to build, and it works today** for the personal account. The Air holds 3160 visits made on the Studio and the Studio holds 1206 made on the Air, and 2701 of the URLs the two archives share came this way. It needs neither Mac's Launchy to be running, and it also brings the pages from the user's other devices.
- **Covers most, not all.** Nearly all of the Studio's 7331 URLs that the Air lacks are in accounts signed in on both Macs. Only the 122 in a profile with no account and the 54 in a client's account (signed in on the Studio only) can't come this way. All 1682 the Air has and the Studio lacks are in shared accounts.
- **Chrome's window only.** Launchy's archive outlives Chrome's 90 days, and sync carries only what Chrome still holds: 415 of the Studio's pages and 229 of the Air's are older. Whether turning sync on carries over any history from before is unknown.
- **Google holds the history** of each account turned on. Whether the Workspace accounts allow history sync wasn't determined. On the Air, Chrome's preferences show it inactive for them, and no Chrome policy is installed.
- **No Mac marker.** A synced page is indistinguishable from one visited here. Launchy doesn't read the visit's origin, and a profile is named differently on each Mac.
- **Synced pages count as this Mac's own.** They go to TypeSafe whenever this Mac's filter is TypeSafe (decision 1 in the problem has no say), and this Mac fetches their descriptions from the sites itself.
- **Deletions follow Chrome, but the archive doesn't.** Chrome syncs history deletions along with history (its deletion type is active beside history on the synced profile), yet Launchy's archive keeps every page it ever read, so a deleted page stays searchable on both Macs, as today.

## User Stories

1. As a user, I want pages from my work profile on the desktop to be searchable on my laptop without waiting for a Launchy change.
2. As a user, I want my other devices' pages searchable too, for accounts that sync.

## Implementation Decisions

- None in Launchy. A line in the user-facing notes, if wanted: Launchy searches whatever Chrome's History holds, synced visits included.

## Testing Decisions

- After turning it on for the work account on both Macs, count the visits marked as synced in that profile's History on the Air, and the archive's URLs from that profile that are new since, the way the problem measured them. Search on the Air for a page visited only on the Studio's work profile after the change.

## Out of Scope

- Reading Chrome's synced-visit markers to badge synced pages with their device. That would be a small follow-up, but the device ids are Chrome's, not Launchy's peers.

## Further Notes

- This option and option 01 combine without conflict. Option 01 merges by URL, so synced pages and pulled pages become one result.
