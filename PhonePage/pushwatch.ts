// Watching the host's Claude panes for notices worth a push (option 02 of phone-page-is-only-a-browser-tab). The rules are pushrule.ts's; this is
// what carries them out against a clock, the host's own `tabs` listing, the presence files and the subscriptions. All of it is behind `PushWorld`,
// so `bun test` runs it on a fake clock. Nothing here is logged but a device's name, a kind, a status and a time.

import { objects } from "./json";
import type { RelayResult } from "./home";
import {
  allows, decide, failureWord, isTurnWord, payloadOf, presenceOf, route, settleMs, type Controller, type Notice, type PresenceReport, type PushPayload, type TurnWord,
} from "./pushrule";
import type { SendResult } from "./pushsend";
import type { Subscription, SubscriptionStore } from "./pushstore";

/** How often the watcher looks at the turn files' dates, the saved tabs and the standing notices. */
export const tickMs = 2000;
/** The host's `tabs` is asked again this often while a pane is in background or a notice stands, and this often otherwise. */
export const busyAskMs = 15_000;
export const idleAskMs = 60_000;
/** At most this many pushes to one device in an hour; past it pushes are dropped and counted in the log. */
export const perDeviceHourLimit = 60;
const hourMs = 3_600_000;
/** Two readings of a turn that began within this are one turn (a host's age is whole seconds). */
const sameTurnMs = 2000;

export interface PushWorld {
  now(): number;
  /** The host's own id: the controller of a pane that names nobody or the host. */
  ownID: string;
  /** `tabs` asked as the host itself; one ask serves this and the port proxy when both want one. */
  askTabs(): Promise<RelayResult>;
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
  send(subscription: Subscription, payload: PushPayload): Promise<SendResult>;
  log(line: string): void;
}

interface PaneReading {
  turn: TurnWord;
  /** When the turn began, in ms on the host's clock (the listing's time less the age). */
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
  /** The running word the notice stands for: an error that follows its waiting stands for the word before it. */
  from: TurnWord;
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

  constructor(private world: PushWorld, private store: SubscriptionStore) {}

  /** What the watcher holds for a pane, for the tests. */
  noticeFor(pane: string): Notice | undefined {
    return this.standing.get(pane)?.notice;
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
    return now - this.lastAsk >= (this.busy || this.standing.size > 0 ? busyAskMs : idleAskMs);
  }

  /** Asks the host's `tabs` and takes it in. A failure changes nothing: the old readings stand until an ask succeeds. */
  async refresh(): Promise<void> {
    this.asking ??= (async () => {
      try {
        const result = await this.world.askTabs();
        this.lastAsk = this.world.now();
        if (result.ok) this.observe(objects(result.reply.tabs));
      } finally {
        this.asking = null;
      }
    })();
    return this.asking;
  }

  private observe(tabs: Record<string, unknown>[]): void {
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
        const since = now - (typeof pane.turnAge === "number" ? pane.turnAge : 0) * 1000;
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
            notice: decision.notice, tab: tab.tab.toLowerCase(), raisedAt: replaces?.raisedAt ?? now, from: before!.turn === "waiting" ? "working" : before!.turn,
            confirmed: false, pushed: new Set(), handled: new Set(),
          });
        } else if (decision.action === "clear") {
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
    const due: Subscription[] = [];
    for (const subscription of this.store.all()) {
      if (standing.pushed.has(subscription.endpoint) || standing.handled.has(subscription.endpoint)) continue;
      const decision = route({
        controller, presence, elapsedMs: now - standing.raisedAt,
        deviceHasPaneOpen: this.world.hasPaneOpen(subscription.device, id), allowed: allows(subscription.switches, standing.notice),
      });
      if (decision === "drop") standing.handled.add(subscription.endpoint);
      else if (decision === "push") due.push(subscription);
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
    await Promise.all(due.map((subscription) => this.push(standing, subscription, payload)));
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

/** Which panes each device has open, from the terminal and live-screen sockets (they close when the page hides). */
export class OpenPanes {
  private open = new Map<string, number>();

  private key(device: string, pane: string): string {
    return `${device}:${pane.toLowerCase()}`;
  }

  /** A session name `varnick-<pane id>` as a socket opens it. */
  static paneOf(session: string): string | null {
    const match = /^varnick-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.exec(session);
    return match ? match[1].toLowerCase() : null;
  }

  add(device: string, session: string): void {
    const pane = OpenPanes.paneOf(session);
    if (pane) this.open.set(this.key(device, pane), (this.open.get(this.key(device, pane)) ?? 0) + 1);
  }

  remove(device: string, session: string): void {
    const pane = OpenPanes.paneOf(session);
    if (!pane) return;
    const key = this.key(device, pane), count = (this.open.get(key) ?? 0) - 1;
    if (count > 0) this.open.set(key, count);
    else this.open.delete(key);
  }

  has(device: string, pane: string): boolean {
    return this.open.has(this.key(device, pane));
  }
}

/** A value shared by every caller for a moment: one ask serves the port proxy and the watcher when both want it. */
export class Shared<T> {
  private at = -Infinity;
  private value: Promise<T> | null = null;

  constructor(private load: () => Promise<T>, private now: () => number, private maxAgeMs: number) {}

  get(): Promise<T> {
    if (this.value && this.now() - this.at < this.maxAgeMs) return this.value;
    this.at = this.now();
    const value = this.load();
    this.value = value;
    // A failure isn't kept: the next caller asks again.
    value.catch(() => { if (this.value === value) this.value = null; });
    return value;
  }
}
