---
problem: models-run-only-on-this-mac
title: Text generation can run on a server, such as a llama.cpp server on the Ryzen
summary: The Text generation row in Settings › Models gets "On this Mac | Server". With Server, Text generation's requests go to an OpenAI-compatible chat address on the tailnet, with Launchy's own prompts and clean-up. They were session titles when this shipped; since titles were removed on 2026-10-09 they are Hey Launchy's answers (ADR 0012 as amended). Nothing on the Ryzen serves chat today; foundry's embedding service is not a chat host. So this needs option 04 or 05, or another machine running such a server.
status: shipped
---

## Solution

Settings › Models' **Text generation** row gets a picker, **On this Mac | Server**, like Search embeddings in option 01. On this Mac is today's row and the default.

With **Server**, the row below takes the server's address and model name. Session titles then send their request to the OpenAI-compatible chat route there (`/v1/chat/completions`), which llama.cpp's server, Ollama, LM Studio and vLLM all answer. The request is the same as today: one user message with Launchy's title prompt around the first 1,500 characters of the first prompt, greedy, at most 24 new tokens. The reply goes through the same clean-up. Nothing else about Session titles changes: which conversations are titled, when, where the title shows and what outranks it.

A server that doesn't answer is no verdict on the conversation. Its title waits for the server and is asked again at the pane's next look, and Claude's own title shows meanwhile. Only a reply that cleans up to nothing marks the conversation, as today.

Nothing on the Ryzen serves chat today. Foundry's ADR-0033 says `foundry-embeddings` "is not a chat host". This option is Launchy's half; the server is option 04 (Launchy's own llama.cpp server) or option 05 (foundry's service also serves Gemma). Any other OpenAI-compatible server on the tailnet works too, such as LM Studio on another Mac.

It gets ADR 0014, or joins option 01's if both are accepted (option 03).

## Trade-offs

- **Small Macs gain the most.** Server saves the 3.6 GB download and about 2.5 GB of memory for 10 minutes after each new conversation. It also saves the reload after an idle unload: 1.3 s, plus about 2.8 s of shader setup the first time after launch. On the Ryzen's Vulkan build a title took 0.078 s (short) and 0.135 s (about 470 tokens), plus a 3–73 ms round trip. On the Mac Studio, warm, a title takes 0.083 s and 0.209 s. So the Studio gains little but memory, and the MacBook Air gains session titles it might not otherwise have.
- **First prompts leave the Mac.** Today the Text generation row says nothing is sent anywhere. With Server, the first 1,500 characters of each conversation's first prompt go to the server over the tailnet. Settings says so, and `where-it-breaks.md`'s titles note changes. The prompt and the title are still never logged by Launchy. Whether the server logs them is the server's setting: llama.cpp's server logs no prompt text at its default verbosity, which option 04 keeps (unverified until checked in its log).
- **The titles may read differently.** The Ryzen runs a GGUF at Q4_0, not MLX's 4-bit, and another server may run another model altogether. The spike timed titles on the Ryzen but didn't compare their wording with the Mac's. The clean-up keeps any reply to one short line.
- **Titles wait while the server is away.** A pane whose server doesn't answer keeps Claude's title until the server is back. If the pane ends first, its conversation stays untitled.
- **There is a server to keep running**, which is ADR 0012's reason for running in process. On this Mac stays the default.

## User Stories

1. As a MacBook Air user, I want session titles without downloading or loading Gemma, so that small Macs name sessions too.
2. As a Launchy user, I want to choose whether Text generation runs On this Mac or on a Server, in Settings › Models.
3. As a Launchy user, I want to check a server from Settings and see that it answers and how fast.
4. As a Launchy user, I want a session whose title couldn't be asked because the server was away to be titled once it is back, not marked as failed.
5. As a Launchy user, I want Settings to say that the first prompt of each session goes to the server, and to which machine.
6. As a Launchy user, I want Session titles to be available as soon as a server passes its check, with no model on this Mac.
7. As a maintainer, I want `--title` and `--generate` to run against the server or this Mac by choice, so that I can compare titles.

## Implementation Decisions

**Settings › Models**

- **Text generation.**
  - Detail: "Writes short text for Launchy's features, such as session titles."
  - Controls: a segmented picker, On this Mac | Server.
