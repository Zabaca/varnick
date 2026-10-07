---
problem: models-run-only-on-this-mac
title: Search embeddings can run on a server, such as the Ryzen's embedding service
summary: The Search embeddings row in Settings › Models gets "On this Mac | Server". With Server, Launchy sends what it embeds (queries, prompts typed in the panel, and the text of pages and sessions) to an OpenAI-compatible embeddings address on the tailnet. Launchy keeps its own prefix and normalization, and stores the vectors under the same model key, so the archive stays as it is. A Check compares the server's vectors with reference vectors shipped in Launchy and refuses a different model. When the server doesn't answer, a search uses this Mac's model if it is installed, and is keyword only otherwise. The minute sync waits for the server. Foundry's `foundry-embeddings` serves it as it is today, with no change on the Ryzen.
status: shipped
---

## Solution

Settings › Models' **Search embeddings** row gets a picker, **On this Mac | Server**, shaped like the relevance filter's TypeSafe | On this Mac. On this Mac is today's row and the default, so nothing changes for anyone who doesn't pick Server.

With **Server**, the row below the picker takes the server's address, for example `http://linux-box:11434`. Launchy then speaks the OpenAI-compatible embeddings route to that address, which Ollama, llama.cpp's server, LM Studio and vLLM all answer. Launchy still does everything that decides what a vector means:

- it adds the query instruction to queries and leaves pages and sessions bare;
- it builds each page's and session's text;
- it normalizes every vector it gets back;
- it stores the vectors under the model key `qwen3-embedding:0.6b`.

The server only turns the string it is given into numbers.

Mixed vectors would ruin search with no error, so Launchy checks the server before it trusts it. The **Check** embeds three fixed sentences and compares the vectors with reference vectors that ship in Launchy, made by this Mac's model. A server that gives anything else is refused. The Check runs on its own before the server's first use in each launch, and before a sync embeds.

When the server doesn't answer, or fails the Check:

- a search uses this Mac's model if it is installed, and is keyword only otherwise, and the search footer says which;
- the minute sync embeds nothing and leaves the new entries for the next sync, as a failed embedding does today.

The server that answers this today is foundry's `foundry-embeddings` on the Ryzen, unchanged. This option asks nothing of foundry.

Running embeddings off the Mac reopens ADR 0003's choice of no Ollama server, but only as an opt-in. It gets ADR 0014 (draft in Further Notes).

## Trade-offs

- **Not faster where the model already runs.** Warm, a query takes 7.1 ms on the Mac Studio and about 30 ms from the Ryzen. What Server saves:
  - the cold start, about 1.75 s after every 10 idle minutes, since the Ryzen keeps its model loaded;
  - the 650 MB download and about 650 MB of memory;
  - the GPU time and battery spent embedding the backlog, which on every Mac includes the paired Macs' pages and sessions.

  The MacBook Air gains the most; the Mac Studio gains little.
- **Prompts and history leave the Mac.** Everything semantic search reads goes to the server:
  - the searches typed;
  - the prompts typed in the panel;
  - each page's title, site, description start, bookmark folders and search terms;
  - each session's title, folder name and prompts, this Mac's and the paired Macs'.

  Today a session's prompts stay on the paired Macs. The server is the user's own machine, reached over the tailnet, which encrypts the traffic. Its log records the caller and the time, not the text (checked for `foundry-embeddings`). It is still a new place where prompts pass through. The rule in `where-it-breaks.md` changes, and Settings says so plainly.
- **It depends on a service another repo owns.** Foundry may:
  - change the model (its ADR names Qwen3-Embedding 4B as the upgrade path), which the Check catches as a different size or a low similarity;
  - rename the tag or take the service down, which shows as the server not answering;
  - restart it, which costs one cold call.

  Each of these falls back as above and never writes a wrong vector.
- **Two producers in one archive.** Vectors made on this Mac and on the server sit side by side under one key; nothing is re-embedded on a switch, either way. ADR 0003 already kept Ollama-made vectors at 0.999. The Check's bar of 0.99 is what keeps this safe, and whether foundry's exact digest clears it hasn't been checked (Testing Decisions).
- **It shares foundry's card.** Embedding a whole archive from nothing takes one to two minutes of card time: the Studio's 7,077 entries make 111 batches of 64, and a batch of short test texts took 0.54 s (real entries are longer). After that each sync sends only new and changed entries. Foundry's hourly job uses the same model. The service takes two requests at a time, so a search is seldom queued behind a sync's batch, unless foundry's job holds the other slot.
- **Off the tailnet it is keyword only**, unless this Mac's model is installed too.

