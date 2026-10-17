---
problem: phone-page-is-only-a-browser-tab
title: A Claude session can tell the user something on its own, through a notify tool of Varnick's and Claude Code's own PushNotification
summary: A new notice kind, Message, that the session raises itself. The user chose both ways in. One is a `notify` tool (a title and an optional body) on Varnick's MCP server, listed in every Claude pane, the headless host's included. The other is Claude Code's own PushNotification tool, in a pane where the user has it on. One PostToolUse hook records either call in the pane's folder, so the MCP server still never acts and one reader serves both. A message is then a Notice like the others. On the Mac in control it shows the dot, plays the louder sound and heads the menu with its title. The pane's host's page server pushes it to the phone by option 02's routing, after a 2-second settle. The push carries ids and the kind only, as ADR 0038 says, and the phone's worker reads the words over the tailnet. A pane alerts at most once a minute for messages. A Done that ends the turn after a message is folded into the message. Protocol 28 carries the message in `status` and `tabs`, so every Mac and the headless host run one commit. Varnick points Claude Code's client-presence marker at a file the page server keeps while it has a subscription, so Claude's own mobile push doesn't double Varnick's. A throwaway check of PushNotification's input and hook comes before anything relies on them. Rough effort is four days on top of option 02.
status: shipped
---

## Solution

### Two ways in, one record

- **`notify`, Varnick's tool.** It is listed on Varnick's MCP server in every Claude pane, on a Mac with Screen and Panel access off too, and on the headless host. It takes:
  - `title`: required, one line, cut to 80 characters;
  - `body`: optional, cut to 300.

  The server checks the arguments and answers. It writes nothing and asks nothing.
- **PushNotification, Claude Code's.** Claude Code offers it when the user has turned on its own setting, Push when Claude decides. Varnick doesn't turn that on. Where it is on, Claude may call it, and Varnick takes the call as a message too.
- **One hook records both.** Every pane's settings gain a PostToolUse entry that matches both tools' names. It saves the hook's input as it comes, by rename, to a message file beside the turn file, as the Stop hook saves its input to the stop file.
  - The file's date is the message's time.
  - The reader takes the title and body from the tool's input: `notify`'s own names, and PushNotification's names as the check under Testing Decisions finds them.
  - A PushNotification input whose fields the reader can't place reads "Claude sent a notification", with no body.
- **How long a message lasts.** From the hook's write until one of these:
  - the user's next prompt in the pane;
  - a `/clear`;
  - claude starting again in the pane.

  The prompt hook, the `/clear` hook and both hosts' start remove the file.

### When a message is a notice

A pane has at most one notice, as now. A message joins `sessions-finish-unnoticed` option 01's table like this:

| What happens | The pane's notice |
|---|---|
| A message is recorded | **Message**, replacing what stands |
| The turn ends (Done) while a message stands | folded into the message: nothing raised |
| Needs you, or an error | raised over the message, replacing it |
| The turn goes to working or background, or a dialog is answered | the message stays |
| The message file goes (next prompt, `/clear`, a start) | cleared |
| Seen: on screen at the controlling Mac, looked at for 3 s on the phone, or shown by the Mac | cleared or dropped, as for any notice |

- **The first read of a pane is a starting point,** as for turns. A message already there at a launch or a server start raises nothing.
- **A Done that follows a standing message is folded into it.** Claude usually calls the tool just before its turn ends, so the turn's end is what the message already announced. Without the fold the phone would buzz twice for one thing.
- **Needs you and errors replace it,** because the user has to act on them. The message's words stay in the terminal.
- **A message is read before the turn.** Varnick's own read of a pane and the page server's read of `tabs` both see a message before the Done that follows it in the same read.

### Where it goes

Option 02's routing, unchanged:
- a Mac notice on the Mac in control of the pane;
- a push to the phone when that Mac's user is away or can't be told, or when the phone controls the pane;
- suppression for anything seen.

