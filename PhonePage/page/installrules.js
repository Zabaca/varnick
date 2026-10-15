// The install offer's pure rules, with no DOM: what `bun test` checks (PhonePage/install.test.ts).

/** What the home page's foot offers: "install" (a button, once Chrome has offered the install), "ios" (a hint), or null. */
export function installOffer({ installed, canPrompt, ios, dismissed }) {
  if (installed || dismissed) return null;
  if (canPrompt) return "install";
  return ios ? "ios" : null;
}

/** An iPhone, an iPod or an iPad, whose Safari has no install prompt: iPadOS says it is a Mac, but a Mac has no touch screen. */
export function isIOS({ userAgent = "", platform = "", maxTouchPoints = 0 }) {
  return /iPhone|iPad|iPod/.test(userAgent) || (platform === "MacIntel" && maxTouchPoints > 1);
}

export const iosHint = "Add to Home Screen from the Share menu to open this page as an app.";
export const installLine = "Install this page as an app, to open it full screen from your Home Screen.";

/** The page's local storage key for a dismissed offer: it is per host, as the page's storage is. */
export const dismissedKey = "install-offer-dismissed";
