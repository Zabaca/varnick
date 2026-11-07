---
problem: sessions-cant-reach-each-other-reliably
title: Option 02 for a headless host, with `send` reaching a session on the headless host and that session answering, set up from a Mac's Settings
summary: Built on options 01 and 02. A Mac session sends to a session the board lists on the headless host, and that session answers the sender with its own `send`, as between Macs. The host has no app, so its relay does the routing with nothing left running, as today. A Mac's message is queued by the relay process that answers the Mac's request, into the same per-pane queue a Mac uses. A host session's answer waits in the host's outbox until the Mac it is for collects it, which that Mac does over the link it already holds, but only while one of its sessions has messaged that host. A host session can answer only a Mac session that messaged it, since it has no board to find others on. The one switch is now labelled Also between my Macs and hosts. Each host gets a row under it in a Mac's Settings, holding the host's own checklist: Upgrade; Claude Code's version and login there; Allow usage data, which the host's relay carries out; Approve on the host; and a live test across. Approve runs the fixed approval command on the host over the existing link once the user presses it, with sudo that asks for no password. Only when the host's sudo wants a password does it open a terminal on the host with the command typed in. There is no protocol bump: two new requests and some optional fields, which older builds ignore or refuse in words. So only the Mac that wants it and the host need the upgrade, never every paired Mac at once.
status: shipped
---

## Solution

Everything in options 01 and 02 holds; `send` also reaches a session hosted on a headless host, and that session can answer.

**From a Mac to the host.** A pane id that `board_read` lists for a session "on" the headless host is a valid `to`, as a paired Mac's is (the board already lists the host's sessions with ids; today `send` refuses them). The Mac sends the host option 02's request over the link it already uses. The host's relay applies option 01's checks to its own session: a Claude session, running, receiving, not an automation's run, and the skip rule from what the request says of the sender. It then queues the text for that session's channel and answers with the receiver's turn, as a Mac does. The receiver sees `from`, `from_project` and `from_mac`, the sending Mac's name as the host lists it.

**From the host back to a Mac.** A session on the host lists `send` beside `notify`. Its `to` is the `from` of a message it received. The text goes to the host's outbox for that Mac; the Mac collects it (below), applies option 01's checks to its own receiver with the host session's facts, queues it, and tells the host what happened. The host session is told what a session on a Mac is told: "Sent to s1 (croft on the laptop). It is working, so it reads this when its current step ends." The receiver on the Mac sees `from` (the host session's id in its own table, so it answers the same way), `from_project`, and `from_mac` holding the host's name as the Mac's board shows it.

**A host session reaches only Mac sessions that messaged it.** It never sends first. It may send to a `from` more than once (a note on progress, then the result an hour later) for as long as that Mac pane lives, across restarts of either session and of Varnick on the Mac. The Mac checks this as well: it takes a host's message only for one of its panes that has sent that host a message.

**When the Mac collects.** The host never calls a Mac back (ADR 0009), so the Mac asks. While Also between my Macs and hosts is on, the host is ready, and at least one open pane on this Mac has messaged that host, the Mac keeps one waiting request open to the host. The host answers it as soon as something waits for that Mac, or empty after 20 s, and the Mac asks again at once. An answer should reach the Mac within about a second of being sent (unmeasured). A Mac that is asleep, has the switch off or runs an older Varnick isn't collecting, so the host session's `send` is refused at once: "that Mac isn't collecting messages from this host now (asleep, Also between my Macs and hosts off there, or an older Varnick). Nothing was sent." A message no Mac takes within 5 s is taken back and refused the same way. Nothing is held for later, as between Macs.

**Setup, from a Mac.** The host has no Settings, so a Mac's Settings › Claude shows it. Option 02's second switch now covers hosts as well and is labelled **Also between my Macs and hosts**. Under it, each headless host gets a row with that host's own checklist. The rows are option 01's, read on the host and fixed from the Mac where they can be:

