import { describe, expect, test } from 'bun:test'
import { AGENT_VOICE, agentSystemPrompt } from './voice.ts'

describe('agentSystemPrompt', () => {
  /*
    The preset is what carries the working directory, the memory path and git
    status. A voice that arrived by replacing it rather than appending to it
    would reintroduce the failure recorded at the `systemPrompt` option in
    ./agent.ts, where the agent ran `pwd` because that was the only way left to
    find out where it was standing.
  */
  test('appends to the Claude Code preset rather than replacing it', () => {
    const prompt = agentSystemPrompt()
    expect(prompt.type).toBe('preset')
    expect(prompt.preset).toBe('claude_code')
    expect(prompt.append).toBe(AGENT_VOICE)
  })
})

/*
  Every assertion below names a rule whose loss would be silent. The prompt
  would still be well-formed, still be sent, and the damage would show up only
  in output nobody was diffing.
*/
describe('AGENT_VOICE', () => {
  test('keeps the negations that carry meaning', () => {
    expect(AGENT_VOICE).toContain('Never drop not, never, no, only, or except')
  })

  /*
    The exemption this repository depends on most. Commit messages here carry
    the reasoning for a change and are the durable record of it, and ADRs and
    CONTEXT.md are prose on purpose.
  */
  test('exempts anything that outlives the conversation', () => {
    expect(AGENT_VOICE).toContain('outlive the conversation')
    expect(AGENT_VOICE).toContain('commit messages')
  })

  test('exempts warnings and irreversible actions', () => {
    expect(AGENT_VOICE).toContain('security warning')
    expect(AGENT_VOICE).toContain('irreversible action')
  })

  test('leaves code alone', () => {
    expect(AGENT_VOICE).toContain('Code blocks unchanged')
  })

  /*
    Self-consistency. The instruction forbids arrows, so it must not use one to
    say so — a prompt that breaks its own rule teaches that the rule is
    optional.
  */
  test('obeys its own rule about arrows', () => {
    expect(AGENT_VOICE).not.toContain('→')
  })
})
