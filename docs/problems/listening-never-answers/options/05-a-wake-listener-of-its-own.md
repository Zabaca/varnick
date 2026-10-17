---
problem: listening-never-answers
title: A wake listener of its own, tuned to "Varnick", that runs without Listening
summary: Replaces option 01's way of hearing the wake phrase; the other steps are whichever option is accepted. A separate mic analyzer uses Apple's `DictationTranscriber` with a custom language model that knows how "Launchy" is pronounced, and listens only for the wake phrase and the request after it. It runs whenever Hey Launchy is on, whether Listening is on or off, and writes nothing to the transcript. It hears "Launchy" more reliably and doesn't require transcribing everything, at the cost of the mic being in use all the time.
status: proposed
---

## Solution

A **wake listener** apart from Listening. With Hey Launchy on, Launchy keeps one `SpeechAnalyzer` on the mic with:

- Apple's voice-activity detector;
- a `DictationTranscriber` using the phrase preset, the short-form hint, contextual strings for "Launchy" and "Hey Launchy", and a custom language model holding an X-SAMPA pronunciation of "Launchy" and a few example phrases ("hey launchy find …").

That is Apple's documented route for a made-up word. The survey picked it as the first thing to try when the plain transcriber mishears "Launchy".

Its final results go through option 01's wake match and request gathering, and then to the accepted option's steps. Nothing it hears is written anywhere. A request's text reaches the transcript only as option 01's `[launchy]` answer line, and the `[mic]` line too when Listening is also on.

The wake listener starts at launch when Hey Launchy is on, and stops when it is turned off. When Listening is also on, both run on the mic, and option 01's match on Listening's text is not used.

## Trade-offs

- **It should hear "Launchy" better,** since the model is told how the word sounds. This is unmeasured: the survey's wake test has to compare it with option 01's match before this is worth building.
- **Asking without transcribing everything.** The user can leave Listening off, with nothing written to the transcript and no system audio tap, and still say "Hey Launchy".
- **The mic is in use whenever Hey Launchy is on.** macOS shows its microphone indicator the whole time, and other apps see the mic as in use. That is a change from Listening's rule of off at each launch, so it is the user's call (open question).
- **Another analyzer's cost,** with both on, is unmeasured. That covers CPU, Neural Engine and whether it competes with Listening's two analyzers and MLX.
- **The custom language model must be built** on the Mac at first use, from the pronunciation and phrases. How long that takes, and whether it needs a download, is unverified.
- **macOS 26 only,** as Listening is.
- **Not a dedicated keyword spotter.** It still transcribes everything it hears on the mic, and in memory throws away whatever doesn't match. A true keyword spotter (a Create ML sound classifier trained on recordings, or FluidAudio's keyword boosting) would listen more cheaply. The first needs recordings and training; the second is a new dependency and an ADR.

## User Stories

1. As a Launchy user, I want "Hey Launchy" heard reliably however I say it, so that I don't repeat myself.
2. As a Launchy user, I want to ask Launchy things without turning on Listening and its transcript.
3. As a Launchy user, I want nothing the wake listener hears written down unless it was a request.
4. As a Launchy user, I want to know the mic stays in use while Hey Launchy is on, and turn it off in one place.

## Implementation Decisions

**Settings**
- Option 01's Hey Launchy switch. Its detail says the mic stays in use while it is on, Listening or not.
- Turning it on asks for mic access if Listening never has.
- The menu bar item shows the wake listener's state beside Listening's: listening for "Hey Launchy", failed and why. It uses the menu item's existing title and tooltip pattern, without a new item.

**The wake listener**
- Its own analyzer on the mic, with the detector and the dictation transcriber above, through the same audio conversion Listening uses.
- When Listening is on, both tap the same mic input. Listening's capture owns the engine, and the wake listener receives the same buffers, so there is one tap on the mic. When Listening is off, the wake listener runs a mic-only capture of its own.
- **The custom language model:**
  - It holds the pronunciation of "Launchy" and a handful of made-up request phrases, in one place.
  - It is built once and kept in Application Support. It is rebuilt only when that content changes, or when the system says the built one is out of date.
- Device changes restart it, with Listening's settle delay and restart limit.
- A failure turns it off and shows why, as a Listening failure does.

**Results**
- Final results only, through option 01's wake match, wait, gap and limit. Volatile results are ignored.
- Nothing is written to the transcript or logged. A result that doesn't wake it is dropped.
- Mic results heard while Launchy speaks are ignored, as in option 01.

**Starting and stopping**
- It starts at launch when the switch is on (once the panel is ready), and stops when the switch goes off or Launchy quits.
- Off below macOS 26.

**State**
- Option 01's switch key; nothing else saved but the built language model.

## Testing Decisions

- The wake match is option 01's seam. The pronunciation and phrases are data, checked by the measurement below.
- **The measurement decides this option:** the survey's wake test, run on option 01's match and on this listener with the same takes.
  - About 50 takes of "Hey Launchy": different voices, distances, speeds, with music or a call playing.
  - An hour of ordinary desk audio, including talk that mentions Launchy.
  - Count misses and false wakes per hour for each. Keep the figures and recordings in the problem's local scratch folder: they are the user's voice.
- **By hand, after a restart:**
  - With Listening off and the switch on, "Hey Launchy, …" is answered, and nothing new is in the transcript but the `[launchy]` answer.
  - With both on, one request is answered once.
  - Turning the switch off stops the mic indicator if Listening is off.
  - Changing the mic, for example connecting headphones, keeps it working.

## Out of Scope

- A trained sound classifier or a third-party keyword spotter (see Trade-offs).
- Speaker identification, so that only the user's voice wakes it.
- Waking on system audio.

## Further Notes

- **Pairs with whichever of options 01–03 is accepted;** it replaces only how the wake phrase is heard.
- **Verified in the macOS 26 SDK:** `DictationTranscriber` with the phrase preset, the short-form and custom-language-model content hints, contextual strings on the analyzer, and custom pronunciations in custom language model data.
- **Unverified:**
  - how well it hears "Launchy";
  - the cost of a third analyzer;
  - building the custom model;
  - feeding one mic tap to two analyzers without dropping buffers.
- **An ADR on acceptance:** a mic listener that runs while Listening is off changes Listening's privacy default, and the ADR should say so.
- **Glossary:** **Wake phrase** as option 01 proposes, without "while Listening is on".