1. **Varnick on the host is new enough.** An older relay gets **Upgrade**, the button the host's row in Settings › Peers already has (ADR 0013).
2. **Claude Code there is new enough** (2.1.319 or later). There is no button: Claude Code updates itself there.
3. **Signed in with Anthropic directly**, there. On any other provider the rows stop.
4. **Usage data allowed**, there. **Allow** asks the host's relay to change the one value in Claude Code's user settings on the host, under option 01's rules and after saying what it means. A value set in the host's shell startup files or its policy gets no button, and the row says where it is set.
5. **This host approves Varnick.** The row says what Approve will do before it is pressed, as on a Mac. **Approve on the host** then runs the one fixed approval command on the host, over the link the Mac already uses, through sudo in its no-password mode. It adds Varnick's own file to the host's policy drop-in folder, owned by root, as on a Mac. **Update** and **Remove approval** work the same way. Nothing reaches the host's machine policy until the user presses one of these buttons. Only when the host's sudo says it needs a password does the row open a terminal tab on that host with the same command typed in, so the user types the host account's password there; the password never passes through Varnick. A policy that turns channels off stops the rows, as on a Mac.
6. **Sessions started before**, on the host. They are counted, and each joins at its next start (Restart in its pane).
7. **Test.** A throwaway session on this Mac sends a word to a throwaway session started on the host, out of sight of every board, and the host session answers. The row shows both times, then both sessions end. It proves that the host's Claude Code registers the channel (Anthropic's switch is per account) and that both directions work.

The host is ready when rows 1 to 5 passed at its last read and its last test did not fail. Its sessions started after that get the channel and `send`. Before then, and after Remove approval, its sessions start exactly as today: `notify` alone, no channel and no warning line.

**Off.** Turning Also between my Macs and hosts off on a Mac stops its sends to other Macs and hosts and its collecting at once, so a host session's answer to it is refused. Remove approval stops the host's new sessions from loading the channel; the ones running keep theirs until they restart.

## Trade-offs

- **Sessions can coordinate work on the headless host,** such as a build on the always-on box with a lead on a Mac, with the same tool and the same answers as between Macs.
- **A host session only answers.** It can't find a Mac session on its own or start a conversation, because host sessions have no board, and they can't message each other on the host without a Mac in between. That covers the lead-and-helper pattern; anything wider needs the board on the host (out of scope).
- **No lockstep upgrade.** Only the host and the Macs that want host messages take this build. Two Macs on option 02's build and on this one go on exchanging everything, messages included. The cost is a documented rule change: an addition that older builds ignore, or refuse in words, no longer bumps the protocol.
- **One more held SSH channel for each host while a session there is in a conversation with this Mac:** a short command every 20 s when idle, on the connection the Mac already shares with that host. sshd allows ten channels on that connection, and the cards' live screens use some of them.
- **One press changes the host's machine policy.** The user's host lets its account use sudo without a password, so Approve installs Varnick's file there with no password asked. The press is the user's decision, as the password is on a Mac, and the row says beforehand what it adds. The command is fixed and carries the file's content itself, so root never reads a file the user's account can write. A host whose sudo asks for a password gets a terminal instead.
- **Usage data from the host.** Pressing Allow makes Claude Code on the host send Anthropic usage data and fetch its feature switches. The host's Claude Code settings turn usage data off today, so messages to the host need that press.
- **The reach grows toward the Mac.** Today a host never acts on a Mac. With this option, a session on the host can push text into a Mac session, but only one that addressed that host, and under the skip rule. A host session misled by what it read can steer a skipping Mac session that is in a conversation with it.
- **Slower than between Macs.** An answer from the host takes two SSH round trips plus the receiver's turn.
- **The channel feature is experimental,** and now it is relied on in two Claude Code installs on two platforms.
- **What reaches Anthropic** grows as in option 01: the text, now also with the receiving session on the host.

## User Stories

