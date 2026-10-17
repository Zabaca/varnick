import { describe, expect, test } from "bun:test";
import { argumentLimit, buildRequest, relayArguments } from "./relay";
import {
  askFields, audioFields, maxChunkBytes, maxChunkText, parseAskBody, parseAudioBody, parseStatusQuery, shapeStatus, shapeTaken, statusFields, uploadRate,
} from "./voice";
import { applyEvents, calibrationFrames, chunkSamples, cut, Endpointer, floorTimes, fromBase64, hint, lowestThreshold, maxUtteranceMs, minSpeechMs, newView, pauseMs, pauseNote, silenceMs, stateLine, toBase64 } from "./page/voicerules.js";
import { block, Downsampler } from "./page/voice-worklet.js";
import { PROTOCOL as V } from "./fixtures/protocol";

const id = "2b6b0d6e-8f0a-4c1e-9d3a-5a7c1e2f3b4d";
const chunk = (extra: Record<string, unknown> = {}) => ({ id, seq: 0, last: false, audio: "AAAA", ...extra });

describe("an audio chunk from the page", () => {
  test("is an id, a place, whether it is last and the audio, with the hint", () => {
    expect(parseAudioBody(chunk({ moment: 1760000000, zone: "America/Denver", units: "us" }))).toEqual({
      ok: true, value: { id, seq: 0, last: false, audio: "AAAA", moment: 1760000000, zone: "America/Denver", units: "us" },
    });
    expect(parseAudioBody(chunk({ id: id.toUpperCase() }))).toMatchObject({ ok: true, value: { id } });
  });

  test("and nothing else is read: a rate, a device or a session in the body is not carried", () => {
    const parsed = parseAudioBody(chunk({ rate: 48000, by: "someone", session: "varnick-x", take: true }));
    expect(parsed.ok && Object.keys(parsed.value).sort()).toEqual(["audio", "id", "last", "seq"]);
  });

  test("anything else is refused", () => {
    const bad: unknown[] = [
      null, [], "x", chunk({ id: "not-a-uuid" }), chunk({ id: 5 }), chunk({ seq: -1 }), chunk({ seq: 1.5 }), chunk({ seq: 60 }), chunk({ seq: "0" }),
      chunk({ last: "yes" }), chunk({ last: undefined }), chunk({ audio: "" }), chunk({ audio: 5 }), chunk({ audio: "not base64!" }),
      chunk({ audio: "A".repeat(maxChunkText + 4) }), chunk({ moment: "now" }), chunk({ moment: -1 }), chunk({ moment: Infinity }),
      chunk({ zone: "../../etc" }), chunk({ zone: "x".repeat(65) }), chunk({ zone: 5 }), chunk({ units: "furlongs" }),
    ];
    for (const body of bad) expect(parseAudioBody(body).ok).toBe(false);
  });

  test("the largest chunk is under the argument limit as a relay request, and so is a second of audio", () => {
    for (const bytes of [maxChunkBytes, uploadRate * 2]) {
      const audio = Buffer.alloc(bytes, 1).toString("base64");
      const parsed = parseAudioBody(chunk({ audio, last: true, moment: 1760000000, zone: "America/Argentina/Buenos_Aires", units: "metric" }));
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const request = buildRequest(V, "voiceAudio", id, audioFields(parsed.value));
      expect(relayArguments("/relay", request)[2].length).toBeLessThan(argumentLimit);
    }
  });

  test("the rate is the server's, and a hint left out is left out", () => {
    expect(audioFields({ id, seq: 3, last: true, audio: "AAAA" }).voice).toEqual({ id, seq: 3, last: true, audio: "AAAA", rate: 16000 });
    expect(JSON.parse(buildRequest(V, "voiceAudio", "device", audioFields({ id, seq: 0, last: false, audio: "AAAA" }))).by).toBe("device");
  });
});

