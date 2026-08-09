import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  AGENT_ENTRY_RELATIVE_PATH,
  CLAUDE_CONFIG_DIR_ENV_VAR,
  CLAUDE_CONFIG_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAME,
  DEVELOPER_TOOLS_CANDIDATES,
  INHERIT_CLAUDE_CONFIG_ENV_VAR,
  agentCommand,
  agentConfigurationOptions,
  agentEntryPath,
  agentEnvironment,
  agentSdkEntry,
  claudeConfigDir,
  developerToolsBin,
  inheritedConfigVariables,
  inheritsClaudeConfig,
  failureOfThrown,
  sandboxEnvOverlay,
  serveTurns,
  type AgentSessionPort,
} from './agent.ts'
import { parsePlanUsageAnswer, type PlanUsageReport } from './subscription.ts'
import { parseTurnEvent, turnFailureMessage, type TurnEvent } from './turn.ts'

/** A value shaped like a real key, used to prove it never comes back out. */
/*
  Assembled, and repeated nowhere. The value is invented and says so, but its
  shape is one every secret scanner looks for — and a literal of that shape in a
  tracked file blocks pushing for this repository and every fork of it. Four
  copies of it used to sit inline below, which is also how a fixture drifts from
  the constant that names it.
*/
const LOOKS_LIKE_A_KEY = ['sk-', 'ant-api03-NEVER-LET-THIS-OUT'].join('')

/*
  The seam is what the Harness hands the host to spawn — a command string, and
  the overlay that goes with it. Nothing here starts a process: the agent is
  spawned by the Rust host (ADR-0008) and proved to be confined in
  sandbox.boundary.test.ts, which is the only place that can prove it.
*/

const CLONE = '/Users/dev/code/varnick'
const BUN = '/Users/dev/.bun/bin/bun'
const SDK = '/Users/dev/code/varnick/node_modules/.store/claude-agent-sdk/sdk.mjs'

