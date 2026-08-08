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
 * The one caller is `runAgentHost` in ./agent.ts, which hands it the session it
 * is already holding, inside `srt`. That is the whole of the wiring: the read
 * happens where the session is, and only the two figures come back out.
 */
export function reportFromSession(session: UsageCapableSession): ReadPlanUsageReport {
  return async () =>
    assignable(await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET())
}

/** The one method this module needs from a running session. */
export interface UsageCapableSession {
  usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(): Promise<SDKControlGetUsageResponse>
}

// ---------------------------------------------------------------------------
// The answer, on its way back out of the Sandbox
// ---------------------------------------------------------------------------

/**
 * What the confined process says about one read.
 *
 * `usage` is `null` for every way the read did not produce two figures — no
 * plan, a missing window, a session that threw. It is a value rather than an
 * absent line on purpose: a read that is simply never answered leaves the host
 * waiting out its patience, and a wait that times out is indistinguishable from
 * a slow agent. Answering with nothing fails the read immediately and leaves
 * whatever was last known on screen.
 *
 * There is no field for a reason. The failure happens against the API, so its
 * prose is where a rejected credential would be — the same rule
 * `turnFailureMessage` follows in ./turn.ts, applied to a read that has exactly
 * one thing to say.
 */
export interface PlanUsageAnswer {
  readonly requestId: string
  readonly usage: PlanUsage | null
}

/** The wire's own name for this line, so nothing else is read as one. */
const PLAN_USAGE_ANSWER_KIND = 'plan-usage'

/**
 * What to tell the developer when a read produced no figures.
 *
 * Authored here, selected by nothing: there is one sentence because there is one
 * outcome. It names what is on screen rather than what went wrong, because the
 * developer's question when a read fails is whether the number they can still
 * see is a number they can still trust.
 */
export const PLAN_USAGE_UNAVAILABLE =
  'The agent session did not report plan usage, so nothing was measured. Any figures shown are the last ones that were.'

/**
 * One answer, as one line.
 *
 * `JSON.stringify` escapes newlines, so nothing here can split the line and
 * desynchronise the pipe — the same framing every other channel in this codebase
 * uses, for the same reason.
 */
export function encodePlanUsageAnswer(answer: PlanUsageAnswer): string {
  return `${JSON.stringify({ kind: PLAN_USAGE_ANSWER_KIND, ...answer })}\n`
}

/** One window's figure, or nothing. Not a rounding question — see below. */
function figureOf(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * Read an answer back, or refuse it.
 *
 * Rebuilt rather than passed through, like every answer that crosses into Core.
 * Two things this does beyond checking shape:
 *
 *   * `source` is *stamped* rather than read. Everything arriving through this
 *     codec came from the plan through the confined session, so `live` is
 *     structural — and a line claiming otherwise must not be able to make a
 *     measurement look seeded, or a seed look measured.
 *   * a figure that is not a finite number makes the whole answer unreadable
 *     rather than half of one. This renders beside the words "plan usage", and
 *     the one rule the surface has is that a number there was measured.
 */
export function parsePlanUsageAnswer(value: unknown): PlanUsageAnswer | null {
  const { kind, requestId, usage } = (value ?? {}) as Record<string, unknown>
  if (kind !== PLAN_USAGE_ANSWER_KIND) return null
  if (typeof requestId !== 'string' || requestId.length === 0) return null
  if (usage === null) return { requestId, usage: null }
  if (usage === undefined || typeof usage !== 'object') return null

  const { fiveHourPct, weeklyPct } = usage as Record<string, unknown>
  const fiveHour = figureOf(fiveHourPct)
  const weekly = figureOf(weeklyPct)
  if (fiveHour === null || weekly === null) return null

  return { requestId, usage: { fiveHourPct: fiveHour, weeklyPct: weekly, source: 'live' } }
}
