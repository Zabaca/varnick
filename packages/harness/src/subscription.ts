import { query, type SDKControlGetUsageResponse } from '@anthropic-ai/claude-agent-sdk'

/**
 * Plan usage across the rolling windows, read from the plan itself.
 *
 * The source was the open question this file answers. It is the Agent SDK's
 * `get_usage` control request — the structured data behind Claude Code's
 * `/usage` — which carries `rate_limits.five_hour` and `rate_limits.seven_day`
 * utilization as percentages measured server-side by claude.ai. It is not a
 * tally of what this application has seen, and deliberately so: a locally
 * derived figure would move with one machine's traffic while the plan window
 * counts every device, and a number that close to right is worse than none.
 *
 * The SDK marks that method experimental and says its name will change. That
 * is why it is called in exactly one place — here — behind a function whose
 * own shape is ours.
 */

/** One rolling window as the plan reports it. */
export interface PlanUsageWindow {
  /** Percentage of the window used, 0-100. Null when the plan reported none. */
  readonly utilization: number | null
}

/**
 * The part of the SDK's usage response this read depends on.
 *
 * Narrow on purpose: `SDKControlGetUsageResponse` also carries session cost,
 * per-model breakdowns, and a local-transcript behaviour scan, none of which
 * belong in a plan-usage read. `assignable` below is what keeps this narrowing
 * honest — if the SDK changes either window, the build fails here.
 */
export interface PlanUsageReport {
  readonly rate_limits_available: boolean
  readonly rate_limits: {
    readonly five_hour?: PlanUsageWindow | null
    readonly seven_day?: PlanUsageWindow | null
  } | null
}

const assignable: (report: SDKControlGetUsageResponse) => PlanUsageReport = (report) => report

/** What the Harness hands back. Structurally the Core's `SubscriptionUsage`. */
export interface PlanUsage {
  readonly fiveHourPct: number
  readonly weeklyPct: number
  /**
   * Always `live`. A seeded figure comes from the seeded actors, never from
   * here, so this function has no way to report anything else.
   */
  readonly source: 'live'
}

/** How the report is obtained. Injected so the seam under test is this file. */
export type ReadPlanUsageReport = () => Promise<PlanUsageReport>

class PlanUsageUnavailable extends Error {
  constructor(why: string) {
    super(`plan usage is unavailable — ${why}`)
    this.name = 'PlanUsageUnavailable'
  }
}

/**
 * A window's utilization, or a refusal.
 *
 * Absent, null, and non-finite all mean the same thing: the plan did not say.
 * Each returns a throw rather than a fallback, because the caller renders this
 * beside the word "plan usage" and a substituted default would read as a
 * measurement.
 */
function utilizationOf(window: PlanUsageWindow | null | undefined, name: string): number {
  const utilization = window?.utilization
  if (typeof utilization !== 'number' || !Number.isFinite(utilization)) {
    throw new PlanUsageUnavailable(`the plan reported no ${name} window`)
  }
  return Math.round(utilization)
}

/**
 * Read the 5-hour and weekly plan-usage windows.
 *
 * Throws whenever the plan did not supply both. The Harness machine's
 * `subscription` region sends a failed read back to `unread` with context
 * untouched, so throwing is how "leave whatever was last known" is spelled.
 */
export async function readSubscriptionUsage(
  read: ReadPlanUsageReport = readReportFromAgentSession,
): Promise<PlanUsage> {
  const report = await read()

  // False for API-key, Bedrock, and Vertex sessions, where no plan exists to
  // have windows. There is nothing to show and nothing to guess.
  if (!report.rate_limits_available || report.rate_limits === null) {
    throw new PlanUsageUnavailable('this session runs without a claude.ai plan')
  }

  return {
    fiveHourPct: utilizationOf(report.rate_limits.five_hour, '5-hour'),
    weeklyPct: utilizationOf(report.rate_limits.seven_day, 'weekly'),
    source: 'live',
  }
}

/**
 * The real read: open an agent session, ask it, close it.
 *
 * The control request needs a live session because that is the only channel
 * the SDK exposes it on. The session is closed in `finally` so a read that
 * throws does not leave a Claude Code process behind.
 */
export async function readReportFromAgentSession(): Promise<PlanUsageReport> {
  const session = query({ prompt: '', options: { maxTurns: 0 } })
  try {
    return assignable(await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET())
  } finally {
    await session.return(undefined)
  }
}