## User Stories

1. As a MacBook Air user, I want search by meaning without downloading or loading the embedding model, so that semantic search works on a small Mac.
2. As a Launchy user, I want to choose whether Search embeddings run On this Mac or on a Server, in Settings › Models.
3. As a Launchy user, I want to give the server's address once, and have Launchy check that it runs the same model before using it, so that my search isn't quietly ruined.
4. As a Launchy user, I want a failed check to say why: no answer, another model, the wrong size, or an address off my tailnet.
5. As a Launchy user, I want my archive kept as it is when I switch either way, with nothing embedded again.
6. As a Launchy user, I want search to keep finding by meaning when the server doesn't answer, on this Mac's model if I have it, and to be told when it is keyword only because the server didn't answer.
7. As a Launchy user, I want Settings to say exactly what goes to the server and where.
8. As a Launchy user, I want to give a key for a server that needs one, kept in the Keychain under Keys.
9. As a maintainer, I want a command that checks a server against the reference vectors and prints the similarities, so that I can vet a server or a new model digest without the app.
10. As a maintainer, I want `--search-eval` to compare Server with On this Mac without touching Settings.

## Implementation Decisions

**Settings › Models**

- **Search embeddings.**
  - Detail: "Qwen3-Embedding 0.6B. Semantic search uses it to find pages and sessions by meaning. It is the only choice: another model would mean embedding the whole archive again."
  - Controls: a segmented picker, On this Mac | Server.
- Under it, one row for the choice, as the relevance filter does:
  - **On this Mac**: today's row, with its detail "8-bit, runs on this Mac after a one-time 650 MB download." and today's states.
  - **Server**:
    - Detail: "Sends your searches, the prompts you type in the panel, and the text of your pages and Claude sessions (titles, sites, descriptions, search terms and prompts, your paired Macs' too) to {server}, over your tailnet." Here {server} is the address's name, or "the server below" before one is given.
    - Controls: the address field (placeholder `http://linux-box:11434`), the model field (prefilled `qwen3-embedding:0.6b`, the name Ollama needs; some other servers ignore it), Check, and the status.
- **Statuses**:
  - "Not checked", "Checking…";
  - "Same model", with help that gives the lowest similarity and the round trip;
  - in orange: "Not answering: {reason}", "Another model (similarity 0.71)", "Wrong size: 768 numbers, needs 1024", "Not on your tailnet".
- **Keys** gains a **Model server** row: an optional key, kept in the Keychain and sent as a bearer token to the server address.
  - Detail: "Sent to a model server that asks for one. The Ryzen's embedding service doesn't."
  - The name isn't embedding-specific, so Text generation can use the same row later (option 02).
- **The links from features.** Search › Semantic search's link reads "Needs a server: Settings › Models" when Server has no address or failed its Check, and "Setting up: Settings › Models" while the Check runs. Its detail ends "Runs on this Mac." or "Runs on {server}.", as the relevance filter's detail already names where it runs.

**What is saved**

- `searchEmbeddingsRunOn`: `local` or `server`, read with `local` as the default.
- `embeddingServer`: the address as typed, empty by default.
- `embeddingServerModel`: `qwen3-embedding:0.6b` by default.
- The key goes in the Keychain under the account `MODEL_SERVER_KEY`, never in UserDefaults.
- `sessions.json` and the search database's shape don't change.

**The address**

- The user gives the server's base address. Launchy adds `/v1/embeddings`, without doubling a `/v1` the address already ends in. Both `http` and `https` are accepted.
- The address must be on the tailnet or on this Mac: its name must resolve only to tailnet addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) or to loopback. This is checked off the main actor, as the Check's first step. Anything else fails with "Not on your tailnet". It is what makes "over your tailnet" true, and it keeps prompts on the user's own machines (open question 2).

**The request**

- One POST with `model` and `input` (a list of texts). The reply's `data` is matched to the inputs by `index`, and there must be exactly one vector per input with as many numbers as the references have (1024), or the batch fails.
- No `dimensions` field: Ollama shortens the vector when it gets one.
- Every vector is normalized again on arrival. Ollama already normalizes (checked), but another server may not, and it costs nothing.
- Batches of 64 texts, shortest first, one request at a time, as on this Mac.
- An ephemeral session, like the TypeSafe request's. Timeouts: 2 s for a query, 30 s for a sync batch, 5 s for the Check.
- Logs give the kind of failure and the status code, never the request, the reply's body or the key, since the texts hold prompts.

**The Check**

