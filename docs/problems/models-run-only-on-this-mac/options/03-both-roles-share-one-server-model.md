---
problem: models-run-only-on-this-mac
title: Both roles can run on a server, sharing one idea of a model server
summary: Options 01 and 02 together, designed and documented as one thing. Each role gets "On this Mac | Server" with its own address, since no single server on the Ryzen serves both today. They share one Model server key, one tailnet rule, one way to check, report and log, and one rule for an absent server (a search falls back to this Mac; background work, the sync and titles, waits). One ADR covers both. Embeddings can ship first, against foundry's service as it is; text generation follows once a chat server exists (option 04 or 05).
status: shipped
---

## Solution

Search embeddings behave as in option 01 and Text generation as in option 02. This option is what changes when they are one feature rather than two.

- **One idea of a server.** In Settings › Models, each role's picker reads On this Mac | Server, and the Server row has the same parts in the same order: address, model, Check, status. The statuses use the same words. Under Keys, one **Model server** row holds an optional key, sent to whichever server addresses are set.
- **An address per role.** This departs from a single server address under Keys: the two roles are served by different programs on the Ryzen today, `foundry-embeddings` on port 11434 and a chat server on another port. Where one server answers both (an Ollama with both models, LM Studio), the same address goes in both rows. A single address would force a router on the Ryzen, or foundry's service to host Gemma (option 05).
- **One rule for a server that isn't there.** Work the user is waiting on falls back to this Mac's model when it is installed: a search, and the sessions under the prompt line. Background work waits for the server: the minute sync's embedding and session titles. That is options 01 and 02's behaviour, written once.
- **One tailnet rule and one logging rule** for both routes. The address must resolve only to tailnet or loopback addresses. Nothing of a request, a reply's body or the key is logged.
- **One request path.** The address handling, the key, the timeouts, the tailnet check and the error kinds are shared. Each role's own part stays its own: the vectors and references for embeddings, the title request for generation.
- **One ADR**, 0014, covering both roles (draft below), instead of two that say the same about servers.
- **Two deliveries.** Embeddings first: they need nothing on the Ryzen. Text generation once a chat server runs there. Accepting this option doesn't commit to option 04 or 05; Text generation's Server choice can ship before the Ryzen has one, since any OpenAI-compatible server on the tailnet works.

## Trade-offs

- **Against 01 alone:** a little more to build now (the shared request path and Settings parts serve two roles), in exchange for not reshaping 01's pieces when Text generation follows. The privacy rules change for both roles in one review, so the user decides once what may leave a Mac.
- **Against 02 alone:** text generation is the bigger saving for a small Mac (3.6 GB and 2.5 GB against 650 MB and 0.65 GB), but it is the half that needs a new server and a foundry decision. Embeddings can be useful in a day.
- **Two addresses where one would read simpler.** The user types the Ryzen's name twice, with two ports. In exchange, nothing on the Ryzen has to change to put one address in front of two services.
- Every trade-off of options 01 and 02 applies, privacy above all. With both roles on a server, the server sees what is embedded (searches, typed prompts, page texts, session prompts) and each conversation's first prompt.

## User Stories

1. As a MacBook Air user, I want both search by meaning and session titles with neither model on the Mac, so that a small Mac gets every feature Launchy has.
2. As a Launchy user, I want both roles' server settings to look and behave the same, so that learning one teaches me the other.
3. As a Launchy user, I want one key row for my model server, used by whichever roles run on it.
4. As a Launchy user, I want to put the same address in both roles when one server answers both.

The stories of options 01 and 02 hold as written.

## Implementation Decisions

- Everything in options 01 and 02, with these settled for both:
  - **Saved:** `searchEmbeddingsRunOn`, `embeddingServer`, `embeddingServerModel`, `textGenerationRunOn`, `textGenerationServer` and `textGenerationServerModel`, each with options 01's and 02's defaults. One Keychain account, `MODEL_SERVER_KEY`.
  - **The fallback rule,** in one place in the code and in one bullet of `where-it-breaks.md`: interactive work falls back to this Mac's installed model, background work waits, and On this Mac never contacts a server.
  - **The request path:** the address handling (adding the route without doubling `/v1`), the tailnet check, the bearer key, the ephemeral session and the error kinds. Each role keeps its own timeouts: 2 s for a query, 30 s for a sync batch, 10 s for a title, 5 s for a Check.
  - **The command line:** `LAUNCHY_EMBEDDINGS` and `LAUNCHY_TEXT_GENERATION` as in options 01 and 02, `--embed-check` and `--embed-reference` from option 01, and `--title` and `--generate` following their role.
- **Order of work:** the request path and the Settings parts with Search embeddings (option 01's tickets, its first one the reference check against `foundry-embeddings`), then Text generation's Server choice, then the server on the Ryzen if option 04 or 05 is accepted.

## Testing Decisions

- Options 01's and 02's testing decisions, run for each role as it ships.
- When both run on a server, one more check by hand: a title and a search made together, both through the Ryzen, with neither model loaded on this Mac.

## Out of Scope

- The out-of-scope lists of options 01 and 02.
- A single address serving both roles through a router on the Ryzen.
- Any role but these two on a server.

## Further Notes

- **Draft ADR 0014**, in place of the single-role drafts:

  > # A role's model can run on a server on the tailnet
  >
  > Search embeddings and Text generation can each run on an OpenAI-compatible server on the user's tailnet instead of in Launchy's process. The choice is made per Mac and per role in Settings › Models. On this Mac stays the default, so ADRs 0003's and 0012's reasons (nothing to install or keep running) hold for anyone who doesn't choose Server. Launchy keeps what decides a result: the embedding instruction, the texts, the normalization and the model key, and the title prompt and its clean-up. The server only computes. A server for embeddings is used only after its vectors match references shipped in Launchy (cosine 0.99), because mixed vectors would ruin search with no error. Work the user waits on falls back to this Mac's installed model when the server is away, and background work waits for it. We chose this over a cloud provider (only tailnet and loopback addresses are accepted), over sharing vectors between Macs, and over one Mac lending its models to another over the peer link. The first servers are foundry's `foundry-embeddings` on the Ryzen and a chat server beside it.
  >
  > ## Consequences
  >
  > - With Server chosen, what semantic search reads (session prompts included) and each conversation's first prompt go to that server over the tailnet. Nothing goes to a third party.
  > - Launchy depends on services it may not own. A change of embedding model shows as a failed Check, and an absent server as a fallback or a wait, never as wrong data.
  > - No new dependency: the requests use URLSession. MLX isn't touched on the server path, and a build without `mlx.metallib` can use a server.

- **Open question:** one address per role, as above (recommended), or one address under Keys, as first proposed. One address is simpler to type, but needs a router or option 05 on the Ryzen.
