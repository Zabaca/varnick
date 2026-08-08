import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  AGENT_ENTRY_RELATIVE_PATH,
  CLAUDE_CONFIG_DIR_ENV_VAR,
  CLAUDE_CONFIG_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAME,
  INHERIT_CLAUDE_CONFIG_ENV_VAR,
  agentCommand,
  agentConfigurationOptions,
  agentEntryPath,
  agentEnvironment,
  agentSdkEntry,
  claudeConfigDir,
  inheritedConfigVariables,
  inheritsClaudeConfig,
  sandboxEnvOverlay,
} from './agent.ts'

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
    const base = { PATH: '/usr/bin', ANTHROPIC_API_KEY: 'sk-" + "ant-api03-NEVER-LET-THIS-OUT' }
    expect(sandboxEnvOverlay({ ...base }, base)).toEqual({})
  })

  test('the credential variable can never ride the overlay, however it got there', () => {
    // The runtime is started by the host, so it inherits whatever the host was
    // launched with — which on a developer machine may include an exported
    // ANTHROPIC_API_KEY. The overlay crosses a pipe; the credential may not.
    const base = { PATH: '/usr/bin' }
    const wrapped = {
      ...base,
      [CREDENTIAL_ENV_VAR_NAME]: 'sk-" + "ant-api03-NEVER-LET-THIS-OUT',
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
    [CREDENTIAL_ENV_VAR_NAME]: 'sk-" + "ant-api03-NEVER-LET-THIS-OUT',
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
    expect(env[CREDENTIAL_ENV_VAR_NAME]).toBe('sk-" + "ant-api03-NEVER-LET-THIS-OUT')

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
    expect(env[CREDENTIAL_ENV_VAR_NAME]).toBe('sk-" + "ant-api03-NEVER-LET-THIS-OUT')
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