describe("a typed ask and a status poll", () => {
  test("an ask is an id and text, with the hint", () => {
    expect(parseAskBody({ id, text: "what time is it", units: "metric" })).toEqual({ ok: true, value: { id, text: "what time is it", units: "metric" } });
    expect(askFields({ id, text: "hi", zone: "UTC" }).voice).toEqual({ id, text: "hi", zone: "UTC" });
    for (const body of [null, { id }, { id, text: "" }, { id, text: "   " }, { id, text: "x".repeat(601) }, { id, text: 5 }, { id: "no", text: "hi" }]) {
      expect(parseAskBody(body).ok).toBe(false);
    }
  });

  test("a status query is an id and a count", () => {
    expect(parseStatusQuery(new URLSearchParams({ id, after: "3" }))).toEqual({ ok: true, value: { id, after: 3 } });
    expect(parseStatusQuery(new URLSearchParams({ id }))).toEqual({ ok: true, value: { id, after: 0 } });
    expect(statusFields({ id, after: 2 }).voice).toEqual({ id, after: 2 });
    for (const query of [{}, { id: "x" }, { id, after: "-1" }, { id, after: "1.5" }, { id, after: "99999" }, { id, after: "abc" }]) {
      expect(parseStatusQuery(new URLSearchParams(query)).ok).toBe(false);
    }
  });
});

describe("what the host said", () => {
  test("a taken ask is its id; a refusal is the host's words", () => {
    expect(shapeTaken({ ok: true, reply: { voice: { id } } })).toEqual({ status: 200, body: { ok: true, id } });
    expect(shapeTaken({ ok: false, error: "The voice session is off." })).toEqual({ status: 502, body: { ok: false, error: "The voice session is off." } });
    expect(shapeTaken({ ok: true, reply: {} }).status).toBe(502);
    expect(shapeTaken({ ok: true, reply: { voice: { id: "x" } } }).status).toBe(502);
  });

  test("a status reply keeps the events the page knows, and where to ask next", () => {
    const session = "varnick-7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d";
    const reply = {
      voice: {
        id, next: 4, done: true,
        events: [
          { kind: "heard", text: "hello" }, { kind: "taken" }, { kind: "futureKind" }, 7,
          { kind: "needsYou", session }, { kind: "needsYou", session: "../../x" },
          { kind: "answered", text: "It is noon.", spoken: "It is noon.", audio: "AAAA", failure: 5 },
          { kind: "answered", audio: "not base64!" },
        ],
      },
    };
    expect(shapeStatus({ ok: true, reply })).toEqual({
      status: 200,
      body: {
        ok: true, id, next: 4, done: true,
        events: [
          { kind: "heard", text: "hello" }, { kind: "taken" }, { kind: "needsYou", session }, { kind: "needsYou" },
          { kind: "answered", text: "It is noon.", spoken: "It is noon.", audio: "AAAA" }, { kind: "answered" },
        ],
      },
    });
  });

  test("a reply without a count, or with a wrong one, is unreadable, and a failure is the host's", () => {
    expect(shapeStatus({ ok: true, reply: { voice: { id, events: [] } } }).status).toBe(502);
    expect(shapeStatus({ ok: true, reply: { voice: { id, next: -1 } } }).status).toBe(502);
    expect(shapeStatus({ ok: true, reply: {} }).status).toBe(502);
    expect(shapeStatus({ ok: false, error: "That request is gone" })).toEqual({ status: 502, body: { ok: false, error: "That request is gone" } });
    expect(shapeStatus({ ok: true, reply: { voice: { id, next: 0 } } })).toMatchObject({ status: 200, body: { events: [], done: false } });
  });

  test("an answer's audio over what a reply line carries is dropped, its words kept", () => {
    const big = "A".repeat(900_004);
    const shaped = shapeStatus({ ok: true, reply: { voice: { id, next: 1, done: true, events: [{ kind: "answered", text: "yes", audio: big }] } } });
    expect(shaped.body).toMatchObject({ events: [{ kind: "answered", text: "yes" }] });
    expect((shaped.body as { events: { audio?: string }[] }).events[0].audio).toBeUndefined();
  });
});