- **References.** Three sentences made up for this purpose: a search with the query instruction, a page-like title, and a session-like prompt. Their vectors, from this Mac's model with the embedder's method, are written into Launchy's source at full precision.
- **Pass.** Every vector has 1024 numbers, and each has a cosine of at least 0.99 with its reference. ADR 0003 measured 0.999 for Ollama's build of the model. A different model or pooling falls far below that, and a different size is refused outright.
- **When it runs:**
  - on Check;
  - when the address or model is submitted;
  - before the server's first use in each launch;
  - before a sync embeds, if the last pass is over 10 minutes old.

  The result lives in memory only, so each launch checks again.
- **When it fails.** An answer that fails (another model, the wrong size) stops all use of the server, queries and sync, until the address or model changes or Check is pressed. A server that doesn't answer is tried again at most once a minute.

**Which model a search uses**

- At each search, as the relevance filter's judge is picked. Semantic search runs when the switch is on, the archive is embedded under the model key, and one of these holds:
  - On this Mac is chosen and its model is installed;
  - Server is chosen and the server passed its Check;
  - Server is chosen, the server isn't answering or failed its Check, and this Mac's model is installed (the fallback).
- **On this Mac never contacts the server.** The fallback goes one way only.
- After the server fails a query, searches for the next minute go straight to the fallback, or to keyword only, so typing away from the tailnet doesn't wait 2 s at every pause. Then the server is asked again.
- Server doesn't need `mlx.metallib`: a Launchy built without it can search by meaning through a server. The fallback still checks it, as today.
- **The search footer.**
  - The keyword-only help gains "Keyword only. Semantic search needs its server: Settings › Models." (no address, or a failed Check) and "Keyword only. The embedding server at {server} isn't answering."
  - A search the fallback answered shows "Hybrid: keyword + semantic (on this Mac: the server isn't answering)".
- **The prompt line.** Matching sessions under the prompt line goes through the same choice. With Server, the typed message's first 1,000 characters go to the server (open question 3). A failure stays quiet, as today.

**The minute sync**

- With Server, the sync embeds through the server once the Check has passed. It never falls back to this Mac: if the server doesn't answer, it leaves the entries for the next sync, and the pages are still found by keyword.
- Vectors are stored under `qwen3-embedding:0.6b` as today. A switch either way embeds only new and changed entries.
- With Semantic search off, nothing is embedded and nothing is sent.
- Choosing Server, or changing the address, starts a sync at once, as turning Semantic search on does.

**The command line**

- `--sync`, `--search` and `--search-eval` follow the setting. `LAUNCHY_EMBEDDINGS` (`local` or `server`) overrides it, as `LAUNCHY_EVAL_FILTER` does for the filter. `--search-eval` prints which one ran.
- `Launchy --embed-check <address> [model]` runs the Check against a server. It prints the size, each similarity and the round trip, and sends nothing else.
- `Launchy --embed-reference` prints the three reference vectors from this Mac's model. It is used once to write them into the source, and again after an mlx-swift or mlx-swift-lm bump to confirm they still hold.

**Peers**

- The choice is each Mac's own. Each Mac embeds its own archive, so a paired Mac's choice changes nothing here.
- Nothing crosses the peer protocol and there is no protocol bump.
- The Ryzen's relay embeds nothing and is unaffected. Its being a server here has nothing to do with its being a peer.

**Docs, once accepted**

- ADR 0014 from the draft below. ADR 0003 gains a line pointing to it.
- `where-it-breaks.md`, under Search store:
  - The session and prompt privacy bullet says that, with Search embeddings on a server, the texts that are embedded go to that server, and to nothing else: never a reranker, TypeSafe or a log.
  - A new bullet holds the server's rules:
    - vectors from the server are stored only after a Check that passed in this launch, under the one model key;
    - On this Mac never contacts the server, and the fallback runs only from server to this Mac;
    - nothing about a request, a reply's body or the key is logged.
- CONTEXT.md gains **Model server** (open question 6).
- No new dependency: the request uses URLSession.

## Testing Decisions

