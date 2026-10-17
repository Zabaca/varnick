---
name: work
description: Work link, the problem or option this session or subagent works on, shown on Varnick's Problems board. Use when starting to build an option, when working on a problem without writing its files, or to clear or show the link.
argument-hint: problem <slug> | option <slug>/<NN> | none
---

# Work link

1. Run `sh <base directory>/work.sh $ARGUMENTS` with the arguments as given, from the repository you work in. The script checks them against `docs/problems/` and prints a marker line; Varnick's hook records it for whoever ran the command, so a subagent sets its own link and the session's stays. A failure names what is wrong (an unknown slug, no such option): fix the argument and run it again.
2. Run the command on the first step's last line. It checks that the hook recorded the link, so the link is made when it prints "Linked to …" (or "Work link cleared.") and exits 0. If it fails, it names the cause, usually a session whose claude was started without the work hooks: tell the user it needs a restart, and carry on with the work. For an option, the branch is tied either way, and that keeps the option in Building.

Report the second command's output.

- `option <slug>/<NN>`: you build that option. On a branch other than main it also ties the branch to the option, which keeps the option in Building until the branch is merged.
- `problem <slug>`: you work on the problem as a whole.
- `none`: no link.
- no arguments: shows the records and the recent log (one command).

Writing under a problem's folders links you by itself: `docs/agents/issue-tracker.md` › "Work links" has the rules.
