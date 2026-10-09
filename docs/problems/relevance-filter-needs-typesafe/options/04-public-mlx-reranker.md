---
problem: relevance-filter-needs-typesafe
title: Rerank on this Mac with a public MLX reranker
summary: Option 01's setting and lifecycle, but the model is a public cross-encoder run by mlx-swift-lm's MLXRerankers library and downloaded once like the embedding model. No model code and no personal weights.
status: rejected
reason: It scored below the fused order with no reranking. On 19 of Launchy's fused top-20 searches on 2026-10-02, the best public model reached NDCG@10 0.852 against 0.860 for no reranking.
---

## Solution

On this Mac runs a public reranker (jina-reranker-v3, bge-reranker-v2-m3 or Qwen3-Reranker-0.6B) through MLXRerankers, a library of the already-pinned mlx-swift-lm. It downloads once from Settings at a pinned revision, as the embedding model does. The setting, the choice at each search, the lifecycle and the failures are option 01's. Nothing is imported and nothing personal is stored.

## Trade-offs

- **No model code, no personal weights, no import.** Another Mac gets the model the same way, and nothing ages as history grows.
- **It did worse than not reranking.** On 2026-10-02, on 19 of Launchy's real fused top-20 searches labelled 0 to 2, NDCG@10 was 0.906 for Jev (Launchy's request at the time), 0.860 for the fused order with no reranking, 0.852 for jina, 0.803 for bge and 0.792 for Qwen3. None beat the fused order. The sample is small.
- **Slower and larger than option 01's checkpoint.** Median calls of 60 ms (bge), 66 ms (jina) and 205 ms (Qwen3) per search on the M3 Ultra, against about 32 ms for option 01's draft. jina and bge raised peak memory by 1.4 to 1.8 GB.
- **Scores aren't calibrated to Jev's,** so each model would need its own threshold in place of 0.5.
- **It can't run option 01's checkpoint.** MLXRerankers supports Jina, BERT, RoBERTa and XLM-R sequence classifiers and Qwen3, not ModernBERT.

## User Stories

Option 01's, except that the model downloads once instead of being imported.

## Implementation Decisions

- Option 01's setting, choice at each search, lifecycle, failures and crash guards.
- The model downloads into Launchy's models folder at a pinned revision, through a `.partial` folder, as the embedder's does.
- Launchy's target gains MLXRerankers, a product of the already-pinned mlx-swift-lm.

## Testing Decisions

- Score the spike's 19 labelled searches and the 200-search eval with the chosen model before shipping, against the fused order and against Jev.

## Out of Scope

- Fine-tuning a public reranker on Jev's labels. That is option 01's route on a different base.

## Further Notes

- Recorded so this route isn't investigated again without new evidence, such as a newer public reranker. The spike's candidates and labels are personal and belong in the private folder the problem names. Scoring option 01's checkpoint on those 19 fused searches would be a cheap check of the problem's main caveat, that the eval's candidates aren't Launchy's fused top 20.
