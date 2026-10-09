---
title: The relevance filter needs TypeSafe
description: Search's last pass, the relevance filter, runs on TypeSafe's hosted Jev model or, since option 01 (ADR 0006), On this Mac with a checkpoint distilled from Jev. On this Mac runs offline with no key, but on searches that describe a page, where TypeSafe helps most, it measured +0.003 MRR over no filter, against +0.115 to +0.191 for TypeSafe (2026-10-05). It sees only the query, the site and 60 characters of the title, and the checkpoint is personal, so another Mac gets it only by copying its folder by hand.
impact: For a filter that helps on descriptive searches the user still has to choose TypeSafe, which sends each search they pause on, with the titles, sites and descriptions of up to 20 of their pages, to a third party, needs a key and a network, and settles about 1.1 to 1.2 s after typing stops. The private choice keeps history on this Mac but mostly leaves the fused order as it was. The checkpoint ages as history grows, and a Mac without its folder, or anyone else, has no On this Mac filter at all.
severity: mid
evidence: A distillation prototype run on 2026-10-03/04 on the user's Mac. Its numbers and recipe are recorded below because its files are untracked and personal (see "Where the personal files are"). Jev's figures for Launchy's own request come from the jev-bench run of 2026-10-03 behind commit 46bbae7. Five investigations and two reviews on 2026-10-04 measured what running its checkpoint in Launchy's Swift stack takes; their results are in the options. On 2026-10-05 `Launchy --search-eval` measured both filters against no filter on Launchy's own fused results.
status: open
---

## Today

Search runs three passes, each refining the last. Keyword matches show at once. Semantic matches are fused in after a 120 ms typing pause. Then comes the relevance filter. On TypeSafe, once typing has paused for 1 s and the query has at least 3 characters, the first 20 page results go to TypeSafe in one request. Claude sessions are never sent. The request asks one yes/no question per page, naming the page by title and site, and carries the query and each page's title, site and own description (the first part of the description field, never its URL or search terms; since 2026-10-05). Pages scoring 0.5 or more move to the top, best first. The rest keep their fused order below them. Nothing is dropped.

The 1 s pause is there so that a keystroke cancels the request before it is paid for. The round trip took 0.12 s at the median (0.16 s p90) with today's request, and 0.23 s (0.48 s p90) with the request before 2026-10-03, measured about 7 hours apart. Without a key TypeSafe can't be asked, and a new install without one starts with the filter off. When a request fails, results stay in fused order with a warning. At TypeSafe's listed $0.032 per 1,000 decisions a search costs about $0.0006 (billing basis unverified).

On this Mac (option 01, ADR 0006) runs the imported checkpoint in Launchy's process with MLX, right after the semantic pass, with no pause and no round trip. Nothing leaves the Mac, and it never falls back to TypeSafe. It judges the same top 20 pages from a row of the query, the page's site and the first 60 characters of its title (The minimal row, below), never the description. The checkpoint is imported once from a folder the user picks, and another Mac needs that folder copied by hand. On descriptive searches it gives almost nothing (below).

## Evidence: the filter against no filter

Everything before 2026-10-05 compared models with each other on synthetic candidate lists. This compares each filter with no filter on Launchy's own fused top 20, measured with `Launchy --search-eval` on a copy of this MacBook's database. Score: MRR of the target page, with 95% intervals from a paired bootstrap over searches.

| Search set | Searches | No filter | On this Mac (the checkpoint) | TypeSafe | TypeSafe with descriptions |
|---|---:|---:|---|---|---|
| Real Google search terms, the page clicked next | 144 | 0.834 | 0.807 (−0.026 [−0.089, +0.034]) | 0.837 (+0.003 [−0.050, +0.056]) | 0.834 |
| Agent-written searches that describe a page without its title's words | 81 | 0.387 | 0.390 (+0.003 [−0.043, +0.050]) | 0.503 (+0.115 [+0.038, +0.195]) | 0.578 (+0.191 [+0.120, +0.262]) |

- On real search terms neither filter helps: the fused order already puts the clicked page first 75% of the time. Both filters help one- and two-word searches (about +0.09, 90 searches) and hurt longer ones, which usually contain the title's words (−0.13 to −0.28, 54 searches).
- On descriptive searches TypeSafe helps and the checkpoint does not. Adding each page's description adds +0.075 [+0.028, +0.129] over TypeSafe alone, all of it on the 32 pages that have one (0.530 to 0.717). The checkpoint sees only query, site and 60 characters of title, so a page whose title is just a product name gives it nothing to match a search that describes what the product does.
- Only 55 of the 81 descriptive targets reach the fused top 20, so for that kind of search retrieval, not the filter, caps the score.
- Caveats: the descriptive searches were written by agents shown each page's description, which likely inflates the description gain; TypeSafe repeats vary by about 0.02 (0.557 on a rerun of the 0.578). Real searches typed into Launchy, with what was opened, would settle both.
- So the checkpoint as trained ties Jev only on keyword-style candidates. A local option needs the description in its row and training candidates from the fused top 20.

