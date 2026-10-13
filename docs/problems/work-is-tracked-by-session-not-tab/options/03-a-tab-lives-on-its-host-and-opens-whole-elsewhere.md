---
problem: work-is-tracked-by-session-not-tab
title: A tab lives on one host and opens whole on other devices, its terminals and files included
summary: On top of options 01 and 02. The machine that runs a tab keeps its layout, its panes and its mark, and lists its open tabs whole to other machines and devices with a new `tabs` request (protocol 24). Another Mac opens a host's tab in the host's layout. Claude and terminal panes show on cards until Take over, which now takes the whole tab. File panes are read over SSH, the Transcript stays on its own Mac, and web and app panes on a local address wait for option 04. Only the machine in control of a tab changes its layout. A split starts the new pane on the tab's host. The host's terminals survive another machine attaching to them, and the headless host keeps tabs of several panes, terminals included. The phone shows a tab's panes one at a time.
status: accepted
---

## Solution

**The host keeps the tab.** A tab is the host's. The host keeps:
- its layout;
- its panes, of every kind;
- its name;
- its mark (option 01);
- who is in control of it.

Every other Mac and device sees it from the host's own listing. `tabs` replaces `sessions`. It lists each open tab with its layout and each pane's kind and what the pane shows. Like `sessions`, the relay answers it from the saved tabs and zmx, so it works with Varnick not running.

**Another Mac opens the tab whole,** in the host's layout. Each pane is what its kind allows from afar:
- **Claude and terminal panes** show their live screen on a card, as a peer's session does today.
- **File panes** show the file, read from the host over SSH.
- **The Transcript** stays on the Mac it runs on, and its pane says so.
- **Web panes** on an outside address load as they are. On a local address (localhost or 127.0.0.1), and for app panes, the pane says the page runs on the host, until option 04 brings it here.

**Control is the tab's.** Take over takes every Claude and terminal pane of the tab at once. Closing the tab in control hands the whole tab back, or ends it if the host started it for this machine. That is today's rule for a session, now for a tab.

**Only the machine in control changes the layout.** It splits, closes panes, moves dividers and renames, and each change is sent to the host. A split starts the new pane on the host, in that place. The other viewers follow the host's layout at their next look, about every 5 s while the tab shows.

**Terminals become reachable.** On a Mac host, a terminal pane that another machine attaches to goes to its card and keeps running, as a Claude pane does. Today it closes and its session ends. The headless host starts terminals as well as Claude, and keeps its own tabs of several panes.

**The phone shows a tab one pane at a time,** with a switcher between them. Take over on the phone takes the whole tab.

## Trade-offs

- **The largest of the four options.**
  - It needs a new listing, control per tab, layout changes sent to the host and terminals that survive a remote attach.
  - The headless host gains tab records.
  - The phone gains a tab view.

  Each part leans on machinery that exists for sessions: labels, cards, the live screen, `start`, `end` and the 5 s follow.
