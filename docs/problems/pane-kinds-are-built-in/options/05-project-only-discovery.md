---
problem: pane-kinds-are-built-in
title: Find apps in the project only
summary: Launchy reads apps only from the focused pane's project, `.launchy/custom-apps/`, with no folder in the user's home.
status: rejected
reason: A tool the user wants in every project, Scratch included, would have to be copied into every repo and kept in step. Agents are read from the project and from the user's folder (ADR 0002), and apps should behave the same way, with the project's copy winning a name clash.
---

## Solution

As option 01, but only `<project>/.launchy/custom-apps/` is read. A pane outside any repo offers no apps.

## Trade-offs

- **One place to look,** and an app always travels with its repo.
- **Personal tools need copying** into each project, or a link per repo.
- **Panes outside a repo get nothing,** including the default folder when it isn't a repo.
- **Unlike agents,** which come from both places.

## User Stories

1. As a project maintainer, I want the apps a project offers to be exactly those committed in it, so that everyone working on it sees the same picker.

## Implementation Decisions

- Not taken further.

## Testing Decisions

- Not taken further.

## Out of Scope

- Not taken further.

## Further Notes

- In option 01 a project's app hides the user's app of the same name, so a project still decides what its own apps do.
