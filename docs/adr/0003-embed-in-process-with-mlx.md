# Embeddings run inside Launchy with MLX, not through Ollama

Semantic search embeds page titles and queries in Launchy's own process with MLX (`mlx-swift-lm`'s `MLXEmbedders`, Qwen3-Embedding 0.6B at 8-bit), and Launchy syncs Chrome history itself every minute. We chose this over talking to an Ollama server so semantic search needs no separate install, service or model pull: the model downloads once from Settings › Search and nothing else is required. In a spike the 8-bit MLX vectors matched Ollama's `qwen3-embedding:0.6b` (cosine 0.999, 9.6 of the top 10 results the same) and embedded about 5x faster, so archives embedded by Ollama were kept as they are.

## Consequences

- Dependencies grow from SwiftTerm alone to SwiftTerm plus `mlx-swift`, `mlx-swift-lm` and `swift-transformers` (and what they pull in); a clean release build takes about 2.5 minutes instead of 20 seconds.
- `swift build` can't compile MLX's Metal shaders without Xcode, so `make build` puts a prebuilt `mlx.metallib` from the matching `mlx-metal` wheel next to the binary. `mlx-swift` is pinned exactly and the wheel URL and checksum move with it.
- MLX's buffer cache defaults to a share of RAM (36 GB, for example, on a Mac with a lot of RAM), so Launchy caps it at 64 MB. The model holds about 650 MB while loaded and is unloaded after ten idle minutes.
- The Python sync script and its LaunchAgent are gone; history is only synced while Launchy runs, which is always for anyone who installed it to start at login.
- Amended by ADR 0014: Search embeddings can also run on a server on the tailnet.