1. As a lead session on a Mac, I want to send work to a session on the headless host by the id the board gave me, so that the always-on box does the long job.
2. As a session on the headless host, I want to answer a message with `send` to its `from`, so that my result reaches the lead without the user carrying it.
3. As a session on the headless host, I want to send to the same `from` again later, so that I can report progress and then the result.
4. As a session on the headless host, I want my `from` to keep working after the lead's pane or Varnick on its Mac restarts, so that a restart there doesn't cut me off.
5. As a receiving session, I want to know which machine the sender is on, so that I don't assume its files are mine.
6. As a session on the headless host, I want a clear refusal when the Mac I'm answering is asleep, on an older Varnick or not collecting, so that I don't wait for an answer that won't come.
7. As a lead session, I want a clear refusal when the host session isn't running, can't receive, is an automation's run or skips permissions when I don't, so that I know why nothing was sent.
8. As a sender, I want to be told whether the receiver is working or started on my message, as between Macs, so that I know when to expect an answer.
9. As the user, I want the skip rule to hold between a Mac and the host in both directions, so that pairing the host doesn't widen what an asking session can steer.
10. As the user, I want a host session to reach only the Mac sessions that messaged it, so that the host can't push text into my other sessions.
11. As the user, I want each host's readiness shown under Also between my Macs and hosts in my Mac's Settings, so that I see what is missing without logging in to the host.
12. As the user, I want Allow for the host's usage data to be one press from my Mac, after being told what it means, so that I never edit the host's settings by hand.
13. As the user, I want Approve on the host to be one press from my Mac when the host's sudo needs no password, so that I never log in to the host to approve it.
14. As the user, I want nothing written to the host's machine policy until I press Approve, Update or Remove approval, so that a machine-wide change is always my decision.
15. As the user whose host asks for a sudo password, I want Approve to open a terminal on the host with the command already typed in, so that I only type the password.
16. As the user, I want the approval to leave every other policy entry on the host as it was, so that turning this on breaks nothing else there.
17. As the user, I want Remove approval for the host, so that the host's policy goes back to how it was.
18. As the user, I want a host on an older relay to offer Upgrade, so that the fix is one press.
19. As the user, I want a live test across the Mac and the host, so that I know messages actually arrive and get answered, and not only that the settings look right.
20. As the user, I want to upgrade only this Mac and the host, so that my other Mac keeps working while I try this.
21. As the user, I want the host's sessions to start exactly as today until its checklist passes, so that nothing changes there before I approve it.
22. As the user, I want the phone kept out of this, so that a listed device can't push text into sessions this way.
23. As the user, I want no Varnick process left running on the host between requests, so that the host stays what ADR 0009 made it.

## Implementation Decisions

**Where the router and the queue are on the host.** The relay starts per request with nothing resident (ADR 0009), and this keeps it so.

- **A Mac's message to the host:** the relay process that answers the Mac's `sendMessage` is the router. It replaces today's refusal in the headless host's forward with the following, in order:
  - the host's gate (`MacMessages.gate` on the host's saved readiness);
  - option 01's checks against the host's records and zmx (`SendRules.decide`). An automation's run never receives; the skip rule uses the request's `skips` against the record's "started skipping" (below);
  - the queue (`MessageQueue`). The queue is `panes/<id>/messages/` in the host's state folder, since the relay points the support folder there, and it is owner-only;
  - the sender, written into the receiver's table (below);
  - a wait of up to 5 s for a waiting receiver's turn, read from the pane's turn file;
  - the answer, `PeerMessageReply`.
- **The queue is emptied at each claude start** in the host's `launch`, beside the message file `launch` already clears, so nothing sent to an earlier run reaches a later one.
- **The receiver's table.** On a Mac, `from` comes from the running Varnick's tables in memory; the host has no running process. Each receiving pane on the host keeps a small file in its pane folder that maps `s1`, `s2` and so on to a sender: a Mac id and that Mac's pane id. Whichever relay delivers to the pane writes the file, under a lock. It is kept across restarts of the pane (not cleared at claude start) and goes with the pane folder. A Mac sender gets the same id each time it messages that pane.
- **A host session's message to a Mac:** the sending pane's own tool server is the router for the first hop. That server is the relay's `--mcp` mode with `--send`, one process per session. In order, it:
  - resolves `to` in its pane's table;
  - refuses as option 01 does: text, size, the rate cap (10 a minute, kept in that process), and an unknown id;
  - refuses at once when that Mac has no fresh collecting mark (below);
  - writes the message, by rename, as one file in the host's outbox for that Mac in the state folder;
  - waits for a Mac to take it within 5 s, else takes it back by rename and refuses;
  - then waits for the Mac's receipt for up to 15 s more, else answers "handed to that Mac's Varnick, which didn't say what happened";
  - turns the receipt into the sender's answer with `SendRules.answer` and `MacMessages.message`.
