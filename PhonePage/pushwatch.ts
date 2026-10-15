// Watching the host's Claude panes for notices worth a push (option 02 of phone-page-is-only-a-browser-tab). The rules are pushrule.ts's; this is
// what carries them out against a clock, the host's own `tabs` listing, the presence files and the subscriptions. All of it is behind `PushWorld`,
// so `bun test` runs it on a fake clock. Nothing here is logged but a device's name, a kind, a status and a time.

import { objects } from "./json";
import type { RelayResult } from "./home";
import {
  allows, decide, decideRoute, failureWord, isTurnWord, macView, payloadOf, presenceOf, seenAfterMs, settleMs, type Controller, type Notice, type Presence,
  type PresenceReport, type PushPayload, type Route, type TurnWord, type View, type Why,
} from "./pushrule";
import type { SendOptions, SendResult } from "./pushsend";
import type { Subscription, SubscriptionStore } from "./pushstore";
import { isSessionName } from "./terminal";

/** How often the watcher looks at the turn files' dates, the saved tabs and the standing notices. */
export const tickMs = 2000;
/** The host's `tabs` is asked again this often while a pane is in background or a notice stands, and this often otherwise. */
export const busyAskMs = 15_000;
export const idleAskMs = 60_000;
/** At most this many pushes to one device in an hour; past it pushes are dropped and counted in the log. */
export const perDeviceHourLimit = 60;
const hourMs = 3_600_000;
/**
 * Two readings of a turn that began within this are one turn. A host's age is whole seconds, counted at the relay's run, and an answer may be the
 * shared ask's up to 1.5 s old (`Shared`), so two readings of one turn differ by that and a relay run, not by a new turn.
 */
const sameTurnMs = 5000;

export interface PushWorld {
  now(): number;
  /** The host's own id: the controller of a pane that names nobody or the host. */
  ownID: string;
  /** `tabs` asked as the host itself; one ask serves this and the port proxy when both want one. `startedAt` is when that ask began (unix ms). */
  askTabs(): Promise<{ result: RelayResult; startedAt: number }>;
  /** The date (unix ms) of each pane's turn file, 0 for a pane with none. */
  turnDates(panes: string[]): Map<string, number>;
  /** Whether a pane folder has appeared since the last call (a pane started that the listing may not have). */
  newPaneFolder(): boolean;
  /** A string that changes when the saved tabs change; "none" where the host gives no file. */
  tabsStamp(): string;
  /** The devices the host lists, by id, and their names. */
  devices(): ReadonlyMap<string, string>;
  presence(controller: string): PresenceReport | null;
  /** Whether the device has the pane's terminal or live view open. */
  hasPaneOpen(device: string, pane: string): boolean;
  send(subscription: Subscription, payload: PushPayload, options?: SendOptions): Promise<SendResult>;
  log(line: string): void;
}

/** A notice as the log names it: its kind, the payload's word (`done`, `permission`, `failed`). */
const noticeLabel = (notice: Notice): string => payloadOf(notice, "", "").kind;

interface PaneReading {
  turn: TurnWord;
  /** When the turn began, in ms on the host's clock (the ask's start less the age). */
  since: number;
}

interface PaneFacts {
  tab: string;
  control: string | null;
  clients: number | null;
}

interface Standing {
  notice: Notice;
  tab: string;
  raisedAt: number;
  /** The controlling Mac listed it in a report, and has shown it to the user since (`macView`): once true, true. */
  held: boolean;
  seen: boolean;
  /** Per device: since when its pane has been open and visible without a break, and those that looked long enough to have seen the notice. */
  viewing: Map<string, number>;
  looked: Set<string>;
  /** The last decision logged for each subscription (by endpoint), so a line is written when it changes and not at every tick. */
  logged: Map<string, string>;
  /** Read again after the settle, before it is pushed (the turn file is written just before the transcript says whether background work or an error goes with a waiting). */
  confirmed: boolean;
  /** The subscriptions (by endpoint) it was pushed to, and those it was dropped for. */
  pushed: Set<string>;
  handled: Set<string>;
}

export class PushWatcher {
  private readings = new Map<string, PaneReading>();
  private facts = new Map<string, PaneFacts>();
  private standing = new Map<string, Standing>();
  private lastPush = new Map<string, number>();
  private sent = new Map<string, number[]>();
  private dates = new Map<string, number>();
  private stamp = "";
  private lastAsk = -Infinity;
  private asking: Promise<void> | null = null;
  private busy = false;
  private ticking = false;
  /** Sends under way. They run off the tick: a retry waits for a push service's Retry-After, up to two minutes, and the tick must not. */
  private inFlight = new Set<Promise<void>>();