- There is no test target. Verification is `make build`, the two commands, `--search-eval`, and checks by hand after the user restarts Launchy.
- **First, before any UI:** write `--embed-reference` and `--embed-check`, and run the check against `foundry-embeddings`. If any similarity is below 0.99, stop and report: this option doesn't work with that service as it is, and the choice moves to option 04's own server, or to another quantization.
- **Search quality.** Run `--search-eval` on a copy of the database with `LAUNCHY_EMBEDDINGS=local`, then `=server`. MRR and top-k should be within noise of each other, since both search the same stored vectors and only the query's vector differs.
- **Checks by hand, after the restart:**
  - Each status: no address, Checking…, Same model, a wrong model (point the model field at one the server doesn't have), and not answering (a wrong port).
  - "Not on your tailnet" for an address on the LAN.
  - Whether macOS asks for Local Network access on the first request. If it does, the Info.plist needs a usage string; note what it says.
  - Search, and the sessions under the prompt line, by meaning with Server and with On this Mac. Switching shows nothing re-embedded (the archive's entry count and model key are unchanged).
  - The fallback: with the server unreachable, a search uses this Mac's model if it is installed, and is keyword only with the new help otherwise. A minute later the server is asked again.
  - With Semantic search off, no requests arrive: watch the Ryzen's Ollama log for this Mac's tailnet address. Don't stop foundry's service to test anything.
  - A full backlog: a fresh database copy (`LAUNCHY_DB`) embeds through the server in a minute or two, and searching meanwhile isn't held up.
  - With Server chosen, this Mac's model isn't loaded (Activity Monitor's memory for Launchy) until a fallback needs it.
  - On the MacBook Air, with no model installed: semantic search through the Ryzen, then keyword only with Tailscale off.

## Out of Scope

- Text generation on a server (option 02), and the relevance filter on a server.
- A cloud embeddings provider, and any address off the tailnet.
- Another embedding model, re-embedding the archive, and sharing vectors between Macs.
- Launchy running its own embedding server (an optional part of option 04), and any change to foundry.
- Finding servers on the tailnet automatically, and a key per server.

## Further Notes

- **Verified in the code, 2026-10-07:**
  - how queries, pages, sessions and typed prompts are embedded and gated;
  - that the peer requests carry no vectors;
  - that the sync leaves failed entries for later;
  - the Settings rows and keys;
  - that the archive holds 7,077 entries, all under `qwen3-embedding:0.6b`, at 1024 dimensions.
- **Verified against the service:** the OpenAI route's vectors, their normalization, the `dimensions` behaviour, the batch timings and the log's contents (problem.md).
- **Inferred:** that ATS allows plain `http` from Launchy's process (from status-200 fetches of `http` pages).
- **Not verified:** the similarity of digest `ac6da0dfba84` to Launchy's model, and the Local Network prompt.
- **Draft ADR 0014** (main has 0001 to 0013; take the next free number at the time):

  > # A role's model can run on a server on the tailnet
  >
  > Search embeddings can run on an OpenAI-compatible server on the user's tailnet instead of in Launchy's process, chosen per Mac in Settings › Models. On this Mac stays the default, so ADR 0003's reasons (nothing to install or keep running) still hold for anyone who doesn't choose Server. The first such server is foundry's `foundry-embeddings` on the Ryzen, which serves the same model. Launchy keeps the query instruction, the texts, the normalization and the model key, so vectors from either source share one archive. Because mixed vectors would ruin search with no error, a server is used only after its vectors match references shipped in Launchy (cosine 0.99). We chose this over sharing vectors between Macs, over a cloud provider, and over Launchy running its own embedding service, because the Ryzen already serves this model.
  >
  > ## Consequences
  >
  > - With Server, the texts semantic search reads, session prompts included, go to that server over the tailnet. Only tailnet or loopback addresses are accepted.
  > - A search falls back to this Mac's model when the server doesn't answer. The minute sync waits instead.
  > - Launchy depends on a service another repo owns. A change of model there shows as a failed Check, never as wrong vectors.

- **Open questions, each with a recommendation:**
  1. *Which server:* `foundry-embeddings` (recommended: it exists, serves this model, stays loaded, and needs nothing from foundry), or Launchy's own embedding service (option 04's optional part), which would load the same model a second time on the card.
  2. *Only tailnet or loopback addresses:* yes. It keeps "over your tailnet" true and prompts on the user's own machines. The alternative accepts any address and warns, which brings third-party providers into scope.
  3. *Prompts typed in the panel go to the server:* yes. A session's prompts reach the server through the sync a minute after they are sent anyway, so keeping the typed ones on this Mac would protect nothing and leave the prompt line without meaning on a Mac without the model.
  4. *The sync falls back to this Mac too:* no. The sync isn't urgent, and a fallback would load the model on a Mac that chose Server to avoid it.
  5. *A model field:* yes, prefilled. Ollama needs the exact tag, and LM Studio names models its own way. The Check guards against a wrong one.
  6. *Glossary:* add **Model server** ("A machine on the tailnet that runs a role's model for Launchy over HTTP, chosen per role in Settings › Models. It isn't a Peer: nothing is paired. _Avoid_: remote, host, backend"). Recommended; it's for the user to accept.