describe('what gets spawned', () => {
  test('the entry is the Harness agent host, inside the clone', () => {
    expect(agentEntryPath(CLONE)).toBe(join(CLONE, AGENT_ENTRY_RELATIVE_PATH))
    // Inside the clone matters: the clone is the one tree the policy reads back
    // out of the denied home. An entry anywhere else would be unreadable to the
    // process that has to run it.
    expect(agentEntryPath(CLONE).startsWith(CLONE)).toBe(true)
  })

  test('the command runs the interpreter on that entry', () => {
    const command = agentCommand({ cloneRoot: CLONE, execPath: BUN, sdkEntry: SDK })
    expect(command).toContain(BUN)
    expect(command).toContain(AGENT_ENTRY_RELATIVE_PATH)
  })

  test('the Agent SDK is named by absolute path, not left to be resolved', () => {
    // The confined process cannot walk the workspace's symlinked node_modules —
    // measured, and recorded beside agentSdkEntry(). The runtime resolves it
    // out here, where nothing is denied, and hands the answer over.
    const command = agentCommand({ cloneRoot: CLONE, execPath: BUN, sdkEntry: SDK })
    expect(command).toContain(SDK)
  })

  test('the real SDK entry resolves to a file that exists', () => {
    // If this ever stops being true the agent stops starting, and the failure
    // in the wrapped process reads as a missing dependency rather than as this.
    expect(existsSync(agentSdkEntry())).toBe(true)
  })

  test('the developer toolchain is found rather than assumed', () => {
    /*
      `git` is not in `/usr/bin` on macOS — the shim there hands over to
      whichever developer directory is active, which is Xcode's when Xcode is
      installed and the Command Line Tools' when it is not. Two different
      absolute paths, and only one of them is under a path anything else names.

      Probed rather than resolved by running `xcode-select -p`: a spawn inside a
      function the policy generator calls would make generating a policy start a
      process, and the answer is a directory either way.
    */
    expect(developerToolsBin(() => false)).toBeNull()
    expect(developerToolsBin((path) => path === DEVELOPER_TOOLS_CANDIDATES[1])).toBe(
      DEVELOPER_TOOLS_CANDIDATES[1],
    )
    // The Command Line Tools win when both are there: that is what a plain
    // `xcode-select` install leaves selected, and the narrower of the two.
    expect(developerToolsBin(() => true)).toBe(DEVELOPER_TOOLS_CANDIDATES[0])
    expect(DEVELOPER_TOOLS_CANDIDATES[0]).toBe('/Library/Developer/CommandLineTools/usr/bin')
  })

  test('a path with a space in it cannot break out of the command', () => {
    // The command is a string handed to `bash -c` inside the wrapper, so an
    // unquoted path is an injection point rather than a cosmetic problem.
    const command = agentCommand({
      cloneRoot: '/Users/dev/my code/varnick',
      execPath: '/opt/weird path/bun',
      sdkEntry: SDK,
    })
    expect(command).toContain('"/opt/weird path/bun"')
    expect(command).toContain('"/Users/dev/my code/varnick/packages/harness/src/agent.ts"')
  })

  test('a path carrying shell metacharacters is quoted, not interpolated', () => {
    const command = agentCommand({
      cloneRoot: '/tmp/a"; rm -rf /; echo "',
      execPath: BUN,
      sdkEntry: SDK,
    })
    // Quoted through JSON, so the quote that would end the argument is escaped.
    expect(command).toContain('\\"')
    expect(command.split('rm -rf').length - 1).toBe(1)
    expect(command).not.toMatch(/[^\\]"; rm/)
  })
})

describe('the overlay carries no secret', () => {
  test('only what the wrapper changed crosses, not the whole environment', () => {
    const base = { PATH: '/usr/bin', HOME: '/Users/dev', LANG: 'en_GB.UTF-8' }
    const wrapped = { ...base, HTTPS_PROXY: 'http://srt:tok@localhost:51418' }
    expect(sandboxEnvOverlay(wrapped, base)).toEqual({
      HTTPS_PROXY: 'http://srt:tok@localhost:51418',
    })
  })

  test('an unchanged environment produces an empty overlay', () => {
    const base = { PATH: '/usr/bin', ANTHROPIC_API_KEY: LOOKS_LIKE_A_KEY }
    expect(sandboxEnvOverlay({ ...base }, base)).toEqual({})
  })

  test('the credential variable can never ride the overlay, however it got there', () => {
    // The runtime is started by the host, so it inherits whatever the host was
    // launched with — which on a developer machine may include an exported
    // ANTHROPIC_API_KEY. The overlay crosses a pipe; the credential may not.
    const base = { PATH: '/usr/bin' }
    const wrapped = {
      ...base,
      [CREDENTIAL_ENV_VAR_NAME]: LOOKS_LIKE_A_KEY,
      HTTPS_PROXY: 'http://srt:tok@localhost:51418',
    }
    const overlay = sandboxEnvOverlay(wrapped, base)
    expect(overlay).toEqual({ HTTPS_PROXY: 'http://srt:tok@localhost:51418' })
    expect(JSON.stringify(overlay)).not.toContain('sk-ant')
  })

  test('a variable the wrapper cleared is not smuggled through as undefined', () => {
    const base = { PATH: '/usr/bin', NOISY: 'yes' }
    const overlay = sandboxEnvOverlay({ PATH: '/usr/bin' }, base)
    expect(Object.keys(overlay)).toEqual([])
  })

  test('the name matches the one the Rust host injects', () => {
    // Mirrored as ENV_VAR in src-tauri/src/credential.rs.
    expect(CREDENTIAL_ENV_VAR_NAME).toBe('ANTHROPIC_API_KEY')
  })
})

/*
  Isolation from the developer's own Claude Code configuration.

  The reason this is a boundary and not a preference: varnick was measured
  launching a Claude Code process with nine inherited CLAUDE_* variables in its
  environment, none of them chosen by varnick and none of them visible to the
  person running it. Behaviour that depends on what happens to be exported in
  the terminal you launched from is behaviour nobody else can reproduce.

  Everything here is a pure function over an environment record. Nothing spawns
  a process, and in particular nothing here starts a Claude Code session — the
  rule ADR-0003's last consequence exists for.
*/
describe('the agent does not inherit the developer\'s Claude Code configuration', () => {
  const developerEnvironment = {
    PATH: '/usr/bin',
    HOME: '/Users/dev',
    [CREDENTIAL_ENV_VAR_NAME]: LOOKS_LIKE_A_KEY,
    CLAUDECODE: '1',
    CLAUDE_CODE_ENTRYPOINT: 'cli',
    CLAUDE_CODE_SESSION_ID: 'a-session-that-is-not-ours',
    CLAUDE_EFFORT: 'xhigh',
    CLAUDE_CONFIG_DIR: '/Users/dev/.claude',
    ANTHROPIC_BASE_URL: 'https://proxy.example.invalid',
    ANTHROPIC_MODEL: 'something-else',
  }

  test('isolated is the default, and takes a flag to leave', () => {
    expect(inheritsClaudeConfig({})).toBe(false)
    expect(inheritsClaudeConfig({ [INHERIT_CLAUDE_CONFIG_ENV_VAR]: '1' })).toBe(true)
    // An empty or explicitly off value is not a flag anyone meant to set. A
    // variable left over as `0` must not silently un-isolate a run.
    expect(inheritsClaudeConfig({ [INHERIT_CLAUDE_CONFIG_ENV_VAR]: '' })).toBe(false)
    expect(inheritsClaudeConfig({ [INHERIT_CLAUDE_CONFIG_ENV_VAR]: '0' })).toBe(false)
    expect(inheritsClaudeConfig({ [INHERIT_CLAUDE_CONFIG_ENV_VAR]: 'false' })).toBe(false)
  })

  test('no filesystem settings are read, and no MCP configuration but ours', () => {
    // settingSources: [] is the SDK's own isolation mode — it drops
    // ~/.claude/settings.json, the clone's .claude/settings.json and
    // .claude/settings.local.json, and with them every hook and every CLAUDE.md.
    // strictMcpConfig drops .mcp.json, user settings and plugin MCP servers.
    expect(agentConfigurationOptions(false)).toEqual({
      settingSources: [],
      strictMcpConfig: true,
    })
  })

  test('the flag stops overriding rather than opting into something new', () => {
    // Inheriting is the CLI's own default behaviour, which is what "inherit"
    // has to mean: varnick stops passing the two options and gets whatever
    // Claude Code would have done on its own.
    expect(agentConfigurationOptions(true)).toEqual({})
  })

  test('every CLAUDE and ANTHROPIC variable is dropped except the credential', () => {
    const env = agentEnvironment(developerEnvironment, { cloneRoot: CLONE, inherit: false })

    // The credential is the one thing that must survive: it is what the host
    // injected, and it is how the agent authenticates.
    expect(env[CREDENTIAL_ENV_VAR_NAME]).toBe(LOOKS_LIKE_A_KEY)

    for (const name of [
      'CLAUDECODE',
      'CLAUDE_CODE_ENTRYPOINT',
      'CLAUDE_CODE_SESSION_ID',
      'CLAUDE_EFFORT',
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_MODEL',
    ]) {
      expect(env[name]).toBeUndefined()
    }

    // Everything else is left alone. PATH and HOME are what the interpreter
    // needs, and scrubbing beyond the two prefixes would be guessing.
    expect(env.PATH).toBe('/usr/bin')
    expect(env.HOME).toBe('/Users/dev')
  })

  test('a variable nobody has thought of yet is dropped too', () => {
    // Prefix rule rather than a list, so a variable Claude Code grows next
    // release is isolated by the rule that already shipped.
    const env = agentEnvironment(
      { CLAUDE_SOMETHING_INVENTED_LATER: 'yes', ANTHROPIC_ALSO_NEW: 'yes' },
      { cloneRoot: CLONE, inherit: false },
    )
    expect(env.CLAUDE_SOMETHING_INVENTED_LATER).toBeUndefined()
    expect(env.ANTHROPIC_ALSO_NEW).toBeUndefined()
  })

  test('the config directory is varnick\'s own, inside the clone', () => {
    const env = agentEnvironment(developerEnvironment, { cloneRoot: CLONE, inherit: false })
    expect(env[CLAUDE_CONFIG_DIR_ENV_VAR]).toBe(claudeConfigDir(CLONE))
    expect(claudeConfigDir(CLONE)).toBe(join(CLONE, CLAUDE_CONFIG_RELATIVE_PATH))
    // Inside the clone is not a preference. Measured under the generated
    // policy: `mkdir` anywhere under $HOME is "Operation not permitted", and
    // the clone and the temp directory are the only writable trees. A Claude
    // Code process pointed at ~/.claude cannot write its own session store.
    expect(claudeConfigDir(CLONE).startsWith(CLONE)).toBe(true)
  })

  test('the config directory is varnick\'s own under the flag as well', () => {
    // The flag inherits configuration; it does not move the config directory,
    // because ~/.claude is unwritable inside the Sandbox either way and a
    // Claude Code that cannot write its config directory does not run at all.
    const env = agentEnvironment(developerEnvironment, { cloneRoot: CLONE, inherit: true })
    expect(env[CLAUDE_CONFIG_DIR_ENV_VAR]).toBe(claudeConfigDir(CLONE))
  })

  test('the flag leaves the rest of the environment as the developer had it', () => {
    const env = agentEnvironment(developerEnvironment, { cloneRoot: CLONE, inherit: true })
    expect(env.CLAUDECODE).toBe('1')
    expect(env.ANTHROPIC_BASE_URL).toBe('https://proxy.example.invalid')
    expect(env[CREDENTIAL_ENV_VAR_NAME]).toBe(LOOKS_LIKE_A_KEY)
  })

  test('the flag itself is not passed on to the agent', () => {
    // It is varnick's switch, not Claude Code's, and an agent that can read it
    // is an agent whose behaviour depends on it.
    for (const inherit of [false, true]) {
      const env = agentEnvironment(
        { ...developerEnvironment, [INHERIT_CLAUDE_CONFIG_ENV_VAR]: '1' },
        { cloneRoot: CLONE, inherit },
      )
      expect(env[INHERIT_CLAUDE_CONFIG_ENV_VAR]).toBeUndefined()
    }
  })

  test('what counts as inherited is what varnick did not put there', () => {
    // The two varnick owns are not the developer's, whatever their names look
    // like: the credential the host injected, and the config directory the
    // Sandbox forces. The boundary probe counts this set inside the real
    // confined process, so a second definition here would be one that drifts.
    expect(inheritedConfigVariables(developerEnvironment)).toEqual([
      'CLAUDECODE',
      'CLAUDE_CODE_ENTRYPOINT',
      'CLAUDE_CODE_SESSION_ID',
      'CLAUDE_EFFORT',
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_MODEL',
    ])

    // The claim, stated as the probe states it: after the scrub, none.
    const env = agentEnvironment(developerEnvironment, { cloneRoot: CLONE, inherit: false })
    expect(inheritedConfigVariables(env)).toEqual([])
  })

  test('the config directory is a path, not a place anything is read from here', () => {
    // The whole point of the seam: this module computes a string. Reading
    // configuration, running a SessionStart hook, or starting a session all
    // happen in the Claude Code process, which is inside srt. Nothing in the
    // Harness reads the file, so agent-authored configuration has no route to
    // an unconfined process — see ADR-0003's last consequence.
    expect(typeof claudeConfigDir(CLONE)).toBe('string')
  })
})

describe('what a Session threw, classified', () => {
  test('a thrown 401 goes through the shared classifier rather than a second rule', () => {
    // The SDK names most failures itself. An exception carries only prose, and
    // prose is where a 401 body would be — so `credentialRejection` decides,
    // and nothing but its verdict is kept.
    expect(failureOfThrown(new Error(`401 invalid x-api-key ${LOOKS_LIKE_A_KEY}`))).toBe(
      'authentication',
    )
    expect(failureOfThrown({ status: 401 })).toBe('authentication')
    expect(failureOfThrown(new Error('socket hang up'))).toBe('execution')
  })

  test('whatever was thrown, the sentence shown is the authored one', () => {
    expect(turnFailureMessage(failureOfThrown(new Error(LOOKS_LIKE_A_KEY)))).not.toContain('sk-ant')
    expect(turnFailureMessage(failureOfThrown({ status: 401, body: LOOKS_LIKE_A_KEY }))).not.toContain(
      'sk-ant',
    )
  })
})

// ---------------------------------------------------------------------------
// The agent host's control loop
// ---------------------------------------------------------------------------

/*
  Still no process. `serveTurns` takes the Session as a port, so these tests
  drive the whole loop — a prompt in, deltas out, an interrupt — with no Claude
  Code executable anywhere. That is ADR-0003's last consequence applied to the
  test suite: a test that opened a session to check a turn would be a session
  outside srt on a developer's machine.
*/

/** A stream a test pushes into and closes by hand. */
function pushable<T>() {
  const queued: T[] = []
  let wake: (() => void) | null = null
  let closed = false

  return {
    push(value: T) {
      queued.push(value)
      wake?.()
    },
    close() {
      closed = true
      wake?.()
    },
    async *[Symbol.asyncIterator](): AsyncIterator<T> {
      for (;;) {
        while (queued.length > 0) yield queued.shift() as T
        if (closed) return
        await new Promise<void>((resolve) => {
          wake = resolve
        })
      }
    },
  }
}

/** What a session that has a plan reports about its windows. */
const BOTH_WINDOWS: PlanUsageReport = {
  rate_limits_available: true,
  rate_limits: { five_hour: { utilization: 11 }, seven_day: { utilization: 54 } },
}

/** A Session that records what was asked of it and answers nothing. */
function fakeSession(
  usage: () => Promise<PlanUsageReport> = async () => BOTH_WINDOWS,
  contextTokens: () => Promise<number | null> = async () => null,
) {
  const asked: string[] = []
  const port: AgentSessionPort = {
    prompt: (text) => {
      asked.push(`prompt:${text}`)
    },
    setModel: async (model) => {
      asked.push(`model:${model}`)
    },
    setEffort: async (effort) => {
      asked.push(`effort:${effort}`)
    },
    interrupt: async () => {
      asked.push('interrupt')
    },
    usage: async () => {
      asked.push('usage')
      return usage()
    },
    contextTokens: () => {
      asked.push('contextTokens')
      return contextTokens()
    },
  }
  return { port, asked }
}

const runTurnLine = (turnId: string, prompt: string, model = 'claude-opus-5', effort = 'xhigh') =>
  `${JSON.stringify({ kind: 'run-turn', turnId, prompt, model, effort })}\n`

const textDelta = (text: string) => ({
  type: 'stream_event',
  event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
})

const result = (text: string) => ({
  type: 'result',
  subtype: 'success',
  is_error: false,
  result: text,
  usage: { input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
})

/** Run the loop over a scripted exchange and collect the events it wrote. */
async function serve(
  script: (input: {
    control: ReturnType<typeof pushable<string>>
    messages: ReturnType<typeof pushable<unknown>>
    asked: string[]
    /** What the `PostCompact` hook would report, from outside the message stream. */
    summarised: (summary: string) => void
  }) => Promise<void>,
  usage?: () => Promise<PlanUsageReport>,
  contextTokens?: () => Promise<number | null>,
) {
  const control = pushable<string>()
  const messages = pushable<unknown>()
  const { port, asked } = fakeSession(usage, contextTokens)
  const written: TurnEvent[] = []
  // Everything the loop wrote, unfiltered. The channel carries more than Turn
  // events now, and a helper that only kept those could not see the rest.
  const lines: string[] = []
  let report: (summary: string) => void = () => {}

  const served = serveTurns({
    control,
    messages,
    session: port,
    compactionSummaries: (deliver) => {
      report = deliver
    },
    write: (line) => {
      lines.push(line)
      const event = parseTurnEvent(JSON.parse(line))
      if (event !== null) written.push(event)
    },
  })

  await script({ control, messages, asked, summarised: (summary) => report(summary) })
  control.close()
  messages.close()
  await served
  return { written, asked, lines }
}

const readUsageLine = (requestId: string) =>
  `${JSON.stringify({ kind: 'read-plan-usage', requestId })}\n`

/** The plan-usage answers the loop wrote, in order. */
const usageAnswers = (lines: readonly string[]) =>
  lines.map((line) => parsePlanUsageAnswer(JSON.parse(line))).filter((answer) => answer !== null)

/** Let the loops run until they have nothing left to do. */
const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 5))

