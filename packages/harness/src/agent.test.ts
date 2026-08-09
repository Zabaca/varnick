import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  developerToolsBin,
  AGENT_ENTRY_RELATIVE_PATH,
  CLAUDE_CONFIG_DIR_ENV_VAR,
  CLAUDE_CONFIG_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAMES,
  DEVELOPER_TOOLS_CANDIDATES,
  INHERIT_CLAUDE_CONFIG_ENV_VAR,
  agentCommand,
  agentConfigurationOptions,
  agentEntryPath,
  agentEnvironment,
  agentSdkEntry,
  claudeConfigDir,
  inheritedConfigVariables,
  inheritsClaudeConfig,
  failureOfThrown,
  lastSessionPath,
  rememberSession,
  resumableSession,
  sandboxEnvOverlay,
  serveTurns,
  type AgentSessionPort,
} from './agent.ts'
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

/** A value shaped like a subscription token, for the same reason. */
const LOOKS_LIKE_A_TOKEN = ['sk-', 'ant-oat01-NEVER-LET-THIS-OUT'].join('')

/** The two variables a credential can arrive in, named by what they are. */
const [API_KEY_VAR, SUBSCRIPTION_VAR] = CREDENTIAL_ENV_VAR_NAMES

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
    expect(developerToolsBin((path) => path === `${DEVELOPER_TOOLS_CANDIDATES[1]}/git`)).toBe(
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

  test('the names match the ones the Rust host injects', () => {
    // Taken from CREDENTIAL_ENV_VARS in ./credentials.ts and pinned here
    // against the literals, because the third copy — API_KEY_ENV_VAR and
    // SUBSCRIPTION_ENV_VAR in src-tauri/src/credential.rs — is in a language
    // this cannot read. Both are authentication variables the Agent SDK reads.
    expect([...CREDENTIAL_ENV_VAR_NAMES]).toEqual(['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'])
  })

  test('no credential variable can ride the overlay, however it got there', () => {
    // The runtime is started by the host, so it inherits whatever the host was
    // launched with — which on a developer machine may include an exported
    // ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN. The overlay crosses a pipe;
    // neither kind of credential may.
    const base = { PATH: '/usr/bin' }
    const wrapped = {
      ...base,
      [API_KEY_VAR]: LOOKS_LIKE_A_KEY,
      [SUBSCRIPTION_VAR]: LOOKS_LIKE_A_TOKEN,
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
    [API_KEY_VAR]: LOOKS_LIKE_A_KEY,
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
    expect(env[API_KEY_VAR]).toBe(LOOKS_LIKE_A_KEY)

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

  test('a subscription token survives the scrub that its own name matches', () => {
    /*
      The failure ADR-0011's ticket names, and it has no error anywhere: the
      isolation drops every `CLAUDE*` variable by prefix, and the variable the
      Agent SDK reads a subscription from is `CLAUDE_CODE_OAUTH_TOKEN`. A
      credential varnick injected has to be owned rather than inherited, or the
      scrub takes away the thing that authenticates and the symptom is "the
      subscription token does nothing".
    */
    const env = agentEnvironment(
      {
        PATH: '/usr/bin',
        [SUBSCRIPTION_VAR]: LOOKS_LIKE_A_TOKEN,
        CLAUDECODE: '1',
        CLAUDE_CODE_ENTRYPOINT: 'cli',
      },
      { cloneRoot: CLONE, inherit: false },
    )
    expect(env[SUBSCRIPTION_VAR]).toBe(LOOKS_LIKE_A_TOKEN)
    expect(env.CLAUDECODE).toBeUndefined()
    expect(env.CLAUDE_CODE_ENTRYPOINT).toBeUndefined()
  })

  test('the agent spawned under a subscription is handed no API key', () => {
    // The spawn removes the other authentication variable rather than leaving
    // an inherited one beside the token — see credential.rs. What arrives here
    // is one credential, and what leaves is the same one.
    const env = agentEnvironment(
      { PATH: '/usr/bin', [SUBSCRIPTION_VAR]: LOOKS_LIKE_A_TOKEN },
      { cloneRoot: CLONE, inherit: false },
    )
    expect(env[API_KEY_VAR]).toBeUndefined()
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
    expect(env[API_KEY_VAR]).toBe(LOOKS_LIKE_A_KEY)
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
    // The ones varnick owns are not the developer's, whatever their names look
    // like: either credential variable the host may have injected, and the
    // config directory the Sandbox forces. The boundary probe counts this set
    // inside the real confined process, so a second definition here would drift.
    expect(inheritedConfigVariables({ ...developerEnvironment, [SUBSCRIPTION_VAR]: LOOKS_LIKE_A_TOKEN })).toEqual([
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

/** A Session that records what was asked of it and answers nothing. */
function fakeSession(contextTokens: () => Promise<number | null> = async () => null) {
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
  contextTokens?: () => Promise<number | null>,
  /** Whether this run was opened by resuming — what the report carries. */
  resumed = false,
) {
  const control = pushable<string>()
  const messages = pushable<unknown>()
  const { port, asked } = fakeSession(contextTokens)
  /** Every session id the loop handed over to be written down, in order. */
  const started: string[] = []
  const written: TurnEvent[] = []
  // Everything the loop wrote, unfiltered. The channel carries more than Turn
  // events now, and a helper that only kept those could not see the rest.
  const lines: string[] = []
  let report: (summary: string) => void = () => {}
  /** Every list of secret names the loop handed over, in order. */
  const described: (readonly string[])[] = []

  const served = serveTurns({
    control,
    messages,
    session: port,
    compactionSummaries: (deliver) => {
      report = deliver
    },
    secretsDescribed: (names) => {
      described.push(names)
    },
    resumed,
    sessionStarted: (sessionId) => {
      started.push(sessionId)
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
  return { written, asked, lines, described, started }
}

const describeSecretsLine = (names: readonly string[], extra: Record<string, unknown> = {}) =>
  `${JSON.stringify({ kind: 'describe-secrets', names, ...extra })}\n`

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
    //
    // The init message is now read rather than dropped — see the runtime report
    // below — and it still produces no event here, because there is no turn to
    // stamp one with. That is the whole reason it is held and replayed.
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

describe('the agent picks up the conversation it was in', () => {
  const CLONE = '/tmp/clone'
  const ID = '788cec56-9b2b-4e22-ad78-2c117bace2c8'

  /** A store with one conversation in it, addressed the way the CLI lays them out. */
  const store = (
    pointer: string | null,
    transcripts: readonly string[] = [ID],
    folder = '-tmp-clone',
  ) => ({
    readFile: (path: string) => {
      if (path === lastSessionPath(CLONE) && pointer !== null) return pointer
      throw new Error('ENOENT')
    },
    readDir: () => [folder],
    exists: (path: string) => transcripts.some((one) => path.endsWith(`${folder}/${one}.jsonl`)),
  })

  test('the id written down is the id offered back', () => {
    const written: Record<string, string> = {}
    rememberSession(CLONE, ID, (path, contents) => {
      written[path] = contents
    })
    expect(written[lastSessionPath(CLONE)]).toContain(ID)
    expect(resumableSession(CLONE, store(written[lastSessionPath(CLONE)] ?? null))).toBe(ID)
  })

  test('a first run resumes nothing rather than failing', () => {
    expect(resumableSession(CLONE, store(null))).toBeNull()
  })

  test('a pointer whose transcript is gone is not resumed', () => {
    /*
      The condition that keeps a bad launch off the table. `resume` against an
      id the CLI has never heard of fails the whole session — so a pointer left
      behind by a cleared store would turn "the agent forgets" into "the agent
      will not start", which is worse than the bug being fixed.
    */
    expect(resumableSession(CLONE, store(JSON.stringify({ sessionId: ID }), []))).toBeNull()
  })

  test('the transcript is found by id, whatever the CLI called the folder', () => {
    // The folder name is derived from the working directory by a rule the CLI
    // owns and does not document. Matching on it would silently stop working;
    // matching on the id cannot.
    expect(
      resumableSession(CLONE, store(JSON.stringify({ sessionId: ID }), [ID], 'whatever-it-likes')),
    ).toBe(ID)
  })

  test('a pointer this build cannot read is a fresh start, not a crash', () => {
    expect(resumableSession(CLONE, store('not json'))).toBeNull()
    expect(resumableSession(CLONE, store(JSON.stringify({ sessionId: 42 })))).toBeNull()
    expect(resumableSession(CLONE, store(JSON.stringify({})))).toBeNull()
  })

  test('an unwritable store costs the next launch its memory, not this one its life', () => {
    expect(() =>
      rememberSession(CLONE, ID, () => {
        throw new Error('EROFS')
      }),
    ).not.toThrow()
  })

  test('a session with no id is not written down', () => {
    let called = false
    rememberSession(CLONE, '', () => {
      called = true
    })
    expect(called).toBe(false)
  })
})

describe('the runtime describing itself', () => {
  const init = {
    type: 'system',
    subtype: 'init',
    model: 'claude-opus-5',
    tools: ['Read', 'Bash'],
  }

  test('an init that arrives before any turn is replayed onto the first one', async () => {
    /*
      The timing this whole arrangement exists for. The Session emits `init` when
      the Claude Code process starts — which is when the agent is spawned, long
      before a turn exists to stamp it with. Forwarded straight through it would
      be dropped as a message with no turn, and the panel would stay empty for
      the life of the Session, because `init` is sent once and not again.
    */
    const { written } = await serve(async ({ control, messages }) => {
      messages.push(init)
      await settle()
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(written.map((e) => e.kind)).toEqual(['runtime', 'done'])
    expect(written[0]).toMatchObject({ kind: 'runtime', turnId: 't1' })
    expect(written[0]).toHaveProperty('report.model', 'claude-opus-5')
  })

  test('every turn carries the report, not just the first', async () => {
    // Replay rather than a one-shot, so a window opened on the second turn is
    // not a window that never learns what it is talking to.
    const { written } = await serve(async ({ control, messages }) => {
      messages.push(init)
      await settle()
      control.push(runTurnLine('t1', 'one'))
      await settle()
      messages.push(result('first'))
      await settle()
      control.push(runTurnLine('t2', 'two'))
      await settle()
      messages.push(result('second'))
      await settle()
    })
    expect(written.filter((e) => e.kind === 'runtime').map((e) => e.turnId)).toEqual(['t1', 't2'])
  })

  test('an init arriving mid-turn is reported without waiting for the next one', async () => {
    const { written } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(init)
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(written.map((e) => e.kind)).toEqual(['runtime', 'done'])
  })

  test('a later init replaces the earlier one', async () => {
    const { written } = await serve(async ({ control, messages }) => {
      messages.push(init)
      await settle()
      messages.push({ ...init, model: 'claude-sonnet-5' })
      await settle()
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(written[0]).toHaveProperty('report.model', 'claude-sonnet-5')
  })

  test('the session id is handed over to be written down, before any answer', async () => {
    // Before the turn completes, not after. A pointer recorded at the end would
    // lose its conversation to exactly the crash the mirror already survives.
    const { started } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push({ ...init, session_id: 'abc-123' })
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(started).toEqual(['abc-123'])
  })

  test('the report says whether this agent resumed or started new', async () => {
    // Not on the init message — the runtime has no idea it was asked to
    // resume. varnick knows, because varnick asked.
    const fresh = await serve(async ({ control, messages }) => {
      messages.push(init)
      await settle()
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(fresh.written[0]).toHaveProperty('report.resumed', false)

    const carried = await serve(
      async ({ control, messages }) => {
        messages.push(init)
        await settle()
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        messages.push(result('hi'))
        await settle()
      },
      undefined,
      true,
    )
    expect(carried.written[0]).toHaveProperty('report.resumed', true)
  })

  test('an init is never mistaken for something the turn said', async () => {
    // It is not transcript. A report that reached `STREAM_DELTA` would put the
    // runtime's description of itself into the conversation and into the mirror.
    const { written } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(init)
      messages.push(result('hi'))
      await settle()
    })
    expect(written.filter((e) => e.kind === 'delta')).toEqual([])
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
  A "plan usage rides the session that is already open" suite stood here: eight
  tests over a `read-plan-usage` control request, including that a read did not
  disturb a streaming Turn and that an interrupt was still answered while one
  was in flight.

  They demonstrated ADR-0003's last consequence — the loop answers off a session
  it did not create — and that property is still demonstrated, by the Compaction
  suite below, which is on the channel for exactly the same reason and is still
  a thing the product does. Ticket 31 cut the read itself: no credential varnick
  can hold reports plan windows, so there was never a figure at the far end.
*/

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

/*
  ADR-0006's naming end, on the loop that runs inside the Sandbox.

  The agent authors code that names a secret and never holds one. The holding
  half is ticket 12's and is proven in secret-resolution.test.ts and in
  `bun run drive`; what is checked here is the other half — the names arriving,
  and nothing else arriving with them.
*/
describe('the agent is told which secrets exist', () => {
  test('the names reach the process that has to put them in front of the agent', async () => {
    const { described } = await serve(async ({ control }) => {
      control.push(describeSecretsLine(['STRIPE_KEY', 'BILLING_TOKEN']))
      await settle()
    })
    expect(described).toEqual([['STRIPE_KEY', 'BILLING_TOKEN']])
  })

  test('a later list replaces the earlier one rather than adding to it', async () => {
    // What makes a removed secret stop being named. A list that accumulated
    // would have the agent writing code against a key the host can no longer
    // resolve, which fails at run time in a built Surface, far from here.
    const { described } = await serve(async ({ control }) => {
      control.push(describeSecretsLine(['STRIPE_KEY']))
      await settle()
      control.push(describeSecretsLine(['BILLING_TOKEN']))
      await settle()
    })
    expect(described).toEqual([['STRIPE_KEY'], ['BILLING_TOKEN']])
  })

  test('an empty list is delivered, because "there are none" is worth saying', async () => {
    const { described } = await serve(async ({ control }) => {
      control.push(describeSecretsLine([]))
      await settle()
    })
    expect(described).toEqual([[]])
  })

  test('no value can arrive alongside the names, however it is labelled', async () => {
    /*
      The assertion the whole ticket turns on, taken at the boundary of the
      confined process rather than inferred from the parse.

      A value cannot get here because `parseControlRequest` rebuilds this
      request out of `kind` and `names` and reads no other field. So a line
      carrying every shape a value might hide in arrives as names alone — and
      what is checked is not only the delivered list but every byte the loop
      wrote back, because a channel that echoed the line would be a second way
      out.
    */
    const { described, lines } = await serve(async ({ control }) => {
      control.push(
        describeSecretsLine(['STRIPE_KEY'], {
          values: [LOOKS_LIKE_A_KEY],
          STRIPE_KEY: LOOKS_LIKE_A_KEY,
          secrets: { STRIPE_KEY: LOOKS_LIKE_A_KEY },
        }),
      )
      await settle()
    })
    expect(described).toEqual([['STRIPE_KEY']])
    expect(JSON.stringify(described)).not.toContain(LOOKS_LIKE_A_KEY)
    expect(lines.join('')).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('being told about secrets is not a turn, and says nothing to the session', async () => {
    // It is the one request on this channel that tells the confined process a
    // fact rather than asking it for one: nothing is prompted, nothing is
    // answered, and nothing reaches the transcript.
    const { asked, lines, written } = await serve(async ({ control }) => {
      control.push(describeSecretsLine(['STRIPE_KEY']))
      await settle()
    })
    expect(asked).toEqual([])
    expect(lines).toEqual([])
    expect(written).toEqual([])
  })

  test('a malformed list leaves the agent knowing what it knew', async () => {
    // Refused whole rather than partly believed, and refused quietly: the line
    // arrives inside the Sandbox at a live agent, so an unreadable one is
    // dropped exactly like any other.
    const { described } = await serve(async ({ control }) => {
      control.push(describeSecretsLine(['STRIPE_KEY']))
      await settle()
      control.push(`${JSON.stringify({ kind: 'describe-secrets', names: ['A', 7] })}\n`)
      await settle()
    })
    expect(described).toEqual([['STRIPE_KEY']])
  })

  test('a turn still runs on a loop that was never told about secrets', async () => {
    // The naming end is additive. An agent nobody has described secrets to is
    // an agent that knows none, not an agent that cannot answer.
    const { asked } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('hi'))
      await settle()
    })
    expect(asked).toContain('prompt:hello')
  })
})

describe('the real git, ahead of the shim', () => {
  /*
    `/usr/bin/git` is not git. It is an xcode-select shim that reads the symlink
    `/var/select/developer_dir` to find the real binary, and under the denied
    root that link is denied. Measured: the shim exits 1 with "unable to read
    data link", the real binary exits 0. Allowing the link's *target* does not
    help — `/private/var/select` is in the allowlist and the shim still failed —
    because what is refused is reading `/var`, the link one level up. The fix
    here is PATH, which costs the boundary nothing.

    Ticket 18 later added `/var` itself to the read allowlist for exactly that
    denial, so the shim does resolve under the shipped policy again. This stays
    because it is the cheaper of the two and does not depend on it: an agent
    whose `git` works only because a symlink at the filesystem root happens to be
    readable is an agent one policy edit away from having no `git`.
  */

  test('the toolchain goes in front of PATH, where /usr/bin already is', () => {
    const env = agentEnvironment(
      { PATH: '/usr/bin:/bin' },
      { cloneRoot: CLONE, inherit: false, toolsBin: '/toolchain/usr/bin' },
    )
    expect(env.PATH).toBe('/toolchain/usr/bin:/usr/bin:/bin')
  })

  test('a machine with no toolchain keeps the PATH it had', () => {
    // Nothing to lose: no toolchain means no working git to have broken.
    const env = agentEnvironment({ PATH: '/usr/bin' }, { cloneRoot: CLONE, inherit: false, toolsBin: null })
    expect(env.PATH).toBe('/usr/bin')
  })

  test('it looks for git itself, not merely for the directory', () => {
    // A toolchain directory that exists without git in it is not a toolchain,
    // and putting it first would shadow nothing while claiming to fix this.
    const seen: string[] = []
    const found = developerToolsBin((path) => {
      seen.push(path)
      return path === '/Library/Developer/CommandLineTools/usr/bin/git'
    })
    expect(found).toBe('/Library/Developer/CommandLineTools/usr/bin')
    expect(seen.every((path) => path.endsWith('/git'))).toBe(true)
  })

  test('neither location present is null rather than a guess', () => {
    expect(developerToolsBin(() => false)).toBe(null)
  })
})
