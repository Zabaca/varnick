---
problem: prompts-cant-run-on-a-schedule
title: Automations are files the user arms, so a Claude session can write one
summary: Option 01's firing, runs, notices and limits, but an automation is defined in a markdown file, not in a list Settings owns. Its frontmatter holds the cadence, host, folder, agent, permission choice and allowed tools, and its body is the prompt. Files live in an automations folder beside a project's custom apps folder, or in the user's own automations folder. Varnick finds them as it finds custom apps (ADR 0002's "comes from disk"). Nothing in a file fires until the user arms it in Settings › Automations, and arming pins the file's contents: any edit disarms it until it is armed again. A Claude session makes or changes an automation by writing the file, with no new tool, and the user sees "new, not armed" in Settings and on the board's Runs tab. Proposed as a later way in on top of option 01's Settings editor, not in place of it.
status: proposed
---

## Solution

- **The file.** An automation file is markdown:
  - its frontmatter holds the name, cadence (option 01's presets, written as words such as `daily 09:00` or `every 2 hours`), host, folder, agent, permission choice, allowed tools and working limit;
  - the body is the prompt, given to Claude as written.
- **Where Varnick looks:** in each project's automations folder, beside its custom apps folder, and in the user's own automations folder in Varnick's support folder. It reads them as it reads custom apps, again when Settings › Automations opens and at each minute check.
- **Which host runs it.** The `host` field names the host. A file is fired only by the host it names, and only from that host's own copy of the file: a headless host reads the projects in its own project folders. A project checked out on both a Mac and the headless host therefore holds one file that one host runs, whichever copy the user arms.
- **Arming.** A file is found, not trusted. Settings › Automations lists every file found, with its host and next slot, and nothing fires until the user arms it there. Arming records the file's path and a digest of its contents, on the host that runs it (option 01's list, now a list of armed files). A file whose digest changes is disarmed, and the list says "changed since you armed it". So a session's edit, a pulled branch or a teammate's commit can't change what runs unattended until the user looks.
- **Firing, runs, notices, limits, overlap and permissions** are option 01's (or option 02's, if that is the run chosen).

## Trade-offs

- **A Claude session makes automations with no new tool.** "Check this repo's open PRs every morning and notify me" ends with Claude writing the file, and the user arms it.
- **Automations travel with the project.** They are versioned, reviewable in a diff, and the same on every checkout, like custom apps (ADR 0005) and agents (ADR 0002).
- **Arming is the consent.** A file alone never runs. The digest pin is what makes that true when files change behind the user's back, and it costs a re-arm after every edit, the user's own included.
- **A file in a project is committed, and may be published.** This repo is public, so its prompts would be published. The user's own folder is the place for private ones, and the editor would have to say so.
- **Two hosts and one file** need the `host` field and per-host arming, and a project checked out under different paths on each host is two different files to arm.
- **A text file is a worse editor than a form** for a cadence, a folder and a permission choice. Mistakes show as a file Settings can't read, listed with the reason, and nothing fires.
- **More to find and check:** a scan of every project's folder, a digest per armed file, and the reasons a file is unreadable or disarmed.

## User Stories

1. As the user, I want to ask Claude to set up an automation and then arm it with one click, so that I don't fill in a form.
2. As the user, I want a project's automations kept in the project, so that they are versioned and reviewable.
3. As the user, I want nothing to run unattended that I haven't armed as it now reads, so that an edit or a pulled branch can't change a run behind my back.
4. As the user, I want a private automation kept out of the project, in my own folder.

## Implementation Decisions

- **One reader of an automation file** in the shared package, which both hosts use. It gives a value, or the reason it can't be read: missing fields, an unknown preset, a host it doesn't know.
- **The armed list** stores, per armed file: its path, its digest, the last slot it fired for, and its runs. It replaces option 01's list of automations.
- **Settings › Automations** lists found files with Arm or Disarm, and the reason for any that can't be armed. It also offers New, which writes a file in the user's folder from option 01's form, so the form isn't lost.
- **A file that leaves** (deleted, renamed, the project removed) is disarmed and its runs are kept.

## Testing Decisions

- **The reader** gets a table of good and bad files, checked by a make target like option 01's slot check.
- **By hand:** a session writes a file, and it shows as not armed. Arming it makes it fire. Editing one word disarms it. A pulled change to an armed file disarms it.

## Out of Scope

- Option 01's list.
- Automations in a project's committed `CLAUDE.md` or settings.
- Arming from the phone.

## Further Notes

- **The other way a session could make an automation** is a `propose` tool on Varnick's MCP server, recorded by a PostToolUse hook into the pane's folder as `notify` is. Varnick would then show a prefilled editor to save from (option 01's later step). That keeps Settings the one store and adds no file format, but the automation isn't in the project. The two ways can both exist.
- **Open questions:**
  1. Files, a propose tool, or both, for a session to make an automation? Recommendation: the propose tool first, since it keeps one store and private prompts out of repos. Files later, if the user wants automations kept with projects.
  2. Should a project's file be armable on a host other than one with that checkout? Recommendation: no. A host runs only the files it can read itself.