describe('a turn rides the session that is already open', () => {
  test('a prompt is put on the running session, not on a new one', async () => {
    const { asked } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(asked).toContain('prompt:hello')
  })

  test('the model and the effort are applied before the prompt goes out', async () => {
    // This is what makes "a change mid-turn applies to the next turn" true: the
    // values arrive with the turn, so the turn in flight is never reconfigured
    // underneath itself.
    const { asked } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello', 'claude-sonnet-5', 'low'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(asked).toEqual(['model:claude-sonnet-5', 'effort:low', 'prompt:hello'])
  })

  test('the answer arrives in pieces and then completes', async () => {
    const { written } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(textDelta('Hel'))
      messages.push(textDelta('lo'))
      messages.push(result('Hello'))
      await settle()
    })
    expect(written.map((e) => e.kind)).toEqual(['delta', 'delta', 'done'])
    expect(written.at(-1)).toMatchObject({ kind: 'done', turnId: 't1', text: 'Hello' })
  })

  test('messages arriving with no turn running are not attributed to one', async () => {
    // The session emits its own init and status messages. A delta with no turn
    // to belong to must not become the first word of the next one.
    const { written } = await serve(async ({ messages }) => {
      messages.push({ type: 'system', subtype: 'init' })
      messages.push(textDelta('stray'))
      await settle()
    })
    expect(written).toEqual([])
  })

  test('a second turn is its own turn, and the first one is not still listening', async () => {
    const { written } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'one'))
      await settle()
      messages.push(result('first'))
      await settle()
      control.push(runTurnLine('t2', 'two'))
      await settle()
      messages.push(textDelta('second'))
      messages.push(result('second'))
      await settle()
    })
    expect(written.filter((e) => e.turnId === 't1').map((e) => e.kind)).toEqual(['done'])
    expect(written.filter((e) => e.turnId === 't2').map((e) => e.kind)).toEqual(['delta', 'done'])
  })
})

