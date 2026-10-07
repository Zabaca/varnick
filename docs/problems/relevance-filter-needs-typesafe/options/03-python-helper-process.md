---
problem: relevance-filter-needs-typesafe
title: Run laya-mlx in a Python helper process
summary: Option 01's setting, import and row, but the model runs in a long-lived Python process with laya-mlx that Launchy starts and talks to over a pipe. No Swift model code gets written.
status: proposed
---

## Solution

Launchy starts a helper process on first use: Python 3.12 with laya-mlx 0.3.0 and mlx 0.32.3, loading the imported checkpoint. Each search sends it the query and each of the 20 candidates' raw title and URL host, and it returns one probability per candidate. The setting, the import, the row format and the failure behaviour are option 01's. When the helper is missing or dies, the relevance check fails and results stay in fused order.

## Trade-offs

- **No model code to write or check.** laya-mlx is the MLX reference the Swift port is checked against: MRR 0.7532, within 0.0041 of the PyTorch scores the checkpoint was evaluated with, 23.6 ms p50 / 27.8 ms p90 for the whole call, and tokenizer parity for free.
- **It goes against ADR 0003.** That ADR put embeddings in-process so semantic search needs no separate install, service or model pull. A helper brings back two of the three, a Python install of about 330 MB (interpreter included) to keep working and a process to start, watch, restart and stop with Launchy, and adds a pipe protocol. The third, the model, is imported the same way in every option.
- **Two MLX runtimes.** The helper's MLX has its own memory (it peaked at 1.15 GB), outside Launchy's 64 MB cache cap and idle unload. Its mlx version also moves independently of Launchy's pin.
- **It's slower to start.** Starting Python and importing MLX comes on top of loading the model (unmeasured).
- **Option 01 has removed the reason for it.** Its model code is already drafted, at parity with this same reference.

## User Stories

Option 01's.

## Implementation Decisions

- The helper's environment lives next to the model in Launchy's Application Support models folder. A `make` target creates it from pinned package versions.
- Protocol: one JSON line per search on standard input and one line of probabilities back, in candidate order. The helper exits when its input closes.
- Launchy starts the helper on first use, stops it after 10 idle minutes and at quit, and starts it again after a crash on the next search.
- The helper builds the state with the prototype's minimal formatter (Python's slice of the title, the host lowercased) and laya-mlx's prepare path, so the row matches training by construction. Only the query's trimming stays on Launchy's side.

## Testing Decisions

- The prototype's MLX benchmark already shows parity. Check by hand after a restart: latency including helper start-up, the helper's memory, behaviour after the helper is killed, and that no request goes to TypeSafe.

## Out of Scope

- Everything out of scope in option 01.
- Bundling a Python runtime with Launchy.

## Further Notes

- Recorded so this route isn't investigated again. The direction so far has been to run in Launchy's own MLX Swift stack.
