---
problem: spoken-requests-cant-see-the-screen
title: Option 01, then a screenshot of the window goes to Claude, which says where the thing is
summary: Option 01 as it stands, plus one fallback behind its own switch. When the Accessibility tree has nothing that fits, Launchy sends a screenshot of the focused window and the request to Claude through Anthropic's Messages API. Claude replies with a point and a short note, and Launchy points there. It is the most capable at icons, layout and "what is this", and works in any app. But a picture of whatever is on the user's screen goes to a third party. No Launchy feature has ever sent an image of the screen, or anything at all to a cloud language model. It needs an Anthropic key, network, money per request and an ADR that amends ADR 0012.
status: proposed
---

## Solution

Everything in option 01 holds. A second switch below Point at the screen, **Ask Claude when Launchy can't find it**, is off by default and can't be turned on without an Anthropic key. With it on, and only when option 01's choice found nothing:

1. Launchy captures the focused window alone, into memory, as option 02 does.
2. It sends the image and the request to Claude, with a fixed instruction: reply with the point where the thing is, in the image's pixels, and one short sentence naming it, or "none".
3. A point inside the window gets option 01's arrow, with a small ring at the point and Claude's sentence as the note. "None", a refusal or a failure is spoken as such, and nothing is drawn.

The image exists in memory only until the request is sent. Launchy never writes or logs it.

## Trade-offs

- **The best at finding things.** Claude reads screenshots well, including icons, layout, which of several look-alike buttons is meant, and "what is this" about a picture. It works in every app, Chrome's pages included, with no flag.
- **A picture of the screen goes to Anthropic.** The window holds whatever is on it: messages, names, documents, a video call's faces. No Launchy feature sends anything to a cloud language model today, and none has ever sent an image of the screen.
  - ADR 0012 chose an in-process model over a cloud provider, and this amends it for this one use.
  - The switch is separate, off by default, and its detail says in plain words that a screenshot of the window goes to Anthropic whenever Launchy can't find the thing itself.
- **Only on a miss.** Requests the tree answers send nothing to Claude. A request about something that isn't on screen, though, always reaches Claude, since option 01 can't tell "absent" from "not in the tree".
- **A key, money and a network.** An Anthropic key goes in the Keychain, as TypeSafe's does. Offline, the fallback is skipped.
- **The cost of each fallback, estimated, not measured.** It uses the prices listening-never-answers option 03 cites (as cached on 2026-10-06) and an image of at most about 1,600 tokens.
  - On Opus 5.5: under a cent.
  - On Haiku 5.5: well under a tenth of a cent.

  The builder's spike measures it.
- **Latency.** One round trip with an image, estimated at 2 to 5 s, unmeasured, after option 01's miss.
- **The point needs scaling.** Claude sees the image at the size the API accepts, which may be smaller than the capture. The reply's point is scaled back before it is drawn.

## User Stories

1. As a Launchy user, I want any thing I can see found and pointed at, whatever app it is in, when I have chosen to let Claude look.
2. As a Launchy user, I want to choose this knowingly, in its own switch, and to read exactly what is sent and when.
3. As a Launchy user, I want my screen sent only when Launchy couldn't find the thing on its own.
4. As a Launchy user, I want my Anthropic key kept in the Keychain and never logged.
5. As a Launchy user, I want to hear when Claude couldn't be reached, quickly, rather than wait.
6. As a Launchy user, I want everything else as in option 01.

## Implementation Decisions

**Everything not below** is as in option 01, and the capture and Screen Recording permission as in option 02.

**Settings**
- **Ask Claude when Launchy can't find it** goes below Point at the screen, off by default.
  - It needs Point at the screen and an Anthropic key.
  - Its detail names Anthropic and says what is sent: a screenshot of the focused window and the request.
- An **Anthropic** key row under Keys, in the Keychain the way TypeSafe's and the model server's keys are. It is never logged, and never shown after saving.
- The model's name is stored in UserDefaults. Which model is an open question.

**When it runs**
- After option 01's Jev call gives `present` under 0.5, or the window had no elements, with the switch on and a key saved.
- With option 02 accepted, only after option 02 also finds nothing.
- Never during the hold. It runs only once the request is finished, so a partial request's screenshot is never sent. That is unlike option 01's speculation, and it costs its latency after the hold.

**The request**
- Anthropic's Messages API over HTTPS, one non-streaming request. There is no official Swift SDK, so it is a plain request. The builder loads the `claude-api` skill for the request shape, image limits and how coordinates relate to the image size.
- A fixed instruction, the image and the request. The reply is one line: two numbers, the point in the image's pixels, then one short sentence; or "none".
- A modest output limit and a 10 s timeout. One address, no redirect.
- **What is spoken on failure:**
  - a refusal: "Claude declined that.";
  - a timeout, a status other than 200, or an unreadable reply: "Claude didn't answer.".

  Nothing is retried.

**Pointing and the note**
- The point is scaled from the image Claude saw to the capture to the screen, through option 01's single conversion.
- **The arrow** ends at the point, with a small ring.
- **The note** is Claude's sentence, cut to one sentence, or "There it is." when it gave none.

**Logs, command line, state**
- **Logged:** the kind of failure and the status code only, never the image, the request, the reply or the key.
- **The timing line** adds the Claude step's duration and outcome kind.
- `--ask --app` prints the point, the reply and the usage the API reports.
- One Keychain item, and two UserDefaults keys (the switch and the model).

## Testing Decisions

- The reply reader (text in, a point and sentence or none out) and the scaling are pure seams.
- **Spike** on the same made-up screenshots as option 03's. Count the points inside the target's box, the "none" answers for absent things, the time and the cost, for each model considered.
- **By hand, after a restart:**
  - With the switch on, ask for an unlabelled icon. The arrow lands on it.
  - Ask for something option 01 finds. No request reaches Anthropic: the timing line says the tree answered.
  - With the network off, the miss is spoken within the timeout.
  - With the switch off, nothing is sent, whatever the key.
  - Launchy's log holds no request, reply, key or image.

## Out of Scope

- Sending the display or other windows, or anything but the one image and the request.
- Claude choosing among option 01's candidates as text. That sends less, but adds nothing over Jev or Gemma for labelled controls.
- Claude Code headless (`claude -p`) instead of the API. It needs a shell and a session file per request, too slow to speak back, as listening-never-answers option 03 found.
- Follow-up requests, and any action beyond pointing.

## Further Notes

- **Accept with option 01, or after it.** Stacks after option 02, and is an alternative to option 03.
- **Open question: which model.** Recommended: let the spike compare the fastest current model with a mid-sized one, and take the fastest that passes. Speed matters here, since the user waits with nothing on screen.
- **ADR, on acceptance:**
  - amends ADR 0012's "not a cloud provider" for this fallback;
  - records that a screenshot of the focused window goes to Anthropic, only on a miss, only with this switch on;
  - names the key.

  SECURITY.md and the README say the same.
- **Whether a screenshot may leave this Mac** was the user's open question. They answered on 2026-10-09 that it may, so this option stays open. Its own switch, off by default, still decides it per user.
- **Verified:** no Launchy code sends anything to a cloud language model, and there is no Anthropic key in Launchy today. **Unverified:** every latency and cost figure, and how well each model places points on UI screenshots.