- **The Mac's half.** The Mac's running Varnick routes the last hop through the code `receiveMessage` uses. It first checks that the target pane is open here and has sent that host a message, and refuses an unknown pane with option 01's `unknownID` and a closed one with `gone`, so the refusal words need no new case.
- **Collection is one new request, for Macs only** (added to `PeerProtocol.isMacsOnly`, so the relay refuses a device). The relay process that answers it:
  - writes a collecting mark for the asking Mac (its process id, dated);
  - writes the receipts the request carries (each message's id with its `PeerMessageReply`) for the senders waiting on them;
  - claims each message waiting for that Mac by rename;
  - answers with them, or empty at 20 s, and never later.

  A request that passes its deadline closes the shared SSH connection (`SSHRunner`), so the Mac sends it with a 35 s deadline and the host must always answer first. The Mac asks again at once, and waits 10 s after a failure.
- **When the Mac collects:** while Also between my Macs and hosts is on, the host's last hello says it is ready, and an open pane here has messaged that host. That last fact is a mark in the pane's folder on the Mac, listing the hosts it has sent to. `send` writes it when a host takes a message, and it survives the pane's Restarts and Varnick restarts and goes with the pane. The same mark is the Mac's answer-only check.

**The host's sessions.**

- **`launch` gives the channel.** The headless host's start, restart, resume, reopen and automation runs all go through `launch`. For a Claude record that is not an automation's run, while the host is ready, it passes the plugin folder to `ClaudeCommand.arguments`. That function already puts `--plugin-dir <folder>` and `--channels plugin:varnick@inline` after `--mcp-config` and before `--settings`. "Ready" means the saved check says rows 1 to 5 passed and the test did not fail, and Varnick's file is in the policy drop-in folder at that moment (read fresh, which is cheap). At the same time the relay's server line in `--mcp-config` gains `--send`.
- **The plugin folder** is `channel-plugin` in the host's state folder (`ChannelPlugin.write`, with the relay's absolute path as the command), written at each start when it differs. `VARNICK_PANE_ID` is already in the environment the host gives claude.
- **The relay gains `--channel --pane <id>`** (`ChannelServer.run`). It and `--mcp` move after the install root is found, since both now need the state folder.
- **The host's record gains "started skipping",** set by `launch` from the value it passes on the command line (the record's own, else the host's default), for the skip rule.
- **`send`'s tool definition moves** from the app into the package, beside `NotifyTool`, and the Mac's `SendMCP` reads it from there (an atomic move, no shim). The host's description says that `to` is the `from` of a message received, that a host session can only answer, and what is refused.

**The host's checklist.**

- **One new request, for Macs only,** answered by the relay: the host's rows, decided by `ChannelChecklist` exactly as a Mac's are, from reads made on the host:
  - `claude --version` and `claude auth status --json`, run through the account's login shell with the environment `launch` gives claude;
  - Claude Code's user settings `env` and the login shell's environment;
  - the policy at `/etc/claude-code` with its `managed-settings.d`. `ChannelPolicy` gains the platform's directory, and the policy reader moves from the app into the package.

  The request also carries the row buttons' actions: `allow`, which applies option 01's Allow on the host (`UserSettingsEdit`, already in the package), and `approve`, `update` and `remove` (below). The result (time, rows, ready) is saved in the state folder, where `launch` and the hello read it. A read younger than 60 s is answered from the file unless the Mac asks for a fresh one (Check again).
