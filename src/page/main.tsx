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

// There is one Landing at a time, and its Snapshot says which branch it is
// about. The page names neither its states nor its reasons (ADR-0010): both are
// rendered as whatever the Snapshot says.
interface LandingView {
  branch?: string;
  reason?: string;
  error?: string;
}

// What the `host` Snapshot says about the Previews it has launched (ADR-0008),
// and which mode the Secrets file put this Host in (ADR-0005, amended).
interface HostView {
  /** The tree this Host runs from: the Live tree, or a Worktree for a Preview (ADR-0008). */
  tree?: string;
  previews?: Record<string, { url: string; pid: number }>;
  previewError?: string;
  proxy?: "on" | "off";
  credential?: { kind: string };
}

function hostOf(snapshots: Record<string, Snapshot>): { state: string } & HostView {
  const host = snapshots.host;
  return { state: String(host?.value ?? "…"), ...(host?.context as HostView ?? {}) };
}

// Which branch a Host is a Preview of, or nothing for Live. The only thing
// that tells the two apart is the tree the Host runs from (ADR-0008), and a
// Worktree is always at `.claude/worktrees/{branch}`.
function previewOf(tree: string | undefined): string | undefined {
  return tree?.match(/\/\.claude\/worktrees\/([^/]+)$/)?.[1];
}

function landingOf(snapshots: Record<string, Snapshot>): { state: string } & LandingView {
  const landing = snapshots.landing;
  return { state: String(landing?.value ?? "…"), ...(landing?.context as LandingView ?? {}) };
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
  const landing = landingOf(snapshots);
  const host = hostOf(snapshots);
  // A selection that has not been made yet falls to the first Session, so the
  // terminal is there as soon as one is.
  const shown = sessions.find((session) => session.branch === selected) ?? sessions[0];

  // A Preview is told from Live in the window title and the heading, and by a
  // tinted ground, so two windows side by side are never mistaken (ADR-0008).
  const preview = previewOf(host.tree);
  const name = preview ? `varnick preview of ${preview}` : "varnick";
  useEffect(() => {
    document.title = name;
  }, [name]);

  return (
    <main
      data-preview={preview}
      style={{
        fontFamily: "system-ui",
        padding: "1rem",
        minHeight: "100vh",
        boxSizing: "border-box",
        background: preview ? "#fff7e0" : undefined,
      }}
    >
      <h1>
        varnick {preview ? <small>preview of <code>{preview}</code></small> : null}{" "}
        <small>{host.state}</small>
      </h1>
      {/* Which mode the Host is in, and the Credential's kind when there is
          one — never its value, which the Snapshot does not carry (ADR-0005). */}
      {host.proxy
        ? (
          <p data-proxy={host.proxy}>
            {host.proxy === "on"
              ? `Proxy on: the agent carries a placeholder for your ${host.credential?.kind}`
              : "Proxy off: no secrets.yaml, so the agent runs /login in its Session"}
          </p>
        )
        : null}
      <NewSession />
      {/* Promotion: the Live Host relaunches onto whatever has landed (spec
          user story 17). The Sessions are not the Host's children and stay. */}
      <button type="button" onClick={() => send("host", { type: "RESTART" })}>
        Restart
      </button>
      {host.previewError ? <span role="alert">{host.previewError}</span> : null}

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
            {/* The Event carries the branch name and nothing else; the Host
                decides the rest (ADR-0003). */}
            <button
              type="button"
              onClick={() => send("landing", { type: "LAND", branch: session.branch })}
            >
              Land
            </button>
            {/* A Preview is a second Host launched from this Session's
                Worktree, in its own window on its own port (ADR-0008). The
                Event carries the branch; the Host chooses the port and says
                where it put it. */}
            <button
              type="button"
              onClick={() => send("host", { type: "PREVIEW", branch: session.branch })}
            >
              Preview
            </button>
            {host.previews?.[session.branch]
              ? (
                <a href={host.previews[session.branch].url} target="_blank" rel="noreferrer">
                  {host.previews[session.branch].url}
                </a>
              )
              : null}
            {landing.branch === session.branch
              ? (
                <span data-landing={landing.state} title={landing.error}>
                  {landing.state}
                  {landing.reason ? `: ${landing.reason}` : ""}
                </span>
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