describe('interrupting', () => {
  test('an interrupt reaches the session it names', async () => {
    const { asked } = await serve(async ({ control }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      control.push(`${JSON.stringify({ kind: 'interrupt', turnId: 't1' })}\n`)
      await settle()
    })
    expect(asked).toContain('interrupt')
  })

  test('an interrupt naming a turn that is not running does nothing', async () => {
    // A stale interrupt from an abandoned turn must not stop the one that
    // replaced it.
    const { asked } = await serve(async ({ control }) => {
      control.push(runTurnLine('t2', 'hello'))
      await settle()
      control.push(`${JSON.stringify({ kind: 'interrupt', turnId: 't1' })}\n`)
      await settle()
    })
    expect(asked).not.toContain('interrupt')
  })

  test('what had already streamed is still on the wire when the interrupt lands', async () => {
    // The machine folds `partial` into the transcript, so keeping the partial
    // means having emitted it as it arrived rather than at the end.
    const { written } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(textDelta('half an ans'))
      await settle()
      control.push(`${JSON.stringify({ kind: 'interrupt', turnId: 't1' })}\n`)
      await settle()
    })
    expect(written).toEqual([{ kind: 'delta', turnId: 't1', text: 'half an ans' }])
  })
})

/*
  Plan usage, on the same channel, for the same reason.

  These tests are the shape of ADR-0003's last consequence: the loop is handed a
  session it did not create, and the only way it can answer a usage read is to
  ask that one. There is no `query()` in reach — the port has five methods and
  none of them opens anything — so a test proving the answer came back is a test
  proving no second session was needed to get it.
*/
describe('plan usage rides the session that is already open', () => {
  test('a read asks the running session and answers with what the plan said', async () => {
    const { asked, lines } = await serve(async ({ control }) => {
      control.push(readUsageLine('u1'))
      await settle()
    })
    expect(asked).toEqual(['usage'])
    expect(usageAnswers(lines)).toEqual([
      { requestId: 'u1', usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' } },
    ])
  })

  test('the answer names the read it belongs to', async () => {
    const { lines } = await serve(async ({ control }) => {
      control.push(readUsageLine('u1'))
      await settle()
      control.push(readUsageLine('u2'))
      await settle()
    })
    expect(usageAnswers(lines).map((answer) => answer.requestId)).toEqual(['u1', 'u2'])
  })

  test('a session with no plan to report answers nothing rather than a figure', async () => {
    // API key, Bedrock and Vertex sessions have no plan windows. The read fails
    // and the machine keeps whatever was last known, which may be nothing.
    const { lines } = await serve(
      async ({ control }) => {
        control.push(readUsageLine('u1'))
        await settle()
      },
      async () => ({ rate_limits_available: false, rate_limits: null }),
    )
    expect(usageAnswers(lines)).toEqual([{ requestId: 'u1', usage: null }])
  })

  test('a session that threw is still answered, so nobody waits on a reply that is not coming', async () => {
    const { lines } = await serve(
      async ({ control }) => {
        control.push(readUsageLine('u1'))
        await settle()
      },
      async () => {
        throw new Error('the session is gone')
      },
    )
    expect(usageAnswers(lines)).toEqual([{ requestId: 'u1', usage: null }])
  })

  test('nothing the session threw is quoted back', async () => {
    // The same rule as a failed Turn. This one runs against the API, so the
    // prose it throws is where a rejected key would be.
    const { lines } = await serve(
      async ({ control }) => {
        control.push(readUsageLine('u1'))
        await settle()
      },
      async () => {
        throw new Error(`401 unauthorized: ${LOOKS_LIKE_A_KEY}`)
      },
    )
    expect(lines.join('')).not.toContain('sk-ant')
    expect(lines.join('')).not.toContain('401')
  })

  test('a read does not disturb the turn that is streaming', async () => {
    const { written, lines } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(textDelta('Hel'))
      control.push(readUsageLine('u1'))
      await settle()
      messages.push(textDelta('lo'))
      messages.push(result('Hello'))
      await settle()
    })
    expect(written.map((e) => e.kind)).toEqual(['delta', 'delta', 'done'])
    expect(written.at(-1)).toMatchObject({ kind: 'done', turnId: 't1', text: 'Hello' })
    expect(usageAnswers(lines)).toHaveLength(1)
  })

  test('an interrupt is still answered while a read is in flight', async () => {
    /*
      The control loop must not be held by a read. An interrupt costing the rest
      of a usage round-trip is the same failure interrupting was built to avoid,
      so the read is started and not waited on.
    */
    let release: (() => void) | null = null
    const { asked } = await serve(
      async ({ control, asked: sofar }) => {
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        control.push(readUsageLine('u1'))
        await settle()
        control.push(`${JSON.stringify({ kind: 'interrupt', turnId: 't1' })}\n`)
        await settle()
        // The read has not answered yet and the interrupt has already landed.
        expect(sofar).toContain('interrupt')
        release?.()
        await settle()
      },
      () =>
        new Promise<PlanUsageReport>((resolve) => {
          release = () => resolve(BOTH_WINDOWS)
        }),
    )
    expect(asked).toEqual(['model:claude-opus-5', 'effort:xhigh', 'prompt:hello', 'usage', 'interrupt'])
  })

  test('a read is not a turn, and does not become one', async () => {
    // Nothing about a usage read may reach the Session's transcript. It is a
    // question about the plan, not something the developer said or was told.
    const { written } = await serve(async ({ control }) => {
      control.push(readUsageLine('u1'))
      await settle()
    })
    expect(written).toEqual([])
  })
})

