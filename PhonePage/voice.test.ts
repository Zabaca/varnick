import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { argumentLimit, buildRequest, Relay, relayArguments } from "./relay";
import {
  askFields, audioFields, maxChunkBytes, maxChunkText, parseAskBody, parseAudioBody, parseStatusQuery, shapeStatus, shapeTaken, statusFields,
} from "./voice";
import {
  applyEvents, calibrationFrames, chunkSamples, cut, DeadMic, deadMicMs, Endpointer, floorTimes, fromBase64, hint, lowestThreshold, maxUtteranceMs,
  minSpeechMs, newView, noiseRunMs, pauseMs, pauseNote, pollFailures, preRollMs, requestCapMs, Segments, serial, settled, shortSpeechMs, silenceMs, stateLine,
  toBase64, uploadRate, Utterance,
} from "./page/voicerules.js";
import { block, Downsampler } from "./page/voice-worklet.js";
import { PROTOCOL as V } from "./fixtures/protocol";

const id = "2b6b0d6e-8f0a-4c1e-9d3a-5a7c1e2f3b4d";
const run = "7f3c9a10-2b4d-4e8f-a6c1-0d9e8f7a6b5c";
const chunk = (extra: Record<string, unknown> = {}) => ({ id, run, seq: 0, last: false, audio: "AAAA", ...extra });

