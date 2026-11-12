---
problem: two-browser-panes
title: "As option 02, but WebKit stays for good as the page pane's fallback when Chromium can't run"
summary: Option 02's steps 1 to 8, with step 9 left out. One Browser tile, drawn by Chromium wherever it can run; WebKit draws a page only when the framework is missing, the switch is off, or the engine failed to start in this process. Pages never go blank, at the price of keeping every page behaviour in both engines for as long as the fallback lives.
status: proposed
---

## Solution

Option 02 up to its step 8, and no step 9. The user sees one Browser tile; Chromium draws its pages whenever it can run, and WebKit stands in, silently but for `pane_read`'s note, when it can't: a build without the framework, the Settings switch off, or an engine that failed to start in this process (a page showing the failure moves to WebKit at its Reload).

## Trade-offs

- **For:** a page pane is never blank, whatever happens to the engine or the framework, and an engine that fails at start costs the user nothing until the next restart. The switch stays as a way to take Chromium out without a new build.
- **Against:** the code keeps two browsers, which the user's decision of 2026-11-12 set out to end. Every page behaviour (titles, addresses, failures and retries, proxied pages, app panes, dialogs, new windows, downloads) lives in both engines, and a change to one is owed to the other or the two drift. A page behaves differently by engine: a WebKit page can't be driven, and the user can't see which engine a page got. Resources keeps both sets of rows.

## User Stories

As in option 02. Story 6 holds in both engines for good: a fallback page tells a session it can't be driven.

## Implementation Decisions

Option 02's sections for steps 1 to 8. The switch is permanent, and stays in Settings › Experimental only while Chromium is experimental; after that it moves to the Browser pane's settings, or goes and the fallback answers only a missing framework or a failed start (the user's choice).

## Testing Decisions

Option 02's checks for steps 1 to 8, and once more with the switch off at the end: every page pane case in WebKit.

## Out of Scope

As in option 02, and step 9.

## Further Notes

**What it leaves broken.** Nothing for the installed app or the headless host, as in option 02. What it costs is upkeep, not breakage.

**The user's decisions** are option 02's, and whether the switch stays once Chromium is no longer experimental.
