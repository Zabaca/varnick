# Text generation runs in Varnick with MLX

Varnick writes short text on this Mac, first the titles of Claude sessions, with Gemma 4 E2B (`mlx-community/gemma-4-e2b-it-4bit` at a pinned revision). It runs in Varnick's own process through mlx-swift-lm's `MLXLLM`, the way semantic search (ADR 0003) and the local relevance filter (ADR 0006) run. The model downloads once from Settings › Models. That section is the one place where each role's model is chosen and set up and where keys are kept, by provider; features keep their own switches. We chose this over a cloud provider, which would send the user's prompts off the Mac, and over a separate server such as Ollama for ADR 0003's reasons: nothing to install or keep running beside Varnick. A spike on the M3 Ultra, with Launchy's exact pins and metallib, loaded it in 1.3 s and wrote a title in 0.34 s, with no change to MLX. The problem and its option are in `docs/problems/models-set-up-per-feature/`.

## Why not Apple's on-device Foundation Models

A second spike compared Foundation Models (macOS 26) with Gemma 4 E2B on 31 real first prompts, with the same title prompt. Gemma won on the titles, and Foundation Models' gains (no download, no memory in Launchy) don't make up for it.

- **Foundation Models** is available on the development Mac, needs no download and adds about 8 MB to Varnick's process, since it runs out of process. The system service and wired memory rose 1.2 to 2.8 GB while it was loaded, and macOS unloaded it after about 5 idle minutes. Its context is 4,096 tokens. It needs macOS 26 and Apple Intelligence, and Varnick targets macOS 14. Its titles were worse: always Title Case despite the prompt, a median of 5 words with 3 over 6, padded with words like "Overview" and "Analysis", and with invented details ("YOLO Model Performance Issues" for a CLI alias `yolo`). Guardrails refused 1 of 31 harmless prompts (none with `permissiveContentTransformations`). A title took a median 0.40 s, and 1.1 s cold.
- **Gemma 4 E2B** refused none, wrote sentence case, a median of 3 words and none over 6, and named the actual thing in about 25 of 31 (the misses mostly drop a proper name). A title took a median 0.08 s, and the first call after a 1.3 s load 0.21 s. It costs a 3.6 GB download and about 2.5 GB in Varnick's process while loaded.
- Foundation Models stays a cheap later addition as a second choice for Text generation in Settings › Models. It would need an availability check, permissive guardrails, a refusal read as no title, and a sentence-case clean-up.

## Consequences

- Varnick's target gains `MLXLLM`, a product of the already-pinned mlx-swift-lm. There is no new package and the metallib contract is unchanged.
- A 3.6 GB download, and about 2.5 GB of MLX memory while loaded (3.1 GB at peak on a 2k-token prompt), on top of the embedder's 650 MB and the relevance model's 0.85 GB. It unloads after ten idle minutes, and MLX's 64 MB cache cap covers it.
- MLX runs one evaluation at a time per process, so a generation can hold up a search's embedding or relevance check. The first generation after a load spends about 2.8 s on shader setup.
- A role can later offer a second choice, such as Foundation Models or a cloud provider for text generation, whose key is a row under Keys. The role's consumers don't change.
- ADRs 0003 and 0006 stay as written.
- Amended by ADR 0014: Text generation can also run on a server on the tailnet.
- Amended 2026-10-09, at the user's request: Launchy no longer writes session titles (the Session titles setting, the title prompt and `Launchy --title` are removed). A session is named by its ⌘⇧R tab name, else its /rename name, else Claude's own title (problem `search-names-sessions-differently`, option 03). Text generation stays for Hey Launchy's answers (ADR 0015), so the model and its download are unchanged. The sections above describe the choice of Gemma over Foundation Models for titles, which no longer apply.
- Amended by ADR 0029: Text generation can also run as the user's own Claude Code on their subscription, and does by default for new installs; no key is kept under Keys for it, since `claude` is already logged in. This Mac's model becomes the optional fallback.
