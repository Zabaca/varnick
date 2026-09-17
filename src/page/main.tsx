import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

// The page renders Snapshots from /stream and nothing else (ADR-0006).
// It holds no machine.

type Snapshot = { value: unknown; context: unknown };

function App() {
  const [snapshots, setSnapshots] = useState<Record<string, Snapshot>>({});

  useEffect(() => {
    const stream = new EventSource("/stream");
    stream.onmessage = (message) => {
      const { actor, snapshot } = JSON.parse(message.data);
      setSnapshots((prior) => ({ ...prior, [actor]: snapshot }));
    };
    return () => stream.close();
  }, []);

  return (
    <main style={{ fontFamily: "system-ui", padding: "1rem" }}>
      <h1>varnick</h1>
      {Object.entries(snapshots).map(([name, snapshot]) => (
        <section key={name}>
          <h2>{name}</h2>
          <p>
            state: <strong>{JSON.stringify(snapshot.value)}</strong>
          </p>
          <pre>{JSON.stringify(snapshot.context, null, 2)}</pre>
        </section>
      ))}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
