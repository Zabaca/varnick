// Where a Session's ttyd was put. The Host chooses each ttyd's port at random
// and then lets the process go (it must outlive the Host), so without a note of
// the port a relaunched Host cannot find the terminal it left running. This is
// the note: a per-clone file under `.varnick/`, gitignored.
//
// It is not persistence of a Machine (ADR-0007). Nothing here is believed: at
// launch every recorded port is checked against the world, and one that does
// not answer is replaced.

export interface RecordedTerminal {
  port: number;
  pid: number;
}

export function terminalsFile(liveTree: string): string {
  return `${liveTree}/.varnick/terminals.json`;
}

/** Every recorded terminal, by branch. A missing or unreadable file is empty. */
export async function readTerminals(liveTree: string): Promise<Record<string, RecordedTerminal>> {
  let text: string;
  try {
    text = await Deno.readTextFile(terminalsFile(liveTree));
  } catch {
    return {};
  }
  try {
    const parsed = JSON.parse(text);
    return typeof parsed === "object" && parsed !== null ? parsed : {};
  } catch {
    // A file we cannot read is a file we ignore; every Session then starts a
    // fresh ttyd, which costs a terminal and never a Session.
    return {};
  }
}

async function writeTerminals(
  liveTree: string,
  terminals: Record<string, RecordedTerminal>,
): Promise<void> {
  const path = terminalsFile(liveTree);
  await Deno.mkdir(path.slice(0, path.lastIndexOf("/")), { recursive: true });
  await Deno.writeTextFile(path, `${JSON.stringify(terminals, null, 2)}\n`);
}

export async function recordTerminal(
  liveTree: string,
  branch: string,
  terminal: RecordedTerminal,
): Promise<void> {
  const terminals = await readTerminals(liveTree);
  await writeTerminals(liveTree, { ...terminals, [branch]: terminal });
}

/**
 * A loopback port nothing is listening on. Every port the Host hands to another
 * process — a ttyd's, a Preview's Door — is chosen here: the listener is opened
 * and closed at once, so the port is free and the process that gets it races
 * only with the rest of the machine.
 */
export function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
}

/** Whether something accepts a connection on a loopback port right now. */
export async function answersNow(port: number): Promise<boolean> {
  try {
    (await Deno.connect({ hostname: "127.0.0.1", port })).close();
    return true;
  } catch {
    return false;
  }
}
