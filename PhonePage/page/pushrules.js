// The Notifications section's pure rules, with no DOM: what `bun test` checks (PhonePage/pushpage.test.ts). The section is one of five states
// (option 02 of phone-page-is-only-a-browser-tab).

/**
 * - `hidden`: nothing to say yet (still looking).
 * - `unsupported`: this browser can't receive a push, or the host sends none.
 * - `not-here`: Safari on an iPhone, outside the installed app: push is for the Home Screen app alone.
 * - `blocked`: the permission was refused.
 * - `off`: a switch to turn on.
 * - `on`: the four switches, Send a test and Turn off.
 */
export function pushState({ looked, browserCanPush, hostSendsPush, ios, installed, permission, subscribed }) {
  if (!looked) return "hidden";
  // On an iPhone the page in Safari has no push API at all, so the hint comes before the check for one.
  if (ios && !installed) return "not-here";
  if (!browserCanPush || !hostSendsPush) return "unsupported";
  if (permission === "denied") return "blocked";
  return permission === "granted" && subscribed ? "on" : "off";
}

export const texts = {
  off: (host) => `Get a notification on this phone when a session on ${host} needs you, finishes, stops on an error or sends you a message.`,
  on: (host) => `This phone gets notifications from ${host} when you're away from the Mac a session runs on, and for sessions you drive from the phone.`,
  blocked: "Notifications are blocked for this page. Allow them in this browser's settings for the site, then come back.",
  notHere: "Add this page to the Home Screen from the Share menu, then open it from there to turn notifications on.",
  noBrowser: "This browser can't receive notifications from this page.",
  noHost: "Notifications aren't set up on this host.",
};

/** What the four switches are called, in the order the Mac's Settings has them, with the key the host stores them under. */
export const switchLabels = [
  ["needsMe", "Needs me"],
  ["done", "Done"],
  ["errors", "Errors"],
  ["messages", "Messages"],
];

/** A base64url string as the bytes a subscription is made with. */
export function keyBytes(text) {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

/** Whether a subscription was made with the host's key now: its `applicationServerKey` (bytes) against the key the host gave (base64url). */
export function sameKey(buffer, text) {
  if (!buffer || typeof text !== "string") return false;
  const have = new Uint8Array(buffer), want = keyBytes(text);
  return have.length === want.length && have.every((byte, index) => byte === want[index]);
}

/** The hash a worker's message may send the page to: a tab (and pane) or the home, nothing else. */
export function openHash(hash, parseTabHash) {
  return typeof hash === "string" && (hash === "" || hash === "#" || parseTabHash(hash) !== null);
}