What is new:
- **The settle is 2 seconds,** as for Needs you. A message is deliberate and doesn't flicker back. The read of `tabs` after the settle stays, so a message the user answered by prompting in the meantime isn't pushed.
- **The Mac notice** shows the orange dot and plays the louder sound, because Claude chose to interrupt and it's held to once a minute. Its menu line is the session's title, its host when that isn't this Mac, and the message's title.

### The words, and what a push carries

- **The words live in the pane's folder on its host.** They travel only over the user's own links:
  - `status`, to the Macs that follow the pane;
  - `tabs`, to the host's own page server and to a listed device.
- **The push payload carries no words.** It is option 02's version 1 with a new kind, `message`, and the tab and pane ids, padded and sent like every other push. This keeps ADR 0038's rule, so Apple and Google can't tell a message from any other push.
- **The notification.** The worker asks the host for the tab, as it does for every push:

  | The tab is read | Title | Body |
  |---|---|---|
  | yes | the message's title | the message's body, then a line "session title · host" |
  | no (off the tailnet, the host asleep, slow) | the host's name | "A session sent you a message" |

- **The page adds no view of its own.** A tap lands on the pane, whose terminal shows Claude's call with its words. A worker from before this build shows option 02's "A session needs a look" until the page loads the new one.

### At most once a minute

- **One alert per pane per minute for messages,** on the Mac (the sound) and on the phone (the push).
- **A newer message within the minute** replaces the standing one quietly: the Mac's menu line changes and nothing sounds. The phone gets one push when the minute is up, if the message still stands then, with the newest words, since the worker reads them at that moment.
- **Option 02's cap of 60 pushes per device an hour still applies.**
- **The tool's description steers Claude.** It tells Claude to use the tool for what the user asked to hear about ("notify me when the tests pass") or would want to know at once. It tells Claude not to use it to say the turn is over or to ask a question or for permission, since Varnick already tells the user those. It also says one alert a minute gets through and the text shows on the phone's lock screen.

### Across hosts

- **Nothing carries a message from one page server to another.** Each host's page server pushes for its own panes (ADR 0038). The message is recorded in the pane's folder on the pane's host, and that host's server reads it in its own `tabs`, as it reads the turn.
- **The Mac in control of a pane on another host learns of it from `status`** (protocol 28). It raises its own notice there and lists it in its presence report, which the host's page server needs so it doesn't push what the user already saw on that Mac.
- **On the headless host,** its relay binary serves the MCP server, with `notify` alone, and the relay passes claude the MCP config it never passed before. The hook and the reader are the same as on a Mac.

### Claude Code's own mobile push