  constructor(private world: PushWorld, private store: SubscriptionStore) {}

  /** What the watcher holds for a pane, for the tests. */
  noticeFor(pane: string): Notice | undefined {
    return this.standing.get(pane)?.notice;
  }

  /** Resolves when the sends under way are over, for the tests. */
  async settled(): Promise<void> {
    while (this.inFlight.size > 0) await Promise.all([...this.inFlight]);
  }

  /** Whether any standing notice still has a subscription it may yet be pushed to: one pushed to every subscription is done. */
  private anyWaiting(): boolean {
    for (const standing of this.standing.values()) {
      if (this.store.all().some((subscription) => !standing.pushed.has(subscription.endpoint) && !standing.handled.has(subscription.endpoint))) return true;
    }
    return false;
  }

  /** One look. Nothing is watched without a subscription, and what was learned goes with the last one. */
  async tick(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    try {
      if (this.store.all().length === 0) return this.reset();
      this.store.dropUnlisted(new Set(this.world.devices().keys()));
      if (this.store.all().length === 0) return this.reset();
      if (this.shouldAsk()) await this.refresh();
      for (const pane of [...this.standing.keys()]) await this.deliver(pane);
    } finally {
      this.ticking = false;
    }
  }

  private reset(): void {
    this.readings.clear();
    this.facts.clear();
    this.standing.clear();
    this.dates.clear();
    this.lastAsk = -Infinity;
  }

  /** When `tabs` is asked: a turn's date or the saved tabs changed, a new pane folder appeared, or the interval ran out. */
  private shouldAsk(): boolean {
    const now = this.world.now();
    if (this.lastAsk === -Infinity) return true;
    const stamp = this.world.tabsStamp();
    const dates = this.world.turnDates([...this.facts.keys()]);
    let changed = stamp !== this.stamp || this.world.newPaneFolder();
    for (const [pane, date] of dates) if (this.dates.get(pane) !== date) changed = true;
    if (changed) return true;
    return now - this.lastAsk >= (this.busy || this.anyWaiting() ? busyAskMs : idleAskMs);
  }

  /** Asks the host's `tabs` and takes it in. A failure changes nothing: the old readings stand until an ask succeeds. */
  async refresh(): Promise<void> {
    this.asking ??= (async () => {
      try {
        const { result, startedAt } = await this.world.askTabs();
        this.lastAsk = this.world.now();
        if (result.ok) this.observe(objects(result.reply.tabs), startedAt);
      } finally {
        this.asking = null;
      }
    })();
    return this.asking;
  }

  /** `startedAt` is when the ask began: a turn's age is counted at the relay's run, which is after it, never at the reply. */
  private observe(tabs: Record<string, unknown>[], startedAt: number): void {
    const now = this.world.now();
    const seen = new Set<string>();
    const facts = new Map<string, PaneFacts>();
    this.busy = false;
    for (const tab of tabs) {
      if (typeof tab.tab !== "string") continue;
      for (const pane of objects(tab.panes)) {
        if (pane.kind !== "claude" || pane.running !== true || typeof pane.id !== "string") continue;
        const id = pane.id.toLowerCase();
        seen.add(id);
        facts.set(id, {
          tab: tab.tab.toLowerCase(),
          control: typeof pane.control === "string" && pane.control !== "" ? pane.control.toLowerCase() : null,
          clients: typeof pane.clients === "number" ? pane.clients : null,
        });
        // A word this watcher doesn't know is a newer host's: the pane stays as it was.
        if (!isTurnWord(pane.turn)) continue;
        if (pane.turn === "background") this.busy = true;
        const since = startedAt - (typeof pane.turnAge === "number" ? pane.turnAge : 0) * 1000;
        const before = this.readings.get(id);
        const decision = decide({
          old: before?.turn ?? null,
          next: pane.turn,
          failure: pane.turn === "failed" && typeof pane.failure === "string" ? failureWord(pane.failure) : null,
          interrupted: pane.esc === true,
          sameTurn: before !== undefined && Math.abs(before.since - since) <= sameTurnMs,
        });
        if (decision.action === "raise") {
          // An error that follows its waiting in the same turn takes over the Done's wait: the settle is for the turn, not for each word.
          const replaces = before!.turn === "waiting" && decision.notice.kind === "failed" ? this.standing.get(id) : undefined;
          this.standing.set(id, {
            notice: decision.notice, tab: tab.tab.toLowerCase(), raisedAt: replaces?.raisedAt ?? now, held: false, seen: false,
            viewing: new Map(), looked: new Set(), logged: new Map(), confirmed: false, pushed: new Set(), handled: new Set(),
          });
          this.world.log(`push notice ${noticeLabel(decision.notice)} raised`);
        } else if (decision.action === "clear") {
          const gone = this.standing.get(id);
          if (gone) this.world.log(`push notice ${noticeLabel(gone.notice)} cleared`);
          this.standing.delete(id);
        }
        this.readings.set(id, { turn: pane.turn, since });
      }
    }
    // A pane that is gone from the listing takes what it had with it.
    for (const id of [...this.readings.keys()]) {
      if (!seen.has(id)) { this.readings.delete(id); this.standing.delete(id); this.lastPush.delete(id); }
    }
    this.facts = facts;
    this.dates = this.world.turnDates([...facts.keys()]);
    this.stamp = this.world.tabsStamp();
  }

