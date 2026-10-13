# A tab lives on one host, which keeps its layout, panes and mark, and other devices view or take over the tab whole

Amends [ADR 0007](0007-varnick-peers-reach-each-other-over-ssh.md) (sessions over SSH, one at a time), [ADR 0009](0009-a-headless-host-runs-varnicks-relay-alone.md) (the headless host's flat records) and [ADR 0011](0011-each-host-serves-the-phone-page-behind-tailscale-serve.md) (the Phone page's sessions), and replaces the last bullet of [ADR 0032](0032-a-tabs-done-mark-belongs-to-its-host-and-completed-lists-tabs.md), which kept another machine's tab to its Claude panes in this Mac's layout and refused to split it. The user works in tabs; a Claude session is one kind of pane in one. The problem and its option are in `docs/problems/work-is-tracked-by-session-not-tab/` (option 03).

The rule is across machines and the protocol encodes it (version 24), so it is hard to undo:
- **A tab is hosted by one machine,** its host, which keeps its layout, its panes of every kind, its name and its mark. Every other Mac and device sees it from the host's `tabs` listing and shows it in the host's layout, or takes it over whole. A tab here that shows another machine's is saved with its host and asks the host again every few seconds while it shows, and when it is shown.
- **`tabs` replaces `sessions`.** It lists each open tab with its layout, its mark, who is in control and a pane per kind (`PeerTab`, `PeerPane`, `PeerLayout`): a Claude pane with its conversation, agent, turn and work links; a terminal; a web pane's address; an app's name and port; a file's path; the Transcript. The relay answers it from the saved tabs and zmx, so it works with Varnick not running. A pane whose zmx session doesn't run is listed as not running. Option 04 adds a web or app pane's proxied address and the reason one can't be proxied, as optional fields.
- **Control is the tab's.** It is the `varnick-control` label on the zmx sessions of the tab's Claude and terminal panes, the same on each. `take` relabels every running pane of a tab for the asker and then detaches their clients, in that order, answered by the relay alone; the asker then attaches each pane without `take`. `end` naming a tab ends it if every running pane's origin names the asker, else releases every pane. A tab with no Claude or terminal pane has no control, and only its host changes it.
- **Only the machine in control changes the layout,** and the host checks it. A split is a `start` naming the tab, the pane split and the axis, of kind Claude or terminal: the host starts the new pane in the split pane's folder, in that place, with the tab's origin. A divider or a rename is `arrange`, which the host takes only if it holds the same panes, re-placed or resized. A pane that has no zmx session of its own (a page, a file) is closed by `end` naming the tab and the pane.
- **Terminals are reachable.** A terminal pane's client exiting while its zmx session runs, labelled for another machine, leaves the pane on its card as a Claude pane does; before this it closed the pane and killed the session. A Mac runs a terminal in zmx only while Keep sessions running is on, so with it off the host lists the terminal as not running and the card offers Start. The headless host starts terminals (`start` with the terminal kind) and keeps tabs of several panes.
- **Each pane is what its kind allows from afar:** a Claude or terminal pane shows its live screen on a card; a file pane shows the file, read by the host's `file` request (capped at 1 MB, only text, only inside the tab's folders); a web pane at an outside address loads; the Transcript stays on its Mac; an app and a web pane at a local address say that they run on the host, until option 04.
- **Reopening a closed tab on another machine is one `reopen`.** The host reopens its closed tab whole, in its layout, Claude panes resumed and terminals started fresh, every one labelled for the asker, and the tab is made for it. This replaces a `resume` per session naming the tab, which brought back only the Claude panes.
- **The phone shows a tab one pane at a time,** with a switcher between its panes. Take over takes the whole tab, and End ends it or hands it back.

## Considered Options

- **A tab spanning machines, or a pane moving between machines:** out of scope; a tab is one machine's.
- **Each viewer keeping its own layout of a host's tab:** rejected by the user (decision 2). Two layouts of one tab would have to agree, which is the ping-pong that one keeper avoids. The cost is that a layout change made elsewhere arrives in about five seconds.
- **`take` by one `attach` with take per pane:** it works, and a Mac does it for a pane that isn't shown, but it leaves a tab half taken while the panes attach one by one. One request relabels every pane before any client is detached.
- **The tab record holding the mark on a headless host:** the mark stays on the tab's session records, where `done` already writes it; the new tab record holds only the layout, the name and the origin.
- **Splitting a pane of another machine's tab on this Mac:** refused by ADR 0032 and now made the host's: the new pane starts on the host, where the tab's folders are.

## Consequences

- **A protocol bump to 24.** A Mac left on version 23 is refused, as for any bump; the headless host is upgraded from a Mac with the installer.
- **The saved file gains no key.** A tab of another machine's is a saved tab whose records carry its host, panes of every kind included; a build before this one restores it with those panes dropped or empty.
- **A layout change made elsewhere shows within about 5 s** while the tab shows, and a tab not shown is brought up to date as it is shown.
- **Taking over a tab takes all its panes.** Whoever wants one session on the phone and another on a Mac at once splits the work into two tabs.
- **Terminals are reachable only with Keep sessions running on, on a Mac.**
- **Web and app panes on the host's localhost aren't reachable until option 04.**
- **A headless host's tab record is written by `start`, `arrange` and `end`;** a tab started before tabs had layouts is its records side by side until it changes.