describe("an audio chunk from the page", () => {
  test("is a segment's id, its Voice mode run, a place, whether it is last and the audio, with the hint", () => {
    expect(parseAudioBody(chunk({ moment: 1760000000, zone: "America/Denver", units: "us" }))).toEqual({
      ok: true, value: { id, run, seq: 0, last: false, audio: "AAAA", moment: 1760000000, zone: "America/Denver", units: "us" },
    });
    expect(parseAudioBody(chunk({ id: id.toUpperCase(), run: run.toUpperCase() }))).toMatchObject({ ok: true, value: { id, run } });
  });

  test("a page that names no run is an old one, and is told to reload", () => {
    const { run: _, ...old } = chunk();
    expect(parseAudioBody(old)).toEqual({ ok: false, error: "Voice mode's page is out of date: reload it" });
  });

  test("and nothing else is read: a rate, a device or a session in the body is not carried", () => {
    const parsed = parseAudioBody(chunk({ rate: 48000, by: "someone", session: "varnick-x", take: true }));
    expect(parsed.ok && Object.keys(parsed.value).sort()).toEqual(["audio", "id", "last", "run", "seq"]);
  });

  test("anything else is refused", () => {
    const bad: unknown[] = [
      null, [], "x", chunk({ id: "not-a-uuid" }), chunk({ id: 5 }),
      chunk({ run: undefined }), chunk({ run: "not-a-uuid" }), chunk({ run: 5 }), chunk({ seq: -1 }), chunk({ seq: 1.5 }), chunk({ seq: 60 }), chunk({ seq: "0" }),
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
    expect(audioFields({ id, run, seq: 3, last: true, audio: "AAAA" }).voice).toEqual({ id, run, seq: 3, last: true, audio: "AAAA", rate: 16000 });
    expect(JSON.parse(buildRequest(V, "voiceAudio", "device", audioFields({ id, run, seq: 0, last: false, audio: "AAAA" }))).by).toBe("device");
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
          { kind: "heard", text: "hello" }, { kind: "collected", text: "so far" }, { kind: "taken" }, { kind: "futureKind" }, 7,
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
          { kind: "heard", text: "hello" }, { kind: "collected", text: "so far" }, { kind: "taken" }, { kind: "needsYou", session }, { kind: "needsYou" },
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

  test("\"over\" said alone is short: a request being collected lets a sound of shortSpeechMs be a segment, and a blip is still not one", () => {
    const over = [loud, loud, ...Array(quietFrames).fill(quiet)];
    expect(shortSpeechMs).toBeLessThan(minSpeechMs);
    // Normally two loud frames are a blip and nothing is sent.
    expect(run(over).includes("begin")).toBe(false);
    expect(run(over).at(-1)).toBe("drop");
    const collecting = calibrated();
    collecting.minSpeech = shortSpeechMs;
    const answers = run(over, collecting);
    expect(answers.includes("begin")).toBe(true);
    expect(answers.at(-1)).toBe("end");
    // A single frame, a click, is still not one.
    const click = calibrated();
    click.minSpeech = shortSpeechMs;
    expect(run([loud, ...Array(quietFrames).fill(quiet)], click).at(-1)).toBe("drop");
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

  // Speech with a breath every half second, so it never looks like a steady sound.
  const talking = (frames: number) => Array.from({ length: frames }, (_, i) => (i % 6 === 5 ? quiet : loud));

  test("a request ends at the longest, even in speech", () => {
    const answers = run(talking(requestCapMs / 100 + 5));
    expect(answers.indexOf("end")).toBe(requestCapMs / 100 - 1);
  });

  test("a steady sound that never lets up is the room, not a person: it is abandoned and the floor rises over it", () => {
    const endpointer = calibrated();
    const steady = 0.05;
    const answers = run(Array(noiseRunMs / 100 + 3).fill(steady), endpointer);
    expect(answers.indexOf("begin")).toBe(2);
    expect(answers.indexOf("abort")).toBe(noiseRunMs / 100 - 1);
    expect(endpointer.threshold).toBeCloseTo(steady * floorTimes, 10);
    // The same sound is now the room's.
    expect(run(Array(30).fill(steady), endpointer).every((answer) => answer === "idle")).toBe(true);
    // And a voice over it is still heard.
    expect(run([0.4, 0.4, 0.4], endpointer)).toEqual(["pending", "pending", "begin"]);
  });

  test("speech with breaths is not the room", () => {
    const answers = run(talking(noiseRunMs / 100 * 2));
    expect(answers.includes("abort")).toBe(false);
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

describe("a request at the longest the host takes", () => {
  /** The host's `VoiceAudio.maxUtteranceBytes`: 30 s of 16-bit mono at 16 kHz. */
  const hostLimitBytes = maxUtteranceMs * uploadRate / 1000 * 2;
  const block = () => new Int16Array(uploadRate / 10);

  test("the page's longest request, with its pre-roll and its last chunk, is under the limit", async () => {
    const sizes: number[] = [];
    const endpointer = new Endpointer();
    for (let i = 0; i < calibrationFrames; i++) endpointer.feed(0.001, 100);
    const ring = Array.from({ length: preRollMs / 100 }, block);
    const utterance = new Utterance("x", async (body: { audio: string }) => { sizes.push(fromBase64(body.audio).length); return { ok: true }; }, ring);
    let ended = false;
    for (let frame = 0; !ended; frame++) {
      const answer = endpointer.feed(frame % 6 === 5 ? 0.001 : 0.1, 100);
      if (answer === "pending") utterance.add(block());
      else if (answer === "begin") { utterance.add(block()); utterance.begin(); }
      else if (answer === "speech") utterance.add(block());
      else if (answer === "end") { utterance.add(block()); ended = true; }
      expect(frame).toBeLessThan(1000);
    }
    expect(await utterance.finish()).toBeNull();
    const total = sizes.reduce((sum, size) => sum + size, 0);
    expect(total).toBeLessThanOrEqual(hostLimitBytes);
    expect(total).toBeGreaterThan(hostLimitBytes - 2 * uploadRate / 5);
    expect(hostLimitBytes).toBe(960_000);
  });
});

describe("a request on its way to the host", () => {
  const block = () => new Int16Array(uploadRate / 10).fill(7);

  test("goes in seconds while it is said, and the rest with a last chunk", async () => {
    const sent: { seq: number; last: boolean; samples: number }[] = [];
    const utterance = new Utterance("u", async (body: { seq: number; last: boolean; audio: string }) => {
      sent.push({ seq: body.seq, last: body.last, samples: fromBase64(body.audio).length / 2 });
      return { ok: true };
    });
    for (let i = 0; i < 25; i++) utterance.add(block());
    expect(sent).toEqual([]);
    utterance.begin();
    for (let i = 0; i < 5; i++) utterance.add(block());
    expect(await utterance.finish()).toBeNull();
    expect(sent.map((chunk) => chunk.seq)).toEqual([0, 1, 2, 3]);
    expect(sent.map((chunk) => chunk.samples)).toEqual([chunkSamples, chunkSamples, chunkSamples, 160]);
    expect(sent.map((chunk) => chunk.last)).toEqual([false, false, false, true]);
  });

  test("a chunk the host refuses stops the rest, tells once, and the request waits for no answer", async () => {
    const posts: number[] = [];
    const told: string[] = [];
    const utterance = new Utterance("u", async (body: { seq: number }) => {
      posts.push(body.seq);
      return body.seq === 0 ? { ok: false, error: "The voice session is off." } : { ok: true };
    }, [], (reason: string) => told.push(reason));
    utterance.begin();
    for (let i = 0; i < 40; i++) utterance.add(block());
    await utterance.chain;
    // It failed while the user was still speaking: the page has nothing to follow.
    expect(utterance.failed).toBe("The voice session is off.");
    expect(utterance.followable).toBe(false);
    expect(await utterance.finish()).toBe("The voice session is off.");
    expect(posts).toEqual([0]);
    expect(told).toEqual(["The voice session is off."]);
  });

  test("a segment that was a segment and sent whole is followed", async () => {
    const utterance = new Utterance("u", async () => ({ ok: true }));
    expect(utterance.followable).toBe(false);
    utterance.begin();
    expect(utterance.followable).toBe(true);
    expect(await utterance.finish()).toBeNull();
    expect(utterance.followable).toBe(true);
  });

  test("a failure in the last chunk is the request's", async () => {
    let calls = 0;
    const utterance = new Utterance("u", async () => (++calls === 2 ? { ok: false, error: "The host didn't answer." } : { ok: true }));
    utterance.begin();
    utterance.add(block());
    expect(await utterance.finish()).toBe("The host didn't answer.");
    expect(utterance.followable).toBe(false);
  });
});

describe("a microphone that reads live and gives nothing", () => {
  test("exact zeros for long enough are dead; anything else, even faint, is not", () => {
    const mic = new DeadMic();
    let dead = false;
    for (let ms = 0; ms < deadMicMs - 100; ms += 100) dead = mic.feed(0, 100) || dead;
    expect(dead).toBe(false);
    expect(mic.feed(0, 100)).toBe(true);
    const faint = new DeadMic();
    for (let ms = 0; ms < deadMicMs * 3; ms += 100) expect(faint.feed(0.00001, 100)).toBe(false);
  });

  test("a sound in between starts the count again", () => {
    const mic = new DeadMic();
    for (let ms = 0; ms < deadMicMs - 100; ms += 100) mic.feed(0, 100);
    expect(mic.feed(0.0003, 100)).toBe(false);
    for (let ms = 0; ms < deadMicMs - 100; ms += 100) expect(mic.feed(0, 100)).toBe(false);
  });
});

describe("Voice mode's own relay", () => {
  test("takes two relays of a device at a time, and a third waits for none", async () => {
    const folder = mkdtempSync(join(tmpdir(), "voice-relay-"));
    try {
      const script = join(folder, "relay.sh");
      writeFileSync(script, `#!/bin/sh\nsleep 0.5\nprintf '{"v":${V},"ok":true}\\n'\n`);
      chmodSync(script, 0o755);
      const config = { relay: script } as never;
      const relay = new Relay(config, V, folder, { total: 4, perKey: 2 });
      const answers = await Promise.all([1, 2, 3].map(() => relay.ask("voiceStatus", "device")));
      expect(answers.filter((answer) => answer.ok).length).toBe(2);
      expect(answers.find((answer) => !answer.ok)).toEqual({ ok: false, error: "The host is busy: try again" });
      // Another device is not held back by the first.
      const other = await Promise.all([relay.ask("voiceStatus", "a"), relay.ask("voiceStatus", "b"), relay.ask("voiceStatus", "a")]);
      expect(other.every((answer) => answer.ok)).toBe(true);
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
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
    // Working is the state line's, not a line of the exchange.
    expect(stateLine[view.state]).toBe("Working…");
    expect(view.exchange).toEqual([{ who: "you", text: "what time is it" }]);
    view = applyEvents(view, [{ kind: "lookingUp" }]);
    expect(stateLine[view.state]).toBe("Searching the web…");
    expect(view.exchange).toEqual([{ who: "you", text: "what time is it" }]);
    view = applyEvents(view, [{ kind: "answered", text: "It is noon.", spoken: "It is noon.", audio: "AAAA" }]);
    expect(view).toMatchObject({ state: "speaking", play: "AAAA", done: true });
    expect(view.exchange).toEqual([{ who: "you", text: "what time is it" }, { who: "varnick", text: "It is noon." }]);
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

describe("a request that ends only at over", () => {
  const collected = (text: string) => ({ kind: "collected", text });

  test("a segment that did not end it shows the request so far, still being built, and the page goes on listening", () => {
    let view = { ...newView(), state: "sending" };
    view = applyEvents(view, [collected("what was I working on")], "s1");
    expect(view).toMatchObject({ pending: "what was I working on", state: "collecting", asking: null });
    expect(stateLine.collecting).toContain("over");
    expect(view.exchange).toEqual([]);
    // Each collected event is all of the request so far: it replaces, it does not add.
    view = applyEvents(view, [collected("what was I working on yesterday afternoon")], "s2");
    expect(view.pending).toBe("what was I working on yesterday afternoon");
    expect(view.state).toBe("collecting");
  });

  test("the segment that ended it turns the line into the user's request and the answer follows", () => {
    let view = applyEvents(newView(), [collected("what time is it")], "s1");
    view = applyEvents(view, [{ kind: "heard", text: "what time is it in Tokyo" }, { kind: "taken" }], "s2");
    expect(view).toMatchObject({ pending: null, asking: "s2", state: "working", done: false });
    expect(view.exchange).toEqual([{ who: "you", text: "what time is it in Tokyo" }]);
    view = applyEvents(view, [{ kind: "answered", text: "It is noon.", audio: "AAAA" }], "s2");
    expect(view).toMatchObject({ asking: null, state: "speaking", done: true, play: "AAAA" });
  });

  test("a segment said while the last request is being answered waits its turn: its words are shown, the state line stays the ask's", () => {
    let view = applyEvents(newView(), [{ kind: "heard", text: "what time is it" }, { kind: "taken" }], "s1");
    view = applyEvents(view, [collected("and in Tokyo")], "s2");
    expect(view).toMatchObject({ pending: "and in Tokyo", state: "working", asking: "s1" });
    view = applyEvents(view, [{ kind: "lookingUp" }], "s1");
    expect(view.state).toBe("lookingUp");
    // The answer ends the ask, and the page is then collecting the next request.
    view = applyEvents(view, [{ kind: "answered", text: "Noon." }], "s1");
    expect(view).toMatchObject({ asking: null, state: "collecting", pending: "and in Tokyo", done: true });
    expect(view.exchange.map((line) => line.who)).toEqual(["you", "varnick"]);
  });

  test("a segment that could not be made into words says so and leaves the request, and an ask in progress, as they were", () => {
    let view = applyEvents({ ...newView(), state: "sending" }, [collected("what time")], "s1");
    view = applyEvents(view, [{ kind: "failed", text: "I couldn't make out the audio." }], "s2");
    expect(view).toMatchObject({ pending: "what time", state: "collecting" });
    expect(view.exchange).toEqual([{ who: "note", text: "I couldn't make out the audio." }]);
    const asked = applyEvents(newView(), [{ kind: "heard", text: "x" }, { kind: "taken" }], "s1");
    const meanwhile = applyEvents(asked, [{ kind: "failed", text: "I couldn't make out the audio." }], "s2");
    expect(meanwhile).toMatchObject({ asking: "s1", state: "working", done: false });
    // The ask's own failure ends it.
    expect(applyEvents(asked, [{ kind: "failed", text: "Claude didn't take that." }], "s1")).toMatchObject({ asking: null, state: "listening", done: true });
  });

  test("an empty request, from a segment with nothing in it, shows no line", () => {
    const view = applyEvents({ ...newView(), state: "sending" }, [collected("")], "s1");
    expect(view).toMatchObject({ pending: null, state: "listening" });
  });

  test("a segment never changes the state of a user who is speaking", () => {
    const view = applyEvents({ ...newView(), state: "hearing" }, [collected("one")], "s1");
    expect(view).toMatchObject({ pending: "one", state: "hearing" });
  });

  test("an \"over\" the Mac kept for later, because it was on another request, says so and keeps the line", () => {
    const view = applyEvents({ ...newView(), state: "sending" }, [{ kind: "collected", text: "and in Tokyo", spoken: "Still on the last one.", failure: "busy" }], "s1");
    expect(view).toMatchObject({ pending: "and in Tokyo", state: "collecting" });
    expect(view.exchange).toEqual([{ who: "note", text: "Still on the last one." }]);
  });

  test("the page asks what it is to wait on", () => {
    expect(settled({ ...newView(), pending: "x" })).toBe("collecting");
    expect(settled(newView())).toBe("listening");
  });
});

describe("the segments being followed", () => {
  const ok = (next: number, done = false, events: unknown[] = []) => ({ ok: true, next, done, events });

  test("are polled newest first, and their news comes oldest first", () => {
    const segments = new Segments();
    for (const id of ["a", "b", "c"]) segments.add(id);
    expect(segments.order()).toEqual(["c", "b", "a"]);
    const news = segments.settle(new Map<string, unknown>([
      ["c", ok(1, true, [{ kind: "collected", text: "c" }])], ["b", ok(1, true, [{ kind: "collected", text: "b" }])], ["a", ok(2, false, [{ kind: "heard", text: "a" }, { kind: "taken" }])],
    ]));
    expect(news.map((item) => item.id)).toEqual(["a", "b", "c"]);
    // Done ones leave; one still being answered stays, and is asked for from where it left off.
    expect(segments.order()).toEqual(["a"]);
    expect(segments.after("a")).toBe(2);
    expect(segments.after("gone")).toBe(0);
  });

  test("a segment with nothing new says nothing, and one that is done says so even with no events", () => {
    const segments = new Segments();
    segments.add("a");
    segments.add("b");
    expect(segments.settle(new Map<string, unknown>([["a", ok(0)], ["b", ok(0, true)]]))).toEqual([{ id: "b", events: [], done: true, lost: null }]);
    expect(segments.size).toBe(1);
  });

  test("one that cannot be reached is given up on after the same number of tries in a row, and a good poll starts the count again", () => {
    const segments = new Segments();
    segments.add("a");
    const fail = new Map<string, unknown>([["a", { ok: false, error: "The host didn't answer." }]]);
    for (let i = 0; i < pollFailures - 1; i++) expect(segments.settle(fail)).toEqual([]);
    expect(segments.settle(new Map<string, unknown>([["a", ok(0)]]))).toEqual([]);
    for (let i = 0; i < pollFailures - 1; i++) expect(segments.settle(fail)).toEqual([]);
    expect(segments.settle(fail)).toEqual([{ id: "a", events: [], done: true, lost: "The host didn't answer." }]);
    expect(segments.size).toBe(0);
  });

  test("a segment that was not polled this round is left alone", () => {
    const segments = new Segments();
    segments.add("a");
    expect(segments.settle(new Map())).toEqual([]);
    expect(segments.size).toBe(1);
  });
});

describe("segments go to the host in the order they were said", () => {
  test("serial runs tasks one after another, whatever each takes, and a failure is its own", async () => {
    const run = serial();
    const order: string[] = [];
    const slow = run(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); order.push("slow"); return 1; });
    const broken = run(async () => { order.push("broken"); throw new Error("no"); });
    const quick = run(async () => { order.push("quick"); return 3; });
    expect(await slow).toBe(1);
    await expect(broken).rejects.toThrow("no");
    expect(await quick).toBe(3);
    expect(order).toEqual(["slow", "broken", "quick"]);
  });

  test("a segment said later reaches the host later, though it is quicker to send", async () => {
    const run = serial();
    const sent: string[] = [];
    const post = (name: string, delay: number) => async (body: { seq: number }) => {
      await new Promise((resolve) => setTimeout(resolve, delay));
      sent.push(`${name}${body.seq}`);
      return { ok: true };
    };
    const block = () => new Int16Array(chunkSamples).fill(3);
    const first = new Utterance("1", post("a", 15), [], undefined, run);
    first.begin();
    first.add(block());
    const finishedFirst = first.finish();
    const second = new Utterance("2", post("b", 1), [], undefined, run);
    second.begin();
    second.add(block());
    const finishedSecond = second.finish();
    expect(await Promise.all([finishedFirst, finishedSecond])).toEqual([null, null]);
    expect(sent).toEqual(["a0", "a1", "b0", "b1"]);
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
