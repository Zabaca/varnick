---
problem: name-taken-by-another-launcher
title: Keep running sessions alive across the rename, by having Varnick read the old names until the last old session ends
summary: Option 01, except that no session ends at the cutover. Varnick adopts every zmx session named the old way and keeps reading the old names for as long as one of them runs. That covers pane sessions, their labels, the hook files their baked-in hooks write, the work marker, and the Phone page's session links. A link left at the old support folder's name lets those hooks keep writing. A session drops the old names only when it is restarted or closed, and a cleanup ticket removes the dual reading once none is left. In-flight turns, background shells and teammates survive. The price is a second name across most of where-it-breaks' rules for zmx, hooks and peers. The user still visits each machine, grants permissions and restarts the app.
status: rejected
reason: The user chose option 01 on 2026-10-09. Restored panes resume their conversations, and the visit for grants needs a restart anyway. Keeping old sessions alive would give every rule that fails silently a second name, for as long as one old session runs.
---

## Solution

Option 01's measurement, rename, GitHub renames, guards and runbooks, with its first-launch "end the old sessions" step replaced by adoption:

- **Pane sessions.** A pane record keeps the zmx name and label scheme it was created under, and only a new session gets the new ones. The launch sweep, the restore, the relay's session list, the take-over and release labels, and the control checks all accept either scheme.
- **The support folder** is moved, and a link is left at its old name, as the `scratch` link was left when `scratch` became `panes`. That is the existing `PaneFolder.migrateOldScratchFolder(in:)` shape. Running hooks keep writing through it.
- **Hook files.** The turn, stop, session and conversations files are read under both names, the newer one winning. The work hook's marker is accepted in both spellings. The branch-tie key is read in both and written in the new one.
- **Peers.** Both protocol versions can't speak to each other, so the bump stays and every machine still crosses in one sitting. Sessions on the Ryzen are adopted the same way. Its install root moves with a link left at the old name.
- **Phone page.** The page's session-name pattern accepts both prefixes. The old `launchy-phone-page` session is still ended and replaced, since its files are in a snapshot that the move takes away.
- **Restart drains them.** A pane's Restart starts claude under the new names and hooks, as it does for any hook change today, so sessions move to the new names one by one.
- **Cleanup** waits until no zmx session on any machine has the old prefix. Only then are the link and every dual reading removed.

## Trade-offs

- **Nothing in flight is lost** at the cutover: turns, background shells and teammates keep running.
- **Every rule gets a second name.** Each where-it-breaks rule about zmx names and labels, the turn, stop and work hooks, take-over and release, the sweep, the relay's listing and the Phone page's names gains a second spelling while old sessions run. Those are the parts that fail silently (a card stuck in Running, a session swept or never swept, two keyboards), and each must be checked both ways.
- **The old folder name stays reachable.** A link at the support folder's old name can be reached by a Launchy relay on another machine. It would read the new state through the old binary and the old settings domain. To prevent that, the relay's old link inside the folder must still be removed, and no old snapshot left in the checkout.
- **Dual reading can last indefinitely.** A session left running for weeks keeps it alive, and the cleanup can't run until the last one closes.
- **The visit still has to happen.** The user still visits every machine to grant permissions, and still restarts the app once. Option 01 asks only that the restart come at a quiet moment, and its restored panes resume their conversations.

## User Stories

Option 01's stories 1 to 3 and 5 to 13, with story 4 replaced:

4. As the user, I want the Claude sessions running at the cutover to keep running in Varnick, with their turns, shells and teammates, until I restart or close them.

## Implementation Decisions

- **Pane records:** each gets an optional field for the zmx name scheme it was created under. It is optional so existing sessions files decode (where-it-breaks › Saved state). Nil means the old scheme for a record from before the rename, and the new one for any record created after.
- **Every reader of a session's name or labels** goes through one function that knows both schemes. A new reader can't then pick one by accident.
- **Turn and work hooks:** the app reads the newer of the two files of each kind. Only sessions started by Varnick write the new ones.
- **The links** at the old support folder's name, and at the Ryzen's old install root, are removed by the cleanup ticket, never before.
- **The rest** as option 01.

## Testing Decisions

As option 01, plus every where-it-breaks check for zmx, the hooks, take-over and release, and the Phone page's terminal, run on both an old-named and a new-named session in a throwaway `ZMX_DIR`. A pane started by Launchy has to be followed through a turn, a background shell, /clear, a take-over from a peer and Done, and then the same pane after its Restart.

## Out of Scope

As option 01, less "Running sessions surviving the switch".

## Further Notes

- **Not recommended.** Restored panes already resume their conversations. The user can pick a quiet moment for the restart that grants require anyway. The cost lands on the rules that fail without an error.
- **Sibling:** the `scratch` to `panes` move, which left a link for panes still running from before it.
