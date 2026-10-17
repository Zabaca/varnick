# Privacy and security

Varnick works on your own data, mostly on your Mac, and runs programs as you: on this Mac, on your other Macs
and from your phone. This page says what it reads and sends, and who can make it act as you. It describes the
code as it is; where a statement rests on a design decision, the decision is in [`docs/adr/`](adr/). To report a
vulnerability, see [the end of this page](#reporting-a-vulnerability).

## What stays on your Mac

- **Your Chrome history.** Varnick reads the History of every Chrome profile and copies it into a local archive
  that only grows, with every profile's bookmarks beside it.
- **Your Claude Code transcripts.** It reads every transcript under `~/.claude/projects`, to list your sessions
  and make your prompts searchable, and keeps the last thing Claude wrote after each prompt (cut at 1,000
  characters), which only the search by meaning reads.
- **What you say and hear, while Listening is on.** It records the microphone and the Mac's system audio and
  writes what it transcribes, on this Mac, to the day's transcript file.
- **Saved audio, only with Settings › Listening › Save audio on (off by default).** It also keeps the sound itself,
  other people on calls included and the mic while Varnick speaks, as mono AAC (32 kbps) m4a files in
  `~/Library/Application Support/Varnick/recordings/` (layout: the guide's Listening section). They are never sent
  anywhere and Varnick never deletes them: you do. Nothing encrypts them beyond your Mac's disk encryption. Files
  already saved stay when the setting is turned off. Varnick's log says only that saving stopped, with an error
  code, never what was heard.
- **Pictures of the screen.** When it reads a window from a picture, the picture is never written to disk,
  logged or sent.

## What leaves your Mac

Out of the box, two things:

- **Requests to the pages in your history,** one each and without cookies, to read and store each page's own
  description. They go to the sites you visited.
- **Model downloads from Hugging Face,** when you ask, at fixed revisions.

Everything else leaves only when you turn it on.

### Paired Macs

Between Macs you have paired, Varnick copies, for Recent and search:

- **Your Claude prompts,** with each session's folder, title and agent, and the last thing Claude wrote after each.
- **Which tab holds each session,** and the tab's name if you gave it one.
- **Your whole browsing-history archive:** full page addresses, titles, the names of your Chrome profiles, visit
  counts and last visits, the terms you searched, and each page's description.

The other Mac keeps them until you remove it from the peer list (or it removes this one). Pair only Macs you
would show that history to.

### TypeSafe

Choosing TypeSafe for the relevance filter is consent to send what a feature backed by it needs, Varnick's own
panel and the names of your sessions and projects included. To keep things private, set the filter to **On this
Mac** or leave it off (it is off by default): then none of this happens.

- **Searches.** Each search, with the title, site and page description of up to 20 results. Never full addresses
  or tags.
- **Hey Varnick, with Varnick's own steps on** (Settings › Experimental; off by default, and Hey Varnick then goes to the voice session instead, below). Two calls. The text you say after "Hey Varnick" goes to TypeSafe's Jev, with today's date and time and
  **a list of your projects**, to decide what you mean: the time, something Varnick can't do, the screen, which project
  and which time it names, whether only your own things can answer it, and which of its words to search for. Each
  project in the list (up to 40, most recently used first) has its folder name, its other names (from its git remote
  and the title of its `CLAUDE.md` or README), a one-line description from its README or `CLAUDE.md` (cut to 120
  characters), its last three session titles and when it was last used; the list is sent twice in the call, once to
  choose among and once to refer to. Your paired Macs' projects go by folder name and session titles only. Then the
  same text goes again in a second call, with
  today's date and where this week started, and for each row Varnick found: its kind (page, bookmark or Claude
  session), title, site or the session's folder name, when (its weekday and part of the day, such as "Monday
  evening, 2 days ago", for the past week), and its own description or a session's prompts, cut to 300 characters.
  That is the top 20 pages, as a typed search sends them, and up to 3 sessions, which a typed search never sends.
  Never an address or a paired Mac's name. A time window's hours are worked out on this Mac from the label chosen.
  Both calls start before you have quite finished, so words said so far may be sent and then discarded. If TypeSafe
  doesn't answer in time, the first call's questions go to Text generation instead (below).
- **Point at the screen** (Settings › Experimental; off by default, and only with Varnick's own steps on). A request about the screen also sends the title of the window in
  front and, for each of its first 255 elements, the label, kind, nearby text and whether it is dimmed. That is
  the window's visible text, not only the text near its controls: a message list's subjects and senders, an open
  mail's body, a page's text in Safari, a file's name in a tab, the account's name in a sidebar. With Varnick's
  panel open and in front, it is read first like any window, so its session titles, folders, projects, agents,
  Macs' names, page titles and sites, and problem titles go too. A terminal pane's text is not among them. The
  elements never hold what is typed in a field, and a password field is not read.
- **Short lines read from a picture.** If the elements don't have the thing, or the window is a Chrome page, and Screen
  Recording is granted, a picture of that window alone is read for text on this Mac, and its short lines go too: at most 6 words and
  60 characters each, at most 150, with no positions. Lines inside a field the elements find (a native one, or a
  web page's in Safari or an Electron app) and inside the field with focus are dropped. **A field Varnick can't
  place is not, so typed text of 6 words or fewer there may reach TypeSafe:** a Chrome page's field, a canvas
  app's, a remote desktop's or a virtual machine's, one past the limits of the read, or one that moved before
  the picture was taken. Don't use this with a password or other secret typed in such a field (ADR 0021).

- **Tasks** (off by default; Settings › Experimental). While a task runs with the relevance filter on TypeSafe and a key
  saved, Jev chooses each step, one call a turn: the task you wrote; the page's address, title, links and buttons (their
  labels) and text blocks; for each link on the page, the title, headings, first lines and link names of the page behind
  it; the text being read as the answer; the labels of form fields and the values the task types into them (the name,
  email and address you wrote in the task, for example); the last few steps; and Claude's hints. A password, a one-time
  code and a card number are never among them: you type those in the page, and the harness never reads them. Without the
  filter on TypeSafe, none of this goes to TypeSafe and Claude chooses the steps instead (below). Not logged.
- **Judge steps of a saved Task** (Settings › Experimental › Tasks). A Judge step asks Jev one question in the same filter
  and key conditions: the question the Task's file wrote and, for a Choice, its options with their criteria, and the
  step's `state`, which is the values the Task's file bound into it (the Task's input and earlier steps' results, so
  whatever a Claude step wrote or the user typed into the Task's form, if the Task's file puts it there). Nothing else of
  the Run goes. The Task's author, usually a Claude session, decides what is in the state; read a Task's file before you
  start it. Without the filter on TypeSafe, none of this goes to TypeSafe. Not logged.

None of this goes to a model server.

### ElevenLabs

Saving an ElevenLabs key under Settings › Models › Keys lets Varnick ask ElevenLabs for your account's voices, when
you save it and whenever Settings › Listening opens; that request carries only the key. Choosing one of those
voices in Settings › Listening › Voice is consent to send every line Varnick speaks to ElevenLabs. To keep the
lines private, leave the voice on one installed on this Mac, which is the default: then no line is sent.

- **What is spoken.** The text of each line, with the voice's id and the key. An answer names pages, sites,
  page descriptions, session titles and folders, and what your prompts said, and can repeat words of your request.
  The fixed lines ("I couldn't answer that.") go too. Never audio from your Mac, or the rows themselves except as
  an answer repeats them.
- **The warm-up.** When "Hey Varnick" is heard, Varnick asks ElevenLabs for the chosen voice, to have the
  connection open when the answer is spoken. It carries the voice's id and the key and nothing of yours.
- **The fallback.** When ElevenLabs fails, is slow or can't be reached, the line is spoken again in the installed
  voice you chose before, on this Mac.
- **The key** is kept in the macOS Keychain and goes only to ElevenLabs, in a request header, and no redirect is
  followed. Varnick never reads it from the environment or a file, and never logs it or what it speaks.

### Anthropic, through Text generation

Text generation writes Hey Varnick's answers when Settings › Experimental › Answer with Varnick's own steps is on (otherwise the voice session answers, and nothing here is used). Choosing **Claude Code** for it (Settings › Models; the default for an install that never chose) is consent to send what it
needs to Anthropic, under your own Claude account and on your plan. Hey Varnick is off until you turn it on, and its
setting says so; nothing is sent before that. To keep the text on this Mac, choose **On this Mac**. An install that
already answered with it stays there when it upgrades.

- **What you say.** The request after "Hey Varnick", cut to 500 characters.
- **The decisions,** when TypeSafe isn't used (the relevance filter is On this Mac or off, or no key is saved) or doesn't
  answer in time: the same questions as TypeSafe's first call, as one prompt, with today's date and time and the list
  of your projects above. With Claude Code that goes to Anthropic, with a server to the server, and with this Mac's
  model nowhere.
- **The judging,** when the relevance filter is on TypeSafe and there is no key or TypeSafe doesn't answer (or the route's
  call to it already failed in the same request), or the filter is off: the request and today's date with the same rows
  TypeSafe's judge gets, up to 20 pages and 3 sessions (kind, title, site or folder, when and description or prompts, cut
  to 300 characters), as one prompt to decide which help. With Claude Code that goes to Anthropic, with a server to the
  server, and with this Mac's model nowhere. **With the filter On this Mac it never does:** if its model isn't ready, the
  top results are read unjudged, and nothing is sent.