Claude Code skips its mobile pushes while the file named by `CLAUDE_CLIENT_PRESENCE_FILE` exists. Varnick sets that variable in every Claude pane to one marker file per host. The host's page server keeps the marker there while it has at least one push subscription and removes it when the last one goes.
- **With Varnick's push on,** Claude's own pushes through Remote Control are skipped (PushNotification's and its input-needed ones), and Varnick's routing alone decides.
- **With it off,** Claude Code pushes as it does today.

This is a decision for the user (open question 1).

### Switches

- **On the Mac:** Settings › Claude's "Notify me when a session…" gains a fourth switch, "sends me a message", on by default.
- **On the phone:** each subscription gains a fourth switch, Messages, on by default. A subscription saved before this build reads as on.
- **The tool itself has no switch.** It's listed in every pane, and the switches decide where its messages go.

## Trade-offs

- **Two ways in, one path.** Both tools end in the same hook, file and reader, so Varnick never has to tell them apart once the call is recorded. The cost is a hook on a tool whose input Claude Code doesn't document. If a Claude Code release renames PushNotification's fields, the message reads "Claude sent a notification" and keeps working.
- **An MCP server in every pane.** A pane with Screen and Panel access off gains one, about 19 MB each going by the memory snapshot of 2026-10-13, and the headless host gains one per pane. A pane started before this build gets `notify` at its next start or restart.
- **The model decides when to interrupt.** The once-a-minute alert, the 60-an-hour cap and the tool's description bound a chatty or misled session, but they don't judge what it says. Its words show on the phone's lock screen when the phone is on the tailnet.
- **The words leave the host only over the user's own links,** to the Macs that follow the pane and to the phone. Off the tailnet the notification says only that a session sent a message.
- **A folded Done is lost** when a message stands unseen through a long turn ("the deploy started" with a Done 20 minutes later). The message is still standing and the tap shows the pane, but no second alert comes.
- **Needs you replaces a message's notice.** The message's words are then only in the terminal and the earlier notification, which the newer one with the same tag replaces.
- **One protocol bump (28).** Every Mac and the headless host run one commit, and the headless host is reinstalled with its Upgrade button.
- **Setting Claude Code's presence marker turns off its own mobile pushes** while Varnick's are on. A user who relies on the Claude app's push and also subscribes the Phone page gets only Varnick's.

## User Stories

1. As the user, I want to say "notify me when the tests pass" to Claude in any pane and be told when they pass, on my Mac if I'm at it and on my phone if I'm not.
2. As the user, I want Claude to be able to tell me something worth knowing at once without my asking, sparingly.
3. As the user with Claude Code's Push when Claude decides on, I want Claude's own PushNotification to reach me through Varnick's routing, not as a second, separate buzz.
4. As the user, I want one alert for a message and the turn that ends right after it, not two.
5. As the user, I want a message from a session on the headless host, or on another Mac, to reach me as one from this Mac's would.
6. As the user on the tailnet, I want the notification to show Claude's words. Off it, I want only "a session sent you a message", and I want the words never to pass through Apple's or Google's servers.
7. As the user, I want a session that messages in a loop to alert me at most once a minute.
8. As the user, I want a switch for messages on the Mac and on each phone subscription, beside the other three.
9. As the user, I want a message I've already answered with a prompt never to be pushed.

## Implementation Decisions

### The tool

- **One definition for both binaries.** The tool's name, description, arguments and checks live in the shared package, like the claude command line. The MCP server's JSON-RPC lines move there too, out of the app's screen server, so `Varnick --mcp` and the headless relay's `--mcp` answer the same way.
- **On a Mac, notify is a third set** beside screen and panel, named on the server's command line and always on for a Claude pane. The configuration is no longer empty with both switches off. With no set named the server keeps listing the screen tools alone, as now.
- **The headless relay passes the MCP config,** first among claude's arguments as the existing rule says, with its own binary as the command and the notify set alone.
- **The server still never reads or acts.** It checks the arguments (a title is required; longer text is cut, and the reply says so) and replies. Only an empty title is refused, and the reader ignores an empty title as well. So whether or not Claude Code fires PostToolUse on a refused call, the result is the same.
- **The reply** says Varnick will tell the user on the Mac in control if they're at it, else on their phone if it's subscribed, and that one alert a minute gets through.
- **Allowed without a dialog.** The session's settings allow the notify tool, so calling it never stops the turn on a permission dialog, which would itself raise Needs you. Whether `--settings` adds to the user's own allow list or replaces it is unverified, and is part of the check below.

### The hook and the file

- **A PostToolUse entry** that matches both names saves its input raw, by rename, and exits 0 whatever happens. It sits beside the turn entries and is there whether the Problems board switch is on or off.
- **The prompt hook and the `/clear` hook remove the message file.** So does each host's start of claude in a pane, as it already clears the stop file and the subagent work.
- **The reader is in the pane folder's module**, shared by both hosts:
  - it reads a file of at most 64 KB and ignores a larger or unreadable one;
  - it takes `tool_name` and `tool_input`;
  - it strips control characters, makes the title one line and cuts it to 80 characters, and cuts the body to 300;
  - it returns the title, the body and the file's date.

### The protocol (28)

- **The host's turn reading carries the message** (title, body and its age in seconds), so the Mac host and the headless host both send it with no code of their own.
- **`status` and the `tabs` pane gain `said`**, an optional field with explicit coding keys, as `failure` and `esc` were added in 27.
- **The page server's protocol version moves with it.**
- **A device gets `said` in `tabs`.** It's the user's own phone, which already sees titles.

### The Mac

- **Reading the message.** A pane on this Mac reads its message file when the file's date changes, one stat a tick, as it reads its work log. A pane on a peer takes `said` from its host's `status`.
- **The merge rule.** A small pure function beside `NoticeRule.decide` applies a message, a turn decision and the standing notice: the fold, the replacement and the clears in the table above. The page server keeps a copy in TypeScript, and a change to one is a change to both, as with the table itself.
- **The notifier.** It gains a Message kind carrying the title. It tracks one alert a minute per pane and lists message notices in the presence report like any other. Its menu line and louder cue are as described above.
- **Settings.** A fourth notice switch, saved in UserDefaults under its own key, defaulting to on.

### The page server

- **Watching.** The watcher reads the message file's date with each turn file's date, and a change triggers a `tabs` ask.
- **Raising.** `observe` takes `said` before the turn. A message whose time moved by more than the same-turn tolerance is new and raises Message. The first reading of a pane is a starting point.
- **The rule.** The merge rule as above. The settle is 2 s. The gap between two pushes of a message for the same pane is 60 s, where other kinds use their settle.
- **Switches.** A fourth switch, `messages`, that a missing value reads as on.
- **What the page and worker get.** The payload kind is `message`. The shaped pane gains `said` for the worker. The worker's text is as in the table above. The Notifications section lists four switches.
- **The marker.** The server writes Claude Code's presence marker while the subscription file has an entry and removes it when it's empty or push is off. Both hosts' starts of claude set `CLAUDE_CLIENT_PRESENCE_FILE` to the marker's path.

### State

- **New:**
  - one UserDefaults key, the Mac's fourth notice switch (default on);
  - an optional `messages` switch in each saved subscription (missing reads as on);
  - the message file in each pane folder, which comes and goes;
  - the host's presence marker.
- **Unchanged:** `sessions.json` and the saved tabs.

### Documents

- **ADR 0038, amended:**
  - a session can raise a notice itself;
  - its words never go in a payload;
  - each host's page server reads the message from its own panes;
  - Claude Code's presence marker follows the subscriptions.
- **CONTEXT.md:**
  - **Notice** gains Message: raised by the session, its fold over Done, and when it clears;
  - **Phone page** names the fourth switch.
- **where-it-breaks:**
  - the hook is the only writer of the message file, and `--mcp` still never acts;
  - PushNotification's fields are undocumented, with the names the check found;
  - the merge rule is kept in two languages;
  - protocol 28's `said`;
  - the presence marker must not exist when nothing will push, or the user loses Claude's own pushes for nothing.
- **The privacy doc:**
  - a message's words reach the Macs that follow the pane and the phone, and show on its lock screen when read;
  - nothing of them goes to a push service;
  - Varnick turns off Claude Code's own mobile pushes while its own are on.

## Testing Decisions

- **Before anything relies on Claude Code, a throwaway check.** Run in a scratch folder with a `claude` whose `--settings` has a PostToolUse entry matching everything, which copies its input to a scratch file. It answers:
  - **Does PostToolUse fire for PushNotification, and what are its input fields?** Run it with Push when Claude decides on. If a print-mode run doesn't offer the tool, ask the user to trigger it in a pane. Don't drive the screen.
  - **Does it fire for an MCP tool,** matched by `mcp__varnick__notify`, and for one that answers with an error?
  - **Does a notify tool allowed in `--settings` run with no dialog** when the user's own settings don't allow it?
  - **What do Claude Code's docs say `CLAUDE_CLIENT_PRESENCE_FILE` skips:** mobile pushes only, or the desktop notification too?

  The dumps can hold paths, so they stay in this problem's scratch folder. Only the field names go into where-it-breaks. If PostToolUse doesn't fire for PushNotification, way in (B) stops there and the user is told; `notify` goes on alone.
- **`bun test`:**
  - each row of the merge table, with the fold and the starting point;
  - the 2 s settle and the read after it;
  - the 60 s gap, with the newest message pushed at the minute's end;
  - the Messages switch, and an old subscription reading as on;
  - the payload's kind and its size, which equals the others';
  - the worker's text with and without the tab;
  - the shaped pane's `said`, cut;
  - the marker written and removed with the subscriptions.
- **Swift, with no test target:**
  - `make check-mcp` covers the notify set: alone, with the other two, and absent with none named;
  - `make build` passes, and the protocol versions match.
- **By hand, after the user restarts Varnick and reinstalls the headless host, with the Android phone subscribed:**
  - **Present at the Mac:** "notify me in 30 seconds" in a pane driven from this Mac gives the dot, the louder sound and the menu line with the title, and no push.
  - **Lock that Mac** with it standing: the push comes, showing the title and body.
  - **Away, one alert:** with the Mac locked, a message followed by the turn's end gives one push, not a Done after it.
  - **The phone in control,** with the app closed: a message pushes after about 2 s.
  - **The headless host:** `/mcp` lists `notify`, and a message pushes from its page server.
  - **A pane hosted on one Mac and driven from another:** the driving Mac's notice.
  - **Answered first:** prompting the pane within 2 s of the message gives no push.
  - **Rate:** five calls in a row give one alert, then at most one more a minute later with the last words.
  - **Off the tailnet:** the generic text.
  - **Switches:** Messages off on the phone gives no push; the Mac switch off gives no Mac notice.
  - **PushNotification:** with Push when Claude decides on, a PushNotification call gives the same Varnick notice. With Remote Control set up, the Claude app doesn't push while the marker exists.
  - **An older pane:** a pane started before the build has no `notify` until it restarts.

## Out of Scope

- **Words in the encrypted payload,** so they'd show off the tailnet: ADR 0038's rule, kept (open question 5).
- **A view of the message on the Phone page** beyond the terminal, such as a strip above the pane or a line on Home.
- **macOS banners for messages:** `sessions-finish-unnoticed` option 02, when it ships.
- **Actions on the notification, and replying from it.**
- **Messages from terminals and other pane kinds.**
- **A per-session mute.**
- **The desktop notification Claude Code itself shows for PushNotification** inside Varnick's terminal.
- **Turning on Claude Code's Push when Claude decides** for the user.

## Further Notes

### Accepted 2026-10-15

The user asked to give Claude in a pane the ability to notify them, hooking into what Claude Code already has, pushed when it happens. Offered a `notify` tool of Varnick's or a hook on Claude Code's PushNotification, they chose "do both", with one notice kind, option 02's routing and the Mac notice included (relayed by the coordinator). The questions below are refinements within that choice.

### Decided 2026-10-15

The user took all five recommendations below, as written:

1. Yes: Varnick sets `CLAUDE_CLIENT_PRESENCE_FILE` to a marker the page server keeps while the host has a push subscription.
2. Yes: a Done is folded into a standing message with no time limit.
3. Yes: each session's settings allow `notify`. The check (below) found that `--settings` adds to the user's allow list, so the condition under which this stopped did not arise.
4. Yes: one alert per pane per minute, the newest words at the minute's end.
5. Yes: the words stay out of the push payload, and ADR 0038's rule is unchanged.

### The throwaway check, 2026-10-15

Run with Claude Code 2.1.300, a scratch `claude -p` whose `--settings` carried a hook on PreToolUse, PostToolUse and PostToolUseFailure that copied its input to a file, and a stand-in MCP server named as Varnick's is. The dumps hold paths and stay in the problem's scratch folder.

- **PostToolUse fires for an MCP tool.** Its input has `tool_name` (`mcp__<server>__<tool>`), `tool_input` (the arguments as sent), `tool_response` (the content blocks) and `mcp_server`.
- **An MCP tool that answers `isError` fires PostToolUseFailure, not PostToolUse.** The failure input has `tool_name`, `tool_input` and `error`. So a refused `notify` is never recorded, whatever the reader does.
- **`--settings` permissions add to the user's own.** The user's allow entry for a built-in tool kept working beside the `--settings` allow of the MCP tools; a tool allowed in neither was refused in print mode with no dialog. So `notify` can be allowed in each session's settings.
- **PushNotification could not be made to appear.** It is behind a server-side feature flag of Claude Code's (`tengu_kairos_push_notifications`) and the user's `agentPushNotifEnabled`. In a print-mode run on the user's account the tool was not among the deferred tools, and a search for it found nothing. Remote Control was not started, because it registers a session with the user's account. So whether PostToolUse fires for it is **unverified**; Claude Code's hooks page says every tool call in the loop fires it.
- **PushNotification's input, read from the 2.1.300 binary, not observed:** `message` (a non-empty string, described as under 200 characters) and `status` (always `"proactive"`). There is no title and no body. Its permission is none, so it needs no allow rule. Its result carries `message`, `pushSent`, `localSent`, `disabledReason` (`config_off`, `user_present` or `no_transport`) and `sentAt`; it succeeds with a `disabledReason` when it sent nothing.
- **`CLAUDE_CLIENT_PRESENCE_FILE` skips Remote Control mobile pushes only,** while the file exists, checked once per push-triggering event (documented in Claude Code's environment-variable reference, v2.1.181 or later). The desktop notification is a separate check and is not muted.

What the build does with it:
- The reader maps PushNotification's `message` to the title when it is one line of at most 80 characters, with no body. Otherwise the title is the first line cut to 80 and the body is the message cut to 300.
- The hook matches `notify` and PushNotification only, on PostToolUse alone.
- A PushNotification result whose `disabledReason` is `config_off` is not a message: the user turned Claude's proactive pushes off. The other reasons record a message, since Varnick's own routing decides where it goes.

### Open questions, recommendation first

1. **Set `CLAUDE_CLIENT_PRESENCE_FILE` to a marker kept while the host has a subscription?** Recommendation: yes. Without it, a pane with Remote Control on buzzes the phone twice: once from the Claude app and once from the Phone page. The cost is that the Claude app's own pushes stop while Varnick's are on.
2. **Fold a Done into a standing message?** Recommendation: yes, with no time limit, while the message stands unseen. The other choice is to fold only a Done within a minute of the message, which brings back the second buzz for a turn that ends a little later.
3. **Allow the notify tool in each session's settings** so it never asks? Recommendation: yes. A permission dialog for a notification would stop the turn and raise Needs you. If the check finds `--settings` replaces the user's allow list instead of adding to it, this stops and the user is asked.
4. **One alert a minute per pane, the newest words at the minute's end?** Recommendation: yes. The alternative is the tool refusing a second call within the minute, which can't apply to PushNotification's hook.
5. **Keep the words out of the push payload** (ADR 0038)? Recommendation: keep them out. The words of a message are what the rule protects, and on the tailnet the worker shows them anyway.

### Verified and inferred

- **Verified in the code at 5a76ad1:**
  - the hook settings both hosts pass claude, and the Stop hook's raw save;
  - that the headless relay passes no MCP config, so Screen and Panel tools are a Mac's alone today;
  - the MCP server's rule never to read or act, and its sets;
  - the turn reading both hosts send in `status` and `tabs`;
  - the notifier's one notice per pane, its cues and its presence lists;
  - the watcher's turn-date gate, settle, per-pane push gap and per-device cap;
  - the worker's read of the tab for a title;
  - the subscription switches' fallback to on;
  - the protocol at 27.
- **Inferred or taken from the coordinator, unverified here:**
  - PushNotification's behaviour and settings;
  - whether its hook fires and its input fields;
  - `CLAUDE_CLIENT_PRESENCE_FILE`'s effect;
  - how `--settings` permissions combine with the user's;
  - the memory cost per MCP server, from the 2026-10-13 snapshot of seven servers.

### Build order

After option 02 (shipped). The throwaway check comes first, then the shared tool and hook, protocol 28 and the Mac, then the page server and the page.

## Comments

**2026-10-17, at the user's ask.** The four notice switches, "sends me a message" among them, moved from Settings › Claude to their own Settings › Notifications section, which also links to Settings › Peers (where option 02's per-device line is). Where this option says Settings › Claude, read Settings › Notifications.
