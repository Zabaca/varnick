---
title: Launchy listens but can't be asked anything
description: Listening transcribes the mic and the Mac's audio into the day's transcript, and that is all it does with them. The user wants to say "Hey Launchy" and ask for something out loud. Launchy should then decide whether to search History, Bookmarks or Claude sessions, read what it finds and answer. Today nothing listens for a wake phrase, nothing in Launchy reads what was heard, and nothing speaks.
impact: To find a page, a bookmark or a past session, the user has to stop, bring up the panel and type, even while Listening is already hearing them. The Voice setting is there and says "Nothing speaks yet".
severity: low
evidence: The user's request of 2026-10-08 (below). The code was read on 2026-10-08 at 253012d. The listening spec left a wake word and spoken replies for later. A throwaway prototype and a speech-to-text survey, both from 2026-10-02, are kept locally.
status: closed
---

## What the user asked (2026-10-08)

> We have our listener and transcriber. I'd like the ability to say "hey launchy" and ask it to do something. Based on what I asked it should 1. decide if it should search history/favorites/sessions, 2. read what it needs to, 3. respond to me.

"Favorites" here means **Bookmarks**, the glossary's term.

## Today

All of this was read in the code.

**Listening**
- Listening runs on macOS 26 only. It is off at each launch and turned on from the menu bar or with `!listen`.
- Each source, the mic and the Mac's output (through a Core Audio process tap), has its own `SpeechAnalyzer` with Apple's `SpeechTranscriber`.
- Volatile results are asked for but dropped. Each final result becomes one line of the day's transcript, `HH:mm:ss [mic] text` or `[system]`. A `[launchy]` line records a failure to listen.
- The system audio tap excludes no process, so anything Launchy itself played would be transcribed as `[system]`.
- Nothing reads the transcript inside Launchy. The `!transcript` pane is `tail -F` on the file.

**Speaking**
- Settings › Listening has a Voice row: "What Launchy will speak in. Nothing speaks yet." It shows "System default". The `voice` value is stored, but the row can't change it.

**Search**
- History, Bookmarks and Claude sessions are all built and searchable (options shipped under `bookmarks-not-searchable` and `sessions-not-searchable`).
- A bookmark joins its page's row, so there are two kinds of row: pages (source `chrome` or `bookmark`) and sessions (source `session`).
- A `?` search fuses keyword and meaning separately for pages and for sessions. It shows up to 3 sessions above up to 40 pages, and the relevance filter reorders the top 20 pages, on TypeSafe or on this Mac.
- That search exists only as the panel's: it runs when the panel's query changes and writes the panel's results. `--search` and `--search-eval` use it by setting the query and waiting for the passes to finish.
- A row holds a title, a site or folder, a date and a description. For a page the description is its own summary from `<head>`, not its text. For a session it is the user's prompts, not Claude's replies.

**Text generation**
- Text generation is Gemma 4 E2B on this Mac (ADR 0012), or an OpenAI-compatible server on the tailnet (ADR 0014). Settings › Models chooses.
- Its one use is session titles: one user message, no history, greedy, a few tokens.
- The pinned mlx-swift-lm can also run tool calls in Gemma 4's format (`ChatSession` with tools and a dispatcher). Launchy doesn't use it.

**What may leave the Mac** (`where-it-breaks.md`)
- A session's prompts go only to the user's paired Macs and, when chosen, to the user's own model server on the tailnet. They never go to a reranker, TypeSafe or any other service.
- With the relevance filter on TypeSafe, a `?` search's words and the top 20 pages' titles, sites and descriptions go to TypeSafe.
- No Launchy feature sends anything to a cloud language model.

## What earlier work found (2026-10-02, kept locally)

- **The prototype** listened to the mic with the same `SpeechTranscriber` setup. It matched "hey" followed by a word starting "launch", "lunch" or "lanch" in volatile and final results, and replied with `say`. Volatile text arrived 0.2–0.4 s after speech, and final text 1–2 s after.
- **"Launchy" is a made-up word, and the transcriber mishears it** ("Launchi", "launch you", and once something unrelated). Apple documents contextual strings and custom pronunciations for `DictationTranscriber`, not `SpeechTranscriber`. Whether `SpeechTranscriber` honours contextual strings is unknown.
- **Wake accuracy was never measured.** The survey's first open question asks for about 50 takes of "Hey Launchy" and an hour of ordinary desk audio, to count misses and false wakes for each approach.
- **Dedicated wake-word engines don't fit.** Porcupine needs a paid key, and openWakeWord is Python with non-commercial models. Apple's own routes add no dependency: `DictationTranscriber` with a pronunciation of "Launchy", or a Create ML sound classifier.

## Left to decide

- **How the wake phrase is heard:** a match on the mic text Listening already produces, or a listener of its own. That decides whether it works only while Listening is on, how much the mic stays in use, and how often it wakes falsely.
- **Who decides and answers:** Launchy's own steps around Text generation, a local model calling tools, Claude calling tools, or a local router that hands some requests to Claude.
- **How it answers:** spoken, on screen in the panel, by opening the result, or a mix. Also whether anything opens or starts without a key press.
- **What may leave the machine:** with a cloud model, History, Bookmarks and session prompts would go to it, which nothing in Launchy does today.