  private controllerOf(pane: PaneFacts): Controller {
    if (pane.control === null || pane.control === this.world.ownID.toLowerCase()) return { kind: "host" };
    if (this.world.devices().has(pane.control)) return { kind: "device" };
    return { kind: "mac", detached: pane.clients === null || pane.clients <= 0 };
  }

  /** Pushes one standing notice to each subscription that should have it now. */
  private async deliver(id: string): Promise<void> {
    const standing = this.standing.get(id);
    const pane = this.facts.get(id);
    if (!standing || !pane) return;
    const now = this.world.now();
    const controller = this.controllerOf(pane);
    const report = controller.kind === "device" ? null : this.world.presence(controller.kind === "host" ? this.world.ownID : pane.control!);
    const presence = presenceOf(report, now / 1000);
    // Whether the controlling Mac has shown the user the notice, which the page server can't see for itself: looked at on every tick, not only when due.
    if (controller.kind !== "device") {
      const view = macView({ report, presence, pane: id, raisedAtSeconds: standing.raisedAt / 1000, held: standing.held });
      standing.held = view.held;
      standing.seen ||= view.seen;
    }
    const due: Subscription[] = [];
    for (const subscription of this.store.all()) {
      if (standing.pushed.has(subscription.endpoint) || standing.handled.has(subscription.endpoint)) continue;
      const decision = decideRoute({
        controller, presence, elapsedMs: now - standing.raisedAt, seen: standing.seen,
        view: this.viewOf(standing, subscription.device, id, now), allowed: allows(subscription.switches, standing.notice),
      });
      this.logDecision(standing, subscription, decision, controller, presence);
      if (decision.route === "drop") standing.handled.add(subscription.endpoint);
      else if (decision.route === "push") due.push(subscription);
    }
    if (due.length === 0) return;
    // At most one push per pane per settle.
    if (now - (this.lastPush.get(id) ?? -Infinity) < settleMs) return;
    // The read after the settle: a Done that background work or an error was about to replace, or a dialog answered since, isn't pushed.
    if (!standing.confirmed) {
      standing.confirmed = true;
      await this.refresh();
      if (this.standing.get(id) === standing) return this.deliver(id);
      return;
    }
    this.lastPush.set(id, now);
    const payload = payloadOf(standing.notice, standing.tab, id);
    // Not awaited: a retry inside a send waits for the push service, and nothing else may wait with it.
    for (const subscription of due) {
      const sending = this.push(standing, subscription, payload).finally(() => this.inFlight.delete(sending));
      this.inFlight.add(sending);
    }
  }

  /**
   * What the device has of the pane while the notice stands: looking (open and visible) for under `seenAfterMs`, or long enough to have seen it.
   * A view that ends before it counts starts over, so a pane glanced at and left is a pane to push for.
   */
  private viewOf(standing: Standing, device: string, pane: string, now: number): View {
    if (standing.looked.has(device)) return "seen";
    if (!this.world.hasPaneOpen(device, pane)) {
      standing.viewing.delete(device);
      return "none";
    }
    const since = standing.viewing.get(device) ?? now;
    standing.viewing.set(device, since);
    if (now - since < seenAfterMs) return "viewing";
    standing.looked.add(device);
    return "seen";
  }