- **The results it reads,** for the answer: each one's kind, title, site or folder, when (its weekday and part of the
  day, how long ago), and description (cut to 300 characters), and for a Claude session its prompts, your paired Macs'
  too. With them go today's date and where this week started, so "this week" is answered right.
- **What Claude Code itself sends** with a call: your account's token, and device and account ids in metadata, as a
  pane's Claude does.

It never sends your Claude settings, hooks, plugins, CLAUDE.md or memory, a `.env`, tools or files, nor the working
folder, the OS or the date that Claude Code would add (a filter drops them); the only date is the one in Varnick's own
prompt, above. Nothing is saved as a transcript, so a call is not a session: it is on no board and in no search. Each
answer counts toward your plan's usage limits.

The call runs through a copy of Bun inside the app, driving your own `claude` with the environment your login shell
builds, as a pane's does. Varnick reads that environment once per launch, keeps it in memory, never logs or writes it,
and gives it only to Bun and `claude`. It holds whatever your shell exports, other services' tokens included, as a
pane's Claude does; the model has no tools to read it back. An `ANTHROPIC_API_KEY` in it is removed, so your plan is
billed and not a key. When Claude Code can't answer or is slow, this Mac's Gemma writes the text if you have installed
it, and nothing is sent for that.

### Anthropic, and a search provider, through Answer from the web

Settings › Experimental › **Answer from the web** (off by default; shown, and used, only while Answer with Varnick's own steps is on; it needs Hey Varnick, the relevance filter on
TypeSafe with a key, and Claude Code found and logged in) answers what your pages, bookmarks and Claude sessions can't,
such as when a shop opens, from the web. Turning it on is the consent: there is no prompt per request. A request goes
to the web when nothing Varnick found helps answer it, or when the writer finds what it found too thin and no
session was read. A request that names one of your session folders, or is only a time ("what did I do last week"), never goes.

- **What goes to Anthropic,** through your own `claude` on your plan: the request after "Hey Varnick", cut to 500
  characters, with today's date and time and your Mac's unit system, in Varnick's fixed prompt. **Nothing about what
  Varnick found:** no row, kept or not, no title, folder or project name, no screen text.
