// When something is worth telling the phone, and where it goes (option 02 of phone-page-is-only-a-browser-tab). Pure: no I/O, no clock.
//
// The first half, `decide`, is `NoticeRule.decide` in Packages/VarnickPeer (sessions-finish-unnoticed, option 01) in this language: the same
// table, so the Mac and the phone say the same thing. A change to the table, the failed word or a kind's wording is a change to both.
// The second half, `route`, is this option's: which notice goes to the phone, and when, by who controls the pane and whether they are there.

/** The turn words a pane can have (Swift's `Turn`). A word this list lacks is a newer host's: the watcher skips such a pane. */
export const turnWords = ["working", "waiting", "permission", "question", "plan", "input", "background", "failed"] as const;
export type TurnWord = (typeof turnWords)[number];

export const isTurnWord = (word: unknown): word is TurnWord => typeof word === "string" && (turnWords as readonly string[]).includes(word);

export type Waiting = "permission" | "question" | "plan" | "input";

/** What a change of turn tells the user (Swift's `NoticeKind`). `failure` is the kind's word ("rate limit"), null when the host didn't say. */
export type Notice = { kind: "done" } | { kind: "needs"; turn: Waiting } | { kind: "failed"; failure: string | null };

export type Decision = { action: "none" } | { action: "clear" } | { action: "raise"; notice: Notice };

const running = (word: TurnWord): boolean => word === "working" || word === "background";

/**
 * The table, from the pane's old word to its new one. `old` is null for the first word read for the pane (a start of the server, a pane that
 * appeared), which is a starting point and raises nothing.
 *
 * | From | To | Notice |
 * |---|---|---|
 * | working or background | waiting, not from Esc or Deny | Done |
 * | any other word | permission, question, plan or input | Needs you |
 * | working or background | failed | Stopped on an error |
 * | waiting, in the same turn | failed | Stopped on an error |
 * | anything | working or background | none, clears |
 * | permission, question, plan or input | waiting | none, clears |
 *
 * Any change the table has no row for clears too. Whether the user is shown it is `route`'s.
 */
export function decide(input: { old: TurnWord | null; next: TurnWord; failure?: string | null; interrupted?: boolean; sameTurn?: boolean }): Decision {
  const { old, next } = input;
  if (old === null || old === next) return { action: "none" };
  switch (next) {
    case "working":
    case "background":
      return { action: "clear" };
    case "waiting":
      return running(old) && !input.interrupted ? { action: "raise", notice: { kind: "done" } } : { action: "clear" };
    case "permission":
    case "question":
    case "plan":
    case "input":
      return { action: "raise", notice: { kind: "needs", turn: next } };
    case "failed":
      return running(old) || (old === "waiting" && input.sameTurn === true)
        ? { action: "raise", notice: { kind: "failed", failure: input.failure ?? null } }
        : { action: "clear" };
  }
}

/** The word a Needs you or an error stands for in the turn: what the pane's turn must still be for the notice to hold. */
export function noticeTurn(notice: Notice): TurnWord {
  return notice.kind === "done" ? "waiting" : notice.kind === "needs" ? notice.turn : "failed";
}

// ---------------------------------------------------------------------------------------------------------------
// Where a notice goes

/** A notice still standing this long after it was raised is pushed. It absorbs a turn that flickers and the up to 5 s a presence report takes. */
export const settleMs = 10_000;
/** A Mac with no input for this long is away. */
export const awayAfterSeconds = 120;
/** A presence report older than this is "can't be told": the Mac is asleep, Varnick isn't running, the link is down or it runs an older build. */
export const staleAfterSeconds = 20;
/** A report dated further ahead than this is nobody's (the host's own clock wrote it). */
const skewSeconds = 5;

export interface PresenceReport {
  /** Seconds since the last input, when the Mac measured it. */
  idle: number;
  /** Locked, display asleep, or its login session switched away. */
  away: boolean;
  /** Unix seconds on the host's clock when the host wrote the report. */
  at: number;
}

export type Presence = "present" | "away" | "unknown";

/**
 * Present means the screen is unlocked, the display awake, the login session the active one and the last input under two minutes ago. The
 * input grows older after the report: idle plus its age. No report, or one too old, can't be told.
 */
export function presenceOf(report: PresenceReport | null, nowSeconds: number): Presence {
  if (!report) return "unknown";
  const age = nowSeconds - report.at;
  if (age > staleAfterSeconds || age < -skewSeconds) return "unknown";
  if (report.away) return "away";
  return report.idle + Math.max(0, age) >= awayAfterSeconds ? "away" : "present";
}

/** Who controls the pane. A host's own panes are the host Mac's; `detached` is a peer Mac whose client is gone (Last controlled on). */
export type Controller = { kind: "host" } | { kind: "mac"; detached: boolean } | { kind: "device" };

export type Route = "push" | "wait" | "drop";

/**
 * One device's subscription, for one standing notice:
 *
 * | The controller | Push |
 * |---|---|
 * | a Mac whose user is present | none while it stays present; sent when it turns away with the notice still standing |
 * | a Mac whose user is away | after the settle |
 * | a Mac that can't be told (no report, or its client detached) | after the settle |
 * | a device | after the settle |
 *
 * `drop` is for good: the category is switched off, or this device has the pane open. `wait` is for now.
 * The host itself is a Mac like any other, except that a pane of its own with no client attached (a restored pane nobody opened) is still
 * its own Varnick's to notify, so it isn't "can't be told" for that.
 */
export function route(input: { controller: Controller; presence: Presence; elapsedMs: number; deviceHasPaneOpen: boolean; allowed: boolean }): Route {
  if (!input.allowed || input.deviceHasPaneOpen) return "drop";
  if (input.elapsedMs < settleMs) return "wait";
  const { controller } = input;
  if (controller.kind === "device") return "push";
  if (controller.kind === "mac" && controller.detached) return "push";
  return input.presence === "present" ? "wait" : "push";
}

// ---------------------------------------------------------------------------------------------------------------
// The wire and the words

export interface Switches {
  needsMe: boolean;
  done: boolean;
  errors: boolean;
}

export const defaultSwitches: Switches = { needsMe: true, done: true, errors: true };

/** The switch a notice belongs to (Swift's `NoticeSwitches.allows`). */
export const allows = (switches: Switches, notice: Notice): boolean =>
  notice.kind === "needs" ? switches.needsMe : notice.kind === "done" ? switches.done : switches.errors;

/** What a push carries (version 1): ids and the kind, and for an error its kind's word. Never a title, prompt, folder or screen. */
export type PushPayload =
  | { v: 1; kind: "test" }
  | { v: 1; kind: "done" | Waiting; tab: string; pane: string }
  | { v: 1; kind: "failed"; tab: string; pane: string; failure?: string };

export function payloadOf(notice: Notice, tab: string, pane: string): PushPayload {
  if (notice.kind === "done") return { v: 1, kind: "done", tab, pane };
  if (notice.kind === "needs") return { v: 1, kind: notice.turn, tab, pane };
  return notice.failure ? { v: 1, kind: "failed", tab, pane, failure: notice.failure } : { v: 1, kind: "failed", tab, pane };
}

/** The error kinds as a notice says them (`TurnFailure.word`); `other` and anything unknown read "API error". */
export function failureWord(wire: unknown): string {
  switch (wire) {
    case "rate_limit": return "rate limit";
    case "overloaded": return "overloaded";
    case "server_error": return "server error";
    case "authentication_failed": return "authentication failed";
    default: return "API error";
  }
}
