// Spike, not v1 (ADR-0004). Answers one question: with a Seatbelt-wrapped shell
// as the Session's command, does ttyd's websocket still work, and does the shell
// inside still refuse to write outside its allowed directory?
//
// The shape under test is the one Wrap would produce: ttyd and the zmx server
// run unconfined on the Host; only the command the Session runs is wrapped.

const SRT = '@anthropic-ai/sandbox-runtime@0.0.76'

type Check = { name: string; ok: boolean; detail: string }
const checks: Check[] = []
const record = (name: string, ok: boolean, detail: string) => {
  checks.push({ name, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}\n      ${detail}`)
}

async function run(cmd: string[]) {
  const p = new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    stdin: 'null',
    stdout: 'piped',
    stderr: 'piped',
  })
  const { code, stdout, stderr } = await p.output()
  const d = new TextDecoder()
  return { code, out: d.decode(stdout), err: d.decode(stderr) }
}

async function firstLine(bin: string, args: string[]) {
  try {
    const r = await run([bin, ...args])
    return (r.out + r.err).trim().split('\n')[0]
  } catch {
    return null
  }
}

async function freePort() {
  const l = Deno.listen({ hostname: '127.0.0.1', port: 0 })
  const port = (l.addr as Deno.NetAddr).port
  l.close()
  return port
}

async function waitForPort(port: number, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    try {
      const c = await Deno.connect({ hostname: '127.0.0.1', port })
      c.close()
      return true
    } catch {
      await new Promise((r) => setTimeout(r, 100))
    }
  }
  return false
}

/**
 * One ttyd client, speaking ttyd's own protocol: the `tty` subprotocol, a JSON
 * auth frame first, then `0`-prefixed frames are terminal output. Receiving
 * output is the proof that the websocket carried the sandboxed shell's PTY, not
 * merely that the upgrade was accepted.
 */
function ttydClient(port: number, ms: number) {
  return new Promise<{ opened: boolean; output: string; error: string }>((resolve) => {
    let output = ''
    let opened = false
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, 'tty')
    ws.binaryType = 'arraybuffer'
    const done = (error: string) => {
      clearTimeout(timer)
      try {
        ws.close()
      } catch {
        // already closing
      }
      resolve({ opened, output, error })
    }
    const timer = setTimeout(() => done(''), ms)
    ws.onopen = () => {
      opened = true
      ws.send(JSON.stringify({ AuthToken: '', columns: 80, rows: 24 }))
    }
    ws.onmessage = (e) => {
      const bytes = new Uint8Array(e.data as ArrayBuffer)
      if (bytes[0] === 0x30) output += new TextDecoder().decode(bytes.slice(1))
    }
    ws.onerror = () => done('websocket error')
    ws.onclose = (e) => done(e.code === 1000 ? '' : `closed ${e.code}`)
  })
}

if (Deno.build.os !== 'darwin') {
  console.log(`SKIP  Seatbelt is macOS-only; this machine is ${Deno.build.os}.`)
  Deno.exit(0)
}

const ttydVersion = await firstLine('ttyd', ['--version'])
const zmxVersion = await firstLine('zmx', ['version'])
if (!ttydVersion || !zmxVersion) {
  console.error(
    `Missing: ${!ttydVersion ? 'ttyd ' : ''}${!zmxVersion ? 'zmx' : ''}\n` +
      'Install with: brew install ttyd zmx',
  )
  Deno.exit(1)
}
const srtVersion = (await run(['npx', '-y', SRT, '--version'])).out.trim() || 'unknown'
console.log(`ttyd ${ttydVersion}\nzmx ${zmxVersion}\nsrt ${srtVersion}\ndeno ${Deno.version.deno}\n`)

const root = await Deno.makeTempDir({ prefix: 'varnick-seatbelt-' })
const allowed = `${root}/allowed`
const outside = `${root}/outside`
await Deno.mkdir(allowed)
await Deno.mkdir(outside)
const settings = `${root}/srt-settings.json`
await Deno.writeTextFile(
  settings,
  JSON.stringify({
    filesystem: { denyRead: [], allowWrite: [allowed], denyWrite: [] },
    network: { allowedDomains: [], deniedDomains: [] },
  }),
)

const session = `varnick-probe-${crypto.randomUUID().slice(0, 8)}`
const port = await freePort()

// This is what Wrap would return if a sandbox ever came back: the Session's
// command, wrapped. ttyd attaches to the session and the zmx server holds the PTY.
const wrapped = `npx -y ${SRT} --settings ${settings} -c '/bin/bash --norc -i'`
const ttyd = new Deno.Command('ttyd', {
  args: [
    '-W',
    '-i',
    'lo0',
    '-p',
    String(port),
    '-w',
    allowed,
    'zmx',
    'attach',
    session,
    '/bin/sh',
    '-c',
    wrapped,
  ],
  stdout: 'piped',
  stderr: 'piped',
}).spawn()

try {
  record('ttyd binds a loopback port', await waitForPort(port, 10_000), `ws://127.0.0.1:${port}/ws`)

  const client = await ttydClient(port, 25_000)
  record(
    "ttyd's websocket carries the sandboxed shell's PTY",
    client.opened && client.output.length > 0,
    client.opened
      ? `${client.output.length} bytes of terminal output${client.error ? `; ${client.error}` : ''}`
      : `websocket never opened: ${client.error}`,
  )

  const sessions = (await run(['zmx', 'ls', '--short'])).out.split('\n')
  record(
    'the zmx session outlives the websocket',
    sessions.includes(session),
    `${session} ${sessions.includes(session) ? 'present' : 'absent'} in zmx ls`,
  )

  // `zmx run` types into the same PTY the websocket was attached to, so the two
  // writes below are made by the shell under Seatbelt, not by this script. zmx
  // appends its own completion marker carrying the command's exit code.
  const exitOf = (out: string) => out.match(/ZMX_TASK_COMPLETED:[^:]+:(\d+)/)?.[1]

  const inside = await run(['zmx', 'run', session, 'touch', `${allowed}/inside.txt`])
  record(
    'a write inside the allowed directory succeeds',
    exitOf(inside.out) === '0',
    `touch allowed/inside.txt exited ${exitOf(inside.out) ?? 'without a marker'}`,
  )

  const out = await run(['zmx', 'run', session, 'touch', `${outside}/out.txt`])
  const code = exitOf(out.out)
  record(
    'a write outside it is refused by Seatbelt',
    code !== undefined && code !== '0',
    code === undefined
      ? 'no completion marker; the session did not answer'
      : code === '0'
        ? `unexpectedly allowed: ${out.out.trim().slice(-200)}`
        : (out.out.split('\n').find((l) => l.includes('not permitted'))?.trim() ??
          `exited ${code}`),
  )
} finally {
  await run(['zmx', 'kill', session, '--force'])
  try {
    ttyd.kill('SIGTERM')
    await ttyd.status
  } catch {
    // already gone
  }
  await Deno.remove(root, { recursive: true })
}

const failed = checks.filter((c) => !c.ok)
console.log(`\n${checks.length - failed.length}/${checks.length} checks passed.`)
Deno.exit(failed.length === 0 ? 0 : 1)
