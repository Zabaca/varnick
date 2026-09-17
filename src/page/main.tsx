import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

// The page renders Snapshots from /stream and sends Events to the Door
// (ADR-0006). It holds no machine, and it names no state: a badge shows
// whatever the Session's Snapshot says its state is (ADR-0010).

type Snapshot = { value: unknown; context: unknown };

interface SessionView {
  branch: string;
  state: string;
  reapable: boolean;
  worktreePath?: string;
  terminalUrl?: string;
  error?: string;
  refusal?: string;
}

function sessionsOf(snapshots: Record<string, Snapshot>): SessionView[] {
  const context = snapshots.sessions?.context as { sessions?: Record<string, SessionView> };
  return Object.values(context?.sessions ?? {}).sort((a, b) => a.branch.localeCompare(b.branch));
}

async function send(actor: string, event: Record<string, unknown>) {
  await fetch(`/actors/${actor}/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(event),
  });
}

function NewSession() {
  const [branch, setBranch] = useState("");
  return (
    <form
      onSubmit={(submit) => {
        submit.preventDefault();
        if (!branch.trim()) return;
        send("sessions", { type: "NEW_SESSION", branch: branch.trim() });
        setBranch("");
      }}
    >
      <input
        aria-label="branch"
        placeholder="branch"
        value={branch}
        onChange={(change) => setBranch(change.target.value)}
      />
      <button type="submit">New Session</button>
    </form>
  );
}

function App() {
  const [snapshots, setSnapshots] = useState<Record<string, Snapshot>>({});
  const [selected, setSelected] = useState<string | undefined>();

  useEffect(() => {
    const stream = new EventSource("/stream");
    stream.onmessage = (message) => {
      const { actor, snapshot } = JSON.parse(message.data);
      setSnapshots((prior) => ({ ...prior, [actor]: snapshot }));
    };
    return () => stream.close();
  }, []);

  const sessions = sessionsOf(snapshots);
  // A selection that has not been made yet falls to the first Session, so the
  // terminal is there as soon as one is.
  const shown = sessions.find((session) => session.branch === selected) ?? sessions[0];

  return (
    <main style={{ fontFamily: "system-ui", padding: "1rem" }}>
      <h1>
        varnick <small>{String(snapshots.host?.value ?? "…")}</small>
      </h1>
      <NewSession />

      <ul style={{ listStyle: "none", padding: 0 }}>
        {sessions.map((session) => (
          <li key={session.branch}>
            <button
              type="button"
              aria-current={session.branch === shown?.branch}
              onClick={() => setSelected(session.branch)}
            >
              {session.branch}
            </button>
            <span data-state={session.state}>{session.state}</span>
            {/* Offered only where the Session says a Reap is something it
                would take — a tag it carries, never a state name (ADR-0010). */}
            {session.reapable
              ? (
                <button
                  type="button"
                  onClick={() => send("sessions", { type: "REAP", branch: session.branch })}
                >
                  Reap
                </button>
              )
              : null}
            {session.error ? <span role="alert">{session.error}</span> : null}
            {/* A Reap the Host would not do, and the one way through it. */}
            {session.refusal
              ? (
                <>
                  <span role="alert">{session.refusal}</span>
                  <button
                    type="button"
                    onClick={() =>
                      send("sessions", { type: "REAP", branch: session.branch, force: true })}
                  >
                    Reap anyway
                  </button>
                </>
              )
              : null}
          </li>
        ))}
      </ul>

      {shown?.terminalUrl
        ? (
          <iframe
            title={`terminal for ${shown.branch}`}
            src={shown.terminalUrl}
            style={{ width: "100%", height: "70vh", border: "1px solid #ccc" }}
          />
        )
        : <p>No terminal yet.</p>}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
