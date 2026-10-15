// Notifications: the section at the foot of Home, the subscription behind it, and the worker's messages (rules: pushrules.js). A push is for the
// host this page is served by; each host's page is its own origin and has its own permission and subscription (option 02 of
// phone-page-is-only-a-browser-tab). Everything the host sent goes in with textContent, never as markup.

import { getJSON, postJSON } from "/dom.js";
import { isIOS } from "/installrules.js";
import { keyBytes, openHash, pushState, sameKey, switchLabels, texts } from "/pushrules.js";
import { parseTabHash } from "/tabrules.js";

const $ = (id) => document.getElementById(id);

/** What the last look found. */
const known = { looked: false, hostSendsPush: false, key: null, host: "", subscription: null, switches: null, busy: false, error: "" };

const browserCanPush = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
const isInstalledApp = () =>
  ["standalone", "fullscreen", "minimal-ui"].some((mode) => window.matchMedia(`(display-mode: ${mode})`).matches) || navigator.standalone === true;
const ios = () => isIOS({ userAgent: navigator.userAgent, platform: navigator.platform, maxTouchPoints: navigator.maxTouchPoints });

/** The worker's registration once it is active; null if there is none within a few seconds (no secure context, a refused script). */
function registration() {
  if (!("serviceWorker" in navigator)) return Promise.resolve(null);
  return Promise.race([navigator.serviceWorker.ready, new Promise((resolve) => setTimeout(() => resolve(null), 5000))]);
}

function paint() {
  const state = pushState({
    looked: known.looked,
    browserCanPush: browserCanPush(),
    hostSendsPush: known.hostSendsPush,
    ios: ios(),
    installed: isInstalledApp(),
    permission: browserCanPush() ? Notification.permission : "default",
    subscribed: known.subscription !== null,
  });
  $("notify").hidden = state === "hidden";
  const line = { off: texts.off(known.host), on: texts.on(known.host), blocked: texts.blocked, "not-here": texts.notHere, unsupported: browserCanPush() ? texts.noHost : texts.noBrowser }[state] ?? "";
  $("notify-text").textContent = line;
  $("notify-switches").hidden = state !== "on";
  $("notify-on").hidden = state !== "off";
  $("notify-test").hidden = state !== "on";
  $("notify-off").hidden = state !== "on";
  for (const input of $("notify-switches").querySelectorAll("input")) {
    input.checked = known.switches?.[input.dataset.switch] !== false;
    input.disabled = known.busy;
  }
  for (const id of ["notify-on", "notify-test", "notify-off"]) $(id).disabled = known.busy;
  $("notify-error").textContent = known.error;
  $("notify-error").hidden = known.error === "";
}

/** Reads the host's key and this browser's subscription, and makes the two agree without asking the user anything. */
export async function lookAtPush() {
  const answer = await getJSON("/api/push");
  // A host that didn't answer says nothing here: the section appears once it does.
  known.looked = answer.ok;
  known.hostSendsPush = answer.ok && answer.supported === true;
  known.key = answer.key ?? null;
  known.host = answer.host ?? "";
  known.subscription = null;
  known.switches = null;
  if (known.hostSendsPush && browserCanPush() && Notification.permission === "granted") {
    const worker = await registration();
    let subscription = worker ? await worker.pushManager.getSubscription() : null;
    // A subscription made with a key the host no longer has can't be sent to: make a new one, with the permission already given.
    if (subscription && !sameKey(subscription.options.applicationServerKey, known.key)) {
      await subscription.unsubscribe().catch(() => {});
      subscription = await subscribeNow(worker);
      if (subscription) await register(subscription, null);
    }
    if (subscription) {
      const state = await postJSON("/api/push/state", { endpoint: subscription.endpoint }, "");
      if (state.ok && state.subscribed) {
        known.switches = state.switches;
        known.subscription = subscription;
      } else if (state.ok) {
        // The host lost it (its subscription file, a removed device added again): the browser's is still good.
        if (await register(subscription, null)) known.subscription = subscription;
      }
    }
  }
  paint();
}

const subscribeNow = (worker) =>
  worker.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(known.key) }).catch((error) => {
    known.error = `The browser wouldn't subscribe: ${error?.name ?? "error"}.`;
    return null;
  });

async function register(subscription, switches) {
  const result = await postJSON("/api/push/subscribe", { subscription: subscription.toJSON(), ...(switches ? { switches } : {}) }, "The host didn't answer. Check that you're on the tailnet.");
  if (result.ok) known.switches = result.switches;
  else known.error = result.error;
  return result.ok;
}

async function act(work) {
  if (known.busy) return;
  known.busy = true;
  known.error = "";
  paint();
  try {
    await work();
  } finally {
    known.busy = false;
    paint();
  }
}

/** Turn on: the permission is asked from this tap, then the browser subscribes and the host is told. */
const turnOn = () => act(async () => {
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return;
  const worker = await registration();
  if (!worker) { known.error = "This page's worker isn't running, so the browser can't deliver notifications."; return; }
  const subscription = await subscribeNow(worker);
  if (subscription && await register(subscription, null)) known.subscription = subscription;
});

const turnOff = () => act(async () => {
  const subscription = known.subscription;
  if (!subscription) return;
  const told = await postJSON("/api/push/unsubscribe", { endpoint: subscription.endpoint }, "The host didn't answer. Check that you're on the tailnet.");
  if (!told.ok) { known.error = told.error; return; }
  await subscription.unsubscribe().catch(() => {});
  known.subscription = null;
  known.switches = null;
});

const sendTest = () => act(async () => {
  const subscription = known.subscription;
  if (!subscription) return;
  const sent = await postJSON("/api/push/test", { endpoint: subscription.endpoint }, "The host didn't answer. Check that you're on the tailnet.");
  if (!sent.ok) known.error = sent.error;
});

const changeSwitch = (key, value) => act(async () => {
  const subscription = known.subscription;
  if (!subscription) return;
  await register(subscription, { ...known.switches, [key]: value });
});

/** Closes the notifications of a tab the page has just opened: it has been seen. */
export async function closeNotices(tab) {
  if (!browserCanPush() || Notification.permission !== "granted") return;
  const worker = await registration();
  const shown = worker ? await worker.getNotifications().catch(() => []) : [];
  for (const notice of shown) if (notice.data?.tab === tab) notice.close();
}

export function startPush(navigate) {
  for (const [key, label] of switchLabels) {
    const row = document.createElement("label");
    row.className = "switch";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.dataset.switch = key;
    input.addEventListener("change", () => changeSwitch(key, input.checked));
    row.append(input, document.createTextNode(` ${label}`));
    $("notify-switches").append(row);
  }
  $("notify-on").addEventListener("click", turnOn);
  $("notify-off").addEventListener("click", turnOff);
  $("notify-test").addEventListener("click", sendTest);
  // A tap on a notification reaches an open window as a message from the worker.
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.addEventListener("message", (event) => {
      if (event.data?.type === "open" && openHash(event.data.hash, parseTabHash)) navigate(event.data.hash);
    });
  }
  // The permission can change in the browser's own settings while the page is away.
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && !$("home").hidden) lookAtPush(); });
  lookAtPush();
}
