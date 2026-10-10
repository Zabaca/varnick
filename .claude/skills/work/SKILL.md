---
name: work
description: Work link, the problem or option this session or subagent works on, shown on Varnick's Problems board. Use when starting to build an option, when working on a problem without writing its files, or to clear or show the link.
argument-hint: problem <slug> | option <slug>/<NN> | none
---

# Work link

Run `sh <base directory>/work.sh $ARGUMENTS` with the arguments as given, from the repository you work in. The script checks them against `docs/problems/` and prints one marker line; Varnick's hook records it for whoever ran the command, so a subagent sets its own link and the session's stays.

- `option <slug>/<NN>`: you build that option. On a branch other than main it also ties the branch to the option, which keeps the option in Building until the branch is merged.
- `problem <slug>`: you work on the problem as a whole.
- `none`: no link.
- no arguments: shows the records and the recent log.

Report the script's output. A failure names what is wrong (an unknown slug, no such option); fix the argument and run it again.

Writing under a problem's folders links you by itself: `docs/agents/issue-tracker.md` › "Work links" has the rules.