- **What goes to Anthropic's search provider:** the search words Claude writes, sent by Anthropic. Claude Code's search
  tool is described as US only, so elsewhere the search may be refused.
- **What Claude Code itself sends** with a call, as above.
- **The one tool** is WebSearch, which runs on Anthropic's side. There is no tool that reads your files, the shell
  environment or the Mac, and none that fetches pages from your Mac.
- The call is not a session: nothing is saved as a transcript. Each answer is two or three model turns and a search,
  and counts toward your plan's usage limits.
- Varnick speaks a sentence or two naming where the answer came from, and writes them to today's transcript. It does
  not log the request, the prompt, the search words, the reply or the answer.

### Anthropic, through Tasks

A task (Settings › Experimental › **Tasks**, off by default) is written in a Website pane and carried out in that pane's own
browser, which has none of your cookies or logins and keeps nothing when it closes. Your own `claude` writes the values it
types and steers, in two conversations kept open for the length of the task, on your plan.

- **What goes to Anthropic:** the task you wrote; each page's address, title, links, buttons, text and form fields (their
  labels and, for a field the task filled, its value); the previews of its links; the trail of every page the task has
  visited, what was done there and what it led to; and the values Claude wrote itself. The first time Claude is shown a
  page, it is shown whole; after that, what changed. When Jev isn't used (the relevance filter isn't on TypeSafe with a key
  saved, or Jev failed three times in a row), Claude also makes each step's choices, so each step is a message.
- **What never goes:** a password, a one-time code or a card field's value (ADR 0039 says which fields). The page script
  does not read them: it sends only whether such a field is filled. You type them in the page. Anything else you type in
  the page, in a field that isn't one of those, is shown to Claude (and to Jev) as that field's value, like one the task typed.
- **What Claude Code itself sends** with a call, as above. The conversations are not sessions: nothing is saved as a
  transcript.
- Each message is a model turn and counts toward your plan's usage limits; a task takes from a handful of messages to
  the 20 it is limited to, plus a call for each step when Jev isn't used.
- Varnick doesn't log a task, a page's address or title, a label, a value or a reply; only each step's kind, who acted,
  how long it took and the task's counts.

### Anthropic, through Task Runs

A saved Task (a JSON file in `.varnick/tasks`, run from `!task`, by a session's `task_run` or by another Task; Settings ›
Experimental › **Tasks**, off by default) is carried out by Varnick in steps, and two kinds of step send to Anthropic.

- **A Claude step** is a hidden Claude session like an automation's run, on your plan, started in the folder the step names
  (Home when it names none) with the permissions you set in Settings › Tasks. What goes to Anthropic is what any session
  sends: the step's prompt (with the Task's input and earlier steps' results filled in as the file bound them), what Claude
  reads and runs, and the result it gives back through the `task_result` tool. Its MCP server lists `notify` and
  `task_result` alone: no Screen access, Panel access or Varnick's automation and task tools. Its conversation is a session
  like any, resumable from the Run's view.
- **A Judge step asks Claude instead of Jev** when the relevance filter isn't on TypeSafe with a key, Jev fails, or Jev is
  not sure (below 0.7): the question, the options and the step's state go to your Claude Code in a conversation opened for
  that one call and ended after it, not saved as a session. Never this Mac's own model for a pick.
- **The tools:** `tasks_list`, `task_run`, `task_run_status` and `task_check` answer a session with the Tasks' names,
  descriptions, schemas, problems and results, which goes to Anthropic with that session. `task_run` starts a Run that draws on
  your Claude subscription with nobody asked first, so a session starts only what you asked for.
- Varnick doesn't log a Task, an input, a state, a prompt or a result: only the tool, the kind of outcome and durations.
- A Task's Run stays on this Mac. Its notice is not pushed to the phone, and no paired Mac or phone lists it.

### Anthropic, through Automations

An automation (Settings › Experimental › **Automations**, off by default) starts a Claude session on a cadence, with the prompt you
saved. It is a session like one you type: its prompt, what Claude reads and the transcript go to Anthropic on your plan, and are
kept in Claude Code's own folders on this Mac. Nothing else leaves because of it. A run never gets Screen access's or Panel access's
tools, so what those send is not sent. Each run is at least one model turn and counts toward your plan's usage limits; nothing
caps how many a day's cadence adds up to beyond its 15-minute floor and one run of an automation at a time. The automations
(names, prompts, folders) are in `automations.json` in Varnick's support folder, and what became of each run (its state, the prompt it
started with and its conversation's id) in `runs.json` beside it; both are owner-only and are not sent to paired Macs or the
phone; a run's tab is listed to them marked as a run nobody opened, which other Macs keep out of their lists and the phone lists under Runs, with the automation's name as its title.

An automation kept on a headless host (Settings › Automations, a section for each) is saved on that host over ssh, from any Mac it lists: its name, prompt, folder, cadence and permissions are in `automations.json` there, and what became of its runs in `runs.json`, both owner-only in the relay's state folder, and the prompt goes to Anthropic from that host with the session. The host fires it from a systemd timer that runs its relay once a minute (added with the installer's `--automations`); nothing else is resident.

With Automations on, a Claude session you start can also list, make, edit and switch automations (below). A session that lists
them sends every automation's name, prompt, folder and cadence to Anthropic with the rest of that session, as anything else it reads
in the conversation; the tools send nothing else, and the list never leaves this Mac but through that session.

### Anthropic, through the Voice session

