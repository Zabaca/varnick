---
problem: pane-kinds-are-built-in
title: A project manifest that extends every Claude pane
summary: A manifest in the project names directories and system-prompt text that Launchy adds to every Claude pane started there, so a tool like Scratch can tell Claude about itself the way Launchy's built-in Scratch does today.
status: rejected
reason: It moves Scratch's per-session cost from every folder to every pane of a project, but keeps it on sessions that never use the tool. Launchy would have to merge flags from manifests into the claude command line, which is where quoting and argument order break. A skill gives Claude the same guidance only when it is needed, and a folder inside the project needs no extra directory.
---

## Solution

A project file lists, per tool, directories to pass with `--add-dir` and text to pass with `--append-system-prompt`. Launchy reads it when starting a Claude pane in that project and adds both to the command line. The tool itself still runs as in option 01, or is started by Launchy when a watched file appears.

## Trade-offs

- **Close to today's Scratch.** Claude knows about the tool from its first turn, and a variant could reopen a pane when a watched file appears.
- **Every session in the project pays,** whether or not the tool's pane is ever opened.
- **Launchy builds claude's command line from project files.** Several manifests' flags have to be merged and ordered (`--add-dir` takes several values), and a resumed session has to be started with the same ones.
- **A watched file that opens a pane** is a Launchy API in all but name: an app describing behaviour that Launchy carries out.
- **Project only.** A user-wide tool would need the same file in every repo.

## User Stories

1. As an app author, I want Claude told about my app in every session in my project, so that it never needs to be asked.

## Implementation Decisions

- Not taken further.

## Testing Decisions

- Not taken further.

## Out of Scope

- Not taken further.

## Further Notes

- Option 01 uses a project skill instead, and keeps the scratch area inside the project so no `--add-dir` is needed.
