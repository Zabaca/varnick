---
problem: memory-use-is-invisible
title: A custom app that shows the process table in a pane
summary: Recommended against. A custom app, built like Scratch, runs `ps` and `footprint` and draws the table in a pane. Varnick doesn't change. The reason to reject it, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

A custom app in the user's custom apps folder. Its server walks the processes with `ps` and reads footprints with `footprint` every few seconds, groups them by zmx session and by kind, and serves the table to its page in a pane.

## Trade-offs

- **No change to Varnick:** it ships by copying a folder, and can change without a build.
- **It can't name tabs.** An app is told only its own pane's id, the pane it was split from, its project and its data folder (verified in the code and the custom-apps contract). Which pane is in which tab, and what a tab is called, live in Varnick's saved state, which an app could read only behind Varnick's back. So the table would list zmx sessions by pane id, not tabs.
- **It can't read MLX's own figure,** so the app's memory can't be split into models and the rest.
- **It runs subprocesses at each refresh,** and only while its pane is open, so a pane has to be given to it.
- **It has no Close.** Closing a tab is Varnick's.
- **Attributing WebKit's processes** needs the same private macOS call as option 01, reached through Bun's FFI.

## User Stories

1. As the user, I want a table of Varnick's processes and their memory in a pane.

## Implementation Decisions

- An app in the user's custom apps folder, following the custom-apps contract. Its server shells out to `ps` and `footprint`.

## Testing Decisions

- Open it from the split picker: the table lists Varnick and the zmx sessions with their processes.

## Out of Scope

- Naming tabs, closing them, and the models' share.

## Further Notes

- **Reason, if rejected:** it can't say which tab a process belongs to, which is what the user needs in order to choose what to close, and it can't split the app's memory.
