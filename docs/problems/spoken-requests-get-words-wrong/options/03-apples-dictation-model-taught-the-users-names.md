---
problem: spoken-requests-get-words-wrong
title: Apple's dictation model, told the speech comes from a distance and taught the user's names
summary: Nothing leaves the Mac and nothing is billed. A switch in Settings › Listening has each spoken request transcribed by Apple's other on-device model in macOS 26, the dictation transcriber, with its far-field hint and a custom language model Varnick builds on the Mac from a list of the user's names. The phone's segments go through it in place of today's model; at the Mac, each line of a request is transcribed again from an in-memory window, as option 01 does for ElevenLabs. Whether it hears the user better than today's model, in the car or anywhere, is unmeasured, and the one vocabulary hint tried before changed nothing. Not what the user asked for; listed because it costs nothing and keeps his voice on the Mac.
status: proposed
---

## Solution

A row in Settings › Listening, **Transcribe requests with Apple's dictation model**, off by default, with the same **Names to listen for** list as option 01. Per Mac, as option 01.

With it on:

- **On the phone,** each segment is transcribed by Apple's dictation transcriber instead of today's speech transcriber, told the speech is short and comes from a distance (a phone in a car mount), and given a custom language model built from the user's names.
- **At the Mac,** Listening keeps option 01's in-memory window, and each line of a request (from the wake phrase's line to "over", and every request line in Voice mode) is transcribed again by the dictation transcriber the same way. The request's text is made from those lines by option 01's rule, today's model's text standing by for a line that fails or is late.
- **The custom language model** is built on the Mac when the list changes, from each name and a few short sentences around it, and kept in Varnick's support folder. Building it needs no network.

Off, nothing changes. Listening's day transcript stays today's model's either way.

## Trade-offs

- **Free and private.** No audio leaves the Mac, nothing is billed, no ADR on data leaving and no change to the privacy page beyond the names list being stored on the Mac.
- **Unmeasured, and the evidence so far is against hints.** The four names given to today's model as contextual strings changed no transcript. A custom language model is a different mechanism, one Apple's dictation model takes and today's model does not, but nothing here shows it fixes the user's names in road noise.
- **An older model.** The dictation transcriber is the model behind the system's dictation; today's speech transcriber is Apple's newer one. It may get names right and ordinary words worse. Only a comparison on the user's voice would tell.
- **No help from the network,** which is the point, and also the limit: a model on the Mac can't be swapped for a better one without Apple shipping it.
- **More on the Mac:** building the language model (time unmeasured) and a second pass per line at the Mac.
- **Not what the user asked for.** He asked for ElevenLabs. This is an alternative if he decides against sending his voice, or a way to improve option 01's fallback later.

## User Stories

1. As the user, I want better names without sending my voice anywhere, so that I keep requests on my Mac.
2. As the user, I want to list the names it gets wrong, so that the model on the Mac learns them.
3. As the user, I want one switch on the Mac for the phone and the desk, so that I turn it on once.
4. As the user, I want today's model's words used when the dictation model fails, so that a request is never lost.
5. As the user, I want to turn it off and get today's behaviour back at once, so that I can compare.
6. As a maintainer, I want the timing lines to say which model's text was used, so that I can compare the two.

## Implementation Decisions

- **The switch, the names list, the in-memory window, the Mac's lines, the rule that makes a Mac request from its lines, and the logs** are option 01's, with the dictation transcriber in ElevenLabs' place and no network request.
- **The dictation transcriber** is set up with the short-form and far-field hints and the custom language model, in English, and installs its model on first use as today's does.
- **The custom language model** is rebuilt when the list changes, off the main actor, from each name in a few fixed carrier sentences; a build that fails leaves the switch on with today's model in use and the reason under it.
- **The choice of text:** the dictation model's when it answers within its limit, today's model's otherwise.
- **The records:** an amendment to ADR 0043 only if its "Listening's transcriber" wording is taken to name the model; the Settings text; `CONTEXT.md`'s Segment if it names the model; `docs/agents/where-it-breaks.md` (the dictation model, the language model's build and where it is kept).

## Testing Decisions

- Option 01's pure functions, by `make check-voice`.
- By hand after a restart: a request with a name today's model gets wrong, at the desk and in the car, with the switch on and off; the timing line names the model.
- **A comparison worth running before building:** the same recorded requests through both models, in agent-lab, where evals live. It needs recordings of the user's requests, which don't exist for the phone today.

## Out of Scope

As option 01, and anything sent off the Mac.

## Further Notes

- **Not recommended over option 01:** it is not what the user asked for, and nothing shows it would fix wrong names. Recommended as the next step only if the user decides his voice should not leave the Mac.
- **Can follow option 01:** the dictation model could become the fallback there, with no change to option 01's switch.
- **Read in the macOS 26 SDK on 2026-11-02:** the dictation transcriber's short-form, far-field and custom-language-model hints; the custom language model data, with phrase counts, templates and custom pronunciations.
- **Verified in the code at fe1cf87:** today's speech transcriber takes contextual strings only, and Listening's four changed nothing on macOS 26.5.1 (a comment beside them).
- **Inferred:** that the dictation model is Apple's older model and may be worse on ordinary words; the time to build a language model.
