// ttyd's wire protocol as data: the whole of it the page depends on, driven
// without a socket, a DOM or an xterm. The expected frames are transcribed
// from ttyd 1.7.7's own client, not recomputed the way the code computes them.
import {
  flowControl,
  handshake,
  input,
  outputDecoder,
  pause,
  resize,
  resume,
  socketUrl,
} from "./ttyd.ts";

const text = (frame: Uint8Array) => new TextDecoder().decode(frame);

function equals(actual: unknown, expected: unknown, what: string) {
  const [a, b] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== b) throw new Error(`${what}: expected ${b}, got ${a}`);
}

Deno.test("the socket is the ttyd URL's /ws, on the same loopback port", () => {
  equals(
    socketUrl("http://127.0.0.1:53211"),
    "ws://127.0.0.1:53211/ws",
    "bare origin",
  );
  equals(
    socketUrl("http://127.0.0.1:53211/"),
    "ws://127.0.0.1:53211/ws",
    "trailing slash",
  );
});

Deno.test("the first frame is ttyd's handshake, with an empty token", () => {
  equals(
    text(handshake(120, 40)),
    '{"AuthToken":"","columns":120,"rows":40}',
    "handshake",
  );
});

Deno.test("client frames carry ttyd's one-byte command prefix", () => {
  equals(text(input("ls\r")), "0ls\r", "input");
  equals(text(input("\x1b\r")), "0\x1b\r", "Shift+Enter, which is ESC CR");
  equals(text(resize(120, 40)), '1{"columns":120,"rows":40}', "resize");
  equals(text(pause()), "2", "pause");
  equals(text(resume()), "3", "resume");
});

Deno.test("only output frames decode, and a character split across two of them survives", () => {
  const decode = outputDecoder();
  // "héllo → 日本" is 17 bytes and the arrow is the three at 7, 8 and 9, so
  // ttyd sending it in two frames cut at 9 splits the arrow between them.
  const out = new TextEncoder().encode("héllo → 日本");
  const frame = (bytes: Uint8Array) => Uint8Array.from([0x30, ...bytes]);
  equals(
    decode(frame(out.slice(0, 9))),
    "héllo ",
    "up to the split arrow, which is held back",
  );
  equals(
    decode(frame(out.slice(9))),
    "→ 日本",
    "the rest, starting with the arrow's last byte",
  );
  equals(
    decode(new TextEncoder().encode("1varnick")),
    "",
    "a window title is not output",
  );
  equals(
    decode(new TextEncoder().encode("2{}")),
    "",
    "preferences are not output",
  );
  equals(
    decode(new TextEncoder().encode("0")),
    "",
    "a prefix with nothing after it",
  );
});

Deno.test("flow control pauses at the high water mark and resumes at the low one", () => {
  const flow = flowControl();
  // Under ttyd's byte limit a write is not counted, so it can never pause.
  equals(flow.writing(1000), { counted: false, pause: false }, "a small write");
  equals(
    flow.writing(100_000),
    { counted: true, pause: false },
    "the write that crosses the limit",
  );

  // Ten more counted writes with nothing landing: pending passes the high
  // water mark of 10 on the last one, and asks ttyd to stop.
  const pauses = Array.from({ length: 10 }, () => flow.writing(200_000).pause);
  equals(pauses, [
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    true,
  ], "pauses");

  // Nothing resumes until pending is under the low water mark of 4, and then
  // only once: the writes that land after it are already flowing.
  const resumes = Array.from({ length: 11 }, () => flow.written().resume);
  equals(resumes, [
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    true,
    false,
    false,
    false,
  ], "resumes");
});
