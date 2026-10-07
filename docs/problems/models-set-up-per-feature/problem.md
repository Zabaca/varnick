---
title: Models are set up inside the features that use them
description: Settings › Search holds the semantic search model's download, the relevance filter's TypeSafe / On this Mac / Off picker, the local checkpoint's import and the TypeSafe key, mixed in with the features they serve. Semantic search has no off switch of its own; it is on once its model is downloaded. Launchy can't write text on this Mac, so a model that would serve a new feature, such as naming sessions, has nowhere to go, and a key that could serve several roles sits under one feature.
impact: Every new model adds another download, status and retry inside whichever feature uses it first, and to set a model up or see why it failed the user has to know which feature owns it. The relevance picker mixes whether the filter is on with who runs it, so turning it off forgets the choice. Without on-device text generation, small writing jobs such as session titles either send the user's prompts to a third party or don't happen.
severity: low
evidence: Settings › Search as of f72de39. A spike on 2026-10-06 ran Gemma 4 E2B on Launchy's exact pins (below, as reported; not rerun for this problem). Claude Code's own session titles were counted in the user's transcripts on 2026-10-06 (below; counts only).
status: open
---

## Today

**Models.** Settings › Search has three rows:

- **Semantic search.** The embedding model's download, its progress, its failure with Retry, and "On" once it's downloaded. There is no switch: semantic search runs whenever the model is downloaded and the archive is embedded with it. The minute history sync embeds new entries whenever the model is downloaded.
- **Relevance filter.** A segmented picker with TypeSafe, On this Mac and Off, saved as one value.
- **The chosen backend's own row.** TypeSafe shows the key controls (Keychain, or "On (from .env)" for TYPESAFE_API_KEY from the environment or `.env`) and what is sent to TypeSafe. On this Mac shows the checkpoint import (Choose…, Importing…, On, failed with Retry). Off shows nothing, and the key and the checkpoint are kept.

Each model's setup is written for its feature. A second consumer of a model, or a key that serves more than one role, has no obvious row to go in. Listening's speech model is installed by macOS and is not one of these.

**How a session gets its name.** Checked in the code as of f72de39.

- A Claude pane's label is Claude Code's terminal title with its leading status glyph dropped. Without one it falls back to the title last saved on the pane's record, then the prompt it started with, then "New session".
- Claude Code names each conversation itself. It writes `ai-title` entries to the transcript and shows the name as the terminal title.
- Rename tab (⌘⇧R by default) gives a tab a name, saved with the tab. The tab header, the session list row and a one-pane tab's board card show it instead of the label.
- Recent and Completed rows show the label saved when the pane ended. A conversation left behind by /clear or /resume takes Claude's `ai-title` from its transcript.
- Search's session rows show Claude's `ai-title`, read into the session index from the transcript.
- A paired Mac and the Phone page get the saved title through the relay: in the open sessions list, in Recent, and in `status` while the host is in control. A pane in control of a session on a paired Mac shows Claude's terminal title for that session.
- zmx sessions are named by pane id and carry no title.
- Claude Code's `/rename` writes a `custom-title` entry. Launchy doesn't read it.

## Evidence

**Claude Code already titles most sessions, quickly, and once.** These counts come from the user's own transcripts on 2026-10-06, all projects.

- Of the 191 transcripts changed in the past 7 days, 170 have a prompt the user typed, and 144 of those have an `ai-title`. Of the 26 without one, 19 had a single prompt.
- The first title is written 0.3 to 2.6 s after the first prompt at the median, and 16 to 18.5 s at p90. The two figures bound it, because the entry carries no time of its own.
- 1 of the 144 ever changed its title.
- In 60 days, 3,086 transcripts held 3 `custom-title` entries from `/rename`.
- Of 488 first prompts, the median is 71 characters long and the p90 is 25,814 characters. 30 were slash commands, 14 of them without arguments.
- The first prompt ends 54 KB into the transcript at the median, 526 KB at p90 and 2.6 MB at p99. So reading only the start of a transcript would miss it.

**Text generation on this Mac (spike, 2026-10-06).** The spike ran on the M3 Ultra with Launchy's exact pins: mlx-swift 0.32.3, mlx-swift-lm 3.32.3 with its MLXLLM product added, swift-transformers 1.3.4 and Launchy's prebuilt mlx.metallib. Model `mlx-community/gemma-4-e2b-it-4bit` at revision 238767527555cb75a05732a84dff5d6ba0dd6809.

- It loads with MLXLLM's model factory from a folder, using the Hugging Face tokenizer loader, and generates through a chat session. Nothing in MLX had to change, and the metallib contract is unchanged.
- The download is 3.55 GB of weights (3,550,670,554 bytes) plus config, generation config, tokenizer (32 MB), tokenizer config, chat template, processor config and weight index. These were checked against the Hugging Face listing at that revision. The weights include audio and vision parts, which the text model drops on load.
- Load takes 1.3 s. MLX holds 2.5 GB once loaded and peaks at 3.1 GB on a 2k-token prompt; the process peaked at 3.76 GB.
- The first generation after a load takes about 2.8 s, for one-off shader setup. After that it generates 150–170 tokens/s and reads prompts at 2,200 tokens/s.
- Asked greedily for a 3–6 word title for a session request, it answered "Relay Host Linker" in 0.34 s. That is usable but vague.
