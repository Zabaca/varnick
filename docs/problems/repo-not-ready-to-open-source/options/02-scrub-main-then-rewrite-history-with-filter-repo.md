---
problem: repo-not-ready-to-open-source
title: Scrub main in ordinary tickets, then keep the history and rewrite it with git filter-repo
summary: Option 01's phase 1, unchanged. Then, instead of one squashed commit, main's 295 commits are kept and rewritten in a fresh clone with git filter-repo. Wholly private paths are removed from every commit, and the scrub list and the category patterns are replaced in every file version and commit message with the placeholders the tree uses. Both author names and the personal address map to the identity the user chooses, and one commit on top translates the docs' commit references. The rewritten history is checked commit by commit before the same cutover as option 01. Public history keeps blame, bisect and the design trail. In exchange it publishes every old version of every kept doc, and the process log in the commit messages.
status: rejected
reason: The user chose option 01 on 2026-10-07. A list-driven history rewrite only catches what's listed, so old commit messages and old versions of docs would still publish; the full history is kept in a local backup instead.
---

## Solution

Everything in option 01 except its history step:

- the defaults and code fixes;
- the scrub and its list;
- the proxy's docs;
- the public-repo rule;
- the new files;
- the order with peers-upgraded-by-hand option 03;
- the cutover.

The history step differs. It still begins with option 01's preconditions and backup. Then, in a fresh clone of origin/main alone, git filter-repo rewrites main's whole history in one run:

- **Paths removed from every commit.** These are the paths that are private through and through: the proxy's problem folder (already deleted at the tip by the scrub) and the four early warehouse sync scripts. The old names of ADRs and options that held the same data go too, where they did.
- **Strings replaced in every version of every file.** Each entry on the scrub list maps to the placeholder the tree now uses, so that an old version reads like the new one. Pattern lines cover the categories: email addresses other than allowed public ones, names under `.ts.net`, tailnet IPs, Tailscale IDs, home paths, and `user@host` forms of the user's machines.
- **Commit messages.** The same replacements, which covers the proxy's name and the hosts in the few messages that have them.
- **Authors.** Both author names and the personal address map to the identity the user chooses, for example a GitHub noreply address.

filter-repo translates references to old commits inside commit messages (inferred from its manual). After the run, one more commit on top translates the docs' short SHAs, using filter-repo's map from old commit to new.

- A commit on top changes no earlier SHA.
- References to commits that were never on main, such as worktree branches, stay dead.

**Checks on the rewritten history:**

- **Files:** in every blob of every commit, the category patterns and the scrub list find nothing, and no removed path appears in any commit.
- **Messages and authors:** every commit message is clean, and every author and committer is the chosen identity.
- **The tip:** its tree equals main's, apart from the translation commit, and `make build` and `bun test` pass there.
- **The root:** the root commit's SHA changed. Git then refuses to merge any pre-rewrite branch into the new main by accident.

The cutover is option 01's, step for step.

## Trade-offs

- **Public history is kept.** Outsiders get blame, bisect and the reasoning in 295 detailed commit messages. Commit references in messages and docs keep working on the public repository.
- **Completeness rests on the list and the patterns.**
  - Only what the scrub list names, or a pattern matches, is replaced in old versions.
  - Names that no pattern catches, such as client names and Chrome profile names, must all be on the list, including spellings that only an old version used.
  - Old versions also keep details that aren't identifiers: per-profile visit figures, host specs, the user's usage numbers. The user accepts these as not sensitive, but they are published.
- **The commit messages publish the process log:** the user's decisions, reviews, fixes and plans, message by message.
- **There is far more to check:** 295 commits and every version of 220 files, against one tree in option 01.
- **It needs git filter-repo,** which isn't installed here (verified). It also refuses to run outside a fresh clone without being forced, and rewrites every ref the clone holds (inferred from its manual). That is why the clone holds main alone.
- **The root commit's SHA has to change** for git to refuse old merges. It will, because the author mapping touches every commit, but the checks confirm it rather than assume it.
- **The same aftermath as option 01:**
  - every machine is reset once;
  - stranded branches are rebased or deleted;
  - old SHAs stay reachable on GitHub for a while.

## User Stories

Option 01's, with these in place of its eleventh:

1. As the author, I want the published history to keep every commit, with my personal address and every identifier replaced in every version and message, so that outsiders can use blame and bisect and follow the design without seeing my data.
2. As a reader of the docs, I want the commits they cite to open on GitHub, so that "code read at" references still lead somewhere.

## Implementation Decisions

- **Phase 1** is option 01's.
- **The removed paths, listed:**
  - the proxy's problem folder;
  - the four early warehouse sync scripts;
  - the older ADR and option names, where an old version holds the data the scrub removed from their successors.

  Everything else is kept and has its strings replaced.
- **The replacement file** is the scrub list plus the pattern lines. It lives in the problem's scratch folder, local and never committed, like the list itself.
- **Allowed public addresses.** Claude's co-author address in the message trailers, and any service's public address, are listed as allowed so that the patterns leave them.
- **The author mapping** covers author and committer, both names and the one address.
- **Doc references.** The translation commit edits only short SHAs that the commit map names, and leaves everything else in the docs as it is.
- **The history step's checks** are those above. The scrub's own checks and the cutover are option 01's.

## Testing Decisions

Option 01's for phase 1 and the cutover, plus:

- **A trial run first.** filter-repo is run once on a throwaway copy, and the check over every blob and message is run on the result before the real run.
- **Translated references.** Each SHA cited in the docs opens a commit in the rewritten history, except those that were never on main, which are listed.
- **Unrelated histories.** A merge of a pre-rewrite branch into the rewritten main is refused unrelated, in a throwaway clone.

## Out of Scope

Option 01's, except rewriting the docs' commit references, which this option does.

## Further Notes

- **Open for the user:** option 01's questions, plus the identity the history maps to.
- **Rewriting the clones too.** Rewriting the user's other local branches in the same run, so that they carry over without a rebase, was considered and left out. Those branches hold real-data prototype captures and work in flight, and a single-branch clone keeps the run to what is published.
- **Tickets.** The sketch is option 01's, with ticket 12 replaced: the preconditions, backup and tag, then the fresh single-branch clone, the trial run, the filter-repo run, the translation commit and the history checks. Nothing is pushed.
