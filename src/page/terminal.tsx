import React, { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
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

// The page mounts the terminal itself and speaks ttyd's socket protocol, so
// that a keystroke can be mapped on its way out (ADR-0002, amended). ttyd and
// zmx are untouched: this is the same socket ttyd's own page connected to.

/** Reconnect backoff, in milliseconds; a Session outlives its window. */
const BACKOFF = [1000, 2000, 4000, 8000, 10_000];

export function TerminalPane({ url, title }: { url: string; title: string }) {
  const box = useRef<HTMLDivElement>(null);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    // Without macOptionIsMeta, macOS composes Option+B into "∫" and Claude
    // Code never sees the word-back it was meant as.
    const terminal = new Terminal({
      cursorBlink: true,
      scrollback: 10000,
      macOptionIsMeta: true,
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.loadAddon(new WebLinksAddon());
    terminal.open(box.current!);
    fit.fit();

    let socket: WebSocket | undefined;
    let attempt = 0;
    let retry: number | undefined;
    let unmounted = false;

    const send = (frame: Uint8Array) => {
      if (socket?.readyState === WebSocket.OPEN) socket.send(frame);
    };

    const connect = () => {
      const flow = flowControl();
      const decode = outputDecoder();
      socket = new WebSocket(socketUrl(url), ["tty"]);
      socket.binaryType = "arraybuffer";

      socket.onopen = () => {
        attempt = 0;
        setConnected(true);
        socket!.send(handshake(terminal.cols, terminal.rows));
      };

      socket.onmessage = (message) => {
        const frame = new Uint8Array(message.data as ArrayBuffer);
        const text = decode(frame);
        // Counted before the text is looked at: a frame ending mid-character
        // decodes to nothing and is still bytes ttyd sent.
        const { counted, pause: stop } = flow.writing(frame.byteLength);
        const landed = () => {
          if (flow.written().resume) send(resume());
        };
        if (!counted) terminal.write(text);
        // A counted frame that decoded to nothing has nothing to wait for, so
        // it lands at once rather than leaving the count permanently raised.
        else if (!text) landed();
        else terminal.write(text, landed);
        if (stop) send(pause());
      };

      socket.onclose = () => {
        setConnected(false);
        if (unmounted) return;
        // zmx replays the whole scrollback when it is attached again, so the
        // terminal is cleared first or the history arrives twice.
        terminal.reset();
        retry = setTimeout(
          connect,
          BACKOFF[Math.min(attempt++, BACKOFF.length - 1)],
        );
      };
    };

    const typed = terminal.onData((data) => send(input(data)));
    const resized = terminal.onResize(({ cols, rows }) => {
      if (cols > 0 && rows > 0) send(resize(cols, rows));
    });

    // Shift+Enter is a bare CR to xterm.js, which is what Enter is, so Claude
    // Code submits. ESC CR is the newline it wants, and is what Option+Enter
    // already sends. xterm asks this handler about the keypress as well as the
    // keydown, and a keypress it is not told to drop sends that CR after all,
    // so both are claimed and only the keydown sends.
    terminal.attachCustomKeyEventHandler((event) => {
      const shiftEnter = event.key === "Enter" && event.shiftKey &&
        !event.altKey && !event.ctrlKey && !event.metaKey;
      if (!shiftEnter) return true;
      event.preventDefault();
      if (event.type === "keydown") send(input("\x1b\r"));
      return false;
    });

    const observer = new ResizeObserver(() => {
      // A hidden pane measures as nothing, and fitting to nothing throws.
      if (box.current?.clientWidth && box.current.clientHeight) fit.fit();
    });
    observer.observe(box.current!);

    connect();

    return () => {
      unmounted = true;
      clearTimeout(retry);
      observer.disconnect();
      typed.dispose();
      resized.dispose();
      socket?.close();
      terminal.dispose();
    };
  }, [url]);

  return (
    <div
      role="group"
      aria-label={title}
      style={{ position: "relative", height: "70vh", border: "1px solid #ccc" }}
    >
      <div ref={box} style={{ width: "100%", height: "100%" }} />
      {connected ? null : (
        <p
          style={{
            position: "absolute",
            top: "0.5rem",
            left: "0.5rem",
            color: "#666",
          }}
        >
          connecting…
        </p>
      )}
    </div>
  );
}
