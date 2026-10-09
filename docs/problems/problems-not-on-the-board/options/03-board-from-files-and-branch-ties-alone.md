---
problem: problems-not-on-the-board
title: The Problems tab from the files and branch ties alone, with no session links yet
summary: Option 01's Problems tab, column rule and shipped rule, with no work records, no hooks and no chips. Building is an `in-progress` option, or one whose tied branch has commits not on main; the builder ties its branch in git config with a one-line step of its own. The claude command line and the peer protocol don't change, so nothing needs a restart but this Mac's own build. Options 02 and 01 add the links on top without changing it. Rough effort is a day and a half, in one branch.
status: abandoned
reason: Built as option 01's first branch (merge 6b80690), and option 01 shipped on top of it.
---

## Solution

**The Problems tab** is option 01's: the same columns, rule, cards, evidence, Show evidence, keys and projects, with no chips.

**Building** is an option that isn't shipped, rejected or abandoned and is `in-progress`, or whose tied branch has commits that aren't on main.

**Tying a branch.** The builder's first step, on a branch other than main, records its option in the repository's git config for that branch, as option 01's `/work option` does. It is one git command in the builder's own steps; there is no `/work` skill yet.

**Shipped** is option 01's rule: the merge that completes an option sets `shipped` in the merge commit, and the branch's tie says which option it built.

**Evidence** is option 01's, without sessions: Building names the status or the branch and how many commits it has that main lacks.

## Trade-offs

- **The smallest step that makes the board true to the files,** and it can ship first: options 02 and 01 add chips and live links on top of the same tab and rule.
- **No hooks, no protocol change.** Only this Mac's build and restart.
- **No chips,** which the user wants on every card.
- **Building starts at the builder's first commit,** not when it starts, and a builder that runs on another Mac doesn't show here.
- **Nothing says which session a problem came out of.**

## User Stories

Option 01's stories 1 to 5, 10 and 11.

## Implementation Decisions

- Option 01's decisions for the tab, the pure model (with no links), the reads and the branch tie.
- The builder's step that ties the branch is written in its agent file, and the tie's form is written once, in the issue tracker's description of option statuses, beside the shipped rule.

## Testing Decisions

- The column rule, sorting and evidence over made-up problems, options and ties, once a test target exists.
- **By hand, after a restart:** every problem sits in the column its files say; a builder's first commit on its branch moves its problem to Building, with the branch in the evidence; the merge moves it to Shipped, with the status set in the merge commit; switching tabs and closing the board work with the keys.

## Out of Scope

- Work records, hooks, `/work`, chips, the SessionStart line, peers and history: options 02 and 01.
- Everything option 01 leaves out.

## Further Notes

- This is the first branch of options 01 and 02 as well, so accepting either starts here.