## Evidence: a distilled model

Everything below is measurement, not a choice of solution. All the options rest on it.

### What a local model can do

The prototype distilled Jev into small Laya-format models and scored them against Jev on 200 of the user's real searches. A Laya-format model is a ModernBERT encoder with Laya's two-layer decision head, from the Python packages `laya` and `laya-mlx`.

**The eval.** It uses 200 search terms the user typed into a search engine in Chrome, taken from the archive's search terms. The page they opened next is the one right answer. Each search has 20 candidates: the clicked page, pages found by Launchy's keyword query (all words, then any word), and random archive pages to fill the rest. Across all searches that is 471 all-words, 2,368 any-word, 961 random and 200 clicked. The score is MRR of the clicked page, with ties broken at random in expectation, and 95% intervals come from a paired bootstrap over searches. Jev's reference answers come from one request per page with a `{search_query, page}` state, asking "Is `page` something the person is looking for with `search_query`?": Launchy's wording from before 2026-10-03, adapted to one page.

| Model | Params | Row | MRR | − Jev [95%] | Agrees with Jev at 0.5 | Per search, PyTorch (MPS) | Per search, Python MLX |
|---|---:|---|---:|---|---:|---:|---:|
| Jev, one request per page (the reference) | – | – | 0.747 | – | – | 0.20 s p50 (network) | – |
| Jev, Launchy's current request (each question names its page) | – | – | 0.752 | +0.005 [−0.023, +0.032] | 90% | 0.12 s p50 (network) | – |
| Jev, Launchy's request before 2026-10-03 (`pages[i]`) | – | – | 0.713 | −0.034 [−0.068, −0.001] | 89% | 0.23 s p50 (network) | – |
| Laya-large, untrained | 421M | full | 0.541 | −0.206 [−0.255, −0.156] | 77% | 0.17 s | – |
| Laya-large, fine-tuned | 421M | full | 0.748 | +0.001 [−0.032, +0.035] | 90% | 0.16 s | about 139 ms |
| **oscar-1-150m, fine-tuned (the checkpoint)** | 164M | minimal | **0.752** | +0.005 [−0.031, +0.040] | 88% | 38 ms | 23.6 ms p50, 27.8 ms p90 |
| oscar-1-150m, eval pages removed (control) | 164M | minimal | 0.736 | −0.011 [−0.045, +0.023] | 88% | 38 ms | – |
| oscar-1-68m, fine-tuned | 75M | minimal | 0.714 | −0.033 [−0.074, +0.007] | 87% | 23 ms | 12.1 ms p50 |
| laya-multilingual, fine-tuned | 322M | minimal | 0.708 | about −0.04 | 88% | 37 ms | – |

- The two "Launchy's request" rows are jev-bench runs on the same eval file, not prototype runs. The old request is the file the prototype copied as its Jev scores. The current one used Launchy's wording except that titles were JSON-escaped; it ran about 7 hours after the others, so its faster round trip may be server load. Commit 46bbae7, which switched Launchy to the current wording, records the same 0.713 to 0.752. Against the current request the checkpoint is +0.0006 [−0.033, +0.034].
- Per-search times for the local models cover the whole call (rows, tokenizing, forward pass) for 20 candidates on an M3 Ultra with 256 GB. Smaller Macs will be several times slower (inferred, not measured). The Laya-large MLX time was measured on a checkpoint of the same size and row format.
- The checkpoint was evaluated and calibrated with PyTorch Laya. Python MLX (laya-mlx 0.3.0, fp16) gives it the same MRR: 0.7532 against 0.7523, with probabilities at most 0.0041 apart. Its MLX memory peaked at 1.15 GB.
- Probabilities are calibrated to Jev's. The noul temperature was refit on held-out training searches (T = 1.0916), so Launchy's 0.5 threshold carries over.
- Each run's final epoch is reported. For the checkpoint's run, held-out cross-entropy fell and within-search Spearman with Jev rose every epoch; top-1 agreement was flat on one held-out set from epoch 2 to 3. Choosing by eval MRR would look better (oscar-1-150m's epoch 2 scored 0.769), but that would be selecting on the test set.

**The minimal row** is what the checkpoint was trained on. It is a noul question with instructions "?" and criteria true "y" / false "n". The state is one plain string: the query, a newline, the page's site (lowercased host), a newline, and the first 60 characters of its title, counted as code points. That is about 1,000 padded tokens per 20-candidate search, against about 2,520 for the full row (the reference's question with a JSON state). On Laya-large the minimal row halves forward time (166 to 82 ms).

### Caveats

