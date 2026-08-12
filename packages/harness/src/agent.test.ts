import { describe, expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import {
  developerToolsBin,
  AGENT_ENTRY_RELATIVE_PATH,
  CLAUDE_CONFIG_DIR_ENV_VAR,
  CLAUDE_CONFIG_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAMES,
  DEVELOPER_TOOLS_CANDIDATES,
  INHERIT_CLAUDE_CONFIG_ENV_VAR,
  TEMP_DIR_ENV_VAR,
  TEMP_PREFIX_ENV_VAR,
  agentCommand,
  agentConfigurationOptions,
  agentPermissionOptions,
  agentEntryPath,
  agentEnvironment,
  agentPlugins,
  agentSdkEntry,
  agentTempDir,
  agentTempPrefix,
  claudeConfigDir,
  pendingBriefingsPath,
  readPendingBriefings,
  hookProbePluginDir,
  hookProbeRecord,
  inheritedConfigVariables,
  inheritsClaudeConfig,
  failureOfThrown,
  lastSessionPath,
  rememberSession,
  writeNodeShim,
  interleave,
  resumableSession,
  sandboxEnvOverlay,
  serveTurns,
  zodEntry,
  type AgentSessionPort,
} from './agent.ts'
import { GIT_CONFIG_GLOBAL_ENV_VAR, agentGitConfigPath } from './gitconfig.ts'
import { previewToolResult, type PreviewOutcome } from './preview.ts'
import { RESTART_STILL_OWED } from './merge.ts'
import {
  parseTurnEvent,
  turnFailureMessage,
  type SlashCommand,
  type TurnEvent,
} from './turn.ts'

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
const ZOD = '/Users/dev/code/varnick/node_modules/.store/zod/index.js'

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

  test('zod is named by absolute path too, for the same measured reason', () => {
    /*
      The Custom Tool needs it — `createSdkMcpServer` refuses an input schema
      that is not a zod raw shape, measured — and a bare `import 'zod'` inside
      the Sandbox would fail exactly the way the SDK's own bare specifier does.
      So the runtime resolves it out here and the confined process imports a
      path.
    */
    const command = agentCommand({ cloneRoot: CLONE, execPath: BUN, sdkEntry: SDK, zodEntry: ZOD })
    expect(command).toContain(ZOD)
    expect(command.indexOf(ZOD)).toBeGreaterThan(command.indexOf(SDK))
    expect(existsSync(zodEntry())).toBe(true)
  })

  test('an installation with no zod is an agent without the tool, not a broken argv', () => {
    /*
      Positional and always present, empty string included. The probe flags come
      after it (`--selftest`, `--toolprobe`, `--nestprobe`), so an argument that
      vanished when it had no value would move all three one place left and every
      containment probe would be reading a path as a flag.
    */
    const command = agentCommand({ cloneRoot: CLONE, execPath: BUN, sdkEntry: SDK, zodEntry: '' })
    expect(command.endsWith('""')).toBe(true)
    expect(command.split(' ').filter((part) => part.startsWith('"')).length).toBe(4)
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

  test('the agent reads the clone it works in, including its CLAUDE.md', () => {
    /*
      The reversal, and the reason it is safe: a hook loaded from the clone runs
      inside the Sandbox, in the process the agent already runs `Bash` in. It
      grants no capability. What it grants is reach through time — it fires in
      future sessions and never appears in the transcript — which is a cost
      worth paying visibly rather than a reason to starve the agent of the
      repository's own rules.

      `project` is required for CLAUDE.md to load at all; the SDK says so.
    */
    expect(agentConfigurationOptions(false)).toEqual({
      settingSources: ['project', 'local'],
      skills: 'all',
    })
  })

  test('the home directory is not claimed, because the Sandbox denies it', () => {
    // `user` is ~/.claude, which denyRead covers. It is added only by the flag,
    // for a run that has widened the policy by hand — naming it by default
    // would be a claim this cannot honour.
    expect(agentConfigurationOptions(false).settingSources).not.toContain('user')
    expect(agentConfigurationOptions(true).settingSources).toEqual(['user', 'project', 'local'])
  })

  test('skills are turned on rather than left to a default', () => {
    // The SDK calls this "the single place to turn skills on", and omitting it
    // is not "skills off" — it is no opinion. The runtime panel reports the
    // list, and an empty one should mean the agent found none.
    expect(agentConfigurationOptions(false).skills).toBe('all')
  })

  test('the SDK asks nobody for permission, because the kernel already answered', () => {
    /*
      `CONTEXT.md` has said since the Sandbox was defined that this layer is
      *replaced* — and it was never turned off. `permissionMode` appeared once
      in the whole repository, in the containment probe, so the chat agent got
      the SDK's documented default: `'default'`, which prompts for dangerous
      operations. varnick has no prompt surface and registers no `canUseTool`,
      so every prompted tool use was refused, for months, while Read and Grep
      passed the same check and made it look like a working agent.

      Asserted as a pair. `bypassPermissions` without
      `allowDangerouslySkipPermissions` is refused by the SDK, so a half-applied
      fix is a silent return to the same wall.
    */
    expect(agentPermissionOptions()).toEqual({
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
    })
  })

  test('nothing narrower is chosen, and the reason is one boundary rather than two', () => {
    // `dontAsk` denies what is not pre-approved, which needs an allowlist of
    // tools and paths kept beside sandbox-policy.json and free to disagree with
    // it — and two boundaries that can disagree is how the first one stops
    // being believed. `acceptEdits` covers Edit and not Bash, which confines an
    // agent only to its choice of tool.
    expect(agentPermissionOptions().permissionMode).not.toBe('dontAsk')
    expect(agentPermissionOptions().permissionMode).not.toBe('acceptEdits')
    expect(agentPermissionOptions().permissionMode).not.toBe('default')
  })

  test('a plugin is a directory in the clone that says it is one', () => {
    // Discovered rather than registered, the rule Surfaces follow: adding one
    // must never require editing Core.
    const found = agentPlugins('/clone', {
      readDir: () => ['caveman', 'not-a-plugin'],
      exists: (path) => path === '/clone/.claude/plugins/caveman/.claude-plugin/plugin.json',
    })
    expect(found).toEqual([{ type: 'local', path: '/clone/.claude/plugins/caveman' }])
  })

  test('a clone with no plugins is not a failure', () => {
    // The honest default. A plugin only exists for this agent if it is
    // somewhere the agent can read, and ~/.claude/plugins is denied.
    expect(agentPlugins('/clone', { readDir: () => { throw new Error('ENOENT') }, exists: () => false })).toEqual([])
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
function fakeSession(
  contextTokens: () => Promise<number | null> = async () => null,
  /** What the runtime says it will accept, when it is asked. */
  offers: readonly SlashCommand[] = [],
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
    contextTokens: () => {
      asked.push('contextTokens')
      return contextTokens()
    },
    supportedCommands: async () => {
      asked.push('supportedCommands')
      return offers
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
    /**
     * What the `PostCompact` hook would report, from outside the message
     * stream. Every compaction reaches the loop this way, whether the developer
     * asked for one or the window filled up on its own.
     */
    summarised: (summary: string) => void
    /**
     * What the `launch_preview` Custom Tool calls. The loop hands this over;
     * here it stands in for the tool's handler, so the round trip can be driven
     * with no Claude Code process and no window.
     */
    askForPreview: (worktree: string) => Promise<PreviewOutcome>
    /** Everything the loop has written so far, while it is still running. */
    written: readonly string[]
  }) => Promise<void>,
  contextTokens?: () => Promise<number | null>,
  /** Whether this run was opened by resuming — what the report carries. */
  resumed = false,
  /** What the runtime answers when asked which commands it accepts. */
  offers: readonly SlashCommand[] = [],
) {
  const control = pushable<string>()
  const messages = pushable<unknown>()
  const { port, asked } = fakeSession(contextTokens, offers)
  /** Every session id the loop handed over to be written down, in order. */
  const started: string[] = []
  const written: TurnEvent[] = []
  // Everything the loop wrote, unfiltered. The channel carries more than Turn
  // events now, and a helper that only kept those could not see the rest.
  const lines: string[] = []
  let report: (summary: string) => void = () => {}
  /** Every list of secret names the loop handed over, in order. */
  const described: (readonly string[])[] = []
  let ask: (worktree: string) => Promise<PreviewOutcome> = async () => 'no-launch'

  const served = serveTurns({
    control,
    messages,
    session: port,
    compactionSummaries: (deliver) => {
      report = deliver
    },
    previewLaunches: (deliver) => {
      ask = deliver
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

  await script({
    control,
    messages,
    asked,
    summarised: (summary) => report(summary),
    askForPreview: (worktree) => ask(worktree),
    written: lines,
  })
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

  test('an answer with no turn running gets one of its own, not the next turn’s', async () => {
    /*
      This asserted `written` was empty, and that emptiness was a defect rather
      than a property: **two complete answers were produced and thrown away
      here.** A subagent finished, the notification reached the Session as a
      prompt varnick never sent, the agent answered it twice, and every message
      of both was dropped for having no Turn to belong to. The developer asked
      why it had not reported; it correctly said it had.

      The concern the old assertion was written for is real and is kept: a
      stray delta must not become the first word of the next Turn. It no longer
      needs to be discarded to be kept — it gets a `u`-stamped Turn of its own,
      which is a different Turn from `t1`.

      The init message still produces nothing, and that is unchanged: there is
      no Turn to stamp a report with, which is the whole reason it is held and
      replayed.
    */
    const { written } = await serve(async ({ control, messages }) => {
      messages.push({ type: 'system', subtype: 'init' })
      messages.push({ type: 'user', message: { content: '<task-notification>done' } })
      messages.push(textDelta('unasked'))
      messages.push(result('unasked'))
      await settle()
      control.push(runTurnLine('t1', 'hello'))
      await settle()
      messages.push(result('asked'))
      await settle()
    })

    const unprompted = written.filter((e) => e.turnId.startsWith('u'))
    expect(unprompted.map((e) => e.kind)).toEqual(['cause', 'delta', 'done'])
    expect(unprompted[0]).toMatchObject({ kind: 'cause', text: 'a subagent finished' })
    expect(unprompted.at(-1)).toMatchObject({ kind: 'done', text: 'unasked' })

    // And the prompted Turn is untouched by it — the original concern.
    const prompted = written.filter((e) => e.turnId === 't1')
    expect(prompted.at(-1)).toMatchObject({ kind: 'done', text: 'asked' })
  })

  test('an unprompted answer does not open for the runtime’s own bookkeeping', async () => {
    // Most of what crosses the stream while idle is not an answer. A run opened
    // for one of those would post an empty message into the transcript.
    const { written } = await serve(async ({ messages }) => {
      messages.push({ type: 'system', subtype: 'init' })
      messages.push({ type: 'system', subtype: 'hook_response', outcome: 'success' })
      messages.push(result('nothing to see'))
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

describe('the commands the runtime will accept', () => {
  const init = { type: 'system', subtype: 'init', model: 'claude-opus-5' }
  const offers = [
    { name: 'compact', description: 'Summarise the conversation', argumentHint: '' },
    { name: 'agents', description: 'Manage subagents', argumentHint: '[name]' },
  ] as const

  test('the described list is asked for, because the init message does not carry it', async () => {
    // `slash_commands` on init is names only. The descriptions and argument
    // hints — each from its own command's frontmatter — are what make a menu
    // usable, and they have to be asked for.
    const { asked, written } = await serve(
      async ({ control, messages }) => {
        messages.push(init)
        await settle()
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        messages.push(result('hi'))
        await settle()
      },
      undefined,
      false,
      offers,
    )
    expect(asked).toContain('supportedCommands')
    const commands = written.find((e) => e.kind === 'commands')
    expect(commands).toBeDefined()
    expect(commands?.kind === 'commands' && commands.commands).toEqual(offers)
  })

  test('a list discovered mid-session replaces the one held, rather than adding to it', async () => {
    /*
      The SDK pushes the whole list on `commands_changed` and says to replace
      the cached one. Merging would go on offering a skill that has gone, which
      is the one lie a discovery surface must not tell.
    */
    const { written } = await serve(
      async ({ control, messages }) => {
        messages.push(init)
        await settle()
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        messages.push({
          type: 'system',
          subtype: 'commands_changed',
          commands: [{ name: 'only-this', description: 'found later', argumentHint: '' }],
        })
        await settle()
        messages.push(result('hi'))
        await settle()
      },
      undefined,
      false,
      offers,
    )
    const last = written.filter((e) => e.kind === 'commands').at(-1)
    expect(last?.kind === 'commands' && last.commands.map((c) => c.name)).toEqual(['only-this'])
  })

  test('every turn carries the list, so a window opened later still has one', async () => {
    const { written } = await serve(
      async ({ control, messages }) => {
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
      },
      undefined,
      false,
      offers,
    )
    expect(written.filter((e) => e.kind === 'commands').map((e) => e.turnId)).toContain('t2')
  })

  test('an entry with no name is dropped rather than drawn as a blank row', async () => {
    const { written } = await serve(
      async ({ control, messages }) => {
        messages.push(init)
        await settle()
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        messages.push({
          type: 'system',
          subtype: 'commands_changed',
          commands: [{ description: 'no name at all', argumentHint: '' }, { name: 'real' }],
        })
        await settle()
        messages.push(result('hi'))
        await settle()
      },
      undefined,
      false,
      offers,
    )
    const last = written.filter((e) => e.kind === 'commands').at(-1)
    expect(last?.kind === 'commands' && last.commands).toEqual([
      { name: 'real', description: '', argumentHint: '' },
    ])
  })

  test('a runtime that will not answer costs a menu, never a turn', async () => {
    // Best-effort on purpose: this is a description of the agent, not a step in
    // answering anything.
    const { written } = await serve(
      async ({ control, messages }) => {
        messages.push(init)
        await settle()
        control.push(runTurnLine('t1', 'hello'))
        await settle()
        messages.push(result('hi'))
        await settle()
      },
      undefined,
      false,
      // A session whose command list throws — see the port below.
      [],
    )
    expect(written.some((e) => e.kind === 'done')).toBe(true)
  })
})

describe('a picture arrives beside the words about it', () => {
  const png = (data: string) => ({ mediaType: 'image/png' as const, data })
  const kinds = (blocks: readonly { type: string }[]) => blocks.map((b) => b.type)

  test('a marker puts the image where the sentence says it is', () => {
    /*
      The difference between three screenshots followed by a wall of text, and a
      question with its screenshot beside it. The developer wrote the markers by
      pasting; this is what they buy.
    */
    const blocks = interleave('the menu in [Image #1] should look like [Image #2]', [
      png('b25l'),
      png('dHdv'),
    ])
    expect(kinds(blocks)).toEqual(['text', 'image', 'text', 'image'])
    expect(blocks[1]).toMatchObject({ source: { data: 'b25l' } })
    expect(blocks[3]).toMatchObject({ source: { data: 'dHdv' } })
  })

  test('a picture nothing names is still sent, on the end', () => {
    // The one failure this whole path exists to prevent: a screenshot that was
    // attached and never sent. Deleting a marker must not delete the image.
    expect(kinds(interleave('no markers here', [png('b25l')]))).toEqual(['text', 'image'])
  })

  test('a marker naming nothing stays as the text it is', () => {
    // It is what the developer typed, and hiding it would silently change the
    // question they asked.
    const blocks = interleave('see [Image #7]', [png('b25l')])
    expect(blocks[0]).toEqual({ type: 'text', text: 'see [Image #7]' })
    expect(blocks[1]?.type).toBe('image')
  })

  test('the same marker twice is one picture, not two', () => {
    // A duplicated marker is a developer editing a sentence, not a request to
    // pay for the image again.
    const blocks = interleave('[Image #1] and again [Image #1]', [png('b25l')])
    expect(kinds(blocks).filter((k) => k === 'image')).toHaveLength(1)
  })

  test('a caption-less paste is the picture and nothing else', () => {
    expect(kinds(interleave('', [png('b25l')]))).toEqual(['image'])
  })

  test('whitespace around a marker is not a text block', () => {
    // "[Image #1] " would otherwise send a block containing one space, which is
    // a block the model has to account for and nobody wrote.
    expect(kinds(interleave('  [Image #1]  ', [png('b25l')]))).toEqual(['image'])
  })
})

describe('a compaction varnick did not perform', () => {
  test('the window is told, so the transcript follows the context', async () => {
    /*
      The live half of this: an auto-compaction fires when the window fills,
      with no command and nobody watching. It rewrites the agent's context
      either way — dropping the news left varnick showing a conversation the
      agent no longer held, which is the `/clear` disagreement with nothing to
      blame it on.
    */
    const { written } = await serve(async ({ control, messages, summarised }) => {
      control.push(runTurnLine('t1', 'carry on'))
      await settle()
      summarised('everything so far, in short')
      await settle()
      messages.push(result('carried on'))
      await settle()
    })
    const compacted = written.find((e) => e.kind === 'compacted')
    expect(compacted?.turnId).toBe('t1')
    expect(compacted?.kind === 'compacted' && compacted.summary).toBe('everything so far, in short')
  })

  test('an empty summary is not a compaction to report', async () => {
    // A transcript replaced by nothing is a transcript discarded, reported as
    // a success.
    const { written } = await serve(async ({ control, summarised }) => {
      control.push(runTurnLine('t1', 'carry on'))
      await settle()
      summarised('   ')
      await settle()
    })
    expect(written.some((e) => e.kind === 'compacted')).toBe(false)
  })

  test('the summary does not end the Turn it arrived during', async () => {
    // A compaction mid-answer is not an answer. The agent carries on with a
    // context it has just rewritten, and what it says next belongs after the
    // summary rather than instead of it.
    const { written } = await serve(async ({ control, messages, summarised }) => {
      control.push(runTurnLine('t1', 'carry on'))
      await settle()
      summarised('everything so far, in short')
      await settle()
      messages.push(result('carried on'))
      await settle()
    })
    const kinds = written.map((e) => e.kind)
    expect(kinds.indexOf('compacted')).toBeLessThan(kinds.indexOf('done'))
    const done = written.find((e) => e.kind === 'done')
    expect(done?.kind === 'done' && done.text).toContain('carried on')
  })

  test('varnick cannot ask for one, so the word is refused on the control channel', async () => {
    // `compact` was a control request. Nothing sends it now, and a host that
    // still accepted it would be a second way to do the thing this listener
    // exists to hear about.
    const { written } = await serve(async ({ control, asked }) => {
      control.push(`${JSON.stringify({ kind: 'compact', turnId: 'c1' })}\n`)
      await settle()
      expect(asked).toEqual([])
    })
    expect(written).toEqual([])
  })

  test('a compaction with no Turn to stamp is dropped rather than misattributed', async () => {
    // The same rule every message on this stream follows. Nothing fills a
    // context when nothing is running, so this is a case that does not happen
    // rather than one that is lost.
    const { written } = await serve(async ({ summarised }) => {
      summarised('a summary with nowhere to go')
      await settle()
    })
    expect(written.some((e) => e.kind === 'compacted')).toBe(false)
  })
})

describe('a conversation that was reset', () => {
  test('the window is told, so the transcript goes when the memory does', async () => {
    /*
      Announced by the CLI after its own `/clear`, a plan-mode exit, or anything
      else that starts a fresh conversation — which is why varnick listens for
      it rather than owning a command. Its own `/clear` could only ever cover
      the clears it was asked for.
    */
    const { written, started } = await serve(async ({ control, messages }) => {
      control.push(runTurnLine('t1', '/clear'))
      await settle()
      messages.push({
        type: 'conversation_reset',
        new_conversation_id: 'fresh-1',
      })
      await settle()
      messages.push(result('cleared'))
      await settle()
    })
    expect(written.map((e) => e.kind)).toContain('reset')
    // And the pointer follows, or the next launch resumes the conversation this
    // one was told to forget.
    expect(started).toContain('fresh-1')
  })

  test('a reset with no turn running tells nobody, because there is nobody', async () => {
    const { written } = await serve(async ({ messages }) => {
      messages.push({ type: 'conversation_reset', new_conversation_id: 'fresh-2' })
      await settle()
    })
    expect(written).toEqual([])
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
    // Filtered rather than exact: the command list rides this channel too and
    // arrives beside the report. What this test is about is the report.
    expect(written.map((e) => e.kind).filter((k) => k !== 'commands')).toEqual(['runtime', 'done'])
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
    expect(written.map((e) => e.kind).filter((k) => k !== 'commands')).toEqual(['runtime', 'done'])
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
  Two suites stood here.

  A "plan usage rides the session that is already open" suite: eight tests over
  a `read-plan-usage` control request, cut by ticket 31 because no credential
  varnick can hold reports plan windows, so there was never a figure at the far
  end.

  A "compaction rides the same session a turn does" suite beside it: fifteen
  tests over a `compact` control request, its two-halved settlement, and the
  failures it could report. varnick does not ask for a compaction any more — it
  hears about the one the Session performed, whoever asked and even when nobody
  did — so there is no request left to test. What survives of it is in "a
  compaction varnick did not perform" above, which asserts the same things
  about the half that is still there: the summary, the measurement, and the
  refusal to invent one.

  Both suites also demonstrated ADR-0003's last consequence — the loop answers
  off a session it did not create — and that is still demonstrated by every
  Turn in this file, which is the same property on the kind that remained.
*/

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
        supportedCommands: async () => [],
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

// ---------------------------------------------------------------------------
// A temporary directory the kernel does not refuse
// ---------------------------------------------------------------------------

describe('somewhere to put a temporary file', () => {
  /*
    Ticket 53. `srt` bakes `TMPDIR=/tmp/claude` into the wrapped command and that
    path is in neither list, so every process inside the Sandbox inherits a
    temporary directory it cannot write. Measured by asking a wrapped shell:

      echo $TMPDIR      /tmp/claude   (denied)
      echo $TMPPREFIX   /tmp/zsh      (denied — zsh's default)

    The symptom is a heredoc, because that is the first thing needing a temporary
    file, and it is shell-specific — bash and sh write theirs to a pipe and both
    passed under the same policy at the same moment zsh failed:

      zsh:1: can't create temp file for here document: operation not permitted

    Fixed in the environment rather than in the policy. `/tmp/claude` is a fixed
    name directly under a world-writable directory shared with every user on the
    machine; the clone is writable already.
  */

  test('it is inside the clone, beside the other machine-local state', () => {
    expect(agentTempDir(CLONE)).toBe(`${CLONE}/.varnick/tmp`)
  })

  test('the agent is handed it', () => {
    const env = agentEnvironment({}, { cloneRoot: CLONE, inherit: false })
    expect(env[TEMP_DIR_ENV_VAR]).toBe(`${CLONE}/.varnick/tmp`)
  })

  test('the value srt left behind is replaced, not honoured', () => {
    // The case that matters: this arrives *set*, and set to a denied path. A
    // fix that only filled in a missing variable would do nothing at all.
    const env = agentEnvironment(
      { [TEMP_DIR_ENV_VAR]: '/tmp/claude' },
      { cloneRoot: CLONE, inherit: false },
    )
    expect(env[TEMP_DIR_ENV_VAR]).toBe(`${CLONE}/.varnick/tmp`)
  })

  test('inheriting the developer’s environment does not restore a denied one', () => {
    const env = agentEnvironment(
      { [TEMP_DIR_ENV_VAR]: '/tmp/claude' },
      { cloneRoot: CLONE, inherit: true },
    )
    expect(env[TEMP_DIR_ENV_VAR]).toBe(`${CLONE}/.varnick/tmp`)
  })

  test('zsh’s here-document prefix is set too, because zsh does not derive it', () => {
    // `TMPPREFIX` defaults to the literal `/tmp/zsh` and is consulted before
    // `TMPDIR`. Setting only the first leaves the heredoc exactly as broken.
    const env = agentEnvironment({}, { cloneRoot: CLONE, inherit: false })
    expect(env[TEMP_PREFIX_ENV_VAR]).toBe(`${CLONE}/.varnick/tmp/zsh`)
  })

  test('the prefix is inside the directory, so one mkdir covers both', () => {
    expect(agentTempPrefix(CLONE).startsWith(`${agentTempDir(CLONE)}/`)).toBe(true)
  })

  test('git’s global config is pointed into the clone too, and it arrives fatal', () => {
    /*
      Ticket 11, and the difference from `TMPDIR` above is worth saying: that one
      arrives *wrong*, this one arrives **fatal**. git treats a global config it
      can see and cannot read as an error rather than a warning, and `$HOME` is
      denied, so without this every git command in the Sandbox exits 128 — `git
      --version` included, and `git worktree add`, `git commit` and `git merge`
      with it, which is the whole of ADR-0014.

      Pointed at the clone for the same reason `TMPDIR` is: the clone is already
      writable, so `allowRead` and `allowWrite` are untouched. Unlike its
      neighbours, the file it names is in `denyWrite` — see ./gitconfig.ts.
    */
    const env = agentEnvironment({}, { cloneRoot: CLONE, inherit: false })
    expect(env[GIT_CONFIG_GLOBAL_ENV_VAR]).toBe(agentGitConfigPath(CLONE))
    expect(agentGitConfigPath(CLONE)).toBe(`${CLONE}/.varnick/gitconfig`)
  })

  test('a developer’s own GIT_CONFIG_GLOBAL is replaced rather than honoured', () => {
    // The case that matters, in both modes: a value pointing anywhere under
    // `$HOME` is a path the kernel refuses, so honouring it under `inherit`
    // would be handing the agent the exact failure this fixes and calling it
    // inheritance.
    for (const inherit of [false, true]) {
      const env = agentEnvironment(
        { [GIT_CONFIG_GLOBAL_ENV_VAR]: '/Users/dev/.gitconfig' },
        { cloneRoot: CLONE, inherit },
      )
      expect(env[GIT_CONFIG_GLOBAL_ENV_VAR]).toBe(agentGitConfigPath(CLONE))
    }
  })

  test('Claude Code’s own scratch is a different path and stays granted', () => {
    /*
      Two temporary directories, two reasons. `/tmp/claude-<uid>` is where Claude
      Code puts the directory every Bash command needs; it does not honour
      `TMPDIR` for that, which is why ticket 27 had to grant it. Pointing this
      variable into the clone must not read as a reason to take that away.
    */
    expect(agentTempDir(CLONE)).not.toContain('/tmp/claude-')
  })
})

// ---------------------------------------------------------------------------
// A `node` that is bun, so a plugin's hooks can run
// ---------------------------------------------------------------------------

describe('a Briefing outlives the restart it recommends', () => {
  /*
    The hole this closes. A Briefing reaches the agent through a
    `UserPromptSubmit` hook, which runs when the developer next speaks — and the
    thing varnick recommends immediately after a merge is a *restart*: the band
    says one is owed and offers the button. So the ordinary sequence is merge,
    restart, no Turn in between, and an in-process queue dies with the process.
    The agent is never told, in exactly the flow the product recommends.

    Kept on disk, and cleared by the delivery rather than by an exit, so a
    Briefing survives any number of restarts and crashes and is still said once.
  */

  const held = (entries: unknown) => (path: string) => {
    if (path !== pendingBriefingsPath(CLONE)) throw new Error(`unexpected read of ${path}`)
    return JSON.stringify(entries)
  }

  test('it is kept beside the session pointer, inside the clone', () => {
    // Writable within the Sandbox and gitignored, like everything in there.
    expect(pendingBriefingsPath(CLONE)).toBe(`${CLONE}/.varnick/claude/pending-briefings.json`)
  })

  test('what a previous process could not deliver is read back', () => {
    const kept = readPendingBriefings(CLONE, held([{ briefing: 'ticket/49 landed as a1b2c3d.' }]))
    expect(kept).toEqual([{ briefing: 'ticket/49 landed as a1b2c3d.' }])
  })

  test('the restart clause is dropped, because a restart plainly happened', () => {
    /*
      The reason the two halves are separate strings at all. Anything found on
      disk was written by a process that is no longer running, so "varnick has
      not restarted, so it is still running the code from before this change" is
      false — and it is the one sentence in a Briefing that must never be read
      after it stops being true.
    */
    const kept = readPendingBriefings(
      CLONE,
      held([{ briefing: 'ticket/49 landed as a1b2c3d.', whileRunning: RESTART_STILL_OWED }]),
    )
    expect(kept[0]?.briefing).toBe('ticket/49 landed as a1b2c3d.')
    expect(kept[0]?.whileRunning).toBeUndefined()
  })

  test('a half-written record is not reconstructed', () => {
    // A Briefing is a sentence or it is not there. Half of one, delivered,
    // spends the one chance to say a branch landed.
    expect(readPendingBriefings(CLONE, held([{ whileRunning: 'x' }, { briefing: '   ' }]))).toEqual(
      [],
    )
  })

  test('no file is nothing owed, which is what a first run looks like too', () => {
    expect(
      readPendingBriefings(CLONE, () => {
        throw new Error('ENOENT')
      }),
    ).toEqual([])
  })

  test('a file this build cannot read is not a reason to fail a launch', () => {
    expect(readPendingBriefings(CLONE, () => 'not json')).toEqual([])
    expect(readPendingBriefings(CLONE, () => '{"briefing":"a"}')).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// A `node` that is bun, so a plugin's hooks can run
// ---------------------------------------------------------------------------

describe('a node that is bun', () => {
  /*
    Plugin hooks had never run, and the reason was a name. A plugin declares its
    hook as a command and that command is conventionally `node <script>`;
    `agentEnvironment` builds the environment outright and varnick runs on bun,
    so nothing on PATH answered to `node` and the spawn failed silently.

    Measured before it was fixed: bun runs a real plugin hook correctly, so what
    was missing was the name rather than the runtime.
  */

  const shimFs = () => {
    const made: string[] = []
    const written = new Map<string, string>()
    const modes = new Map<string, number>()
    return {
      made,
      written,
      modes,
      mkdir: (path: string) => void made.push(path),
      write: (path: string, contents: string) => void written.set(path, contents),
      chmod: (path: string, mode: number) => void modes.set(path, mode),
    }
  }

  test('it writes an executable node beside the configuration directory', () => {
    const fs = shimFs()
    const bin = writeNodeShim(CLONE, '/opt/bun/bin/bun', fs)

    expect(bin).toBe(`${CLONE}/.varnick/bin`)
    expect(fs.made).toEqual([`${CLONE}/.varnick/bin`])
    // Executable, or the spawn fails exactly as it did before.
    expect(fs.modes.get(`${CLONE}/.varnick/bin/node`)).toBe(0o755)
  })

  test('the interpreter is absolute and exec-ed, not searched for', () => {
    // A bare `bun` would make the hook depend on a PATH search inside the
    // Sandbox, which is the failure agentSdkEntry records for a bare specifier.
    // `exec` so the hook's process is bun rather than a wrapper holding it.
    const fs = shimFs()
    writeNodeShim(CLONE, '/opt/bun/bin/bun', fs)

    expect(fs.written.get(`${CLONE}/.varnick/bin/node`)).toBe(
      '#!/bin/sh\nexec "/opt/bun/bin/bun" "$@"\n',
    )
  })

  test('an interpreter path with a space in it survives the shell', () => {
    const fs = shimFs()
    writeNodeShim(CLONE, '/Applications/My Tools/bun', fs)

    expect(fs.written.get(`${CLONE}/.varnick/bin/node`)).toContain('"/Applications/My Tools/bun"')
  })

  test('it goes on PATH behind the real toolchain', () => {
    // Only `node` lives here and no toolchain supplies that, so the order is
    // about keeping the rule rather than about a collision that exists today.
    const env = agentEnvironment(
      { PATH: '/usr/bin' },
      { cloneRoot: CLONE, inherit: false, toolsBin: '/toolchain/usr/bin', agentBin: `${CLONE}/.varnick/bin` },
    )
    expect(env.PATH).toBe(`/toolchain/usr/bin:${CLONE}/.varnick/bin:/usr/bin`)
  })

  test('a launch that could not write one keeps the PATH it had', () => {
    // A clone whose `.varnick` cannot be written is a clone whose hooks will
    // not run, which is where varnick already was. It is not a reason to refuse
    // to start.
    const env = agentEnvironment(
      { PATH: '/usr/bin' },
      { cloneRoot: CLONE, inherit: false, agentBin: null },
    )
    expect(env.PATH).toBe('/usr/bin')
  })
})

// ---------------------------------------------------------------------------
// The fixture that makes "hooks run" a measurement
// ---------------------------------------------------------------------------

describe('varnick declares a hook of its own', () => {
  /*
    Ticket 58's first two criteria, and the reason they needed a fixture at all.

    The finding was visible only because the `caveman` plugin wrote a flag file
    that had never appeared — and deleting that plugin took the evidence with
    it. A plugin varnick owns cannot be removed by a decision about somebody
    else's plugin, which is the whole argument for this directory existing.

    Two halves are provable here and one is not. That the hook *command* can
    spawn — the half ticket 58's first commit fixed, `node` on PATH — is proved
    below by running it. That Claude Code actually *fires* it needs a real
    Session, which needs a credential, so it is proved at launch instead: the
    record carries `pluginRoot`, which only Claude Code can supply.
  */

  const repoRoot = resolve(import.meta.dir, '..', '..', '..')

  test('the clone holds a plugin that declares a SessionStart hook', () => {
    // The criterion that had nothing to test against once caveman was deleted.
    const manifest = JSON.parse(
      readFileSync(join(hookProbePluginDir(repoRoot), '.claude-plugin', 'plugin.json'), 'utf8'),
    ) as { hooks?: { SessionStart?: unknown[] } }

    expect(manifest.hooks?.SessionStart).toBeArray()
  })

  test('discovery finds it, so it reaches the agent at all', () => {
    // Filesystem-based, like every other kind of discovery here — a fixture
    // that had to be registered in Core would prove something else.
    const found = agentPlugins(repoRoot).map((plugin) => plugin.path)
    expect(found).toContain(hookProbePluginDir(repoRoot))
  })

  test('its command names node, which is the thing that was missing', () => {
    /*
      Deliberately asserted rather than assumed. The point of the fixture is to
      exercise the exact idiom that failed — `node "${CLAUDE_PLUGIN_ROOT}/…"` —
      and a fixture that quietly said `bun` instead would pass forever while
      proving nothing about any plugin a developer installs.
    */
    const manifest = JSON.parse(
      readFileSync(join(hookProbePluginDir(repoRoot), '.claude-plugin', 'plugin.json'), 'utf8'),
    ) as { hooks: { SessionStart: { hooks: { command: string }[] }[] } }

    expect(manifest.hooks.SessionStart[0]?.hooks[0]?.command).toBe(
      'node "${CLAUDE_PLUGIN_ROOT}/hooks/record.mjs"',
    )
  })

  test('the hook writes its record when it is run', async () => {
    /*
      Run for real, against a throwaway clone root, with the shim on PATH and
      `CLAUDE_PLUGIN_ROOT` supplied the way Claude Code supplies it. This is the
      spawn that used to fail with `node: command not found` and say nothing.
    */
    const root = mkdtempSync(join(tmpdir(), 'varnick-hook-probe-'))
    try {
      mkdirSync(claudeConfigDir(root), { recursive: true })
      const bin = writeNodeShim(root, process.execPath, {
        mkdir: (path) => mkdirSync(path, { recursive: true }),
        write: (path, contents) => writeFileSync(path, contents),
        chmod: (path, mode) => chmodSync(path, mode),
      })

      const pluginRoot = hookProbePluginDir(repoRoot)
      const child = Bun.spawn({
        cmd: ['/bin/sh', '-c', `node ${JSON.stringify(join(pluginRoot, 'hooks', 'record.mjs'))}`],
        env: {
          PATH: `${bin}:/usr/bin:/bin`,
          CLAUDE_CONFIG_DIR: claudeConfigDir(root),
          CLAUDE_PLUGIN_ROOT: pluginRoot,
        },
        stdout: 'pipe',
        stderr: 'pipe',
      })
      const [code, stdout] = await Promise.all([child.exited, new Response(child.stdout).text()])

      expect(code).toBe(0)
      /*
        Silence is a requirement, not a detail. A `SessionStart` hook's stdout is
        injected into the agent's context — a fixture that talked would change
        the thing it measures, on every session, for ever.
      */
      expect(stdout).toBe('')

      const record = hookProbeRecord(root)
      expect(record).not.toBeNull()
      expect(record?.pluginRoot).toBe(pluginRoot)
      // The shim answered, rather than some `node` that happened to be around.
      expect(record?.argv0).toContain('bun')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('a missing record is null, because absence is the finding', () => {
    // varnick was in this state for months. A reader that invented a record to
    // stand in for one would erase the only evidence the defect ever had.
    expect(hookProbeRecord(mkdtempSync(join(tmpdir(), 'varnick-hook-empty-')))).toBe(null)
  })
})

// ---------------------------------------------------------------------------
// A Preview, asked for from inside the Sandbox
// ---------------------------------------------------------------------------

/*
  The round trip and nothing else. No window is opened, no second varnick is
  started and no dialog is drawn here — all three are the host's, in
  src-tauri/src/preview.rs, and the ticket says plainly that no test may do any
  of them. What this seam owns is the question going out and the answer coming
  back, which is the whole of what the confined half does.
*/

describe('asking the host for a preview', () => {
  const requested = (lines: readonly string[]) =>
    lines
      .map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((value) => value.kind === 'launch-preview')

  const answerLine = (requestId: string, outcome: string, extra: Record<string, unknown> = {}) =>
    `${JSON.stringify({ kind: 'preview-answer', requestId, outcome, ...extra })}\n`

  test('the name goes out as a request and the answer comes back as the tool result', async () => {
    const answers: PreviewOutcome[] = []
    await serve(async ({ control, askForPreview, written }) => {
      const asking = askForPreview('agent-one').then((outcome) => answers.push(outcome))
      await settle()
      const request = requested(written)[0] as Record<string, unknown>
      expect(request.kind).toBe('launch-preview')
      expect(request.worktree).toBe('agent-one')
      control.push(answerLine(request.requestId as string, 'launched'))
      await asking
    })
    expect(answers).toEqual(['launched'])
    expect(previewToolResult(answers[0] as PreviewOutcome).launched).toBe(true)
  })

  test('a launch that did not happen reaches the agent as a tool call that did not launch', async () => {
    /*
      There is no `declined` any more — a Preview is confined by the live tree's
      policy, so there is nothing for a developer to approve and no dialog to
      say no at (ADR-0019). What is left are the outcomes where the host tried
      and there is no window, and the agent has to be able to tell one of those
      from a launch: an agent that went on to describe what the preview shows
      would be describing a window nobody opened.
    */
    const answers: PreviewOutcome[] = []
    await serve(async ({ control, askForPreview, written }) => {
      const asking = askForPreview('agent-one').then((outcome) => answers.push(outcome))
      await settle()
      control.push(answerLine(requested(written)[0]?.requestId as string, 'no-launch'))
      await asking
    })
    expect(answers).toEqual(['no-launch'])
    const result = previewToolResult(answers[0] as PreviewOutcome)
    expect(result.launched).toBe(false)
    expect(result.text).toContain('Nothing is running from it')
  })

  test('the request carries a name and has no field a command could arrive in', async () => {
    const { lines } = await serve(async ({ control, askForPreview, written }) => {
      const asking = askForPreview('agent-one')
      await settle()
      const request = requested(written)[0] as Record<string, unknown>
      expect(Object.keys(request).sort()).toEqual(['kind', 'requestId', 'worktree'])
      control.push(answerLine(request.requestId as string, 'launched'))
      await asking
    })
    expect(requested(lines)).toHaveLength(1)
  })

  test('two requests in flight are answered by request id rather than by order', async () => {
    const answers: string[] = []
    await serve(async ({ control, askForPreview }) => {
      const one = askForPreview('agent-one').then((outcome) => answers.push(`one:${outcome}`))
      const two = askForPreview('agent-two').then((outcome) => answers.push(`two:${outcome}`))
      await settle()
      // The second answered first. A loop that paired these up by arrival would
      // tell the agent that the worktree it did not ask about is the one with
      // no window.
      control.push(answerLine('preview-2', 'no-launch'))
      await settle()
      control.push(answerLine('preview-1', 'launched'))
      await Promise.all([one, two])
    })
    expect(answers).toEqual(['two:no-launch', 'one:launched'])
  })

  test('an answer to a request nobody is waiting for changes nothing', async () => {
    const answers: PreviewOutcome[] = []
    await serve(async ({ control, askForPreview }) => {
      const asking = askForPreview('agent-one').then((outcome) => answers.push(outcome))
      await settle()
      control.push(answerLine('preview-1', 'launched'))
      await asking
      // Replayed, and again for a request that never existed. A promise
      // resolved twice would be a tool call answered by whichever line arrived
      // last rather than by the developer's decision.
      control.push(answerLine('preview-1', 'no-launch'))
      control.push(answerLine('preview-99', 'no-launch'))
      await settle()
    })
    expect(answers).toEqual(['launched'])
  })

  test('an answer this build cannot read leaves the tool waiting rather than guessing', async () => {
    const answers: PreviewOutcome[] = []
    await serve(async ({ control, askForPreview }) => {
      const asking = askForPreview('agent-one').then((outcome) => answers.push(outcome))
      // An outcome nothing wrote, and an answer with no outcome at all. Neither
      // is a control request, so neither resolves anything — the far end is the
      // host, and an unreadable line from it is not a decision.
      control.push(answerLine('preview-1', 'probably'))
      control.push(`${JSON.stringify({ kind: 'preview-answer', requestId: 'preview-1' })}\n`)
      await settle()
      expect(answers).toEqual([])
      control.push(answerLine('preview-1', 'launched'))
      await asking
    })
    expect(answers).toEqual(['launched'])
  })

  test('a host that goes away is a launch that did not happen', async () => {
    /*
      The control channel closing means no answer can arrive on it. Left
      unresolved, the tool call would hold its Turn open for the life of a
      process that has stopped listening — which is the state a Turn can neither
      retry nor dismiss.
    */
    const answers: PreviewOutcome[] = []
    await serve(async ({ askForPreview }) => {
      void askForPreview('agent-one').then((outcome) => answers.push(outcome))
      await settle()
    })
    await settle()
    expect(answers).toEqual(['no-launch'])
  })

  test('a preview request is not a Turn event and does not become transcript', async () => {
    // Two shapes on one pipe. `parseTurnEvent` is what Core reads the pipe
    // with, and it names a Turn; this names a request and nothing else.
    const { written, lines } = await serve(async ({ control, askForPreview }) => {
      const asking = askForPreview('agent-one')
      await settle()
      control.push(answerLine('preview-1', 'launched'))
      await asking
    })
    expect(written).toEqual([])
    expect(lines).toHaveLength(1)
    expect(parseTurnEvent(JSON.parse(lines[0] as string))).toBeNull()
  })

  test('a Turn is unaffected by a preview asked for in the middle of it', async () => {
    const { written } = await serve(async ({ control, messages, askForPreview }) => {
      control.push(runTurnLine('t1', 'change the sandbox'))
      await settle()
      messages.push(textDelta('working'))
      const asking = askForPreview('agent-one')
      await settle()
      control.push(answerLine('preview-1', 'launched'))
      await asking
      messages.push(result('done'))
      await settle()
    })
    expect(written.map((event) => event.kind)).toEqual(['delta', 'done'])
  })
})
