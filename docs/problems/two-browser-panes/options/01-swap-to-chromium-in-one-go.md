---
problem: two-browser-panes
title: "Every page pane moves to Chromium in one merge, WebKit's page path deleted in the same one, and Varnick.app carries the framework from then on"
summary: One branch does all of option 02's work at once and merges it whole. From that merge Chromium is the only engine for page panes, the framework is required by every build and by Varnick.app, and nothing stands in when it is missing or fails to start. Simplest in the end state; the riskiest to merge, and no release can be cut until the helper notarizes.
status: proposed
---

## Solution

The same end state as option 02 after its step 9, reached in a single merge: the engine starts when a page wants it, with no restart; Browser is Chromium for every page, custom app, Scratch page and proxied page; CDP is as the user chooses; WebKit's logins are carried over once; Varnick answers dialogs, the context menu, new windows and downloads; Resources and screen reading count Chromium; Varnick.app carries the framework; WebKit's page path, the Chromium tile and the restart message are gone. What each piece does, and the choices that are the user's, are option 02's; this option differs only in how it lands.

- **The framework is required.** A build without it fails rather than running without a browser, and Varnick.app is notarized with it from the same merge.
- **No fallback.** A page pane is Chromium or nothing: when the framework is missing or the engine fails to start, the pane says so and needs a restart.
- **No switch.** Nothing turns Chromium off; it is not experimental from the merge on.

## Trade-offs

- **For:** one browser in the code from the first merge; nothing is written twice; no switch, no fallback state, no `pane_read` text for an undrivable page.
- **Against:** the whole change is reviewed and checked by hand at once, and a fault in the start without a restart, which no one has seen in Varnick yet, breaks every page pane, Scratch and custom apps included, until it is fixed. A start that fails leaves every page blank until a restart, with nothing to fall back on. The release waits on the helper notarizing under the hardened runtime, which is untried: until it does, no Varnick.app can be cut from main. The user's logins move into Chromium in the same merge as the CDP change, so a mistake there exposes them at once.

## User Stories

As in option 02, but for story 10 (the installed app works only from the release that carries the framework) and story 11 (there is no switch).

## Implementation Decisions

- Option 02's sections hold for what each piece does: the engine's start, what carries over, what a page asks of its pane, CDP, logins and the profile, the framework in Varnick.app, and what is deleted.
- **Which engine a page gets:** always Chromium. A saved `chromium` mark means nothing; no new field.
- **Order inside the branch** (one merge, so for review only): the start, CDP, the page's asks, the logins, Browser panes, apps and proxied pages, Resources and screen reading, the framework in the app, the deletions.

## Testing Decisions

Every hand check of option 02's steps 1 to 9, all after one restart on the merged result, then on a notarized Varnick.app before the next release.

## Out of Scope

As in option 02.

## Further Notes

**What it leaves broken.** For an installed app: nothing changes until a release carries the merge; that release can't be made until the helper notarizes, so releases stop until then. If a release went out without the framework, it would have no browser at all: every page pane, custom app and Scratch would show the engine's failure. The headless host is unchanged: it has no browser and lists no page pane. A Mac whose engine fails to start has no pages until a restart.

**The user's decisions** are option 02's, less the switch and the fallback.