- **The host's hello fills `messages`** (`PeerMessagesState`, already in protocol 35) from that file: ready, or the first failing row's words. A hello never runs claude.
- **Approve, Update and Remove approval run on the host, behind the user's press only.**
  - **The command:** `ChannelPolicy`'s install script gets a Linux form: GNU `base64 -d`, the tools' Linux paths, and owner `root:root`, since Linux has no `wheel` group. The Mac's form is unchanged. As on a Mac, the content travels in the command, so root never reads a file the user's account can write. Remove approval is the removal of Varnick's one file.
  - **How it runs:** the relay, answering the Mac's checklist request with that action, runs the command through `sudo -n` (sudo's no-password mode), so it fails at once instead of waiting for a password nobody can type. Its exit status maps to the row's words, as the Mac's `installFailure` does. The relay then reads the host again and answers with the new rows.
  - **The fallback:** when sudo answers that a password is required, the reply says so. The Mac then opens a terminal tab on the host (an ordinary terminal `start`) and types `sudo` and the same command into it once its shell is up, for the user to enter the host account's password. The row reads the host again when that tab closes, and on Check again.
  - **Never automatic:** nothing else runs these actions. No launch, refresh, hello or upgrade writes the host's machine policy.
- **The test.** The Mac starts the receiver on the host with `start` and a new optional mark. The host saves the mark and keeps the session out of its `tabs` and Recent answers. With no folder asked, the receiver starts in the host's Home, which is marked trusted (Claude Code never trusts an account's own home folder, so no one is asked a question). The Mac starts the sender here as option 01's test does. It watches its own send's answer (the turn started: arrived) and the sender's queue (answered), 60 s each, then ends both. The mark is not the unopened-run mark, which the host's automation sweep clears.

**Settings on the Mac.** Option 02's second switch is relabelled **Also between my Macs and hosts**, and its detail text names hosts; the setting behind it is the same, so nothing saved changes. `MessagesMacsView` lists headless hosts too, each with the checklist lines its host decided, shown here with their buttons here. Upgrade goes through `HeadlessUpgrade`, and it is offered for a relay on another protocol and for one that answers the new requests "Unknown request". No ask goes to a host (`peerAnswered` keeps skipping them), since there is nobody at the host to show a notice to.

**Protocol: no bump.**

- **What changes:** two new requests (the host's checklist with its actions, and collection) and optional fields (`PeerStart`'s test mark, the receipts on the request, and the collected messages and checklist rows on the reply). Option 02's `sendMessage` keeps its shape.
- **How older builds react:** a relay at 35 answers a request it doesn't know with "Unknown request" (read in `PeerRelay.run`: an operation that doesn't decode is refused after the version check), which the Mac reads as "Upgrade the host". A relay on another protocol fails the version check, as now.
- **What that buys:** a Mac on option 02's build and a Mac on this one go on exchanging everything, messages included, and only the host and the Macs that message it take this build.
- **The rule it relies on:** an addition that an older build ignores (a field) or refuses in words (a request) needs no bump, and no new case is added to an enum that travels in a reply an older build decodes, since a plain `JSONDecoder` fails the whole reply on an unknown case.
- **Where the rule is recorded:** an amendment of ADR 0007, and where-it-breaks' Peers bullet that says any shape change bumps.

**The framing (decided by the user on 2026-11-07).** The channel's instructions say "machines" where they say "Macs". The two sentences that change become:

> Messages on this channel come from another of your user's Claude Code sessions, running in a Varnick pane on one of the user's own machines (a Mac, or a headless host Varnick runs sessions on).