describe('a compaction rides the same session a turn does', () => {
  const compactLine = (turnId: string) => `${JSON.stringify({ kind: 'compact', turnId })}\n`

  const boundary = (post?: number) => ({
    type: 'system',
    subtype: 'compact_boundary',
    compact_metadata: {
      trigger: 'manual',
      pre_tokens: 812_000,
      ...(post === undefined ? {} : { post_tokens: post }),
    },
  })

  test('summarising is a command on the session already open, not a second one', async () => {
    // The whole of ADR-0003's last consequence. The only thing that happens on
    // a compaction is a prompt onto the pipe the confined process is reading.
    const { asked } = await serve(async ({ control }) => {
      control.push(compactLine('c1'))
      await settle()
    })
    expect(asked).toEqual(['prompt:/compact'])
  })

  test('a compaction reports the summary and what the context now measures', async () => {
    const { written } = await serve(async ({ control, messages, summarised }) => {
      control.push(compactLine('c1'))
      await settle()
      summarised('Earlier: the developer wired the sandbox policy.')
      messages.push(boundary(4_000))
      await settle()
    })
    expect(written).toEqual([
      {
        kind: 'compacted',
        turnId: 'c1',
        summary: 'Earlier: the developer wired the sandbox policy.',
        tokensUsed: 4_000,
      },
    ])
  })

  test('a boundary that reported no size is measured by asking the session', async () => {
    // Never estimated. The figure is either the compaction's own or the
    // Session's answer to what it now holds.
    const { written, asked } = await serve(
      async ({ control, messages, summarised }) => {
        control.push(compactLine('c1'))
        await settle()
        summarised('a summary')
        messages.push(boundary())
        await settle()
      },
      undefined,
      async () => 5_500,
    )
    expect(asked).toContain('contextTokens')
    expect(written).toEqual([
      { kind: 'compacted', turnId: 'c1', summary: 'a summary', tokensUsed: 5_500 },
    ])
  })

  test('the compaction is not asked how big it is when it already said', async () => {
    const { asked } = await serve(async ({ control, messages, summarised }) => {
      control.push(compactLine('c1'))
      await settle()
      summarised('a summary')
      messages.push(boundary(4_000))
      await settle()
    })
    expect(asked).not.toContain('contextTokens')
  })

  test('a compaction nobody could measure fails rather than showing a figure it invented', async () => {
    const { written } = await serve(
      async ({ control, messages, summarised }) => {
        control.push(compactLine('c1'))
        await settle()
        summarised('a summary')
        messages.push(boundary())
        await settle()
      },
      undefined,
      async () => null,
    )
    expect(written).toEqual([
      { kind: 'failed', turnId: 'c1', failure: 'compaction-unmeasured' },
    ])
  })

  test('a session that throws when asked its size is the same answer as no answer', async () => {
    const { written } = await serve(
      async ({ control, messages, summarised }) => {
        control.push(compactLine('c1'))
        await settle()
        summarised('a summary')
        messages.push(boundary())
        await settle()
      },
      async () => {
        throw new Error('the control request was refused')
      },
    )
    expect(written).toEqual([
      { kind: 'failed', turnId: 'c1', failure: 'compaction-unmeasured' },
    ])
  })

  test('a compaction that never happened is a failure and nothing else', async () => {
    // Nothing is emitted that Core could turn into a transcript, which is what
    // makes "the conversation is unchanged" a property of the wire rather than
    // of whoever reads it.
    const { written } = await serve(async ({ control, messages }) => {
      control.push(compactLine('c1'))
      await settle()
      messages.push({ type: 'system', subtype: 'status', status: null, compact_result: 'failed' })
      await settle()
    })
    expect(written).toEqual([{ kind: 'failed', turnId: 'c1', failure: 'compaction' }])
  })

  test('the summary may arrive after the boundary and still complete the compaction', async () => {
    const { written } = await serve(async ({ control, messages, summarised }) => {
      control.push(compactLine('c1'))
      await settle()
      messages.push(boundary(4_000))
      await settle()
      summarised('a summary')
      await settle()
    })
    expect(written).toEqual([
      { kind: 'compacted', turnId: 'c1', summary: 'a summary', tokensUsed: 4_000 },
    ])
  })

  test('a summary reported with no compaction running is not attributed to one', async () => {
    // Auto-compaction fires the same hook. A conversation nobody asked to
    // compact must not be rewritten because the window filled up.
    const { written } = await serve(async ({ messages, summarised }) => {
      summarised('an auto-compaction happened')
      messages.push(boundary(4_000))
      await settle()
    })
    expect(written).toEqual([])
  })

  test('a compaction ends exactly once, however much the session keeps saying', async () => {
    const { written } = await serve(async ({ control, messages, summarised }) => {
      control.push(compactLine('c1'))
      await settle()
      summarised('a summary')
      messages.push(boundary(4_000))
      await settle()
      messages.push(boundary(9_000))
      summarised('another summary')
      await settle()
    })
    expect(written).toHaveLength(1)
  })

  test('an interrupt reaches a compaction by name, like any other turn', async () => {
    const { asked } = await serve(async ({ control }) => {
      control.push(compactLine('c1'))
      await settle()
      control.push(`${JSON.stringify({ kind: 'interrupt', turnId: 'c1' })}\n`)
      await settle()
    })
    expect(asked).toContain('interrupt')
  })

  test('a session that refuses the compaction fails it rather than hanging it', async () => {
    const control = pushable<string>()
    const messages = pushable<unknown>()
    const written: TurnEvent[] = []
    const served = serveTurns({
      control,
      messages,
      session: {
        prompt: () => {
          throw new Error('401 unauthorized')
        },
        setModel: async () => {},
        setEffort: async () => {},
        usage: async () => BOTH_WINDOWS,
        interrupt: async () => {},
        contextTokens: async () => null,
      },
      write: (line) => {
        const event = parseTurnEvent(JSON.parse(line))
        if (event !== null) written.push(event)
      },
    })
    control.push(compactLine('c1'))
    await settle()
    control.close()
    messages.close()
    await served

    expect(written).toEqual([{ kind: 'failed', turnId: 'c1', failure: 'authentication' }])
  })
})