- Under it, one row for the choice:
  - **On this Mac**: today's row, with its detail "Gemma 4 E2B, 4-bit. Runs on this Mac; nothing is sent anywhere. One-time 3.6 GB download. Uses about 2.5 GB of memory while in use, and frees it after 10 idle minutes." and today's states, Download again included.
  - **Server**:
    - Detail: "Sends the first prompt of each new Claude session on this Mac (its first 1,500 characters) to {server}, over your tailnet, to name it."
    - Controls: the address field (placeholder `http://linux-box:8080`), the model field (prefilled `gemma4:e2b`, the name Ollama needs; llama.cpp's server ignores it), Check, and the status.
- **Statuses**: "Not checked", "Checking…", "Answers in 0.12 s" (with help naming the model the reply reports), and in orange "Not answering: {reason}" or "Not on your tailnet".
- **Keys** gains the optional **Model server** key, as in option 01 (one row, whichever options are accepted).
- **Claude › Session titles** can be turned on once Text generation is ready: On this Mac with the model installed, or Server with a passing Check. Its link reads "Needs a server: Settings › Models" for Server with no address or a failed Check.

**What is saved**

- `textGenerationRunOn`: `local` or `server`, read with `local` as the default.
- `textGenerationServer`: the address, empty by default.
- `textGenerationServerModel`: `gemma4:e2b` by default.
- The key is the Keychain account `MODEL_SERVER_KEY`, shared with option 01.
- `sessions.json` doesn't change: a title record is the same whichever model wrote it.

**The address**, as in option 01:

- a base address, with `/v1/chat/completions` added;
- `http` or `https`;
- it must resolve only to tailnet or loopback addresses, or the Check fails with "Not on your tailnet";
- the key, if any, is sent as a bearer token.

**The request**

- One POST with `model`, `messages` (one user message, the title request), `temperature` 0, `max_tokens` 24 and `stream` false. The title is the first choice's `message.content`; any reasoning field is ignored.
- An ephemeral session with a 10 s timeout per title, so a cold server's first load fits.
- Logs give the kind of failure and the status code, never the request, the reply's body or the key.

**The Check**

- It sends a fixed request ("Reply with the single word: ready") and passes on any non-empty reply, showing the time taken and the model the reply names.
- It doesn't compare models. A different model only words titles differently, and nothing stored mixes the way vectors do.
- It runs on Check, when the address or model is submitted, and before the server's first title in each launch. A server that doesn't answer is tried again at most once a minute.

**Session titles with a server**

- Which model a title uses is decided at each title: On this Mac when chosen and installed, Server when chosen and passing, otherwise none (the title waits).
- **There is no fallback.** With Server chosen, this Mac's Gemma is never loaded for a title, even if it is installed. A title isn't urgent, and a Mac that chose Server did so to keep 2.5 GB free (open question 2).
- **A failure that isn't the model's** (no answer, a timeout, a status other than 200, a reply that can't be read) doesn't set the failed mark. The pane looks again at its next transcript change, at least 5 s later, as today's look does. Only a reply that cleans up to nothing sets it, as today.
- A result for a conversation the pane has left, or for a pane that has ended, is dropped, as today.

**The command line**

- `--title` and `--generate` follow the setting. `LAUNCHY_TEXT_GENERATION` (`local` or `server`) overrides it. Both print where the reply was made and the time taken.

**Peers**

- A session's title is made by the Mac that hosts it, with that Mac's choice. A session the Studio started for the Air is titled by the Studio's Text generation. Nothing crosses the peer protocol and there is no protocol bump.
- The Ryzen's sessions stay untitled, as today. Its relay makes no titles, and serving a model there doesn't change that.

**Docs, once accepted**

- ADR 0014 (or option 03's joint one). ADR 0012 gains a line pointing to it.
- `where-it-breaks.md`, Session titles:
  - with Text generation on a server, the cut first prompt goes to that server and nowhere else;
  - a failure that isn't the model's never sets the failed mark;
  - the prompt and the title are never logged, error bodies included.
- CONTEXT.md: **Model server**, as in option 01.

## Testing Decisions

- There is no test target. Verification is `make build`, `--title` and `--generate` against both choices, and checks by hand after the user restarts Launchy.
- **Titles side by side.** Run `--title` over the 31 first prompts the title spike used, with `LAUNCHY_TEXT_GENERATION=local` and `=server`, and compare the titles and times. The prompt files are personal: keep them out of the repo.
- **Checks by hand, after the restart:**
  - Each status: no address, Checking…, the answer time, not answering (a wrong port), not on your tailnet.
  - Session titles turned on with Server and no Gemma installed.
  - A new session titled through the server.
  - With the server unreachable: Claude's title shows, no failed mark is saved (the pane's record in `sessions.json` has no title record for it), and the title arrives once the server is back while the pane is open.
  - Gemma isn't loaded with Server chosen (Activity Monitor).
  - The server's log holds no prompt text after a title.
  - Whether macOS asks for Local Network access, as in option 01.

## Out of Scope

- Search embeddings on a server (option 01).
- The Ryzen's side of it: options 04 and 05.
- Cloud text generation providers, and any address off the tailnet.
- Falling back to this Mac's Gemma.
- Titling the Ryzen's sessions, or a paired Mac's sessions from here.
- Other uses of text generation, streaming, and a model chosen per feature.
- Launchy on one Mac lending its in-process models to another over the peer link.

## Further Notes

- **Verified in the code, 2026-10-07:**
  - how a title is asked, cleaned up and recorded;
  - that today any error with the model ready sets the failed mark, which is what this option changes for a server's failures;
  - that the Session titles switch is gated on the model being installed.
- **Not verified:**
  - whether a server's titles match the Mac's in quality;
  - what llama.cpp's server logs at its default verbosity;
  - the Local Network prompt.
- **Open questions, each with a recommendation:**
  1. *Which server:* option 04 (recommended, if this option is accepted) or option 05. They are compared in their own Trade-offs.
  2. *No fallback to this Mac's Gemma:* none, as above. The alternative is option 01's rule for searches: use this Mac's model while the server is away. That titles sooner, but loads 2.5 GB on a Mac that chose not to hold it.
  3. *A model field:* yes, prefilled for Ollama, as option 01's.
