---
problem: models-set-up-per-feature
title: A Models section in Settings, with text generation on this Mac naming sessions
summary: Settings gets a Models section that sets up the model for each role (Search embeddings, Relevance filter, Text generation) and holds keys by provider. Features keep their switches, and a switch whose model isn't set up points to Models. Text generation is new, with Gemma 4 E2B downloaded once and run in Launchy's process with MLX. Its first use is session titles, made from the first prompt and shown in place of Claude Code's own title. A name the user gives always wins.
status: shipped
---

## Solution

Settings gets a **Models** section, beside Claude, Search, Listening, Peers and Shortcuts. It is the one place to pick and set up the model for each role, and to hold keys:

- **Search embeddings**: Qwen3-Embedding 0.6B, 8-bit, the only choice. Its download, progress, failure and Retry move here from Search.
- **Relevance filter**: TypeSafe or On this Mac. The choice and the checkpoint import move here from Search.
- **Text generation**: Gemma 4 E2B, 4-bit, the only choice for now. It is new, and downloads once the way the embedding model does.
- **Keys**, grouped by provider: TypeSafe today.

Features keep their on/off switches in their own sections:

- Search has **Semantic search**, a new switch; today it is on once the model is downloaded.
- Search has **Relevance filter**; today's Off becomes this switch.
- Claude gets **Session titles**, the first use of text generation.

A switch that is on while its model or key isn't set up says so and links to Models ("Needs a model: Settings › Models"). It doesn't hold a download button of its own.

With Session titles on, Launchy asks Gemma, on this Mac, for a short title for each conversation a Claude pane here is on, made from the first prompt the user typed in it. That title replaces Claude Code's own title everywhere a session's title shows today:

- the tab;
- the session list;
- the board card;
- Recent and Completed;
- what paired Macs and the Phone page are sent.

A name the user gives always wins: a tab's name from Rename tab, or a `/rename` in Claude Code.

Text generation running in Launchy's process warrants an ADR, 0012. It adds a dependency product and a 3.6 GB download. It is a third model sharing MLX with search, and it decides how future roles and providers fit. The draft is in Further Notes.

## Trade-offs