describe('the control channel refuses what it does not understand', () => {
  test('a line that is not a control request is ignored rather than acted on', async () => {
    const { asked } = await serve(async ({ control }) => {
      control.push('not json\n')
      control.push(`${JSON.stringify({ kind: 'exec', command: 'rm -rf /' })}\n`)
      await settle()
    })
    expect(asked).toEqual([])
  })

  test('a request split across two chunks is still one request', async () => {
    const line = runTurnLine('t1', 'hello')
    const { asked } = await serve(async ({ control }) => {
      control.push(line.slice(0, 12))
      await settle()
      control.push(line.slice(12))
      await settle()
    })
    expect(asked).toContain('prompt:hello')
  })

  test('a session that refuses the prompt fails the turn rather than hanging it', async () => {
    const control = pushable<string>()
    const messages = pushable<unknown>()
    const written: TurnEvent[] = []
    const served = serveTurns({
      control,
      messages,
      session: {
        prompt: () => {
          throw new Error('401 unauthorized')
        },
        setModel: async () => {},
        setEffort: async () => {},
        interrupt: async () => {},
        usage: async () => BOTH_WINDOWS,
        contextTokens: async () => null,
      },
      write: (line) => {
        const event = parseTurnEvent(JSON.parse(line))
        if (event !== null) written.push(event)
      },
    })
    control.push(runTurnLine('t1', 'hello'))
    await settle()
    control.close()
    messages.close()
    await served

    // A turn that was sent and never answered is the worst available state:
    // `sending` for ever, with nothing to retry or dismiss.
    expect(written).toEqual([{ kind: 'failed', turnId: 't1', failure: 'authentication' }])
  })
})
