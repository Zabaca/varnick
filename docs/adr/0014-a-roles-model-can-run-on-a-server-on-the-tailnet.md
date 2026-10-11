# A role's model can run on a server on the tailnet

Search embeddings and Text generation can each run on an OpenAI-compatible server on the user's tailnet instead of in Varnick's process. The choice is made per Mac and per role in Settings › Models. On this Mac stays the default, so ADRs 0003's and 0012's reasons (nothing to install or keep running) hold for anyone who doesn't choose Server. Varnick keeps what decides a result: the embedding instruction, the texts, the normalization and the model key, and the prompts and their clean-up. The server only computes. A server for embeddings is used only after its vectors match references shipped in Varnick (cosine 0.99), because mixed vectors would ruin search with no error. Work the user waits on falls back to this Mac's installed model when the server is away, and background work waits for it. We chose this over a cloud provider (only tailnet and loopback addresses are accepted), over sharing vectors between Macs, and over one Mac lending its models to another over the peer link. The first servers are foundry's `foundry-embeddings` on the Ryzen and a chat server beside it. The problem and its options are in `docs/problems/models-run-only-on-this-mac/`.

## Consequences

- With Server chosen, what semantic search reads (session prompts included) goes to that server over the tailnet. Nothing goes to a third party.
- Varnick depends on services it may not own. A change of embedding model shows as a failed Check, never as wrong vectors; an absent server shows as a fallback or a wait.
- No new dependency: the requests use URLSession (`ModelServer.post` is the one path, and it follows no redirect). MLX isn't touched on the server path, and a build without `mlx.metallib` can use a server.
- A server for Text generation has to answer in `message.content`, which a model that thinks first at the server does not. Varnick reads that as the server not answering.
- Amended by ADR 0029: "over a cloud provider" no longer holds for Text generation. The choice is Claude Code, On this Mac or Server, and the fallback rule extends to Claude Code: when it fails, the interactive request runs again on this Mac's installed model.
