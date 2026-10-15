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

/**
 * What a change of turn tells the user (Swift's `NoticeKind`). `failure` is the kind's word ("rate limit"), null when the host didn't say. `message` is a
 * message the session sent itself (option 04); its words are never in the notice, only in the tabs the worker asks for.
 */
export type Notice = { kind: "done" } | { kind: "needs"; turn: Waiting } | { kind: "failed"; failure: string | null } | { kind: "message" };

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

// ---------------------------------------------------------------------------------------------------------------
// A message the session sent itself (option 04 of phone-page-is-only-a-browser-tab): `NoticeRule.decide(message:)` and `NoticeRule.merge` in Swift.

/**
 * What a change of a pane's message tells the user. `old` and `next` are the message's id, the message file's date on the host's clock in ms (the
 * same number every time the message is read, a new one for the next), null for none.
 *
 * | What happens | Notice |
 * |---|---|
 * | the first message read for the pane (`first`: a start of the server, a pane that appeared) | none: a starting point |
 * | a message whose id is not the last one's | Message, replacing what stands |
 * | the message is gone (the next prompt, `/clear`, a start), also at the first reading | none, clears a standing message |
 *
 * `clear` is for a standing Message only: the caller keeps any other notice.
 */
export function decideMessage(input: { old: number | null; next: number | null; first: boolean }): Decision {
  if (input.next === null) return input.first || input.old !== null ? { action: "clear" } : { action: "none" };
  if (input.first || input.old === input.next) return { action: "none" };
  return { action: "raise", notice: { kind: "message" } };
}

/**
 * A turn's decision over the notice that stands (`NoticeRule.merge`). A standing Message is folded into by a Done (nothing is raised: the turn's
 * end is what the message announced) and stays when the turn goes on or a dialog is answered; Needs you and an error replace it. Any other
 * standing notice is the turn's decision alone.
 */
export function merge(decision: Decision, standing: Notice | undefined): Decision {
  if (standing?.kind !== "message") return decision;
  if (decision.action === "raise" && decision.notice.kind !== "done") return decision;
  return { action: "none" };
}

// ---------------------------------------------------------------------------------------------------------------
// Where a notice goes

/**
 * A Done still standing this long after it was raised is pushed. It absorbs a turn that flickers straight back to work, and the up to 5 s a
 * presence report takes.
 */
export const doneSettleMs = 10_000;
/**
 * A Needs-you notice or an error still standing this long is pushed. Short, because the user is waiting on it and a hand test showed 10 s long
 * enough to open the app and look for the 3 s that count as seen before the push left; neither flickers back the way a Done does (the Mac's
 * `SessionNotifier` raises a Needs-you at once, and settles only Done and errors, for about 1 s).
 */
export const urgentSettleMs = 2_000;

/** How long a notice stands before it may be pushed. A message is deliberate and doesn't flicker back, so it settles as Needs you does. */
export const settleOf = (notice: Notice): number => (notice.kind === "done" ? doneSettleMs : urgentSettleMs);
/** At most one push for a message per pane in this long: the newest words are pushed at the end of it, if the message still stands. */
export const messageGapMs = 60_000;
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
  /** The Claude panes (lowercase ids) the Mac holds a standing notice for, and those it shows on screen; absent from a Mac that doesn't say. */
  notices?: string[];
  onScreen?: string[];
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
 * The settle is `settleOf` the notice: 10 s for a Done, 2 s for Needs you, for an error and for a message.
 *
 * `drop` is for good: the category is switched off, this device has looked at the pane while the notice stood (`view`), or the controlling Mac
 * has shown the user the notice (`seen`, from `macView`). `wait` is for now, and includes a device that has the pane open and visible but not yet
 * long enough to have seen the notice: it either keeps looking (drop) or leaves (the push goes).
 * The host itself is a Mac like any other, except that a pane of its own with no client attached (a restored pane nobody opened) is still
 * its own Varnick's to notify, so it isn't "can't be told" for that.
 */
export function route(input: RouteInput): Route {
  return decideRoute(input).route;
}

