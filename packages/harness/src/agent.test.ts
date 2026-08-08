import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  AGENT_ENTRY_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAME,
  agentCommand,
  agentEntryPath,
  agentSdkEntry,
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