Every "Hey Varnick" request goes to a Claude Code session of yours in Home, out of sight until you open it (the default; Settings › Experimental ›
Answer with Varnick's own steps turns it off and answers the older way, above). It is a session like one you type, so everything it reads goes to
Anthropic on your plan with it, and the transcripts are kept in Claude Code's own folders on this Mac and are found by session search like any
session's:

- **What you say after "Hey Varnick",** with a line in front of every request that gives today's date and time, whether it was said on this Mac
  or from the phone, and the unit system (US or metric), and asks for a short spoken answer.
- **Whatever the session does for the request:** the files it reads, the commands it runs and their output, the pages it fetches, the web
  searches it makes (Claude's search words go on to Anthropic's search provider), and pictures of your screen when it uses Screen access's
  `look` with a picture, which it can with the screen tools on.
- **What its search tool finds.** The session can search your history, bookmarks and Claude sessions through Varnick, which answers up to 20
  pages (title, site, address, when, and a description) and 3 sessions (title, folder, when, prompts cut to 300 characters, the conversation id and,
  for one on this Mac, the transcript's path, or the paired Mac's name). Nothing is filtered or judged first, so rows that do not help go too.
  The tool is listed for sessions started as the voice session, until they are opened, and the app refuses a call from any other pane; a pane id is not a
  secret, though, so any process on this Mac that knows the voice session's pane id and can open Varnick's socket could call it, as with the task tools.
- **The first request and its hint are saved as the session's prompt** in `sessions.json` in Varnick's support folder, with the session's record, as any
  session's first prompt is. Later requests are in Claude Code's transcript only.
- **Each request counts toward your plan's usage limits;** it is at least one model turn, and a session is kept until 10 minutes after your
  last request.

Nothing of a spoken request goes to TypeSafe, and Text generation, the relevance filter's part in a spoken request, Answer from the
web and Point at the screen are not used for it. The Voice session needs Hey Varnick on (for Voice mode on the phone too: nothing runs with permissions skipped on a Mac whose user never turned it on), Keep sessions running and Claude Code found and logged in, and
Claude Code's one-time warning for skip-permissions mode accepted; when one is missing Hey Varnick says so and the setting shows it beside Hey Varnick, and
nothing falls back to Varnick's own steps, so nothing is sent by another route.
What the session does is shown in its tab (Settings › Listening › Show beside Hey Varnick, or its Needs you notice); Varnick's log says only how long a
request took, whether the session was started or reused, and how it ended, never a word of the request, the answer or what Claude did.

### Anthropic, through Screen access

With Screen access on (off by default), the Claude sessions started or restarted after you turn it on can read
the window in front, or one they name. What they read goes to Anthropic with the session and stays in its
transcript on this Mac: the window's title, its first 255 controls' label, kind and nearby text and, for a
window that lists nothing or a Chrome page, its short lines read from a picture (the same limits as above), and
which control has the keyboard focus, by its id or its kind ("a text field that isn't listed", "a password
field"), never its label or what it holds. The same caveat holds: typed text of 6 words or fewer in a field
Varnick can't place may be among the lines. Nothing on this path goes to TypeSafe. Varnick's own panel is never
read.

A session can also ask for a **picture** of the window (`look` with `picture`, or one area of it). A picture shows
everything on the window, including what you typed into a field, which the listing leaves out, and it goes to
Anthropic with the session and stays in its transcript on this Mac. Varnick paints black the password fields it
can see before it sends the picture. It can't see one where the app doesn't report it (a Chrome page whose tree
is hidden, a canvas app, a remote desktop, a virtual machine), in a window with more controls than it reads,
where an app shows a password in a plain field ("show password"), or in a field that has no frame, and those
show. The reply says when it reached only part of a window. The picture needs Screen Recording. Varnick's log
holds its kind, pixel size and byte count, never what it shows. If you don't want what is on a window sent to
Anthropic, leave Screen access off, or close the window first.

A session can also ask for a picture of **every display, or of one** (`look` with `screen` or `display`, or one area
of them). **Nothing is hidden in it.** It shows everything on those displays: Varnick's own window, with other
sessions' text, whatever you typed, and every password field, because Varnick reads none of the windows on a
screen and so can't find their fields to paint black. It goes to Anthropic with the session and stays in its
transcript on this Mac. The reply says nothing was blacked out. It needs Screen Recording. The log holds the number
of pictures and each one's kind, pixel size and byte count, never what they show. If you don't want your screen sent
to Anthropic, leave Screen access off, or close what you don't want seen first.

### Anthropic, through Panel access

With Panel access on (off by default), the Claude sessions started or restarted after you turn it on can read what
Varnick's panel shows, through Varnick itself (ADR 0031). What they read goes to Anthropic with the session and stays
in its transcript on this Mac: whether the panel is visible, key and pinned; what it shows, with the names and kinds of
the tab and panes in it (the session board's selected card, Settings or the Restart Varnick card when one is up);
and which of those has the keyboard. They can also read **the session board** (`board_read`): for every session
it lists, on this Mac or a paired one, the title (which can be a prompt's first line or a name you gave it), the
folder, the Mac, the turn and how long, any background work, the card's note, the problem or option it is linked
to, and for the Problems tab the problems' titles, projects and the sessions on them. A paired Mac's cards are as
last fetched: the read asks no paired Mac. They can also read **the text on the screen of any terminal pane**
(`pane_read`): another session's, a shell's, or their own. That is whatever the terminal shows at that moment, as
you would see it: a session's latest exchange, a command's output, a secret that was just printed or typed where it
echoes. Only the live screen is read, wherever you have scrolled to, and anything that scrolled off it is not read, and a pane showing a card of a session another Mac
controls gives the last screen the card holds. A page, a file or a custom app gives its kind and title only. All
of it goes to Anthropic with the session. The search field's mode (the session list, a prompt, a `?` search or a `!`
command list) and whether it is empty are read, never what is typed in it. Nothing on this path goes to TypeSafe.
It reads no window through Accessibility and needs no permission, and turning the switch off stops every session's
tools at once. Varnick's log holds the tool, the outcome's kind, a count of lines and the time, never a name, a title or a screen's
text. Reading a pane's screen resizes, writes to and focuses nothing in it. If you don't want what a terminal shows
sent to Anthropic, leave Panel access off.

They can also read **your Outline** (`outline_read`, only while Settings › Experimental › Outline is on), which is otherwise kept in a file on this Mac and nowhere else:
every bullet's text and note and whether it is completed, collapsed or a mirror, from Home or from a bullet down, or the
rows as you see them with your zoom, filter and caret. All of it goes to Anthropic with the session and stays in its
transcript on this Mac. The read loads `outline.json` as showing the Outline would and never writes it, and a file
Varnick can't read is refused. Varnick's log holds a count of lines, never a bullet's text or a filter word. If you
don't want your bullets sent to Anthropic, leave Panel access off.

A session can also change your Outline (`outline_act`) without asking: add bullets, edit a bullet's text or note, complete,
delete, move, indent, outdent, collapse or mirror one. Each change goes through the Outline's own edits and is one step of
your undo (⌘Z), and an edit to the bullet you are typing in goes in as if typed, your caret kept at its place in your text. Varnick's log holds the action and a count
of lines, never a bullet's text. If you don't want a session to change your Outline, leave Panel access off. With
Settings › Experimental › Outline off, `outline_act` is refused too, even for an edit already under way.

A session can also change what the panel shows (`show`): the search, the board, the Problems tab, the Outline, a pane's tab, or a
`!` command (`!transcript`, `!kanban`, `!problems`, `!outline`), the same changes your keys make. It never shows, hides or pins the
panel, never takes the keyboard from the app you are in, never turns on Listening (`!listen` is refused), and is
refused while Settings or a dialog of Varnick's shows and for two seconds after a key you pressed in the panel. Showing the
Outline (`view: outline` or `!outline`) is refused while the Outline switch in Settings › Experimental is off.

A session can also press keys in the panel (`keys`): text and key combos for the search, the session board or your Outline, sent inside Varnick
to the panel's own key handling, as your keys go. Nothing is sent to another app and no permission is used. It works only while
the panel is open with the keyboard, never opens it, and stops at once when you type in it. It never presses the keys that end,
mark done or restart a session, Varnick's shortcuts that work anywhere, quit, paste, or Return where it would start a Claude
session, turn on Listening or open a page. Varnick's log holds the tool and counts, never the keys. If you don't want a session
to press keys in your panel, leave Panel access off.

### A model server you name

With Server chosen for Search embeddings or Text generation (Settings › Models), Varnick sends the server the
searches you type, the prompts typed in the panel, and the text of every page and session it embeds, which for
a session includes Claude's last reply to each prompt (paired Macs' sessions included). With Hey Varnick on, the
words you say go to the embedding server with the request's search words, and the request with the titles,
sites, folders and descriptions of the results it reads out go to the Text generation server; words said
before you finished may be sent and then discarded.

Varnick accepts only an address whose name resolves to your tailnet or this Mac, over HTTP or HTTPS, and follows
no redirect and no system proxy. It does not pin the address between its check and the connection. The server
can read all of this and the key you give it (kept in the Keychain), so name only a server you run.

### Custom apps and the npm registry

Varnick itself makes no request to list or install the catalog's apps: they ship inside the release, and turning one
on copies files on this Mac. An app's **packages** are fetched by Bun, from the npm registry it is set to use, in
three cases:

- the first time you pick an app that has packages, which for a catalog app is Scratch's Vite and React plugin;
- Scratch's first use in each project, which installs React for the pages;
- any app of your own that has a `package.json`, the same way.

The registry sees the package names and your Mac's address. Offline, the pane shows Bun's error and nothing runs.
What an app does beyond that is its own business, and each catalog app's row says what it fetches or sends.

### Peers and the Phone page

They talk to the hosts and devices you list, over SSH and Tailscale (below).

## What can act as you

### Custom apps

A custom app is code that runs as you, and picking one runs it. It has your rights, and its pane has Varnick's macOS
permissions (see Screen permissions reach every pane, below). Nothing sandboxes it. The apps in Varnick's catalog
are reviewed in its repository before they ship and run only the code of the release you installed; that is a
review, not a restriction. A project's `.varnick/custom-apps/` is read from any repository you open a pane in, so a
cloned repository's apps appear in the picker, and picking one runs its code.

### Skip permissions

Settings › **Skip permissions** starts Claude sessions with `--dangerously-skip-permissions`: Claude Code then
runs its tools, shell commands and file edits included, without asking, in the session's folder and as your
account. Anything that can steer a session, such as a web page Claude reads, a file in the repository or a
prompt, can then act with your account's rights.

- **It is off for a new install.** A Mac that ran an earlier Varnick keeps what it had stored, and can turn it
  off in Settings.
- **A peer's start request carries the peer's own choice,** and the host follows it whatever its own setting
  says. A listed peer already reaches the host's account over SSH, so this grants nothing SSH doesn't. The
  Linux relay's default, for a request that doesn't say, is off.
- The Phone page's sessions follow the host's setting.

### Peers over SSH

Peers pair over SSH, with your own keys (ADR 0007). The boundary is:

- **The peer list.** A request other than `hello` is answered only for a Mac the receiver lists, and an unlisted
  Mac is never contacted except by Find Macs and Add, which you start. The list is checked against the name the
  request gives; that name is not a credential, the SSH login is.
- **Your SSH keys.** Varnick runs the relay with `ssh` as the account you gave, with no password prompts
  (`BatchMode`), accepting a host key on first contact and refusing it if it later changes. Whoever holds a key
  that logs in as that account can run the relay, and could do anything that account can anyway.
- **The relay runs as you,** with your files and tools. It is Varnick's own binary (`varnick-peer` on a headless
  host), listens on no network port, and on a Mac talks to the app through a socket only your account can use.

### The Phone page

- **It is off by default** (Settings › Serve the phone page; on a headless host, the installer's `--page`).
- **It is published only with `tailscale serve`, to your tailnet,** on HTTPS port 8444. Varnick and the
  installer never run `tailscale funnel`, and refuses to publish if Funnel is on for that port or its state can't be read.
- **Who is calling comes from Tailscale.** The server asks Tailscale (`tailscale whois`) who owns the address
  `tailscale serve` forwards, and serves only a device you listed on that host. Everything the page does is a request to the host's own relay,
  as that device. Changes need a `POST` with a
  matching `Origin`, and websockets are checked against it.
- **Installing it as an app keeps no session content on the phone.** The page's service worker answers a page load that failed
  on the network with a note naming the host, and nothing else: it caches no reply, and every other request goes to the host as
  before. Every reply is still `no-store`. The only thing the page stores on the phone is whether you dismissed the install offer.
  The manifest, the icons and the worker are served only to a listed device, like every file of the page.
- **Notifications go through Apple's or Google's push service,** the only request the page server makes outside the tailnet, and
  only after you turn them on in the page, for that host. A push carries ids and the kind of notice (done, needs permission, an
  error and its kind) and nothing of the session: no title, prompt, folder or screen. It is encrypted for your phone's browser
  (Web Push, `aes128gcm`), padded to one size and sent alike every time, so the push service can't read it and can't tell one kind from
  another; it sees that a push went, when, from this host's address, to which browser. The phone reads the session's title from the
  host over the tailnet when the push arrives; off the tailnet the notification names only the host. The push is signed with a key
  each host makes for itself: in the Keychain (Varnick's own item) on a Mac, an owner-only file on a headless host. It names
  Varnick's public site, never your email. To choose between your Mac's own notice and the phone, each Mac tells the hosts it has a
  pane on whether you are at it (seconds since your last input, whether the screen is locked or asleep, and which sessions it holds a
  notice for or shows on screen) over the SSH link that already carries its status requests. That goes to the host's page server on your
  own machines, and never into a push. The push key reaches the server through an owner-only file it deletes at once, not its environment.
- **A message a session sends you reaches your lock screen, and no push service.** A Claude session can call a `notify` tool (or Claude
  Code's own push notification) with a title and a body of its own words. Those words go to the Macs that follow the session and to the
  host's page server, over the links you already have, and your phone's worker reads them from the host over the tailnet when the push
  arrives and shows them as the notification, so they show on a locked phone. A push never carries them: Apple and Google see a push
  of the same size as any other. Off the tailnet the notification says only that a session sent a message. A session decides what to
  say, so put nothing private where you would not want it on a lock screen; at most one alert a minute per session and 60 pushes an
  hour per device bound it. While a host has a push subscription, Varnick sets Claude Code's client-presence file so Claude Code skips
  its own Remote Control mobile pushes, and Varnick's decide alone.
- **A listed device can do most of what a Mac peer can:** list sessions, start one in a project the host lists,
  take over and type in a terminal. Not the search sync, upgrades or restarts. List only devices you control.

**Known weakness: loopback mode.** The server listens either on a Unix socket in a folder only your account can
enter (socket mode), or on `127.0.0.1:18444` (loopback mode). In loopback mode any process on the Mac, other
accounts' included, can send the headers the server trusts, pose as a listed device, and so start and drive
sessions: a shell as you. Tailnet addresses and the page's name aren't secrets. This is to be fixed.

Varnick falls back to loopback when it can't serve a socket: the Tailscale app's own command line can't, an older
standalone one can't, none was found or answered, or the Tailscale daemon refuses a socket to a user who isn't
root (Homebrew's does). Settings names the reason, and the page shows a "Loopback mode" note. Until it's fixed:

- **A refused socket:** press **Use a socket** in Settings (ADR 0011 has the fix outside Varnick for a Homebrew
  daemon). It runs the same `tailscale serve` as root, through macOS's password prompt: the one place Varnick asks
  for your password, and it runs the `tailscale` executable Varnick found, whoever owns that file. Cancel the
  prompt and the page stays on loopback.
- **The Tailscale app's command line:** updating the app doesn't help. Varnick uses it whenever the app is
  installed, so a standalone command line takes over only on a Mac without the app.
- **An older command line:** install a newer one. **None found or answering:** install one where Varnick looks
  (the [guide](guide.md#requirements) lists the places).
- Or don't serve the page on a Mac other people have accounts on, or that runs programs you don't trust. A
  headless host always uses a socket.

### Upgrades from origin/main

Settings › Peers › **Upgrade** fetches `origin/main` in the checkout Varnick runs from, fast-forwards to it and
runs `make build`, which runs whatever that commit holds, the `Makefile` included. So anyone who can push to the
repository a Mac fetches from can run code on it as you, once you press Upgrade (or Upgrade all, which asks once
and lists each machine). A fork fetches its own `origin`: check which remote a checkout uses before upgrading it.
An upgrade leaves alone a checkout that isn't on `main` or has uncommitted changes to tracked files, and refuses
one whose `main` and `origin/main` have each moved on. A restart is separate and asks again.

The Linux installer builds the committed `Packages/VarnickPeer` at its own checkout's `HEAD`, not `origin`'s.

### Screen permissions reach every pane

Point at the screen and Screen access ask macOS for Accessibility, which lets a process read and drive any app's
windows, and Screen Recording, which lets it see anything on the screen. macOS attributes every process in
Varnick's panes to Varnick, sessions kept running in zmx included, so **every Claude session and shell there gets
both**. A session started with Skip permissions can read and drive any app and capture the screen without
asking. A grant to zmx or to another program a pane runs is never consulted.

Turning either switch off doesn't revoke the permissions; removing Varnick from System Settings › Privacy &
Security does. A signed build keeps them across rebuilds (ADR 0022); an ad-hoc one may not (not verified). macOS
may also ask again after some weeks whether Varnick may keep recording (not verified).

Point at the screen itself only reads the window in front, and only when you ask about the screen. The arrow it draws can't
take focus or clicks, and goes by itself.

### Tasks act as you on a site, and wait for you

A task (Settings › Experimental › Tasks, off by default) clicks links and buttons and types into forms in a Website pane's own browser,
as you would, to carry out what you wrote. It is the other way round from Screen access: it acts inside Varnick's web view only,
never on your screen, needs no permission, and brings nothing to the front.

- **It can do anything a site lets a visitor do,** account creation and a purchase included, with the details you wrote in the
  task and Claude filled in from it. What it doesn't do: type your password, a one-time code or a card number (you type those
  in the page), tick a terms box Claude marked as yours (you tick it), or press a form's submit without you. **Every form
  submit but a search box's asks** ("Allow" lets Varnick press it, "I'll do it" waits for you to press it in the page), and so
  does any button on a page that has a form, a script-handled "Place order" included, and any link on a page that has a form or
  that has no real address (`#`, `javascript:`). A submit the page itself makes as a field is filled is held until you allow it.
  On a page with no form, a link to a page is an ordinary click: a site that changes things when such a link is followed, or a
  script-handled button on a page with no form, is not stopped by this (inferred, not tried).
- **A click or a key of yours in the page pauses the task** before its next action; Resume hands it back. Stop ends it at once.
- The pane's cookies and storage are its own, empty at the start and gone when it closes, so a site never sees your logins and a
  task can't use them.
- **What steers a task can steer it:** a page it reads is read by Jev and by Claude, and a page that talks to them is read like
  any text. The gates above are in code, not in the models' hands.

### Home is marked trusted in Claude Code

When Varnick makes `Home` (`~/Library/Application Support/Varnick/Home`), it sets that one folder's trust in Claude Code's own
`~/.claude.json`. It is the only thing Varnick writes there, it changes that one value and no other byte, and it never does this for
any other folder. How is in `docs/agents/where-it-breaks.md`.

### Automations act while you are away

An automation (Settings › Experimental › Automations) starts Claude sessions with nobody there to answer a dialog. Which tools it
may use without asking is yours to set per automation: by default it follows Skip permissions, as a prompt you type does, and an
install that predates that setting has it on, so such a run runs any command, edit and fetch without asking, in its folder and as your
account. The choices that narrow it are Ask (a command that is not allowed waits for you, and Needs you is raised) and Allowed tools only
(anything not allowed is refused with no dialog; Claude Code's read-only tools and commands still run).

- **A run reaches the screen the way every pane does.** It gets no Screen access or Panel access tool, but a shell command it
  runs inherits Varnick's Accessibility and Screen Recording (see Screen permissions reach every pane, above). With permission
  checks skipped that covers every command; with Ask or Allowed tools only it covers the commands you allowed. The editor says so.
  A headless host has no screen and no macOS grants, so an automation kept there reaches only what its account can; it suits one that allows broad shell use, and with permission checks skipped every command a run tries is allowed, as the host's own user, with nobody there to answer. A run there follows the host's own Skip permissions unless the automation says otherwise.
- **What steers a run can steer it:** a file in the folder, a page it reads, a prompt that quotes either. A run is as exposed as
  a session you leave unattended with the same permissions.
- **A session can set up unattended runs, with no approval step of Varnick's.** With Automations on, every Claude session started or
  restarted afterwards can list, make, edit and turn on or off your automations through Varnick's tools (not a run's own session,
  and not behind Panel access). Claude Code asks you before each call unless Skip permissions is on, which is its own check. What a
  session writes becomes a prompt that runs on a cadence while you are away, so a session that reads something hostile can be steered
  into making one. A session may follow Skip permissions as a prompt you type does, choose Ask or Allowed tools only, and switch an
  automation you set to Skip. It can't set Skip, edit an automation set to Skip, delete one or run one now, **but it can grant a run tool
  rules** (`allowed_tools`, a broad one such as `Bash` included), so with Skip permissions off a session can give an unattended run more
  than a prompt you type gets. That is your decision, recorded on 2026-10-15, and the mark names the rules a session set. You are told by
  a mark on the automation in Settings and in the Runs tab until you open its editor, switch it or press Seen; there is no notice. Any process on this Mac that can open Varnick's socket can make one the same way, as for Panel access, with no grant.
  The log names the tool and whether it was done, never a name or a prompt.

### The Voice session acts on what the microphone hears

The Voice session runs with permissions skipped: Claude Code never asks before a command, an edit, a fetch or a screen tool, whatever Skip
permissions says (that was the choice made for it, so a spoken request is not stopped at a dialog nobody is looking at). So anything the
microphone hears that starts "Hey Varnick" can make it run a command on this Mac as your account, in Home and anywhere your account can reach:
your own voice misheard, a video or a call played through the speakers (Listening hears the Mac's audio too), or another person in the room.
It also has Varnick's tools your other sessions have (Screen access and Panel access when they are on, notifications, automations and Tasks),
which can click, type and press keys without asking. Settings › Listening says so beside Hey Varnick. If that is too much, turn on Settings › Experimental ›
Answer with Varnick's own steps: that Hey Varnick only reads, searches and answers, and opens nothing (the voice session is then off, and so is Voice mode on the phone).

- **It is a session like any other in what it can reach:** Varnick's Accessibility and Screen Recording are inherited by the commands it runs
  (see Screen permissions reach every pane, above).
- **A question or a plan it raises waits for you.** Varnick says "Claude needs your OK in Varnick." and raises Needs you; the session opens from its
  notice, and what Claude says after that is read in the pane, not spoken.
- **Its tab is out of sight until you open it,** and once you have, it is yours: Varnick never types into a session you opened, and from its next start or
  resume it is an ordinary session: it follows your Skip permissions and has neither the search tool nor the voice hooks.

### Voice mode on the phone

Voice mode (the Phone page, on a Mac's page; it needs Hey Varnick turned on at that Mac, and is refused while Answer with Varnick's own steps is on) sends the phone's microphone audio to that Mac and gets audio back. It is the Voice session's second surface, so everything above holds for it: **anything your phone's microphone hears while Voice mode is on can make the Mac run commands, unasked.**

- **The microphone is the phone's, asked for when you tap Start.** The page sends audio only between Start and End, and only the stretches it takes for a request (it listens for speech and sends from the first word to a pause, with the 300 ms before the first word, which it keeps in memory while it listens), never continuously. The browser's own microphone indicator is on the whole time.
- **Each chunk is briefly visible on the Mac as the argument of a relay process** (a request is one base64 argument), to anyone on that Mac who can list processes. It is not logged or kept.
- **The audio goes to the Mac over the tailnet and nowhere else.** The Mac turns it into text on-device (Listening's transcriber) and does not keep it; the text goes to the Voice session, and from there to Anthropic as ADR 0042 says. The reply's audio is made on the Mac, by the installed voice or, if you chose one, by ElevenLabs (which then receives what the phone is told, as everything Varnick speaks).
- **Nothing of the exchange is kept on the phone,** and the page server logs the method, path, status, device and time of a request, never the audio, the words or the answer. The Mac's log holds durations and kinds. The session's transcript on the Mac is a session's, found by search like any.
- **A quiet tone plays on the phone for as long as Voice mode runs,** to keep the page from being frozen while it is in the background.
- **A question the session asks is answered in the session's terminal,** opened from the page with Take over, as any session is.

### Screen access acts without asking

Screen access (ADR 0023) gives the sessions started or restarted while it is on a `varnick` MCP server with
`look`, `point`, `click`, `type`, `drag` and `window`.

- **A session can click, type, drag and move windows for you, and nothing asks.** The arrow shows on the target
  for a second, then the app comes to the front (not for `window`) and the action happens: no approval prompt, no
  per-pane switch, no list of apps to keep out. A session with Skip permissions gets no prompt from Claude Code
  either; one without gets Claude Code's own prompt for an MCP tool you haven't allowed (inferred, not checked).
  Whatever can steer a session (a page it read, a file, a message) can then act as you. Typing is the strongest:
  it can type a command into a terminal, a message into a chat or a form's fields.
- **Typing is made of key events, and a field's value is never set.** The app sees keystrokes as if you typed
  them, in the app in front. `look` never reads what a field holds, so a session can't check what it typed except
  by selecting the field's contents first and typing over them.
- **Nothing is typed or pressed while a password field has focus,** where Varnick can see one. It can't where the
  app doesn't report it: a Chrome page whose tree is hidden, a canvas app, a remote desktop or a virtual machine.
  A session can type into a password field there, as ADR 0021 accepted for reading. Varnick can't tell a password
  you meant to give from one a session found in a file or a page, and what a session types goes to Anthropic with
  its context, so you type it yourself.
- **Some combos are refused:** Varnick's own shortcuts that work anywhere (show or hide, pin, Listening), and macOS's
  log out, lock screen and Force Quit. Every other combo goes to the app in front as if you pressed it, ⌘Q and ⌘W
  included. A click or drag on the menu bar can still reach Apple menu › Lock Screen or Log Out.
- **Typing stops** when you turn the switch off, bring up Varnick's panel, or another app comes forward.
- **Varnick's log never holds what a session typed.** It holds the tool, the outcome's kind, how many characters
  and keys went, and durations.
- **It adds little today,** because every pane already has the permissions (above): a session could already use
  `osascript`, `screencapture` or its own code. Screen access gives it a supported way with an arrow and a
  switch, not a boundary.
- **The server only relays.** `Varnick --mcp` sends each call as one line on a socket only your account can open,
  and the running Varnick answers. A paired Mac or a device can't send one: the peer relay refuses it. Any
  process of yours on this Mac can, naming any pane's id; the id is a label, not a credential.
- **`look` can return a picture of a window,** which takes nothing from the screen but that window (see above for
  what it shows and what is hidden), **or of the whole screen,** which takes everything on it and hides nothing
  (see above).
- **Varnick's own window is refused for reading controls and for actions,** though not in a picture of the screen
  (above), and so is a session another Mac or a device is in control of. Turning the
  switch off refuses every call at once. `window` moves no pointer and brings no app forward.

### The downloaded app moves itself to Applications

Opened from a download (macOS runs it from a temporary copy) or straight off its disk image, Varnick offers to
move itself to `/Applications`. If you agree, it first checks that the new copy's signature is valid and carries
the same team and identifier as the running copy, and only then removes the "downloaded from the Internet"
quarantine attribute from that copy, so macOS doesn't run it from a temporary copy again at each open. It removes
that attribute from nothing else. It replaces an older Varnick in `/Applications` only once that has quit, and
puts it in the Trash. It never asks for an administrator password: on an account that can't add apps to
`/Applications`, it says so and stops.

### Downloads are pinned and checked

The build checks the Metal shaders, zmx and Bun against SHA-256 digests in the `Makefile`; the Linux installer does
the same for zmx and Bun; the models download at fixed revisions. The text helper's packages (`@zabaca/agent` and the
Agent SDK) are pinned in `TextHelper/package.json` and install from a committed lockfile, frozen. A catalog app's packages are pinned by a
`bun.lock` committed beside it, which holds an integrity hash for every package, and review makes sure it is in step
with the app's `package.json`. The first pick installs with `--frozen-lockfile`, so it fails rather than resolve
versions the lockfile doesn't name.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this repository,
then **Report a vulnerability**. Please don't open a public issue or pull request for a vulnerability. No email
address is published for reports.
