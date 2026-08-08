import { describe, expect, test } from 'bun:test'
import { readSubscriptionUsage, type PlanUsageReport } from './subscription.ts'

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
