// The terminals file is changed once per Session at launch, all at once; every
// entry must survive that (spec §Restart: a relaunched Host finds its terminals).
import { readTerminals, recordTerminal, terminalsFile } from "./terminals.ts";

Deno.test("terminals recorded at the same time are all kept", async () => {
  const liveTree = await Deno.makeTempDir({ prefix: "varnick-terminals-" });
  const branches = ["a", "b", "c", "d", "e"];
  await Promise.all(
    branches.map((branch, i) => recordTerminal(liveTree, branch, { port: 1000 + i, pid: i })),
  );
  const terminals = await readTerminals(liveTree);
  const kept = Object.keys(terminals).sort();
  if (kept.join() !== branches.join()) {
    throw new Error(
      `expected ${branches.join()} in ${terminalsFile(liveTree)}, got ${kept.join()}: ${
        await Deno.readTextFile(terminalsFile(liveTree))
      }`,
    );
  }
});