describe("where a request ends", () => {
  const loud = 0.1;
  const quiet = 0.001;
  /** An endpointer that has measured a quiet room. */
  function calibrated() {
    const endpointer = new Endpointer();
    for (let i = 0; i < calibrationFrames; i++) endpointer.feed(quiet, 100);
    return endpointer;
  }
  /** Feeds 100 ms frames at these levels, and lists what the endpointer answered. */
  function run(levels: number[], endpointer = calibrated()) {
    return levels.map((rms) => endpointer.feed(rms, 100));
  }
  const quietFrames = Math.ceil(silenceMs / 100);

  test("speech begins when it has lasted long enough and ends after the quiet", () => {
    const answers = run([quiet, quiet, loud, loud, loud, loud, ...Array(quietFrames).fill(quiet)]);
    expect(answers.slice(0, 2)).toEqual(["idle", "idle"]);
    expect(answers.slice(2, 5)).toEqual(["pending", "pending", "begin"]);
    expect(answers[5]).toBe("speech");
    expect(answers.slice(6, 6 + quietFrames - 1).every((answer) => answer === "speech")).toBe(true);
    expect(answers.at(-1)).toBe("end");
  });

  test("a blip is dropped, and sends nothing", () => {
    const answers = run([quiet, loud, ...Array(quietFrames).fill(quiet)]);
    expect(answers[1]).toBe("pending");
    expect(answers.at(-1)).toBe("drop");
    expect(answers.includes("begin")).toBe(false);
  });

  test("a pause inside a request is not its end", () => {
    const answers = run([loud, loud, loud, quiet, quiet, quiet, loud, loud, ...Array(quietFrames).fill(quiet)]);
    expect(answers.filter((answer) => answer === "end").length).toBe(1);
    expect(answers.indexOf("end")).toBe(answers.length - 1);
  });

  test("a request ends at the longest, even in speech", () => {
    const answers = run(Array(maxUtteranceMs / 100 + 1).fill(loud));
    expect(answers.indexOf("end")).toBe(maxUtteranceMs / 100 - 1);
    expect(answers.at(-1)).toBe("pending");
  });

  test("after an end the next request begins afresh", () => {
    const endpointer = calibrated();
    run([loud, loud, loud, ...Array(quietFrames).fill(quiet)], endpointer);
    expect(run([loud, loud, loud], endpointer)).toEqual(["pending", "pending", "begin"]);
  });

  test("the threshold follows the room: a steady hum is not speech, and speech over it is", () => {
    const endpointer = new Endpointer();
    const hum = 0.02;
    const measured = run(Array(calibrationFrames).fill(hum), endpointer);
    expect(measured.every((answer) => answer === "idle")).toBe(true);
    expect(endpointer.threshold).toBeCloseTo(hum * floorTimes, 10);
    expect(run([hum, hum, hum, hum, hum, hum], endpointer).every((answer) => answer === "idle")).toBe(true);
    expect(run([hum * 5, hum * 5, hum * 5], endpointer)).toEqual(["pending", "pending", "begin"]);
  });

  test("the room is the quietest of the first frames, so speech in the first moment doesn't raise it", () => {
    const endpointer = new Endpointer();
    run([0.2, 0.001, 0.2, 0.2, 0.2], endpointer);
    expect(endpointer.threshold).toBe(lowestThreshold);
  });

  test("a quiet room that gets a little louder is followed", () => {
    const endpointer = calibrated();
    run(Array(200).fill(0.01), endpointer);
    expect(endpointer.threshold).toBeGreaterThan(lowestThreshold);
  });

  test("it is never below the lowest", () => {
    expect(new Endpointer().threshold).toBe(lowestThreshold);
    expect(run([lowestThreshold / 2, lowestThreshold / 2])).toEqual(["idle", "idle"]);
  });

  test("speech has to be a few frames to count", () => {
    expect(minSpeechMs).toBe(300);
    expect(run([loud, loud])).toEqual(["pending", "pending"]);
  });
});

describe("chunks", () => {
  test("a request is cut in seconds, and the last piece is what is left", () => {
    const samples = new Int16Array(chunkSamples * 2 + 500);
    expect(cut(samples).map((piece) => piece.length)).toEqual([chunkSamples, chunkSamples, 500]);
    expect(cut(new Int16Array(0))).toEqual([]);
  });

  test("16-bit samples go as little-endian bytes in base64, and come back", () => {
    const samples = Int16Array.from([0, 1, -1, 32767, -32768, 258]);
    expect(toBase64(samples)).toBe(Buffer.from([0, 0, 1, 0, 255, 255, 255, 127, 0, 128, 2, 1]).toString("base64"));
    expect([...fromBase64(toBase64(samples))]).toEqual([0, 0, 1, 0, 255, 255, 255, 127, 0, 128, 2, 1]);
  });

  test("a full second is a chunk the host takes, large ones too", () => {
    expect(chunkSamples * 2).toBeLessThanOrEqual(maxChunkBytes);
    expect(toBase64(new Int16Array(chunkSamples * 5)).length).toBeGreaterThan(maxChunkText);
    expect(toBase64(new Int16Array(chunkSamples)).length).toBeLessThanOrEqual(maxChunkText);
  });
});