- **A layout change made elsewhere arrives within about 5 s,** while the tab shows. A tab not shown is brought up to date when it is shown.
- **Taking over a tab takes all its panes.** A user who wants one session on the phone and another on the Mac at the same time can't have both in one tab: they split the work into two tabs.
- **Terminals on a Mac host are reachable only with Keep sessions running on there,** since a terminal runs in zmx only then (verified). Without it, the host lists them and says why they can't be opened.
- **Web pages on a local address, and app panes, aren't reachable until option 04.** This option ships without the proxy.
- **The Transcript never leaves its Mac** (Listening's privacy rule).
- **Protocol 24.**

## User Stories

1. As the user, I want to open a tab of another Mac or the Ryzen as it is there, with its splits and all its panes, so that the work looks the same wherever I open it.
2. As the user, I want one Take over to give me the whole tab, so that I don't take its sessions one by one.
3. As the user, I want to watch a tab another machine is in control of, every Claude and terminal pane live, without taking it.
4. As the user, I want to split a tab of another machine and get the new pane on that machine, where the tab's folders are.
5. As the user, I want to close a pane, move a divider or rename a tab I'm in control of, and have the host keep it.
6. As the user, I want a terminal on another machine, such as a dev server or a build, to be reachable, and to keep running when I take it over.
7. As the user, I want a file pane of another machine's tab to show the file.
8. As the user, I want a Transcript pane of another Mac's tab to say it stays on that Mac, not to show mine or nothing.
9. As the user, I want a web pane of another machine's tab to say the page runs there, until option 04 brings it here.
10. As the user, I want the Ryzen to keep tabs of several panes, a Claude session and a terminal side by side, like a Mac.
11. As the user, on the phone, I want to open a tab and move between its panes one at a time, and take over the whole tab with one press.
12. As the user, I want closing another machine's tab here to hand the whole tab back to it, unless that machine started it for me, in which case it ends.

## Implementation Decisions

**The `tabs` listing** (replaces `sessions`)
- **For each open tab:** its id, name, mark (option 01), the machine or device in control and its name (as `controlName` is today), and its layout.
- **For each pane in the layout:** its id, kind, folder, title, plus what its kind shows:
  - a Claude pane: its conversation, agent, turn and work links, as today's listing has them;
  - a terminal: its folder as it last reported it;
  - a web pane: its address;
  - an app pane: the app's name and port;
  - a file pane: its path;
  - the Transcript: nothing more.
- **Answered by the relay from the saved tabs and zmx alone,** like `sessions`. A pane whose zmx session doesn't run is listed as not running. A device is told no other controller's id (today's rule), and gets no work links and no marks.

**Opening a host's tab on a Mac**
- **The tab here is a view of the host's.** It has the host's id and the host's layout (option 01 gave it the id; the layout it had here is dropped). It is saved with its host, so it comes back after a restart and asks the host again.
- **Each pane by kind:**
  - **Claude and terminal:** the card, with the live screen, as opening a paired Mac's session does today; nothing attaches until Take over.
  - **File:** the file's text from a new read-only request. It is capped in size and read when the pane shows and on reload. A path outside the tab's folders, or a file over the cap, is refused.
  - **Transcript:** a card naming the Mac it runs on.
  - **Web:** an outside address (anything but localhost, 127.0.0.1 and ::1) loads here. A local one shows a card with the address and "runs on <host>" (option 04 replaces it).
  - **App:** the same card.
- **The viewer asks `tabs` of the host** while the tab shows, every 5 s, as the panes on a peer are followed today, and when it is shown. It applies the layout the host gives.

**Control by tab**
- **A tab's control is the label on its Claude and terminal panes' zmx sessions,** kept the same on each. A tab with none of those has no control, and only its host changes it.
- **Take over** (the card's button, ⇧↩) is one new request, `take`, naming the tab. The host relabels every one of its panes for the taker, then detaches their clients. The label always comes before the detach, as today. The taker then attaches each pane with `attach`, which finds the label naming it. The check after each attach runs per pane, as today, so two takers racing end with one keyboard per pane.
- **Closing the tab in control is one `end` for the tab.** The host ends the tab if its origin names the closer. Otherwise it releases every pane: the labels are cleared, the clients detached, the host's cards go live. That is today's rule, with the tab's origin in place of the session's. On the headless host, release keeps the label, as today.
- **A tab's origin is set when it is made for a machine:** a `start` that makes a new tab, or a `resume` that reopens one. A pane added to the tab later keeps the tab's origin.

**Layout changes**
- **Only the machine or device in control of a tab changes its layout** (picked, to match **In control**: only it types). A viewer's split, close, divider and rename keys are refused with "Take over to change this tab". A tab with no control is changed only on its host.
- **A split** sends `start` with the tab, the pane it splits, the side and the kind, either Claude or terminal. The host adds the new pane there, labelled for the asker. Web, file and app panes come from the host's own split picker until option 04.
- **A close of one pane** sends `end` for that pane, and the host decides as today.
- **A divider moved, or a rename,** sends a new `arrange` request with the tab's layout and name. The host takes it only if it holds the same panes, re-placed or resized. Anything that adds or removes a pane is refused.
- **The host's own changes** (its splits, closes and renames, while it is in control) go into its saved tab, and the others see them at their next ask.

**Terminals on a host**
- **A Mac host:**
  - A terminal pane's client exiting while its zmx session runs, labelled for another machine, puts the pane on its card, as a Claude pane does. Today it closes the pane and kills the session (verified).
  - The host's own terminals are attached again after a release, as its Claude panes are.
  - Terminals are listed only with Keep sessions running on. With it off, the listing says why they can't be opened.
- **The headless host:**
  - `start` gains the kind. A terminal is the account's login shell in zmx, labelled as a Claude session is, in the folder asked. It has no hooks and no turn.
  - Its records gain the tab each session is in. A new tab record holds the layout, name, mark and origin, written under the state lock by `start`, `arrange` and `end`, and never held across a wait (today's rule).
  - A record with no tab, from option 01 or earlier, is its own one-pane tab.
- **The reconcile rules** (a session gone in this boot is ended, one gone from an earlier boot is lost) apply to terminals too. A lost terminal starts fresh in its folder, since it has nothing to resume.

**The Phone page**
- **Home lists the host's tabs** (option 02 grouped them). Opening one shows its first pane, with a switcher for the rest, one pane at a time.
- **Claude and terminal panes** are today's session view: the live screen, then the terminal after Take over. The terminal cap of three per device still holds, and only the shown pane's terminal is open.
- **Other panes:** a file pane shows its text; a web or app pane shows its address, and the note that it runs on the host until option 04; the Transcript shows its note.
- **Take over takes the tab,** and a refused or raced take is told as today.
- **A new session from the phone** is still a one-pane tab.

**The protocol** goes to 24, with the Phone page's constant:
- `tabs` is new;
- `sessions` is gone;
- `start` gains the tab, the pane split, the side and the kind;
- `take` is new and names a tab, and `end` names a tab;
- `arrange` is new, and so is the file read.

## Testing Decisions

- **No test target yet.** The pure parts are where tests would go once there is one:
  - the layout check in `arrange`;
  - placing a split in a layout;
  - the headless host's tab records under start, arrange, end and reconcile;
  - the page's pane switcher.
- **Builds:** `make build`, the package's build on Linux, and `bun test` in the Phone page.
- **A copy of the relay:** checks against a copy of the relay binary on the headless host, never against the installed one.
- **By hand,** after the user restarts Varnick on each Mac and upgrades the headless host:
  - **Opening a tab.** On Mac A, a tab of a Claude pane beside a terminal running a long command. On Mac B it opens in the same layout, both panes live, unchanged.
  - **Take over.** One Take over on Mac B: both panes are typed into on Mac B, both show on cards on Mac A, and the command keeps running.
  - **A split.** A split on Mac B adds a terminal on Mac A, in that place, on both Macs within about 5 s.
  - **Closing.** Close the tab on Mac B: Mac A's tab goes live again, the command still running.
  - **A file pane** of Mac A's tab shows on Mac B. Its Transcript pane says it is on Mac A. A web pane on localhost says it runs on Mac A.
  - **The Ryzen.** A tab with a Claude pane and a terminal survives an upgrade, and after a reboot the terminal comes back fresh in its folder.
  - **The phone.** Open a tab, switch between its two panes, take over, and type into the terminal.

## Out of Scope

- Web and app panes on a local address from another machine (option 04).
- A tab spanning machines, and moving a pane between tabs or machines.
- Splits of web, file and app kinds made from another machine.
- Sharing a browser's logged-in state between machines (decision 4 keeps pixel streaming for that, later).

## Further Notes

- **An ADR once accepted:** "A tab lives on one host, which keeps its layout, panes and mark; other devices view or take over the tab whole".
  - It amends ADR 0007 (sessions over SSH, per session) and ADR 0009 (the headless host's records).
  - It follows from decision 2.
- **CONTEXT.md:** **Take over**, **Release**, **Card**, **In control** and **Host** speak of tabs. **Phone page** opens tabs.
- **where-it-breaks to update:**
  - Peers: `tabs`, control by tab, `arrange`, terminals on a card, and the headless host's tab records;
  - The terminal and The live screen on the phone: a tab's panes, one at a time.
- **Verified in the code at 0d1d161:**
  - `attach` works on any pane's zmx session by name, whatever its kind;
  - a terminal's client exiting closes its pane and kills its session, and only Claude panes go to a card;
  - terminals run in zmx only with Keep sessions running on;
  - the headless host starts only claude, and keeps flat session records;
  - the Phone page caps terminals at three per device.
- **Inferred, not tested:**
  - that taking over several zmx sessions at once is as safe as one, since each step is today's, per pane;
  - that 5 s is soon enough for a layout change made elsewhere.
- **Picked:** only the machine in control changes the layout; a split from afar offers Claude and terminal only.
- **Closing a pane (ruled 2026-10-12, still pending the user):** ⌘W on a pane in a tab this Mac controls closes it in the host's tab exactly as ⌘W would on the host. A Claude pane closes without asking, and its conversation goes to the tab's history. A terminal asks first, with a sentence saying it ends that terminal on the host, and then ends. A pane that is released never stays behind in the host's tab. The host decides whether the pane is the tab's last, not the asker, whose copy can be 5 s old, and then it is handled as the tab's `end`. Closing the whole tab keeps the earlier rule: it ends if every running pane's origin names the closer and is handed back otherwise. An `end` naming a session and no tab (the phone's single-session view) keeps the old release rule: it ends if the session's origin names the asker and is released otherwise. Only the ⌘W path in a controlled tab ends. It is one place to change (`LauncherModel.hostEnd` and the headless `end`).
- **Departures accepted at review (2026-10-12):**
  - `reopen` is a request of its own, in the protocol list. It reopens a closed tab whole in the host's layout, in place of a `resume` per session.
  - A headless host's mark stays on its session records; the new tab record holds the layout, the name and the origin.
  - `start` names the pane to split and an axis (`sideBySide` or `stacked`), and the new pane goes second. There is no side.
  - A web pane at an outside address is an "Open in the browser" link on the phone, not a frame. The Mac loads it in the pane.
  - A machine is in control only when every running Claude and terminal pane names it, and a pane's Start is refused while another machine holds the tab.
- **Decided by the user (2026-10-12),** when accepting this option, each the recommendation:
  1. **Splitting a pane of another machine's tab** starts the new pane on that host.
