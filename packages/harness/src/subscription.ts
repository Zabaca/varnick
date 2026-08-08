import type { SDKControlGetUsageResponse } from '@anthropic-ai/claude-agent-sdk'

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

/**
 * How the report is obtained. Always supplied by the caller — there is no
 * default, and that is a containment rule rather than a testing convenience.
 *
 * The control request rides a live Agent SDK session, and `query()` spawns a
 * Claude Code executable. Opening one here would put an agent process on the
 * host outside srt, on launch, in a clone where the agent can write
 * `.claude/settings.json` — and a SessionStart hook there would then run
 * unconfined. That is the one thing this product claims cannot happen
 * (ADR-0003). So the session is never created here: it is the confined one
 * ticket 03 establishes, passed in.
 */
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
export async function readSubscriptionUsage(read: ReadPlanUsageReport): Promise<PlanUsage> {
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
 * Take the report from a session that is already running under the Sandbox.
 *
 * `usage_EXPERIMENTAL_…` is the SDK method, called in exactly one place because
 * the SDK says its name will change. The session is a parameter and is never
 * created here: see {@link ReadPlanUsageReport} for why opening one would be an
 * unconfined agent process rather than an implementation detail.
 *
 * Nothing calls this yet. The confined session exists and now takes control
 * requests — a Turn is one — so what is left is a `TurnControl` kind that asks
 * for usage and a route for the answer. Until then `readSubscriptionUsage` has
 * no reader and the strip stays seeded, which is the honest state rather than a
 * chore left undone.
 */
export function reportFromSession(session: UsageCapableSession): ReadPlanUsageReport {
  return async () =>
    assignable(await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET())
}

/** The one method this module needs from a running session. */
export interface UsageCapableSession {
  usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(): Promise<SDKControlGetUsageResponse>
}