- 200 searches, one person's history and one right answer per search. Differences under about 0.035 MRR can't be told apart.
- Candidates came from keyword and random picks, not from Launchy's fused keyword and semantic top 20. MRR also scores the full ranking, while Launchy shows pages at 0.5 or above first and leaves the rest in fused order. The next check is to label a few thousand of Launchy's own fused top-20s with Jev.
- Training pages overlap the eval's: all 200 clicked pages appear as some training candidate, and Jev called 176 of them relevant for some search in the training files. That is realistic for a model trained on the user's own pages. The control run removed every eval clicked page from training and scored 0.016 lower (interval [−0.005, +0.037]), still level with Jev.
- The checkpoint knows the user's history as of 2026-10-03. Pages added later are unseen, and the control run suggests that costs about 0.016 MRR.

### How the checkpoint was made

Training used Python 3.12 with laya 0.3.26, transformers 5.18.0 and torch 2.14.1 on MPS. The MLX check used laya-mlx 0.3.0 with mlx 0.32.3. All data came from a read-only snapshot of Launchy's history archive taken on 2026-10-03.

1. **Heuristic training searches** (1,568). These are the 68 real search terms the eval didn't use, each with its most recent clicked page as the target, plus 1,500 made up from archive pages. Each made-up search is the site name and/or one to three title words, sometimes with a typo, which is how the real terms look (seed 20261004). No eval term is reused.
2. **Agent-written training searches** (1,822). 2,000 random archive pages were sampled, deduplicated on title and host, leaving out eval clicked pages and interstitial titles such as "Just a moment…" (seed 20261005). They were split among 8 agents, each shown 30 of the user's real non-eval search terms as style examples, and the agents wrote one search per page. Null, empty, eval-term and repeated queries were dropped.
3. **Candidates.** Each search gets 20, picked like the eval's: the keyword all-words query, then any-word, then random archive pages, deduplicated on title and host, with the search's target page included.
4. **Labels.** Jev answers for every candidate, one request per candidate, with the same question and state as the eval's reference: 67,800 decisions, about $2.20 at the listed price.
5. **Near-repeats.** 41 training searches whose query nearly repeats an eval query were dropped: difflib ratio of 0.85 or more on the normalised strings or on their sorted words.
6. **Training.** Full fine-tune on the minimal row of mgoeckel/oscar-1-150m at revision 1015773b7b1e3dcab42029db39efeffaed31cfce. That model is an Ettin-150m encoder (ModernBERT architecture, 22 layers × 768) with a Laya-format head already trained; it is third-party and Apache-2.0.
   - Split: 10% of each file's searches held out (seed 20261004), leaving 3,012 training searches (60,240 rows) and 337 held out.
   - Loss: soft cross-entropy against Jev's [1 − p, p], plus a per-search listwise KL at weight 1 (ListNet over log-odds, temperature 1, two whole searches per step).
   - Optimiser: AdamW at 2.5e-5 for the encoder and 1e-4 for the head, bf16 on MPS, 3 epochs. It took about 38 minutes on the M3 Ultra.
   - Rows were built with Laya's own state encoder, so training saw exactly the tokens inference sees.
7. **Calibration.** After each epoch the noul temperature was refit on the held-out searches and saved in the agent config.
8. **Saved.** The final epoch, as a folder `laya.Agent` loads:
   - the weights: fp16, PyTorch parameter names, 170 tensors, 328 MB;
   - the encoder config;
   - the tokenizer (`tokenizer.json` and its config);
   - the agent config, with `launchy_format` "minimal", `launchy_question` and the temperatures.

### Where the personal files are

All of these are personal: they are built from, and encode, the user's browsing history. So none of them can go in this repo, which was private on 2026-10-07 (only its owner had access then, but access can widen and history can't be rewritten), or to Hugging Face.

They have no durable home yet:

- The untracked `prototypes/laya-distill` folder of the laya-distill worktree holds the checkpoint folder, the eval set, the labels, the scripts, the results notes and the reference scores (PyTorch and Python MLX probabilities for every eval candidate). Removing the worktree with `--force` deletes them, and the Settings folder picker can't see inside the hidden `.claude` folder.
- Session scratch under `/private/tmp/claude-501/`, which goes at reboot, holds the rest of what the options rely on: the three Swift drafts with their parity harnesses, Python's token rows for every eval row and a synthetic long-row fixture (session 73ebe2a6, `local-reranker`), and the 2026-10-02 public-reranker spike's candidates and labels (session 3b700023, `rerank`).
- The same scratch also holds further personal copies: the eval set, Jev's eval scores and a history snapshot (session 01687a04, `jev-bench`), database snapshots, probably of Launchy's search database (session 3b700023), and every eval and training state as text, 5,384 full archive URLs and the token ids of every eval row (session 73ebe2a6).

Proposed home: one private folder outside every repo and worktree, not hidden and not synced to iCloud. Keep there the checkpoint folder (the final epoch's), the eval set, both reference score files, the prototype's scripts and results notes, the Swift drafts with their harnesses, Python's token rows, the long-row fixture and the spike's candidates and labels. Then delete the scratch copies; only the synthetic fixture is not personal.