describe("the view the host's events make", () => {
  test("a request, its answer and the voice to play", () => {
    let view = applyEvents(newView(), [{ kind: "heard", text: "what time is it" }, { kind: "taken" }]);
    expect(view.state).toBe("working");
    expect(view.exchange).toEqual([{ who: "you", text: "what time is it" }]);
    view = applyEvents(view, [{ kind: "lookingUp" }]);
    expect(stateLine[view.state]).toBe("Looking that up.");
    view = applyEvents(view, [{ kind: "answered", text: "It is noon.", spoken: "It is noon.", audio: "AAAA" }]);
    expect(view).toMatchObject({ state: "speaking", play: "AAAA", done: true });
    expect(view.exchange.at(-1)).toEqual({ who: "varnick", text: "It is noon." });
  });

  test("an answer with no audio leaves the page listening, with its words shown", () => {
    const view = applyEvents(newView(), [{ kind: "answered", text: "Noon." }]);
    expect(view).toMatchObject({ state: "listening", play: null });
    expect(view.exchange).toEqual([{ who: "varnick", text: "Noon." }]);
  });

  test("a question for the user names the session to open", () => {
    const view = applyEvents(newView(), [{ kind: "taken" }, { kind: "needsYou", session: "varnick-x" }]);
    expect(view).toMatchObject({ state: "needsYou", session: "varnick-x", done: true });
    expect(stateLine.needsYou).toContain("OK");
  });

  test("a failure, no answer and the deadline each end the ask with a line or a state", () => {
    expect(applyEvents(newView(), [{ kind: "failed", text: "Claude didn't take that." }]).exchange).toEqual([{ who: "note", text: "Claude didn't take that." }]);
    expect(applyEvents(newView(), [{ kind: "noAnswer" }]).exchange).toEqual([{ who: "varnick", text: "I couldn't answer that." }]);
    expect(applyEvents(newView(), [{ kind: "deadline" }])).toMatchObject({ state: "slow", done: true });
  });

  test("the view it was given is not changed", () => {
    const before = newView();
    applyEvents(before, [{ kind: "heard", text: "x" }]);
    expect(before.exchange).toEqual([]);
  });
});

describe("a page that was paused", () => {
  test("says so only for a gap that is one", () => {
    expect(pauseNote(pauseMs - 1)).toBeNull();
    expect(pauseNote(30_000)).toBe("The page was paused for 30 seconds. Voice mode reconnected.");
    expect(pauseNote(5 * 60_000)).toBe("The page was paused for 5 minutes. Voice mode reconnected.");
  });

  test("the hint is the phone's moment, zone and units", () => {
    expect(hint(new Date(1_760_000_000_900), "en-US", "America/Denver")).toEqual({ moment: 1_760_000_000, zone: "America/Denver", units: "us" });
    expect(hint(new Date(0), "en-GB", "Europe/London").units).toBe("metric");
    expect(hint(new Date(0), "de-DE", "Europe/Berlin").units).toBe("metric");
  });
});

describe("the microphone's reader", () => {
  test("48 kHz is averaged to 16 kHz in threes", () => {
    const out: number[] = [];
    new Downsampler(48000).push(Float32Array.from([0.3, 0.6, 0.9, -0.3, -0.6, -0.9, 1]), out);
    expect(out.map((sample) => Math.round(sample * 100) / 100)).toEqual([0.6, -0.6]);
  });

  test("a rate that doesn't divide still gives the right count, and 16 kHz passes through", () => {
    const out: number[] = [];
    new Downsampler(44100).push(new Float32Array(44100).fill(0.5), out);
    expect(Math.abs(out.length - 16000)).toBeLessThanOrEqual(1);
    expect(out.every((sample) => Math.abs(sample - 0.5) < 1e-6)).toBe(true);
    const same: number[] = [];
    new Downsampler(16000).push(Float32Array.from([0.1, 0.2]), same);
    expect(same.map((sample) => Math.round(sample * 10) / 10)).toEqual([0.1, 0.2]);
  });

  test("a call may end between samples: the rest carries into the next", () => {
    const one = new Downsampler(48000), out: number[] = [];
    one.push(Float32Array.from([0.3, 0.6]), out);
    one.push(Float32Array.from([0.9, 0.0, 0.0, 0.0]), out);
    expect(out.map((sample) => Math.round(sample * 100) / 100)).toEqual([0.6, 0]);
  });

  test("a block is 16-bit samples and their level", () => {
    const { pcm, rms } = block([0.5, -1, 2, -2]);
    expect([...pcm]).toEqual([16384, -32767, 32767, -32767]);
    expect(rms).toBeCloseTo(Math.sqrt((0.25 + 1 + 1 + 1) / 4), 5);
    expect(block([]).rms).toBe(0);
  });
});