  /**
   * One line when a subscription's decision for a standing notice changes, so a hand test can tell why a push did or didn't come. The kind,
   * the device's name, the controller's kind and what the report said, never a pane's or tab's id, a title or the report's numbers.
   */
  private logDecision(standing: Standing, subscription: Subscription, decision: { route: Route; why: Why }, controller: Controller, presence: Presence): void {
    const outcome = {
      drop: `suppressed(${decision.why})`,
      wait: `waiting(${decision.why})`,
      push: "pushing",
    }[decision.route];
    const by = controller.kind === "mac" ? (controller.detached ? "mac-detached" : "mac") : controller.kind;
    const line = `push decide ${noticeLabel(standing.notice)} ${this.world.devices().get(subscription.device) ?? "device"} -> ${outcome} controller=${by}${controller.kind === "device" ? "" : ` presence=${presence}`}`;
    if (standing.logged.get(subscription.endpoint) === line) return;
    standing.logged.set(subscription.endpoint, line);
    this.world.log(line);
  }

  private async push(standing: Standing, subscription: Subscription, payload: PushPayload): Promise<void> {
    const name = this.world.devices().get(subscription.device) ?? "device";
    const now = this.world.now();
    const recent = (this.sent.get(subscription.device) ?? []).filter((at) => now - at < hourMs);
    if (recent.length >= perDeviceHourLimit) {
      this.sent.set(subscription.device, recent);
      standing.handled.add(subscription.endpoint);
      this.world.log(`push ${name} ${payload.kind} dropped: ${perDeviceHourLimit} an hour`);
      return;
    }
    recent.push(now);
    this.sent.set(subscription.device, recent);
    standing.pushed.add(subscription.endpoint);
    const result = await this.world.send(subscription, payload);
    this.world.log(`push ${name} ${payload.kind} ${result.outcome} ${result.status ?? "-"}`);
    if (result.outcome === "sent") this.store.record(subscription, "success", this.world.now());
    else if (result.outcome === "gone") this.store.drop(subscription);
    else this.store.record(subscription, "failure", this.world.now());
  }
}

/**
 * One terminal or live-screen socket of a device, for a pane. The pane is open on the device while the page says it is visible: Android keeps a
 * hidden app's socket for over a minute, and a pane nobody is looking at is not one a notice can have been seen on. The terminal's page sends
 * `visibility` when it hides or shows (`terminal.ts`); the live screen's socket is closed when the page hides, so it is visible while it exists.
 */
export class OpenPane {
  visible = true;

  constructor(private panes: OpenPanes, readonly device: string, readonly pane: string) {}

  setVisible(visible: boolean): void {
    this.visible = visible;
  }

  close(): void {
    this.panes.release(this);
  }
}

/** The panes each device has open and visible, from the terminal and live-screen sockets. */
export class OpenPanes {
  private entries = new Set<OpenPane>();

  /** A session name `varnick-<pane id>` as a socket opens it. */
  static paneOf(session: string): string | null {
    return isSessionName(session) ? session.slice("varnick-".length) : null;
  }

  /** Counts a socket as open, visible, until it is closed. Null for a name that isn't a pane's session. */
  open(device: string, session: string): OpenPane | null {
    const pane = OpenPanes.paneOf(session);
    if (!pane) return null;
    const entry = new OpenPane(this, device, pane);
    this.entries.add(entry);
    return entry;
  }

  release(entry: OpenPane): void {
    this.entries.delete(entry);
  }

  /** Whether the device has the pane open and visible: any of its sockets for it. */
  has(device: string, pane: string): boolean {
    const wanted = pane.toLowerCase();
    for (const entry of this.entries) if (entry.device === device && entry.pane === wanted && entry.visible) return true;
    return false;
  }
}

/** A value shared by every caller for a moment: one ask serves the port proxy and the watcher when both want it. */
export class Shared<T> {
  private at = -Infinity;
  private startedAt = -Infinity;
  private value: Promise<T> | null = null;

  constructor(private load: () => Promise<T>, private now: () => number, private maxAgeMs: number) {}

  get(): Promise<T> {
    return this.stamped().then((answer) => answer.value);
  }

  /** The answer with the time its ask began, which is what a turn's age is counted from. */
  stamped(): Promise<{ value: T; startedAt: number }> {
    if (this.value && this.now() - this.at < this.maxAgeMs) {
      const kept = this.startedAt;
      return this.value.then((value) => ({ value, startedAt: kept }));
    }
    this.at = this.startedAt = this.now();
    const startedAt = this.startedAt;
    const value = this.load();
    this.value = value;
    // A failure isn't kept: the next caller asks again.
    value.catch(() => { if (this.value === value) this.value = null; });
    return value.then((answer) => ({ value: answer, startedAt }));
  }
}
