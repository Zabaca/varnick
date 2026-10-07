---
problem: orchestration-lives-in-one-session
title: Keep orchestrating in Claude sessions and fix the worst pains cheaply
summary: No engine. The lead session and the Workflow tool keep running the work. Reusable workflow scripts are saved in the repo, and reviews run as saved Workflow runs rather than teammates; tickets and specs are written to the main checkout, never a worktree; merge commits name the problem, option and ticket they ship; a drift check lists what's out of step; and the orchestrator agent's rules cover statuses at merge, resuming a crashed run, and a shared blast-radius list.
status: proposed
---

## Solution

Six changes, each aimed at a measured failure:

- **Saved workflows.** The scripts used more than once (review, verify and fix a ticket; build a ticket with a nested review) live in the repo instead of each lead session's folder, where the same script is copied once per run today. A lead runs them by path with the ticket as arguments.
- **Reviews run as saved Workflow runs,** not as Agent-tool teammates, so a crash leaves a journal to resume from. Both measured crashes killed teammates.
- **Tickets and specs in the main checkout.** Builders and planners are given the main checkout's `.scratch` path and write tickets and specs there, never in a worktree's copy, so removing a worktree deletes nothing.
- **Links in commit messages.** Every merge message names the problem slug, the option number and the tickets it ships. A link is then a `git log --grep` away instead of a guess from shared words.
- **A drift check.** A small script, or the product-board prototype made into a custom app, that reads problems, options, tickets, worktrees and merges and lists drift: an option still accepted after its merge, a merge naming no problem or ticket, a worktree with no branch work, a ticket only in a worktree. The lead runs it after every merge.
- **Orchestrator rules.**
  - At a merge the user approved, the lead updates the option's status (and asks whether to close the problem) in the same step.
  - After a crash, the dead session is resumed and the run relaunched from its journal, as the tool offers, so finished agents return cached.
  - Blast-radius rules live in one shared document every script points to, instead of a paragraph pasted into each, and the temporary-HOME rule says `CFFIXED_USER_HOME` too.

## Trade-offs

- **Hours of work, not weeks.** No new process, language or store, and nothing to keep running.
- **Each fix targets a measured failure:** the lost ticket and spec, the 12 drift flags, the merges that could only be guessed, the paragraph of constraints repeated in every prompt, the teammates no crash could resume.
- **Nothing to migrate.** Today's scripts keep working, and every fix here (main-checkout tickets, linked merges, a drift list) is still useful if option 01 comes later.
- **Rides on Anthropic's tool,** which improves without work here.
- **Durability goes only as far as the tool's journal.** A crashed run resumes with finished agents cached once someone resumes its session. Agents in flight start over, and nothing notices a dead lead while the user is away: after the 00:21 crash the work stood still for ten hours.
- **Visibility is unchanged.** Agents still run inside the lead's process.
- **Gates are unchanged.** A decision still ends a run, and the lead still carries what was decided.
- **The rules are prose an agent has to follow,** which is how statuses drifted in the first place. The drift check catches misses; it doesn't prevent them.
- **The plan still lives in one session.** When the lead ends, so does the knowledge of what was in flight, apart from what the drift check can read back from files and git.

## User Stories

1. As the user, I want the review-verify-fix script saved in the repo, so that each lead runs the same tested script instead of a copy.
2. As the user, I want tickets and specs to survive removing a worktree, so that merged work keeps its spec.
3. As the user, I want each merge to name the problem, option and tickets it ships, so that the board can follow links instead of guessing.
4. As the user, I want a drift list after each merge, so that statuses stay true without my auditing them.
5. As the user, I want a crashed run resumed from its journal, so that only its unfinished agents run again.
6. As the user, I want one blast-radius list every script points to, so that a fix to a rule reaches every agent.

## Implementation Decisions

- Saved scripts take every run-specific value as an argument: ticket, branch, worktree, base commit.
- The main checkout's `.scratch` path is given to agents as an absolute path in their brief. The builder agent's definition says where tickets and specs go.
- The merge message format is defined once, in the orchestrator agent, and the drift check parses it.
- The drift check reads only files and git and changes nothing.
- The issue-tracker doc gains the merge message format and the rule that tickets and specs live in the main checkout.

## Testing Decisions

- The drift check is tried on merges made after the message format exists, plus one planted case of each kind of drift. The board's 12 flags aren't its target: some came from the board's guessing.
- A saved script is tried once by hand on a real ticket.

## Out of Scope

- Durability beyond the tool's journal, visibility and gates, which need options 01 or 04.

## Further Notes

- Unverified: whether Claude Code reads a project folder of saved workflow scripts by itself. If it doesn't, the lead passes the path; the run records already show each script's path.
- These fixes overlap with option 01's step 1 and can come before it, so choosing this option now doesn't rule option 01 out.
- Open questions:
  1. Is this enough on its own for now, with option 01 judged again after a few more features?
  2. Should statuses past `proposed` be updated by the lead at merge, given they belong to the user? Recommendation: yes, at a merge the user approved, since the approval is the user's decision.
  3. Board or script for the drift check? Recommendation: the script first; the board when there is a custom app to host it.
  4. How does a dead lead reach the user when they're away? Option 01's open question 7 asks the same.
