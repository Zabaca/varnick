---
problem: models-run-only-on-this-mac
title: Foundry's embedding service also serves Gemma, so one Ollama on the Ryzen answers both roles
summary: The Ryzen side of Text generation on a server, done in foundry instead of Launchy. Foundry amends its ADR-0033 so that `foundry-embeddings` also keeps `gemma4:e2b` loaded. Launchy installs nothing. Both roles can then use the same address, `http://linux-box:11434`. It reverses the line in foundry's ADR that says the service "is not a chat host", and it runs Gemma on the ROCm path with the GFX override, where the spike saw page faults.
status: proposed
---

## Solution

Foundry, in its own repo, changes `foundry-embeddings`:

- ADR-0033 is amended (or superseded) to make the service a chat host for one small model, Gemma 4 E2B, for Launchy's session titles.
- The compose file pulls `gemma4:e2b` beside `qwen3-embedding:0.6b`. `OLLAMA_MAX_LOADED_MODELS` goes from 1 to 2, so both stay loaded and neither evicts the other. The keep-alive stays at forever.
- Gemma's context is set to 4K, which is all a title needs, instead of Ollama's default.

Launchy changes nothing beyond option 02. Its Text generation row takes `http://linux-box:11434` with the model `gemma4:e2b`, the defaults option 02 already prefills. With option 03, both roles hold the same address.

## Trade-offs

- **Nothing new for Launchy to install or upgrade.** Foundry already owns this service's restarts, its probe and its compose file, and both roles share one address.
- **It reverses a line foundry wrote on purpose.** ADR-0033 says a chat model "changes what the card can hold and reintroduces the contention this ADR says does not exist". The service would serve another repo's feature, and the hourly favorites job and Launchy's titles would share one Ollama.
- **The path the spike was least happy with.** Ollama's ROCm image with `HSA_OVERRIDE_GFX_VERSION=11.0.0` logged seven amdgpu page faults while loading this model, with no hang. `foundry-embeddings` runs with that same override. Ollama wasn't run again to see whether the faults repeat.
- **Slower generation, which titles barely notice.** About 126–131 tokens/s against about 196 for llama.cpp's Vulkan build (option 04). A short title took a median of 0.087 s against 0.078 s.
- **A different build of the model.** Ollama's `gemma4:e2b` is Q4_K_M with a draft model and a vision projector, 3.5 GB on disk. It used about 3.8 GB of VRAM at its default 32K context; less at 4K (by how much, unmeasured). It differs from the Mac's MLX 4-bit and from option 04's Q4_0.
- **The tag resolves to whatever Ollama's library holds** when foundry applies, unless foundry pins a digest.

## User Stories

1. As a MacBook Air user, I want session titles from the Ryzen with no model on the Air, served by the service that already serves my embeddings.
2. As the person who runs the Ryzen, I want one model service on the card, owned and probed by foundry, rather than two from two repos.

## Implementation Decisions

- **Foundry's side, decided and done in foundry's repo:** the ADR change, the compose change (the model pull, `OLLAMA_MAX_LOADED_MODELS=2`, a 4K context for Gemma), and a digest pin if wanted.
- **Launchy's side:** option 02 as written, with `http://linux-box:11434` and `gemma4:e2b`.
- **Docs, once accepted:** ADR 0014 (option 02's or 03's) names foundry's service as the chat server and links foundry's ADR.

## Testing Decisions

- Foundry's own checks after its apply, and the journal and `dmesg` on the Ryzen for amdgpu faults while Gemma loads.
- Option 02's checks against `http://linux-box:11434`, including the 31-prompt title comparison.
- `--embed-check` (option 01) after the change, to confirm the embedding model's vectors are unchanged.

## Out of Scope

- Launchy's side: option 02.
- Any model on foundry's service beyond these two.

## Further Notes

- **Verified 2026-10-07:** `foundry-embeddings`' settings (`OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=2`, keep-alive forever, `HSA_OVERRIDE_GFX_VERSION=11.0.0`), and ADR-0033's words as quoted.
- **From the spike's report, not rerun:** Ollama's timings, its VRAM and its page faults.
- **Compared with option 04:**
  - this one installs nothing and gives one address;
  - option 04 keeps foundry's service as its ADR describes, runs the faster Vulkan path that logged no faults, and pins the exact model measured.

  Either needs a foundry ADR. Option 04 is recommended.
