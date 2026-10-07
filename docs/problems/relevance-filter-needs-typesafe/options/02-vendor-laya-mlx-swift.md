---
problem: relevance-filter-needs-typesafe
title: Vendor MstyAI/laya-mlx-swift for the model
summary: The same as option 01, except that the encoder and decision head come from MstyAI/laya-mlx-swift's sources, copied into Launchy and adapted, because its exact pin on mlx-swift 0.31.6 can't be resolved alongside Launchy's 0.32.3.
status: proposed
---

## Solution

Everything Launchy-facing is as in option 01: the setting, the import, the lifecycle, failures, the row, the eval command and the docs. Only the model code differs. Instead of being written for Launchy, it is taken from MstyAI/laya-mlx-swift 0.1.2, a Swift port of laya-mlx under Apache-2.0. Its sources are copied into Launchy and adapted:

- drop its Hugging Face download and the deprecated MLXFast import;
- rename the checkpoint's PyTorch parameter names to the MLX names it expects;
- add a call that scores many states against one question in a single pass.

Its LICENSE and NOTICE stay beside the copy, and each changed file is marked.

## Trade-offs

- **It can't be a package.** It pins mlx-swift at exactly 0.31.6, which was the latest release on the day it was published. SwiftPM refuses to resolve that alongside Launchy's exact 0.32.3 (verified), so copying the sources is the only technical route. Vendored third-party code still counts against CODING_STANDARDS' no-new-dependencies rule, so this option would need its own exception in the ADR.
- **It saves little now.** Option 01's model code is about 300 lines and has already been drafted three times, matching Python each time. The vendored copy is about 850 lines, about 550 more than our own draft. Roughly 200 of them are for things Launchy wouldn't call: choice and score questions, the action head, confidence and the one-state predict API. It is indented with 2 spaces in a 4-space codebase. The Launchy integration costs the same either way.
- **Its API has the wrong shape.** It takes one state and many questions, while Launchy needs 20 states and one question. The added method, about 25 lines, is ours to maintain inside someone else's code.
- **It doesn't load our checkpoint as it stands.** It expects the names laya-mlx's converter writes and fails on the PyTorch ones (verified). An 11-line rename fixes that.
- **Young, single-author and unreviewed.** It has 4 commits within one hour on 2026-09-21, no stars, forks or issues, and CI whose only test that runs checks enum names; both checkpoint tests skip without the model. Its parity claim is equal aggregate accuracy on Laya-large. Upstream fixes would have to be copied in again by hand.
- **Once adapted, it works.** It compiles against mlx-swift 0.32.3 and swift-transformers 1.3.4 with no warnings, in Swift 5 mode too. With the rename and the many-states call it matched Python MLX on all 4,000 eval rows: largest difference 6e-8, MRR 0.7532, 31.0 ms p50 / 36.8 ms p90.
- **Licence.** Apache-2.0 section 4 asks for the licence, the NOTICE and a mark on each changed file. That only bites if Launchy is distributed; the repo was private on 2026-10-07.
- **What it adds.** Laya's other question types (choice, score) come with it, for any later use, and it is a second author's reading of Laya.

## User Stories

Option 01's.

## Implementation Decisions

- Every Launchy-facing decision is option 01's: the setting, the reranker chosen at each search with its own pause, the import and checks, the lifecycle, failures and crash guards, the row, precision, concurrency, the tokenizer pin and the docs.
- Vendor tag 0.1.2 (commit 353ba75), kept apart from Launchy's own files, with its LICENSE and NOTICE beside it and a note on each changed file.
- Drop its Hugging Face download file and the MLXFast import. The fast functions live in MLX in 0.32.
- Rename weights at load: the head's in_proj weight and bias, and the scorer's and action head's numbered layers. Renaming at load means the imported folder is exactly what training saved, with no conversion step.
- Add many-states scoring that reuses its prompt builder and batching.
- It differs from laya-mlx in a few ways, none affecting this checkpoint: no temperature clamp, hard-coded special-token strings, markers filtered instead of raising an error, `layer_types`, `rope_parameters` and `act_costs` required where laya-mlx has defaults, and no check that the RoPE type is the default one. Keep option 01's import checks and add the clamp.
- The state string is still built by Launchy, as in option 01.

## Testing Decisions

- Option 01's eval command, pass bar and checks by hand.
- When re-vendoring, diff the copy against upstream so Launchy's changes are carried over.

## Out of Scope

- Everything out of scope in option 01.
- Sending the many-states method or 0.32 support upstream to MstyAI.

## Further Notes

- The vendored copy loaded in 165 to 170 ms, and its MLX memory peaked at 1.16 GB.
- Its published benchmarks are self-reported, on Laya-large and a synthetic support workload: Swift 27.1 ms p50 against 27.0 ms for Python MLX.