/** What this device has of the pane: it is not looking, it is looking (open and visible) but not yet for long, or it looked long enough to have seen. */
export type View = "none" | "viewing" | "seen";

export interface RouteInput {
  controller: Controller;
  presence: Presence;
  /** What stands, which sets the settle (`settleOf`). */
  notice: Notice;
  elapsedMs: number;
  view: View;
  allowed: boolean;
  seen: boolean;
}

/** Why a notice goes, waits or is dropped: what the log says, so a hand test can tell. */
export type Why = "switch" | "open-pane" | "seen-on-mac" | "viewing" | "settle" | "present" | "away" | "unknown" | "detached" | "device";

export function decideRoute(input: RouteInput): { route: Route; why: Why } {
  if (!input.allowed) return { route: "drop", why: "switch" };
  if (input.view === "seen") return { route: "drop", why: "open-pane" };
  if (input.seen) return { route: "drop", why: "seen-on-mac" };
  if (input.view === "viewing") return { route: "wait", why: "viewing" };
  if (input.elapsedMs < settleOf(input.notice)) return { route: "wait", why: "settle" };
  const { controller } = input;
  if (controller.kind === "device") return { route: "push", why: "device" };
  if (controller.kind === "mac" && controller.detached) return { route: "push", why: "detached" };
  return input.presence === "present" ? { route: "wait", why: "present" } : { route: "push", why: input.presence };
}

/** A device that has the pane open and visible this long while a notice stands has seen it. */
export const seenAfterMs = 3000;

/**
 * What the controlling Mac's report says of one standing notice. The page server only has its own copy of the notice; the Mac may have shown it
 * to the user since, and locking and leaving must not push what was seen. So a notice the Mac listed in a report and no longer lists, or whose
 * pane a report of a present user shows on screen, is seen. A Mac that never listed it (its Settings switch for the category is off, the notice not yet raised, an
 * old report) is no evidence: the notice stands. Only a fresh report written after the notice was raised counts. `held` is whether an earlier
 * report listed it; both answers are kept by the caller once true.
 */
export function macView(input: { report: PresenceReport | null; presence: Presence; pane: string; raisedAtSeconds: number; held: boolean }): { held: boolean; seen: boolean } {
  const { report, held } = input;
  if (!report || input.presence === "unknown" || !report.notices || !report.onScreen || report.at < Math.floor(input.raisedAtSeconds)) return { held, seen: false };
  const listed = report.notices.includes(input.pane);
  // A pane on screen of a Mac that is away (locked, asleep) isn't looked at: its panel may well stay up.
  return { held: held || listed, seen: (input.presence === "present" && report.onScreen.includes(input.pane)) || (held && !listed) };
}

// ---------------------------------------------------------------------------------------------------------------
// The wire and the words

export interface Switches {
  needsMe: boolean;
  done: boolean;
  errors: boolean;
  /** A message the session sent itself. A subscription saved before this build has none, and reads as on. */
  messages: boolean;
}

export const defaultSwitches: Switches = { needsMe: true, done: true, errors: true, messages: true };

/** The switch a notice belongs to (Swift's `NoticeSwitches.allows`). */
export const allows = (switches: Switches, notice: Notice): boolean =>
  notice.kind === "needs" ? switches.needsMe : notice.kind === "done" ? switches.done : notice.kind === "message" ? switches.messages : switches.errors;

/** What a push carries (version 1): ids and the kind, and for an error its kind's word. Never a title, prompt, folder, screen or a message's words (ADR 0038). */
export type PushPayload =
  | { v: 1; kind: "test" }
  | { v: 1; kind: "done" | "message" | Waiting; tab: string; pane: string }
  | { v: 1; kind: "failed"; tab: string; pane: string; failure?: string };

export function payloadOf(notice: Notice, tab: string, pane: string): PushPayload {
  if (notice.kind === "done") return { v: 1, kind: "done", tab, pane };
  if (notice.kind === "message") return { v: 1, kind: "message", tab, pane };
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
