---
problem: relevance-filter-needs-typesafe
title: Rerank on this Mac with our own MLX port of Laya
summary: The relevance filter gets a TypeSafe / On this Mac / Off choice. On this Mac runs the distilled checkpoint inside Launchy on its pinned mlx-swift, with a ModernBERT encoder and Laya decision head written for Launchy. The checkpoint is imported once from a local folder, and nothing leaves the Mac.
status: accepted
---

## Solution

Settings › Search gets a choice for the relevance filter: TypeSafe (today's behaviour and the default), On this Mac, or Off. On this Mac judges the same top 20 pages with the distilled checkpoint, running in Launchy's own process with MLX, the way semantic search does. The user imports the checkpoint once from a folder on disk, and Launchy copies it next to the embedding model.

There is no 1 s pause and no round trip, so the order settles about 30 ms after the semantic pass instead of about 1.1 to 1.2 s after typing stops, and it works offline. The model code is about 300 lines written for Launchy against mlx-swift 0.32.3 and swift-transformers, with no new package: the encoder, the decision head and the row builder. A hidden command scores the prototype's 200-search eval with the app's own code. That is how the port is checked against Python without a test target.

## Trade-offs

- **Nothing leaves the Mac.** No key, no network, no cost per search. On this Mac never falls back to TypeSafe, even after a failure.
- **Faster.** The whole call measured 31.6 ms p50 / 37.8 ms p90 in a Swift draft on the M3 Ultra, and it runs right after the 120 ms pause. Smaller Macs will be slower (unmeasured).
- **Quality is level** with Jev asked per page (0.752 against 0.747) and with Launchy's current TypeSafe request (0.752); 0.713 was the request before 2026-10-03. So the case for On this Mac is privacy, offline use, latency and cost, not quality. This was measured on keyword and random candidates, not on Launchy's fused top 20 (see the problem's caveats).
- **Roughly 600 to 750 lines of Swift to own, about 300 of them model code.** During the investigation the model code was written three times, by separate agents, and each version matched Python. The risk is therefore not the maths. It is the row drifting from training, or an MLX or tokenizer update changing results. Both are silent: ranking gets worse with no error. The eval command is the guard, and every mlx-swift or swift-transformers bump has to rerun it.
- **Memory.** About 0.85 GB of MLX memory at peak during a search, including the 328 MB of weights, so about 0.5 GB is transient. Up to about 1.2 GB at peak over a whole 200-search run; whether that came from loading or from the longest searches wasn't pinned down. All of it is on top of the embedder's 650 MB. The model unloads after 10 idle minutes, like the embedder.
- **Shares MLX with the embedder.** mlx-swift runs one evaluation at a time per process, so a rerank can wait behind a history-sync embedding batch. Sync runs every minute; the delay is unmeasured.
- **The checkpoint is personal and has no download.** Another Mac needs the folder copied by hand. It ages as history grows, and retraining needs new TypeSafe labels (about $2.20) and about 40 minutes.
- **It imitates Jev asked per page, not Launchy's request.** Launchy's current batched request scores the same on the eval, so switching costs no measured quality.

## User Stories

1. As a Launchy user, I want the relevance filter to run on this Mac, so that my searches and page titles never leave it.
2. As a Launchy user, I want the relevance filter to work offline and without a TypeSafe key, so that it is always there.
3. As a Launchy user, I want results to settle right after I pause typing, not a second later.
4. As a Launchy user, I want to choose TypeSafe, On this Mac or Off in Settings and have my next search use that choice.
5. As a Launchy user, I want to import my checkpoint once from a folder and see that it's on, so that I never handle model files myself.
6. As a Launchy user, I want to see why On this Mac isn't working (no metallib, no model, a broken model) and retry, so that I'm not left guessing.
7. As a Launchy user, I want a failed relevance check on this Mac to show unfiltered results with the usual warning, never to send the search to TypeSafe instead.
8. As a Launchy user, I want the relevance tooltips to say whether TypeSafe or this Mac judged the results.
9. As a Launchy user, I want the model to leave memory when I'm not searching, as semantic search's does.
10. As a maintainer, I want one command that scores the eval with the app's own code against the Python scores, so that I can tell when a port change or an upgrade broke ranking.

## Implementation Decisions

**The setting**
- A saved choice with three values: TypeSafe, On this Mac, Off. It is stored in UserDefaults under `relevanceFilter` as `typesafe`, `local` or `off`, and read with `typesafe` as the default. Existing users see no change: with a key the filter is on, without one it is off.
- In Settings › Search, the Relevance filter row holds a segmented control, the first picker in Settings. Its detail is "After you pause typing, moves the results that match what you meant to the top." Under it is a row for the chosen backend:
  - TypeSafe keeps today's key controls, and today's detail, which says what is sent to TypeSafe.
  - On this Mac shows the model's status the way the semantic search row does:
    - no metallib: "Needs mlx.metallib: build with make";
    - no model: "Choose…";
    - importing: a spinner and "Importing…" (a local copy reports no progress);
    - installed: "On", and "Choose…" to replace it;
    - failed: the message, "Retry" and "Choose…".
    Its detail says the model was trained on the user's own history and nothing is sent anywhere.
  - Off shows nothing, and the key stays in the Keychain.
- Two kinds of error, kept apart:
  - An import error is shown beside "Choose…" and leaves the state as it was: On stays On, and no model stays no model.
  - Only a failed load of the installed model sets the failed state. Retry clears it and loads at once, off the main actor.
- The UI keeps calling it TypeSafe; "Jev" appears nowhere.

**Choosing the reranker at each search**
- Both rerankers sit behind today's single call: query and candidates in, one probability per candidate out, in candidate order. Each also says how long a typing pause it waits for.
- The reranker is picked at each search from the setting, the way the embedder is checked at each search. It is TypeSafe when chosen and a key exists, On this Mac when chosen and the model is installed and not failed, and none otherwise. This replaces today's subscription to the key.
- The pause belongs to the reranker. TypeSafe keeps 1 s from the last keystroke, which saves paid requests. On this Mac adds none: it runs as soon as the semantic pass finishes, and that pass already waits for a 120 ms pause.
- Unchanged: the 3-character minimum, the 20 candidates, the 0.5 threshold and how results reorder.
- Candidates stay pages only, after the leading sessions. Session rows have no host and look nothing like training rows. The caller already takes that slice, so nothing changes there.
- The tooltips name the reranker that produced the scores on screen, not the current setting, which can differ after a switch. That name is recorded with the rerank status when the scores arrive. TypeSafe's strings stay as they are; On this Mac's are "Filtered by relevance on this Mac", "Relevance check on this Mac failed — showing unfiltered results" and "On this Mac: 82% relevant". The footer counts are already neutral.

**Where the checkpoint lives and how it gets there**
- It lives in one fixed folder, `laya-relevance`, in Launchy's Application Support models folder next to the embedding model, so a re-import replaces it. It never goes in the repo, the app or Hugging Face, because the weights encode the user's browsing history.
- "Choose…" opens a folder picker like the project-folders picker. The user picks the checkpoint in the private folder the problem names, which isn't hidden, so the picker needs no change. The import runs off the main actor:
  1. Check the folder. These five files are present: the weights (`model.safetensors`), the encoder config, `tokenizer.json`, the tokenizer config and the agent config. `launchy_format` is "minimal" and `launchy_question` is the minimal question. The encoder is ModernBERT with `layer_types` and per-type `rope_parameters`. The noul temperature is present. `tokenizer.json` matches the pinned SHA-256 (see Tokenizer).
  2. Copy only those five files into a `.partial` folder. The checkpoint folder also holds eval scores and logs, which stay out of Application Support.
  3. Load the copy and score one row; the question prefix must match the expected ids and the result must be finite.
  4. Replace the installed folder with it and drop any loaded model.
- If any step fails, the `.partial` folder is removed and the error is shown. The installed model, if there is one, is left as it was.
- The weights and configs carry no checksum. The embedder pins a revision because it downloads its model; this folder comes from the user's own disk, and the trial load proves the weights and configs load and score. It does not prove the tokenizer is safe to build, which is why `tokenizer.json` is pinned.
- If the model folder is deleted while Launchy runs, the state goes back to "no model", as the embedder's does.

**Lifecycle** (shaped like the embedder's)
- The reranker is created at launch next to the embedder. Its init only checks that mlx.metallib and the model folder exist. It touches no MLX and reads no files, because it runs on the main thread at launch.
- It loads on first use, and a second caller joins a load already in progress. It unloads after 10 idle minutes and clears MLX's cache.
- MLX's 64 MB cache cap is set once, by whichever model loads first. Today only the embedder sets it. The metallib check is shared with the embedder.
- A failed load sets the failed state with its message and turns the filter off until Retry. The embedder retries on the next search instead, but a broken checkpoint would fail the same way on every search. A failed scoring only shows the warning for that search; the next search tries again.
- The first search after a load pays for loading, about 0.2 s from the page cache including the tokenizer, and for shader setup: 43 ms with a warm OS shader cache; a fully cold start is unmeasured. Check it by hand.

**Failures**
- If a rerank fails (an MLX error, a non-finite output, a failed load), results stay in fused order with "relevance check failed", as a TypeSafe failure does. The error is logged like a semantic-search failure. The search is never retried with TypeSafe.
- Several failures would crash Launchy and end every session in it. Each gets a guard:
  - Nothing touches MLX before the metallib check, including setting the cache cap.
  - Loading and scoring run inside mlx-swift's wrapper that turns MLX errors into Swift throws. MLX's default error handler exits the app.
  - swift-transformers never sees a `tokenizer.json` that doesn't match the pin.
  - The reranker returns exactly one score per candidate or throws, because reordering reads a score for every judged page.

**The row** (a contract with the checkpoint: drift lowers ranking without any error)
- The row builder takes a query, a site and a title and returns token ids. The app passes the page URL's host, lowercased, as the site; the eval command passes the eval file's site, which is already Python's lowercased host. So the URL-to-site step is covered by the investigation's host check and by `--search`, not by the eval command.
- The state is the query (trimmed, as search trims it), a newline, the site, a newline, and the title cut to its first 60 Unicode scalars. Any literal "[MASK]" in the state becomes a space.
- Hosts are lowercased because training lowercased them. Swift's URL host matched Python's on all 5,384 snapshot URLs, which are already lowercase, but it keeps a mixed-case host such as GitHub.com as typed.
- The title is cut by Unicode scalars because Python's slice counts code points, while a Swift string's prefix counts grapheme clusters. On the eval they differ on 1 of 4,000 titles, and 1,431 of the 4,000 get cut.
- The sequence is:
  1. a fixed 16-token question prefix, built once at load from `launchy_question`;
  2. the state's tokens, encoded without special tokens and cut to the first 495;
  3. [SEP].
- The prefix is built as Laya builds it. Encode "noul question: ?", " false: n" and " true: y" without special tokens, then assemble [CLS], the question, [SEP], [MASK] and the false option, [MASK] and the true option, [SEP]: false first. The answer markers are the two [MASK] positions, 7 (false) and 11 (true). Compare the result with the expected ids in Further Notes. If they differ, the tokenizer doesn't match, so the checkpoint is refused (an import error, or the failed state at load).
- All 20 rows go through in one forward pass, right-padded with [PAD] to the longest and with an explicit attention mask. Rows are judged independently: a row's score barely depends on its batch (4e-7 in fp32 on the CPU; up to 3e-3 in fp16 on the GPU, with no candidate crossing 0.5 on the eval).

**The model**
Written from the Python MLX reference (laya-mlx) against mlx-swift 0.32.3. Every size comes from the encoder config; the values given are this checkpoint's. A config without `layer_types` or per-type `rope_parameters` is refused, never defaulted.

- *Encoder* (ModernBERT: pre-norm, no biases anywhere, LayerNorm without bias at eps 1e-5):
  - Token embeddings, then a LayerNorm. There are no position embeddings.
  - Each layer does x += attention(norm(x)), then x += MLP(norm(x)). Layer 0 has no attention norm.
  - Attention is one fused Wqkv projection split into q, k and v, with heads of 64 (12 here). q and k get rotate-half RoPE over all 64 dimensions (MLX's non-traditional RoPE), positions starting at 0 in every row, RoPE scale 1. Attention is softmax(q·kᵀ / 8 + mask)·v, the 8 being √64.
  - RoPE theta comes from `rope_parameters` for the layer's type: 160000 for both types in this checkpoint, not the 10000 ModernBERT usually uses on sliding layers.
  - The MLP is one Wi projection to 2 × the intermediate size (2 × 1152 here). Exact (erf) GELU on the first half is multiplied by the second half as the gate, then Wo.
  - A final LayerNorm.
- *Attention masks*: each layer's type comes from `layer_types`: 8 full and 14 sliding here.
  - Full mask: the key is a real token.
  - Sliding mask: the key is real and either |q − k| ≤ 64 (half of `local_attention`, inclusive) or the query is padding. Letting padded queries through keeps every row from being fully masked, which would give NaN.
  - Build the band here. mlx-swift-lm's bidirectional sliding-window helper masks by absolute key index, which is a different mask.
- *Decision head*:
  - Add type embedding 2 (noul) at every position.
  - Two norm-first layers shaped like PyTorch's TransformerEncoderLayer. The width is the encoder's hidden size, the heads are width / 64 and the feed-forward is 4 × width (768, 12 and 3072 here). ReLU, LayerNorms with bias at eps 1e-5. Each does h += out_proj(attention(norm1(h))), with a fused in_proj that has a bias and a key-padding mask only, then h += linear2(relu(linear1(norm2(h)))).
  - No final norm.
- *Scorer*, at the two marker positions: LayerNorm with bias, Linear width → width, exact GELU, Linear width → 1. The logits come out in the order false, true.
- *Probability*: P(true) = sigmoid((logit_true − logit_false) / T). T is the agent config's `temperature_by_options` entry `noul:2`, clamped to [0.5, 5]; here it is 1.0916.
- *Not loaded*: the action head (Laya's escalate probability) and the stored temperature buffer.
- *GELU in MLXNN*: the plain function and the default module are exact erf. The "precise" variant is the tanh approximation.

**Weights**
- Load the checkpoint's PyTorch-named safetensors directly, with no conversion step. Linear layouts already match MLX, so nothing is transposed.
- Key the Swift modules to the PyTorch names: Wqkv, Wo, Wi, attn_norm, mlp_norm, final_norm, self_attn, type_emb.
- Keep the head's fused in_proj as its two parameters, in_proj_weight and in_proj_bias.
- Make the scorer an array of its four layers so its numeric names map directly. MLX's Sequential would need them renamed.
- Drop the action head and temperature tensors, then update with full verification, so a missing or unused tensor is an error, not a weight silently left at its random initial value.

**Tokenizer**
- swift-transformers loads the checkpoint's tokenizer folder with the same loader the embedder uses. Measured: the same ids as Python on all 70,194 texts tested, including every eval and training state and 276 edge cases.
- `tokenizer.json` is pinned by SHA-256 (in Further Notes) and checked before swift-transformers reads it, at import and at every load. Building a tokenizer passes about 20 `fatalError` calls in swift-transformers 1.3.4 (an unsupported normalizer, pre-tokenizer, post-processor or decoder type, a missing field, BPE without merges), and any of them ends Launchy and every session in it, so a trial load can't test for them. Every English checkpoint the prototype trained (Laya-large, oscar-1-150m, oscar-1-68m) has this byte-identical file, so the pin refuses none of them, and the measured id parity holds for exactly this file.
- Special ids are looked up by name ([CLS], [SEP], [MASK], [PAD]), and each is checked against [UNK]'s id, because a missing name returns [UNK] rather than nothing.
- Pad with [PAD], not the end-of-text fallback the embedder pads with.
- Pin swift-transformers to exactly 1.3.4, the way mlx-swift is pinned, because its ids are now part of the contract. Today it is "1.3.0 or later", resolved to 1.3.4.
- A file that imports both MLXLMCommon and Tokenizers gets an ambiguous `Tokenizer`. Qualify the name.
- Tokenizing takes about 7 ms of the 31 ms call. That is fine for now; caching is out of scope.

**Precision**
- Run in fp16, as shipped. The residual stream reaches 39,554, which is 60% of fp16's maximum of 65,504. So:
  - LayerNorm goes through MLX's fused kernel, which keeps its statistics in fp32. A hand-written fp16 mean or variance overflows.
  - The scorer's last projection, the logits and the temperature step run in fp32.
  - Non-finite logits throw.
- fp32 throughout would double the weights to about 656 MB. bf16 is no fallback: over the 200 searches it differs from fp16 by up to 0.025 and flips 6 candidates (0.0145 and no flips on the first 20 searches, on the CPU).

**Concurrency**
- One actor owns the loaded model, the tokenizer and the prefix. Scoring runs inside it with no awaits, and it checks for cancellation first, so a stale search is skipped instead of queued.
- The main-actor object keeps the state Settings shows, the load and the idle timer, as the embedder's does.
- All MLX work stays off the main actor. Weights load lazily, so the first forward pass is what reads the 328 MB.
- mlx-swift-lm's serial container and model factories don't fit. The container is package-scoped, and the factories expect a registered model type and a top-level config.

**Dependencies and credit**
- Launchy's target gains MLXNN, a product of the already-pinned mlx-swift. No new package. CODING_STANDARDS' dependency line becomes "for embeddings and reranking".
- The model code is a translation of laya-mlx (Apache-2.0), so its doc comment credits Laya and laya-mlx.

**Docs, once accepted**
- ADR 0006 (main has 0001 to 0005) records:
  - reranking in-process with our own MLX port of Laya, chosen over TypeSafe only and over a vendored port;
  - the personal checkpoint staying on this Mac;
  - TypeSafe becoming optional;
  - the eval command gating mlx-swift and swift-transformers upgrades;
  - that the 64 MB cache cap and the 10-minute unload now cover two models.
  ADR 0003 stays as written.
- where-it-breaks, under Search store:
  - The session rule says "any reranker" instead of "the TypeSafe reranker".
  - New: MLX is shared by the whole process. Check the metallib before any MLX call, let the first model to load set the cache cap, and wrap MLX calls.
  - New: the row format is a contract with the checkpoint, and `tokenizer.json` is pinned.
  - New: On this Mac never sends anything to TypeSafe, including after a failure.
  - New: the checkpoint and the eval data are never committed, uploaded or logged.

## Testing Decisions

- There is no test target. Verification is `make build`, the eval command, `--search`, and checks by hand after the user restarts Launchy.
- **The eval command**, `Launchy --rerank-eval <checkpoint folder> <eval file> <reference file> [<output file>]`, shaped like `--search`:
  - It loads only the local reranker, from the checkpoint folder given. No import, no database, no settings. It runs as its own process and doesn't restart the app.
  - It scores the eval file with the same row builder and model the app uses, padding each search to its longest row as the app does.
  - The eval file is `{seed, n, skipped, queries}`; each query is `{id, search_query, pages, clicked, sources}`, with 20 pages of `{site, title}` and `clicked` the index of the right page. A score file is `{scores: {query id: 20 probabilities in page order}}` (the PyTorch one also has a summary). The output, if asked for, is a score file.
  - Against the reference it prints the largest probability difference, the number of candidates on the other side of 0.5, the MRR, the whole-call p50 and p90, and the MLX peak memory. MRR is computed as the prototype does: expected reciprocal rank with ties broken at random.
  - Pass, against the Python MLX scores: the largest difference is 0.01 or less; no candidate whose reference is more than 0.01 from 0.5 changes side; MRR is 0.7532 ± 0.005. Candidates near 0.5 are exempt from the side check because 51 references lie within 0.01 of it, and the PyTorch scores themselves put one on the other side. The drafts reached 1.2e-7 (and under 5e-5) with MRR 0.7532.
  - Its inputs, the checkpoint, the eval set and the reference scores, come from the private folder the problem names.
- Run it on the GPU, the default device. The references are GPU runs, and CPU fp16 lands about 4e-3 away from them, enough to move rows near the threshold.
- **Long rows.** Only 17 of the 4,000 eval rows are longer than 65 tokens, the only rows where the sliding band differs from full attention. So a wrong band passes the eval: dropping the band entirely moves probabilities by at most 0.0096 with no flips, right at the 0.01 bar, and mlx-swift-lm's absolute-index helper with a window of 128 does the same. Add a few synthetic rows longer than 129 tokens, scored by both Swift and Python MLX; the investigation's synthetic fixture is one such set. A wrong sliding-layer theta fails the eval at once (theta 10000: up to 0.50, 240 flips, MRR 0.729).
- **Token ids.** When probabilities miss, first compare the app's token rows with Python's for all 4,000 eval rows. That separates tokenizer bugs from model bugs.
- `--search "<query>"` with the setting on On this Mac runs on real fused candidates, with sessions excluded.
- By hand, after the user restarts Launchy, importing the checkpoint from the private folder:
  - Each Settings state: no metallib, no model, importing, on, an import error (the state unchanged), and a broken installed model's failed state with Retry.
  - Switching between TypeSafe, On this Mac and Off takes effect at the next search.
  - With Wi-Fi off, reranking still works, and on On this Mac no request goes to TypeSafe.
  - The tooltips name this Mac, and after switching they follow the reranker that judged the results on screen.
  - The order settles right after the pause.
  - Memory with both models loaded, and the unload after 10 idle minutes.
- The eval data and reference scores are personal. They stay outside the repo, in the private folder with the checkpoint.

## Out of Scope

- Training or retraining from Launchy. The training scripts stay out of the repo.
- Labelling Launchy's own fused top-20s with Jev and retraining on them, the next quality check.
- Caching each page's token ids across keystrokes. It is exact: query and suffix tokenized separately join to the same ids on 71,800 of 71,800 states, and it cuts tokenizing from about 7 ms to about 0.1 ms. A follow-up if the call feels slow.
- Judging more than 20 candidates, or Claude sessions.
- Wrapping the embedder's MLX calls in the same error guard. Worth doing as its own change.
- Keeping several checkpoints for rollback, or downloading one.
- Rerunning in fp32 after a non-finite result.
- Warming the model when the panel opens, unless the hand check shows a slow first search.

## Further Notes

- **Size.** Model code is about 230 to 320 lines without comments (287 to 394 with them). Integration is about 300 to 380 lines:
  - the local reranker's state, import, lifecycle and actor: 150 to 230;
  - the shared call, the choice and the pause: about 30;
  - Settings: about 60;
  - strings: about 10;
  - the eval command: about 50.
  Then the docs. That is 1 to 1.5 builder days, plus half a day for the eval run and the checks by hand.
- **What the drafts verified.** Three agents wrote them outside the repo during the investigation, the third after reading laya-mlx-swift. The user may keep one to start from, in the private folder.
  - All three compiled in Swift 5 mode, Launchy's mode. Two were built against Launchy's own release modules, one in a scratch package on the same exact versions, and one was also typechecked in Swift 6.
  - They loaded the PyTorch-named weights with full verification.
  - Two ran the eval with Launchy's mlx.metallib on the GPU: token rows identical on all 4,000 eval rows, probabilities within 1.2e-7 and under 5e-5 of Python MLX, MRR 0.7532.
  - Timings: forward pass 25 ms p50 / 29 ms p90; whole call 31.6 / 37.8 ms, of which tokenizing was 6.7 ms.
  - The third, on the CPU in fp32, matched an independent numpy reimplementation to within 8e-7.
- **Reference values.**
  - The question prefix ids: [CLS] 50281; "noul question: ?" as 79 3941 1953 27 3736; [SEP] 50282; [MASK] 50284; " false: n" as 3221 27 295; [MASK] 50284; " true: y" as 2032 27 340; [SEP] 50282. [PAD] is 50283 and [UNK] 50280.
  - `tokenizer.json` SHA-256: 6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30.
  - T = 1.091619610786438.
  - Eval rows run 25 to 81 tokens, median 41.
- **The 68m student.** oscar-1-68m takes 12 ms in MLX and scores 0.714. It is 512 wide with 8 heads and 19 layers, and its head is 512 wide with a 2048 feed-forward. It should load with this code if every size comes from the config (untested). Worth trying only if smaller Macs turn out slow.
- **Which code this describes.** Current behaviour and the docs named here (the session slice, ADRs 0004 and 0005, where-it-breaks' session rule) are main's as of 06f5d9f. This problem was written on the laya-distill branch, which is behind main, so the work starts from main.
- **Glossary, open question.** "Relevance filter" isn't in the glossary. Proposed entry: "**Relevance filter**: Search's last pass: a model judges which of the top 20 pages match what the search is after and moves them to the top, leaving the rest below in their order. Runs on TypeSafe or on this Mac. _Avoid_: reranker (in the UI), Jev."
- **Open questions, each with a recommendation.**
  - Default choice: TypeSafe, which matches today.
  - Stay loaded, or unload after 10 idle minutes: unload, like the embedder.
  - Import from Settings or with a command: Settings, following the project-folders picker.
