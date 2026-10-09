---
title: Every model runs on the Mac that uses it
description: Search embeddings and Text generation run only inside Launchy, on each Mac. A Mac that can't spare the downloads, the memory or the GPU, such as the MacBook Air, either goes without search by meaning and Hey Launchy's spoken answers, or pays for both models itself, including embedding every paired Mac's pages and sessions. Meanwhile the Ryzen already serves the same embedding model on the tailnet, and its card ran Gemma as fast as the Mac Studio does, and faster for long prompts (timed on session titles, which Launchy no longer writes).
impact: Each Mac that wants both roles downloads 650 MB and 3.6 GB, holds about 0.65 GB and 2.5 GB while they are loaded, and runs the whole embedding backlog on its own GPU and battery. Each model unloads after 10 idle minutes, so the next search after a pause waits about 1.75 s for the embedder to load again, and the next spoken answer waits for Gemma. A Mac that skips the downloads gets keyword-only search and no spoken answers.
severity: low
evidence: Measured and read on 2026-10-07 (below), with fixed made-up sentences and counts only, never the user's text. Latency figures for this Mac were measured by the coordinator; the GPU figures come from the spike report of the same day. Neither was rerun for this problem.
status: open
---

## Today

**Search embeddings** run in Launchy's process with MLX (ADR 0003): Qwen3-Embedding 0.6B, 8-bit, downloaded once from Settings › Models.

- A query gets Launchy's own instruction prefix; pages and sessions are embedded bare. Every vector is normalized and stored under the model key `qwen3-embedding:0.6b`, the name Ollama gives the same model. ADR 0003 kept archives that Ollama had embedded, at cosine 0.999.
- Each Mac embeds its own archive, and that archive holds every paired Mac's pages and sessions too. Vectors never travel between Macs: the peer requests carry rows, not vectors (checked in the code). On the Mac Studio, 7,077 entries are embedded, 155 characters long on average.
- What gets embedded is personal. For a page it is the title, the site, the start of the page's description, its bookmark folders and the search terms that led to it. For a session it is the title, the folder name and the user's prompts, up to 1,000 characters. While a prompt is typed in the panel, its first 1,000 characters are embedded to list matching sessions.
- `where-it-breaks.md` says a session's prompts stay on the user's paired Macs and go to no other service, and that a typed prompt runs only this Mac's embedder.

**Text generation** runs in Launchy's process with MLX (ADR 0012): Gemma 4 E2B, 4-bit, a 3.6 GB download. Its only use is session titles, made from each conversation's first prompt (its first 1,500 characters). Its Settings text says nothing is sent anywhere. (Since then Hey Launchy's answers use it too, and on 2026-10-09 session titles were removed, so those answers are its only use; ADR 0012 as amended.)

**The relevance filter** already runs on TypeSafe or on this Mac. It isn't part of this problem.

No role can run anywhere but this Mac. ADRs 0003 and 0012 chose in-process models over an Ollama server so that nothing has to be installed or kept running beside Launchy. ADR 0012 expected that a role could later offer a second choice without its consumers changing.

## The Ryzen

**`foundry-embeddings`** is foundry's service, not Launchy's (foundry ADR-0033). It runs ollama's ROCm image and serves `qwen3-embedding:0.6b` on port 11434, with no authentication. These facts were checked on 2026-10-07:

- The model digest is `ac6da0dfba84`, Q8_0, 1024 dimensions, and Ollama's version is 0.34.1.
- The model stays loaded (`OLLAMA_KEEP_ALIVE=-1`), with two requests at a time (`OLLAMA_NUM_PARALLEL=2`) and one model loaded at a time (`OLLAMA_MAX_LOADED_MODELS=1`).
- It runs with `HSA_OVERRIDE_GFX_VERSION=11.0.0`.
- Docker publishes the port on every interface. Foundry's ADR says the existing firewall gates it to the tailnet.
- Foundry's own pipeline embeds its favorites through it every hour.

Foundry's ADRs set the terms for anything else on that card:

- ADR-0033 says the service exists "so other things on the box can use them", that it is the card's only tenant, and that "It is not a chat host … Adding a model to this stack is a change to this ADR."
- ADR-0032 and ADR-0001 say a second GPU tenant is a new decision.
- ADR-0026 and ADR-0028 make foundry the runtime other repos deploy onto: the repo that owns the work declares its own guest.

**The card** is an RX 7800 XT, 16 GB. The amdgpu driver on this box has hung before.

## Evidence

**Measured this session (2026-10-07)**, with two fixed sentences, one of them a query with Launchy's prefix:

- Ollama's OpenAI-compatible route (`/v1/embeddings`) returns the same vectors as its native one (`/api/embed`), at cosine 1.000000. Both come back normalized, with 1024 dimensions. A `dimensions` field in the request truncates the vector (256 asked, 256 returned).
- From this Mac over the tailnet, a batch of 64 short texts took 0.54 s and a batch of 256 took 2.37 s.
- The service's log records each request's method, route, time and caller address, and not its text: the test sentences appear nowhere in it.
- Launchy is a bare executable whose Info.plist has no App Transport Security keys. 86 `http://` pages in the archive were fetched with status 200, so plain `http` from Launchy's process is likely allowed (inferred).

**Reported, not rerun:**

- **Local embedding** on the Mac Studio, with Launchy's own files and method: the model loads in 391 ms and the first query takes 1,356 ms (shader setup). Warm, a query takes a median of 7.1 ms (6.8–7.6, n=9).
- **The Ryzen's service** answers in about 30 ms warm over the tailnet, about 5.5 ms of it on the server. The first call took 1.1 s, and the model stays loaded after that. So warm, a query on this Mac is about 4 times faster. The server's gain is that it never starts cold.
- **Gemma 4 E2B on the Ryzen** (GPU spike, Q4_0 GGUF, llama.cpp's Vulkan build, the 7800 XT selected as `Vulkan1` because `Vulkan0` is the iGPU):
  - prefill about 5,965 tokens/s against about 2,200 for the Mac's MLX, and generation about 196 tokens/s against 150–170;
  - a short title in 0.078 s against 0.083 s, and a title from a prompt of about 470 tokens in 0.135 s against 0.209 s;
  - about 1.6 GB more VRAM at a 4K context, beside foundry's model's 3.2 GB.
- **Other servers in the spike:** llama.cpp's ROCm build generated about 35% slower than its Vulkan build. Ollama's ROCm image, with the same GFX override that `foundry-embeddings` runs, logged seven amdgpu page faults while loading Gemma, with no hang. Tailscale's round trip from this Mac to the Ryzen ranged from 3 to 73 ms.

**Not checked:**

- Whether the digest `ac6da0dfba84` gives vectors within 0.99 of Launchy's MLX model. ADR 0003's 0.999 was measured against an earlier pull.
- The MacBook Air's memory, and which models it has installed. It didn't answer over SSH.
- Whether port 11434 answers from the LAN. Docker-published ports often bypass a host firewall, and a probe from this session was inconclusive (a proxy intercepted it).
- Whether macOS's Local Network privacy prompt covers a tailnet address reached from Launchy's own process. No Launchy code makes such a connection today.
