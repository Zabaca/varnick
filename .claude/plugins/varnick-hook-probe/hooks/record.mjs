/**
 * Record that a plugin's hook ran.
 *
 * Ticket 58. Plugin hooks had never fired under varnick — a plugin declares its
 * hook as a command, that command is conventionally `node <script>`, and the
 * agent's environment is built outright rather than inherited. The failure is
 * silent, which is the property that let it go unnoticed for months.
 *
 * This is the fixture that makes it observable. It is varnick's own, so it
 * cannot be removed by somebody else's decision about somebody else's plugin —
 * which is exactly what happened to the evidence the first time.
 *
 * ## Rules this file lives by
 *
 * **Nothing on stdout.** A `SessionStart` hook's stdout is injected into the
 * agent's context. A fixture that talked would be changing the thing it is
 * measuring, on every single session.
 *
 * **Never throw, never exit non-zero.** A hook that fails the session would make
 * this fixture more dangerous than the defect it proves. Every failure here is
 * swallowed deliberately: the absence of the file is the negative result.
 *
 * **It records what it was given, not what it expected.** `CLAUDE_PLUGIN_ROOT`
 * and `PATH` are the two candidates ticket 58 named, and the point of writing
 * them down is that the answer comes from the run rather than from a reading of
 * the code.
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

try {
  // Where varnick points Claude Code's own state — inside the clone, because the
  // Sandbox leaves nowhere else durable. See CLAUDE_CONFIG_RELATIVE_PATH.
  const configDir = process.env.CLAUDE_CONFIG_DIR
  if (configDir) {
    const path = join(configDir, 'hook-probe.json')
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(
      path,
      `${JSON.stringify(
        {
          ran: new Date().toISOString(),
          // The two ticket 58 asked about, answered by the run.
          pluginRoot: process.env.CLAUDE_PLUGIN_ROOT ?? null,
          // Which interpreter actually answered to `node`. Under varnick this is
          // the shim, and that is the whole of the first half's fix.
          argv0: process.argv[0] ?? null,
          // Enough of PATH to see whether varnick's bin is on it, without
          // putting a developer's whole environment in a file.
          pathHead: (process.env.PATH ?? '').split(':').slice(0, 3),
        },
        null,
        2,
      )}\n`,
    )
  }
} catch {
  // Deliberately silent. See the header: a fixture that can fail a session is
  // worse than the defect it exists to prove.
}
