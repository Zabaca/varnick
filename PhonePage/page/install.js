// Installing the page as an app: the service worker's registration and the offer at the foot of Home (rules: installrules.js).
// Chrome's `beforeinstallprompt` drives the Install button; Safari has no such event, so it gets a hint.

import { dismissedKey, installLine, installOffer, iosHint, isIOS } from "/installrules.js";

const $ = (id) => document.getElementById(id);
let prompt = null;
let installed = false;

const storage = {
  read: () => { try { return localStorage.getItem(dismissedKey) === "1"; } catch { return false; } },
  write: () => { try { localStorage.setItem(dismissedKey, "1"); } catch { /* private mode: the offer shows again next time */ } },
};

const isInstalledApp = () =>
  ["standalone", "fullscreen", "minimal-ui"].some((mode) => window.matchMedia(`(display-mode: ${mode})`).matches) || navigator.standalone === true;

function paint() {
  const offer = installOffer({
    installed: installed || isInstalledApp(),
    canPrompt: prompt !== null,
    ios: isIOS({ userAgent: navigator.userAgent, platform: navigator.platform, maxTouchPoints: navigator.maxTouchPoints }),
    dismissed: storage.read(),
  });
  $("install").hidden = offer === null;
  $("install-text").textContent = offer === "ios" ? iosHint : installLine;
  $("install-button").hidden = offer !== "install";
}

async function install() {
  const asked = prompt;
  if (!asked) return;
  // Chrome allows one prompt per event: whatever the user chose, this one is spent.
  prompt = null;
  asked.prompt();
  const { outcome } = await asked.userChoice.catch(() => ({ outcome: "dismissed" }));
  if (outcome === "accepted") installed = true;
  else storage.write();
  paint();
}

export function startInstall() {
  // The worker's scope is the whole page. A failure (no secure context, a browser without workers, an unlisted device's refusal) loses only the note.
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js", { scope: "/", updateViaCache: "none" }).catch(() => {});
  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    prompt = event;
    paint();
  });
  window.addEventListener("appinstalled", () => {
    installed = true;
    prompt = null;
    paint();
  });
  $("install-button").addEventListener("click", install);
  $("install-dismiss").addEventListener("click", () => {
    storage.write();
    paint();
  });
  paint();
}
