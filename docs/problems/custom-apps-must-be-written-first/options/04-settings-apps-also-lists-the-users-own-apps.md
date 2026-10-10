---
problem: custom-apps-must-be-written-first
title: Settings › Apps also lists the user's own apps, with switches
summary: Not recommended now; an addition to option 01, not a rival. Below the catalog, Settings › Apps lists the apps in `~/.varnick/custom-apps/` that Varnick didn't install, each with a switch that hides it from the picker without deleting it. People see their own apps where they see the catalog's. But hiding an app means a new rule in the loader and restore, and a list kept in UserDefaults, for a folder the user can already edit. A project's apps can't be listed, since Settings has no project. Option 01's last line (make your own, and show the folder in Finder) gives most of the discoverability for none of that. Rough effort is a day and a half on top of option 01.
status: proposed
---

## Solution

As option 01, plus a second group in Settings › Apps, "Your apps": every folder in `~/.varnick/custom-apps/` without Varnick's marker, with its icon, name, `description` if any, and its folder. Each has a switch, on by default. Off hides the app from the picker in every project, and leaves its folder alone. The names switched off are kept in UserDefaults.

## Trade-offs

- **One place for every app a person has,** which helps people who forget what they made.
- **Hiding without deleting,** useful for an app kept for later.
- **A new rule in discovery.** The loader and restore skip hidden names, and a restored pane of a hidden app closes. ADR 0005's contract (the folder is the app) gains an exception, and the `custom-apps` skill must say it.
- **A UserDefaults list** that outlives a renamed or deleted folder.
- **Project apps are left out.** Settings has no project, so the list shows only part of what the picker can show.

## User Stories

1. As a person with apps of my own, I want to see them listed beside the catalog's.
2. As that person, I want to hide an app from the picker without deleting it.

## Implementation Decisions

- **The list:** read from the user's apps folder each time the section shows, leaving out marked folders.
- **The switch:** a Settings property holding the hidden names. The loader skips them in the user's group only, and restore treats a hidden app as gone.
- **Docs:** the `custom-apps` skill and the guide say how to hide an app, and that a hidden app's panes close at the next launch.

## Testing Decisions

- The loader with hidden names, restore of a hidden app's pane, and a hand test of the group.
- **Rough effort,** a day and a half on top of option 01.

## Out of Scope

- Listing project apps.

## Further Notes

Recommended later, if at all: once people have several apps of their own and ask to hide some. Until then, option 01's line with Show in Finder points people at their own apps without changing how apps are found.