- **One place for models, two for a feature.** Turning a feature on and setting its model up are now in different sections. The link from the switch to Models covers the gap. The relevance filter's choice survives it being switched off.
- **Session titles compete with Claude's own; they don't fill a gap.** Claude Code titles about 85% of sessions (144 of 170 last week) within about 3 s of the first prompt, and almost never changes the title. A title that only stood in until Claude's arrived, or only where Claude gave none, would hardly ever show. So with the switch on, the generated title takes Claude's place. Gemma 4 E2B may name things vaguer than Claude does (the spike's "Relay Host Linker"). The prompt lives in one place, and a hidden command prints titles for tuning.
- **The tab shows Claude's title first.** Claude's title can arrive before Gemma's. The first title after a load takes about 4.5 s: 1.3 s to load, 2.8 s of shader setup, then the reply. Later titles take about 0.5 s.
- **Memory and disk.** The download is 3.6 GB. MLX holds about 2.5 GB while the model is loaded (3.1 GB at peak). That comes on top of the embedder's 650 MB and the local relevance model's 0.85 GB. The model unloads after 10 idle minutes, so with titles on it is resident for 10 minutes after each new conversation.
- **Shares MLX with search.** MLX runs one evaluation at a time per process. A title made right after a load can hold up a search's semantic pass or local relevance check for up to about 3 s. Titles are made once per conversation, so this is rare.
- **Privacy is unchanged.** The prompt is read and judged on this Mac. The title goes where titles already go: the paired Macs and the Phone page, which already receive the session's prompts and titles. Nothing goes to a third party.
- **Semantic search off stops embedding too.** It frees memory and CPU. Turning it back on embeds the backlog at the next sync, as a finished download does today.

## User Stories

1. As a Launchy user, I want one Settings section that lists each model Launchy uses and what for, so that I know where to set one up or see why it failed.
2. As a Launchy user, I want to download the search embedding model from Settings › Models and follow its progress there, so that its setup sits with the other models'.
3. As a Launchy user, I want to choose TypeSafe or On this Mac for the relevance filter in Settings › Models, and import my checkpoint there.
4. As a Launchy user, I want to turn the relevance filter off and on in Settings › Search without losing my choice of TypeSafe or On this Mac.
5. As a Launchy user who had the relevance filter set to Off, I want it to stay off after the update, and to find TypeSafe chosen when I turn it on.
6. As a Launchy user, I want a switch for semantic search, so that I can stop it without deleting its model.
7. As a Launchy user, I want my TypeSafe key under Keys in Settings › Models, kept in the Keychain or read from `.env` as today, so that a key serves every role that uses its provider.
8. As a Launchy user, I want a feature that is on but not set up to tell me so and take me to Settings › Models in one click.
9. As a Launchy user, I want to download a text generation model once, on this Mac, and see its progress and any failure with a way to retry.
10. As a Launchy user, I want to turn session titles on in Settings › Claude once text generation is set up, so that sessions get short names made on this Mac.
11. As a Launchy user, I want each new session titled from what I first asked, on its tab, session list row, board card, Recent and Completed rows, and on my other Macs and phone.
12. As a Launchy user, I want a tab I renamed, or a session I named with /rename in Claude Code, to keep my name whatever is generated.
13. As a Launchy user, I want /clear to give the new conversation its own title, and the one I left to keep its title in Recent.
14. As a Launchy user, I want turning session titles off to bring Claude's own titles back at once.
15. As a Launchy user, I want the text generation model to leave memory when it isn't in use, as the search models do.
16. As a maintainer, I want a command that prints the title for a given prompt with the app's own code, so that I can tune the title prompt without restarting Launchy.

## Implementation Decisions

**The Models section**

- A new Settings section, Models, comes after Peers and before Shortcuts, with the `cpu` symbol. Settings reopens on the last section viewed, as now.
- Rows, in order:
  - **Search embeddings.**
    - Detail: "Qwen3-Embedding 0.6B, 8-bit. Semantic search uses it to find pages and sessions by meaning. Runs on this Mac after a one-time 650 MB download. It is the only choice: another model would mean embedding the whole archive again (ADR 0003)." The ADR reference is for this spec and stays out of the UI string.
    - Controls: today's states. These are "Needs mlx.metallib: build with make", Download, a progress bar with its percentage, failed with the message and Retry, and **"Installed"** instead of "On". "On" is a feature's word, and the switch now says it.
  - **Relevance filter.**
    - Detail: "Judges which of the top 20 results match what the search is after."
    - Controls: a segmented picker, TypeSafe | On this Mac.
    - Under it, one row for the choice:
      - TypeSafe keeps today's detail on what is sent to TypeSafe. Its status reads "Key saved" (in the Keychain), "Key from .env", or "Needs a key" (orange) with the key set under Keys below.
      - On this Mac is today's row, unchanged except that "On" becomes "Installed".
  - **Text generation.**
    - Detail: "Gemma 4 E2B, 4-bit. Writes short text on this Mac, such as session titles; nothing is sent anywhere. One-time 3.6 GB download. Uses about 2.5 GB of memory while in use, and frees it after 10 idle minutes."
    - Controls: the same states as Search embeddings. A failed load also offers Download again (see Text generation).
  - **Keys**, a section label, then one row per provider:
    - **TypeSafe**, detail "Used by the relevance filter when it runs on TypeSafe. Kept in the macOS Keychain."
    - Controls: today's key field, Save, Remove key and the `.env` fallback, unchanged.
    - A later cloud text-generation provider adds its own row here, and one key then serves every role that uses that provider. (This grouping is the planner's decision; the user had no preference.)
- Model setup leaves Settings › Search: the download states, the picker, both backend rows and the key all move to Models.

**Feature switches, and the link to Models**

- **Search › Semantic search**, a switch.
  - Detail: "Also finds pages and sessions by meaning, not only matching words. Runs on this Mac."
  - Saved in UserDefaults as `semanticSearch`; read with on as the default, so nothing changes for anyone today.
- **Search › Relevance filter**, a switch.
  - Detail: "After you pause typing, moves the results that match what you meant to the top." followed by "Runs on TypeSafe." or "Runs on this Mac." for the current choice.
- **Claude › Session titles**, a switch.
  - Detail: "Names each session on this Mac from its first prompt, in place of Claude's own title. A tab you rename keeps its name." Once Claude's /rename is read (below), the last sentence becomes "A tab you rename, or a session you name with /rename, keeps its name."
  - Saved as `sessionTitles`, off by default.
  - It can't be turned on while text generation isn't installed: it is disabled and shows the link.
  - If it is on and the model later goes (deleted, or a failed load), it stays on, shows the link, and no titles are made meanwhile.
- **The link** sits beside a switch that is on (or, for Session titles, disabled) while its role isn't set up. It is a link-style button that switches Settings to Models:
  - "Needs a model: Settings › Models" for a missing, failed or unavailable model (no metallib);
  - "Needs a key: Settings › Models" for TypeSafe without a key;
  - "Setting up: Settings › Models" while a download or import runs.
- The search footer's keyword-only icon explains itself whenever semantic search isn't running:
  - the switch is off: "Keyword only. Semantic search can be turned on in Settings › Search.";
  - the switch is on and the model isn't installed: "Keyword only. Semantic search needs its model: Settings › Models.";
  - the switch is on and the model is installed but the pages aren't embedded yet: "Keyword only until the pages are embedded."

**The relevance filter, split in two**

- **What is saved.**
  - An on/off switch, saved as `relevanceFilterOn`.
  - The choice, saved under the existing `relevanceFilter` key, now holding only `typesafe` or `local`.
- **Reading old values.**
  - `relevanceFilterOn` is read with a default of "the stored `relevanceFilter` isn't `off`".
  - `relevanceFilter` reads `off`, or nothing, as TypeSafe.
  - So a user on Off stays off with TypeSafe chosen, a user on TypeSafe or On this Mac stays on with that choice, and a new user gets on with TypeSafe, which is today's default. With no key that means no filter, as today.
  - Nothing is rewritten at launch; each key is written when the user changes it.
- **At each search**, the judge is:
  - none when the switch is off;
  - else TypeSafe when chosen and a key exists;
  - else On this Mac when chosen and the model is installed and not failed;
  - else none.
- `LAUNCHY_EVAL_FILTER` keeps its meaning (`typesafe`, `local`, `off`) and overrides both settings, so `--search-eval` still compares filters without touching Settings.
- The choice type loses Off. The tooltips still name the backend that judged the results on screen.

**Semantic search's switch**

- Off means search runs keyword only, with no semantic pass. Launchy's minute history sync then doesn't embed, so the model isn't loaded.
- Turning it on starts a sync at once, as a finished download does today, so the backlog embeds.
- `Launchy --sync` embeds as today whatever the switch says, because it builds test databases.
- `--search` and `--search-eval` follow the switch as they follow the model today. `--search-eval` already prints whether semantic search was on.
- Vectors already stored are kept while it is off.

**Text generation (the model)**

Shaped like the embedder, with the local relevance model's rule for a failed load:

- **Download.**
  - From `mlx-community/gemma-4-e2b-it-4bit` at the pinned revision 238767527555cb75a05732a84dff5d6ba0dd6809.
  - Files: config.json, generation_config.json, tokenizer.json, tokenizer_config.json, chat_template.jinja, processor_config.json, model.safetensors.index.json, then model.safetensors last, so the progress bar follows the weights.
  - It goes into a `.partial` folder first, then is moved to `gemma-4-e2b-it-4bit` in Launchy's Application Support models folder, next to the embedding model.
  - Before the move, the weights' and the tokenizer's byte counts are checked against Further Notes, so a cut-short file never looks installed.
  - The embedder and text generation download through the same code. The embedder's behaviour doesn't change.
- **States**: unavailable (no metallib), missing, downloading with a fraction, installed, and failed with a message. The object is created at launch next to the embedder. Its init only checks that the metallib and the weights exist: it runs on the main thread at launch and touches no MLX.
- **Load** on first use.
  - It checks the metallib, sets the shared 64 MB cache cap if it isn't set yet, and loads through MLXLLM's model factory from the folder with the Hugging Face tokenizer loader, inside MLX's error wrapper.
  - A second caller joins a load already under way.
  - A folder deleted while Launchy runs sends the state back to missing.
- **Generate.**
  - Each request gets a fresh chat with no history: greedy (temperature 0), with a cap on new tokens set by the caller.
  - It runs inside MLX's error wrapper, off the main actor, one request at a time.
  - The main-actor object keeps the state Settings shows, the load and the idle timer, as the embedder does.
- **Unload** after 10 idle minutes, then clear MLX's cache.
- **Failures.**
  - A failed load sets the failed state, and no titles are made until the user acts. Retry loads again. Download again fetches a fresh copy into `.partial` and replaces the folder only once that copy is complete.
  - A failed download shows failed with Retry, as the embedder's does.
  - A failed generation fails only that request.
- **What consumers see**: give it a prompt and a token cap, get back the reply's text or an error. Session titles is the only consumer for now.
- **Dependency.** Launchy's target gains `MLXLLM`, a product of the already-pinned mlx-swift-lm. No new package, and the metallib is unchanged.
- **Gotchas.**
  - A file that imports both MLXLMCommon and Tokenizers sees an ambiguous `Tokenizer`, so qualify it.
  - mlx-swift-lm's registry adds an extra end-of-turn token for this model. Whether loading from a folder applies it is unverified; the spike's titles ended cleanly. The token cap and the first-line rule (below) cover a reply that runs on.

**Session titles**

- *What is fed in.* Only the conversation's first counted prompt, cut to its first 1,500 characters.
  - "Counted" means the first prompt the user typed, as the session index reads prompts: text only, a slash command as "/name args". A slash command with no arguments is skipped, and the next prompt counts.
  - Not fed in: Claude's replies, tool output, the folder or agent (rows and cards already show both beside the title), and later prompts.
  - Why: it says what the session is for at its start, it is there as soon as the user sends it, it holds only what the user typed, and it keeps the title fixed, as Claude's is. First prompts reach 25,000 characters at p90, and their start carries the gist.
- *Where it's read.* From the conversation's transcript, which the pane already knows from its session file.
  - The whole file is read once, off the main actor, using the session index's own reader.
  - Reading only the start would miss the first prompt: it sits 526 KB in at p90.
- *When.* A Claude pane on this Mac (not one on a paired Mac) that has started already checks its conversation and turn every half second. On those checks it looks for the first prompt when all of these hold:
  - Session titles is on and text generation is installed;
  - the pane's current conversation has no title record yet;
  - its transcript exists, and its date has changed since the pane last looked, at least 5 s ago.
  The look stops once a title is made or recorded as failed. Turning the switch on titles every started pane's conversation that has none.
- *The request.* The title prompt in Further Notes, a single user message, greedy, at most 24 new tokens. The prompt text lives in one place in the code so it can be tuned.
- *Clean-up.*
  - Take the reply's first non-empty line.
  - Strip a leading "Title:", any surrounding quotes, backticks, asterisks or #, and any trailing . ! : ; ,.
  - Collapse whitespace.
  - If it is over 60 characters, cut at the last space before 60.
  - If nothing is left, there is no title.
- *Where it's kept.* On the pane's saved record, as an optional field naming the conversation it is for. Old `sessions.json` files load unchanged. The field holds:
  - the generated title;
  - or a mark that generation failed or gave nothing, so it is never asked again for that conversation;
  - and, once Claude's /rename is read, the user's name.
- *Where it shows.* A Claude pane's label is, in order:
  1. the user's /rename name for the current conversation;
  2. the generated title for it, while Session titles is on;
  3. Claude's terminal title;
  4. the last saved title;
  5. the prompt;
  6. "New session".

  A tab's name from Rename tab still comes before the label everywhere it does today: the tab, the session list row and a one-pane tab's board card.
  Recent and Completed rows, and what the relay sends to paired Macs and the Phone page, use the saved title, which is the label when the pane was saved. So the generated title reaches them with no protocol change.
- *When it arrives,* the pane publishes a change and saves, so its tab, rows and card update and a paired Mac sees it at its next refresh.
- *Switching conversation.* After /clear or /resume:
  - the record left behind for Recent takes the pane's title for that conversation (the user's name, else the generated title while the switch is on, else Claude's `ai-title` as today) and keeps the title record;
  - the new conversation gets its own title.
  - A result that arrives after the pane has moved to another conversation is dropped.
- *Switching it off* brings Claude's titles back on every pane at once (the panes publish a change). Stored titles are kept, so turning it on again shows them.
- *Not titled*:
  - panes on a paired Mac (their host titles them, if its own switch is on);
  - the Ryzen's sessions;
  - shells, web, file, app and transcript panes.
- *Claude's /rename* is read from the transcript in two places:
  - the whole-file read that finds the first prompt also returns the conversation's last `custom-title`; with one, nothing is generated and the name is kept;
  - whenever the pane has a title record, whatever the switch says, each change of the transcript's date makes the pane search its last 64 KB for a `custom-title`, the tail the turn correction already reads.
  Once found, the name is saved in the title record and outranks the generated title. It is Claude Code's undocumented format, as the turn correction's markers are: a renamed entry type stops this with no error.
- *Privacy and logs.* The prompt is read on this Mac and given to the model in-process. Logs say that a title failed and why, and never include the prompt or the title.

**Docs, once accepted**

- ADR 0012, from the draft in Further Notes.
- CODING_STANDARDS' dependency line: mlx-swift, mlx-swift-lm and swift-transformers "for embeddings, reranking and text generation; see ADRs 0003, 0006 and 0012".
- where-it-breaks:
  - Search store's MLX bullet names the text generator among the models sharing MLX.
  - New, under Sessions and tabs: a short note that points to the code for the title order and the one try per conversation, and keeps one rule that code could break: the prompt and title are never logged.
  - New, beside the turn correction's note: `custom-title` is read from Claude Code's undocumented transcript format.

## Testing Decisions

- There is no test target. Verification is `make build`, the generate and title commands, and checks by hand after the user restarts Launchy.
- **The generate command.** `Launchy --generate <file>` sends the file's text, as is, as one user message and prints the reply, with the load time and the generation time. It checks text generation alone, before any consumer exists, and helps with later roles' prompts.
- **The title command.** `Launchy --title <file>` treats the file's text as a conversation's first prompt and prints the title and the time taken. It uses the app's own cut, request and clean-up, and loads only text generation from Application Support. It runs as its own process, like `--rerank-eval`, so it doesn't restart the app. It needs the model downloaded first, and downloads nothing. Prompt files are personal: keep them out of the repo.
- **Checks by hand**, after the user restarts Launchy:
  - **Models.**
    - Each model row's states: no metallib, Download, progress, Installed, and failed with Retry.
    - Text generation's failed load offers Download again.
    - The TypeSafe key row with a key in the Keychain, from `.env`, and with none.
  - **Search.**
    - Semantic search off gives keyword-only results, and the next minute's sync embeds nothing.
    - Semantic search on again embeds the backlog at once.
    - The relevance switch keeps the choice when off.
    - A user who was on Off before the update finds the switch off and TypeSafe chosen; one who was on On this Mac finds it on with On this Mac.
    - Each link opens Models.
  - **Session titles.**
    - Disabled, with the link, until text generation is installed.
    - A new session from the panel and one typed in the terminal each get a title within a few seconds of the first prompt, on the tab, the session list, the board and, after it ends, Recent.
    - A first prompt that is a bare slash command waits for the next prompt.
    - After /clear the new conversation gets a new title, and Recent keeps the old one.
    - A renamed tab keeps its name.
    - `/rename` in Claude wins over the generated title, and stays after a restart.
    - Turning titles off brings Claude's titles back, and on again restores the generated ones.
    - A paired Mac's session list and the Phone page show the host's generated title.
    - Memory with all three models loaded, and Gemma's unload after 10 idle minutes.
    - A search typed straight after a title shows any delay.

## Out of Scope

- Search's session rows and the session index: they keep Claude's `ai-title`.
- Titles for sessions on a paired Mac or the Ryzen made by this Mac; the host makes them, and the Ryzen has no Launchy.
- Making the title again as the session moves on, or feeding in Claude's replies or later prompts.
- Gemma 4 E4B or any second choice for text generation; a cloud text-generation provider and its key row.
- Removing a downloaded model, or showing disk use.
- Listening's speech model, which macOS installs and manages.
- Checking downloaded weights by SHA-256 (the hashes are in Further Notes for later).
- Warming the model ahead of a title.
- Wrapping the embedder's MLX calls in the error wrapper (already deferred by the relevance work).

## Further Notes

- **The title prompt**, a starting point to tune with `--title`. `{prompt}` is the cut first prompt:

  > Write a short title for a coding session, from the request that started it.
  > Rules: 2 to 6 words. Name the specific thing the request is about (the feature, bug, file, tool or question), not the act of asking. Sentence case. No quotes, no punctuation at the end.
  > Reply with the title only.
  >
  > Request:
  > {prompt}

- **Reference values**, checked against the Hugging Face listing at revision 238767527555cb75a05732a84dff5d6ba0dd6809:

  | File | Bytes | SHA-256 |
  |---|---:|---|
  | model.safetensors | 3,550,670,554 | 038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e |
  | tokenizer.json | 32,169,626 | cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f |

  The rest are small: chat_template.jinja 17,336; config.json 6,395; generation_config.json 208; model.safetensors.index.json 218,323; processor_config.json 1,316; tokenizer_config.json 2,740. The total is about 3.6 GB.

- **What was verified and what wasn't.**
  - Verified in code or data:
    - how labels, tab names, Recent, the board, search rows and peer titles are made today;
    - that a pane started for a paired Mac is started on the host, so its checks run and it gets a title;
    - that mlx-swift-lm 3.32.3 registers Gemma 4 and that mlx-swift 0.32.3 has an async error wrapper;
    - the file list and sizes;
    - the transcript counts in the problem.
  - Taken from the spike as reported, not rerun: load, memory, speed, and the generation API working with Launchy's pins.
  - Not checked:
    - whether Claude Code shows a `/rename` name as its terminal title (the order above doesn't depend on it);
    - whether the extra end-of-turn token applies when loading from a folder.

- **Draft ADR 0012** (main has 0001 to 0011):

  > # Text generation runs in Launchy with MLX
  >
  > Launchy writes short text on this Mac, first the titles of Claude sessions, with Gemma 4 E2B (`mlx-community/gemma-4-e2b-it-4bit` at a pinned revision). It runs in Launchy's own process through mlx-swift-lm's `MLXLLM`, the way semantic search (ADR 0003) and the local relevance filter (ADR 0006) run. The model downloads once from Settings › Models. That section is the one place where each role's model is chosen and set up and where keys are kept, by provider; features keep their own switches. We chose this over a cloud provider, which would send the user's prompts off the Mac, and over a separate server such as Ollama for ADR 0003's reasons: nothing to install or keep running beside Launchy. A spike on the M3 Ultra, with Launchy's exact pins and metallib, loaded it in 1.3 s and wrote a title in 0.34 s, with no change to MLX. The problem and its option are in `docs/problems/models-set-up-per-feature/`.
  >
  > ## Consequences
  >
  > - Launchy's target gains `MLXLLM`, a product of the already-pinned mlx-swift-lm. There is no new package and the metallib contract is unchanged.
  > - A 3.6 GB download, and about 2.5 GB of MLX memory while loaded (3.1 GB at peak on a 2k-token prompt), on top of the embedder's 650 MB and the relevance model's 0.85 GB. It unloads after ten idle minutes, and MLX's 64 MB cache cap covers it.
  > - MLX runs one evaluation at a time per process, so a generation can hold up a search's embedding or relevance check. The first generation after a load spends about 2.8 s on shader setup.
  > - A role can later offer a second choice, such as a cloud provider for text generation, whose key is a row under Keys. The role's consumers don't change.
  > - ADRs 0003 and 0006 stay as written.

- **Open questions, each with a recommendation.**
  - *Generated title above Claude's own, while the switch is on:* yes. Below it, the generated title would hardly ever show, because Claude titles about 85% of sessions within about 3 s.
  - *Session titles disabled until text generation is installed, or always enabled with the link:* disabled. That is how "off unless text generation is set up" reads, and it keeps the switch from looking on while doing nothing.
  - *Semantic search off also stops embedding in the minute sync:* yes, so off means the model isn't touched. The alternative keeps the archive embedded so turning it on is instant.
  - *Models' place in the sidebar:* after Peers, before Shortcuts.
  - *Glossary:* add **Text generation** ("A model on this Mac that writes short text for Launchy's features; today it names sessions. Set up in Settings › Models. _Avoid_: LLM, Gemma (in the UI)") and a session's **Title** ("What tabs, rows and board cards call a session: a name the user gave it (the tab's, or with /rename in Claude Code), else the generated title while session titles are on, else Claude Code's own, else its first prompt. _Avoid_: label, name (a tab's name is the user's)"). Recommended; it's for the user to accept.
  - *Apple's on-device Foundation Models* (macOS 26) would need no download and use none of Launchy's memory. It wasn't weighed in the spike and isn't evaluated here. If the user considered it, the ADR should say why Gemma was chosen.