> Each arrives with `from`, the sending pane, and `from_project`, its project (and `from_mac`, that machine's name, when it comes from another machine).

The rest of the instructions stays as it is, and the attribute keeps its name. `make check-messages` pins the new words. A change to these words is a change of behaviour (where-it-breaks), so the checklist's test on a Mac and a hand test run again.

**The log** is as option 01's: never the text, an id, a project or a machine's name.

**Docs:**
- where-it-breaks: Messages between sessions (the host's route, queue, table, outbox, collecting, checklist, and approval on Linux through `sudo -n` with the terminal fallback) and Peers (the two requests, the additive rule, and the headless bullets, where the host still never calls a Mac back);
- amendments of ADR 0031's amendment of 2026-11-07 (for hosts) and of ADR 0007 (the additive rule);
- CONTEXT.md's **Session message**, and the switch's new label wherever it is named;
- the privacy doc (the host's usage data after Allow, that Approve changes the host's machine policy with no password where its sudo asks none, and that a host session can reach a Mac session that addressed it);
- the guide.

## Testing Decisions

- **A good test** drives what a session or the user sees: what `tools/list` lists, the lines a server writes, the arguments, the refusals' words and the rows. It never drives how a file is named.
- **The pure parts,** in `make check-messages`' table:
  - the host's send rules: an unknown id, the rate cap, a Mac not collecting, a message taken back, and a receipt turned into the answer;
  - the table file;
  - the outbox's two renames racing (taken by the Mac against taken back);
  - the collecting mark's freshness;
  - the Mac's answer-only check;
  - the host rows' decisions from the host's reads, the policy at the Linux path included;
  - the Linux install script, run as the current user in a scratch folder with the owner swapped, as the Mac form is run;
  - telling sudo's "a password is required" apart from the script's own failures;
  - the hello's `messages` from a saved check;
  - the arguments `launch` builds with and without the channel;
  - the framing's new words.
- **`make check-mcp`:** the relay's `--mcp --send` lists `notify` and `send`, and without `--send` lists `notify` alone; the relay's `--channel` runs against a scratch state folder, as the app's channel server is run. The relay is a package executable that also builds on macOS, so these run on a Mac worktree.
- **On the host:** the package builds on Linux. The installer builds it there, and nothing else checks a Linux build.
- **By hand, after the host is upgraded to the build and this Mac restarts:**
  - setup: the switch shows its new label; the host's row shows each line; Allow with the host's usage data off; Approve turns the row to a tick with no terminal and no password, and the host's policy folder then holds Varnick's file alone, owned by root; Update; Remove approval leaves the folder as it was; Upgrade from a host on an older relay; the test passing, then failing with the host's file removed;
  - the terminal fallback: it can't be reached on the user's host, whose sudo asks no password, so it rests on the pure check and on a host whose sudo asks;
  - messages: `send` from a Mac session to a host session the board lists starts a turn there with `from_mac`; its `send` to `from` arrives back; a second answer an hour later still arrives; an answer after a Restart of the Mac pane, and after a Varnick restart on the Mac, still arrives;
  - refusals: a host session's send with the Mac's switch off, and with the Mac asleep, is refused at once; sends to a host terminal, an automation's run and a session started before the approval are refused; a Mac session that asks before its tools is refused toward a host session that skips;
  - isolation: the other Mac, still on option 02's build, keeps messaging this one;
  - the logs on both sides hold no text, id, project or machine name.

## Out of Scope

- Sessions on the host reaching each other with no Mac in between. They have no addresses for each other; a Mac session can relay.
- A host session messaging a Mac session first. That needs `board_read` on the host, and the host's sessions get no pane tools today.
- `opener` and `tab_open` on a host.
- An automation's run on the host sending or receiving, and the phone sending.
- Holding a message for a Mac that is asleep, or for a host that doesn't answer.
- Restart them for the host's panes. A Restart from a Mac needs control of the tab, so each joins at its next start.
- A checklist on the host's own command line.

## Further Notes

- **Decided by the user (2026-11-07), relayed by the coordinator:** this option is accepted, with these choices:
  - one switch, relabelled Also between my Macs and hosts;
  - the framing says "machines" instead of "Macs" (the words above);
  - Approve on a host runs the fixed Linux command over the existing link with `sudo -n`, still behind the user's press, and Update and Remove approval the same way, because machine-wide policy is always the user's decision and never automatic. Only when sudo says a password is required does it fall back to a terminal on the host with the command typed in.
- **Verified in the code at 51bc068:**
  - the headless relay's tool server serves `notify` alone;
  - the headless host's forward refuses `sendMessage` and `messageAsk`;
  - the Mac's `send` refuses a headless host's pane after `whereIs` has found it on the board;
  - the host's `launch` builds claude's arguments with `ClaudeCommand.arguments`, passing `--mcp-config` and no channel, and `ClaudeCommand.arguments` already places `--plugin-dir` and `--channels`;
  - `VARNICK_PANE_ID` is in the host's claude environment;
  - the relay points the support folder at the state folder, so `PaneFolder` and `MessageQueue` land there;
  - the relay refuses an operation it doesn't know with "Unknown request", after the version check;
  - peer JSON decodes with a plain `JSONDecoder`, which ignores unknown fields;
  - a request past its deadline makes `SSHRunner` close the shared connection;
  - the Mac's Approve runs `osascript`, and the install script uses macOS's `base64 -D`, `/usr/sbin/chown` and `root:wheel`;
  - `MessagesMacsView` and `peerAnswered` skip headless hosts;
  - the host's hello sets `headless` and no `messages`.
- **Read in Claude Code 2.1.319's own code (this Mac's copy), not seen on Linux:**
  - one function picks the policy folder for every platform (`/etc/claude-code` on Linux);
  - one reader takes the main file and then the `.json` files of `managed-settings.d` sorted by name, joining them, on every platform but WSL's special case;
  - the owner and permissions check is the same POSIX check on every platform but Windows: a file or folder the running account can write is not trusted, and a session run as root trusts none.
- **Checked on the host over SSH, read only, on 2026-11-07:**
  - this Mac reaches it;
  - its relay is at a commit of 2026-10-21 that speaks protocol 34, while this Mac speaks 35. So today the two refuse each other's every request but hello and Upgrade, and the host has never built options 01 and 02's code;
  - Claude Code 2.1.319 is installed there in the same layout as on this Mac;
  - there is no `/etc/claude-code` at all (the coordinator saw the same later that day);
  - Claude Code's user settings there set `DO_NOT_TRACK` to 1, and the login shell sets none of the three tracking settings;
  - its config holds a Claude account sign-in, and its cache says Anthropic's switch for channels is on and lists the same four approved plugins;
  - its login shell is zsh, and the account is in the sudo group;
  - **the account's sudo needs no password** (`sudo -n true` succeeds, checked by the coordinator), so Approve takes the no-password path there;
  - Swift is installed;
  - the tools the Linux script needs are there, with `chown` in `/usr/bin`, and there is no `wheel` group.
- **Unverified:**
  - `claude auth status` on the host (not run, since it can refresh the sign-in): whether the provider reads as Anthropic's own;
  - the time for an answer from the host to reach a Mac;
  - whether the host's Claude Code registers a `--plugin-dir` channel on Linux;
  - for the fallback only, whether keys typed into a new terminal pane on a host reach zsh after its startup files. The user's host never takes this path; if the keys are lost, a terminal `start` takes the first command as an optional field.
- **Assumptions:**
  - 20 s for the waiting request, 35 s for its deadline and 10 s after a failure;
  - 5 s for a Mac to take a message and 15 s for its receipt;
  - 60 s for the host's saved check;
  - an id for a Mac sender that lasts for the receiving pane's life;
  - the test's receiver kept out of the host's lists by a mark of its own;
  - `from_mac` keeping its name;
  - sudo's password refusal recognised from its exit and its message, in the host's language.
- **Still open:** the board on the host, so that host sessions can send first and to each other. Recommended: a separate option, if wanted.
- **Steps that need the user:**
  1. First, upgrade the host now, from its row in Settings › Peers. It is behind this Mac's protocol anyway, and the upgrade shows whether option 01 and 02's package code builds on Linux.
  2. After the build: upgrade the host again, and restart Varnick on this Mac. The other Mac needs neither.
  3. On this Mac, under the host's row: Allow (Claude Code on the host then sends Anthropic usage data), Approve (no password on this host), then Run test.
  4. Restart, in their panes, the host sessions that should receive.
  5. A hand test of about 30 minutes.
- **Before building:**
  1. Upgrade the host to main, as in step 1 above.
  2. In a throwaway session on the host, started as the host will start it (its plugin folder, both flags, the host's environment, and `DO_NOT_TRACK` set to 0 for that session only), with a root-owned drop-in listing `varnick@inline`: does the channel register (its debug log), and does a pushed line start a turn? This proves that Linux reads the drop-in as the code says and that Anthropic's switch reaches the host's account. It writes the host's machine policy, so it waits for the user's go; with no sudo password there it is one command over SSH, and the drop-in can stay for the build.
  3. `claude auth status --json` on the host, through its login shell.
- **What a worktree on this Mac can check:** `make build`, `make check-messages` and `make check-mcp` with the cases above, the relay's modes among them.
- **What only the host can check:** the Linux build, the policy folder there, the no-password Approve, Claude Code registering the channel there, and the waiting request over the real link.
- **What only the main checkout can check, after a restart:** the switch's label, the rows, the collecting and the hand test.
- **Size, in agent time:** about 7 to 8 hours of building, and 1.5 to 2 hours of review and a fix round.
  - The building: the host's routing, table, outbox and collection, about 2.5 hours; the host's checklist request with Allow and the approval actions (the no-password run and the terminal fallback), the Linux approval script and the host's starts with the channel, about 1.5 hours; the Mac's collecting, its answer-only check, the switch's label and the host rows, about 2 hours; the test, about 45 minutes; docs and checks, about 45 minutes.
  - On top: the host's installs, a Swift build on Linux each (unmeasured), and the user's steps, about an hour.
  - Wall clock: about one working day.
  - The test can be cut to save about 45 minutes, leaving the hand test as the proof.
- **Depends on** options 01 and 02, both shipped; it closes option 02's review note that the protocol 35 bump looked avoidable, by not bumping here.
- **Build order:** after the host has been upgraded to main and has built there, on its own branch from main.
- **Review follow-ups (merged 2026-11-07; reviewer verdict merge after one fix round, which fixed a failed host test being wiped by a later read and a second host answer being refused as "not collecting" during a hand-off):**
  - should-fix: a Mac sends the test result it holds on every read (every 10 s while Settings is open), so an older result on one Mac can overwrite a newer one saved by another Mac's test. Send passed or failed once, in the read that ends a test.
  - should-fix: tests run at the same time (this Mac's and a host's, or two hosts') share one set of test panes and watches, so the first to finish ends the other's sender and it fails with a misleading reason.
  - should-fix: the check has no case for the host's own `launch` decision (no channel for a terminal or an automation's run, and `--send` always with the plugin).
  - should-fix (only for a host left on a relay built from this branch before the fix round, which none was): such a relay ignores `hold: false` and could claim a message into a receipts-only request that the Mac discards. Have the Mac's flush hand over any messages a reply carries.
  - nits: MCPServer's header still points to the deleted `NotifyTool.serve`; SendTool names `HostSend` for `HostSendServer`; HostMessagesSetup's comment row numbers don't match the line ids; row positions are hard-coded in several places; HostChecklistView copies MessagesChecklistView's symbol and color helpers; where-it-breaks and message-check say the refusal set keeps the cases it had at 35, though the never-encoded `.headless` was removed; additions the spec didn't ask for (the blank-line heartbeat, the 10-minute sweep of the test receiver, refusing a test start unless the host is ready and its folder trusted, `receiving`, `collectingFreshFor` of 12 s) are documented but not in the option.
- **Hand check owed** after the merge: Upgrade the host from its row and restart Varnick on this Mac; in the host's block, Allow, Approve (no password expected; the drop-in folder then holds only Varnick's root-owned file), Run test; restart the host sessions that should receive; then a Mac session's message to a host session and its answer back, again after a pane Restart and a Varnick restart, and the refusals (switch off, a host terminal, an automation run, a session started before approval, the skip rule toward a host session).
- **Fix merged 2026-11-07 (branch host-home, reviewer verdict merge):** a host session with no folder, and the test's receiver, start in the host's Varnick Home (made and trusted) instead of the account's home folder, whose trust Claude Code never records, so the test can pass and no-project sessions stop asking for trust. Follow-ups: should-fix, `scripts/check-mcp.sh` copies the relay binary over the same path before each run, which macOS kills on the next start about half the time ("exited with -9"); unlink before copying, or copy once per scratch home (predates this fix). nits: one run saw "the queue still holds [] after its messages were pushed" in the app channel-server case (looks timing-related, unverified); `agents` with no folder reports Home's path before Home exists.
