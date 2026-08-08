import { describe, expect, test } from 'bun:test'
import {
  encodePlanUsageAnswer,
  parsePlanUsageAnswer,
  readSubscriptionUsage,
  type PlanUsageReport,
} from './subscription.ts'

/**
 * The seam is the exported function, not the SDK call underneath it.
 *
 * What is worth testing here is the one product rule the ticket turns on: a
 * figure is either the measurement the plan reported or it is nothing. Every
 * shape the real endpoint can return where a window is missing must throw
 * rather than fall back to a plausible number, because a default rendered in
 * the usage strip is indistinguishable from a reading.
 */

const report = (rate_limits: PlanUsageReport['rate_limits']): PlanUsageReport => ({
  rate_limits_available: true,
  rate_limits,
})

const bothWindows = report({
  five_hour: { utilization: 11 },
  seven_day: { utilization: 54 },
})

describe('readSubscriptionUsage', () => {
  test('reports the two windows the plan measured, as live', async () => {
    expect(await readSubscriptionUsage(async () => bothWindows)).toEqual({
      fiveHourPct: 11,
      weeklyPct: 54,
      source: 'live',
    })
  })

  test('rounds to whole percent, because that is what the strip renders', async () => {
    const usage = await readSubscriptionUsage(async () =>
      report({ five_hour: { utilization: 11.4 }, seven_day: { utilization: 54.6 } }),
    )
    expect(usage).toEqual({ fiveHourPct: 11, weeklyPct: 55, source: 'live' })
  })

  test('keeps a measured zero rather than treating it as absent', async () => {
    const usage = await readSubscriptionUsage(async () =>
      report({ five_hour: { utilization: 0 }, seven_day: { utilization: 0 } }),
    )
    expect(usage).toEqual({ fiveHourPct: 0, weeklyPct: 0, source: 'live' })
  })

  // Every case below must throw. A resolved value here would be an invented
  // figure — the one outcome this ticket rules out.
  const refusals: [string, PlanUsageReport][] = [
    [
      'plan limits do not apply — API key, Bedrock, Vertex',
      { rate_limits_available: false, rate_limits: null },
    ],
    ['no windows at all', report(null)],
    ['the 5-hour window is absent', report({ seven_day: { utilization: 54 } })],
    ['the weekly window is absent', report({ five_hour: { utilization: 11 } })],
    [
      'the 5-hour window reported no utilization',
      report({ five_hour: { utilization: null }, seven_day: { utilization: 54 } }),
    ],
    [
      'the weekly window reported no utilization',
      report({ five_hour: { utilization: 11 }, seven_day: { utilization: null } }),
    ],
    [
      'a window is explicitly null',
      report({ five_hour: null, seven_day: { utilization: 54 } }),
    ],
  ]

  for (const [why, unusable] of refusals) {
    test(`refuses to invent a figure when ${why}`, async () => {
      await expect(readSubscriptionUsage(async () => unusable)).rejects.toThrow(/plan usage/i)
    })
  }

  test('lets a failed read fail, rather than answering with a default', async () => {
    await expect(
      readSubscriptionUsage(async () => {
        throw new Error('no agent session')
      }),
    ).rejects.toThrow('no agent session')
  })
})

/**
 * The answer, as it leaves the confined process.
 *
 * The read happens inside the Sandbox — the session is there and nowhere else —
 * so the two figures have to travel back out. This is that line, and it is a
 * codec on both sides of the wall: written by the agent host, read back by the
 * bridge on the way into Core.
 */
describe('the answer the confined session writes back', () => {
  test('a reading crosses as itself, on exactly one line', () => {
    const line = encodePlanUsageAnswer({
      requestId: 'u1',
      usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' },
    })
    expect(line.endsWith('\n')).toBe(true)
    expect(line.match(/\n/g)).toHaveLength(1)
    expect(parsePlanUsageAnswer(JSON.parse(line))).toEqual({
      requestId: 'u1',
      usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' },
    })
  })

  test('a failed read crosses as nothing, never as a figure', () => {
    // The whole rule, on the wire. A read that could not be answered has to be
    // answered *with nothing* rather than left unanswered: the caller would
    // otherwise wait out its patience for a reply that is never coming.
    const line = encodePlanUsageAnswer({ requestId: 'u1', usage: null })
    expect(parsePlanUsageAnswer(JSON.parse(line))).toEqual({ requestId: 'u1', usage: null })
    expect(line).not.toMatch(/\d+(\.\d+)?%/)
  })

  test('an answer is rebuilt field by field, like everything else crossing in', () => {
    const smuggled = {
      kind: 'plan-usage',
      requestId: 'u1',
      usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live', apiKey: 'sk-ant-NEVER' },
      cost: 12.5,
    }
    const answer = parsePlanUsageAnswer(smuggled)
    expect(answer).toEqual({
      requestId: 'u1',
      usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' },
    })
    expect(JSON.stringify(answer)).not.toContain('sk-ant')
    expect(JSON.stringify(answer)).not.toContain('cost')
  })

  test('the source is stamped here rather than believed', () => {
    // Anything arriving through this codec came from the plan, so `live` is
    // structural. A line claiming otherwise cannot make a measurement look
    // seeded — or, worse, make a seed look measured.
    expect(
      parsePlanUsageAnswer({
        kind: 'plan-usage',
        requestId: 'u1',
        usage: { fiveHourPct: 11, weeklyPct: 54, source: 'seeded' },
      }),
    ).toEqual({ requestId: 'u1', usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' } })
  })

  test('a line that is not an answer to a read is not read as one', () => {
    expect(parsePlanUsageAnswer(null)).toBeNull()
    expect(parsePlanUsageAnswer({ ready: true })).toBeNull()
    expect(parsePlanUsageAnswer({ kind: 'delta', turnId: 't1', text: 'hi' })).toBeNull()
    expect(parsePlanUsageAnswer({ kind: 'plan-usage', usage: null })).toBeNull()
    expect(parsePlanUsageAnswer({ kind: 'plan-usage', requestId: 'u1' })).toBeNull()
  })

  test('a figure that is not a figure is no answer at all', () => {
    // Not a rounding problem. A window that arrived as a string or a NaN is a
    // reading nobody made, and it renders beside the words "plan usage".
    for (const usage of [
      { fiveHourPct: '11', weeklyPct: 54, source: 'live' },
      { fiveHourPct: 11, weeklyPct: null, source: 'live' },
      { fiveHourPct: Number.NaN, weeklyPct: 54, source: 'live' },
      {},
    ]) {
      expect(parsePlanUsageAnswer({ kind: 'plan-usage', requestId: 'u1', usage })).toBeNull()
    }
  })
})
