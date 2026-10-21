// The menu in the session view's bar (protocol 33, ADR 0045): Done, Redraw and Restart, under one button. The items are wired where they act (tab.js,
// session.js), each showing and hiding itself by its own rules; this only shows the button while some item is shown, opens and closes the list, and
// closes it on a choice, on a tap outside and on Escape, and when the view goes. The menu is the page's own element, never the browser's.

const $ = (id) => document.getElementById(id);
const button = $("menu");
const list = $("menu-list");

function close(refocus) {
  if (!list.hidden) list.hidden = true;
  button.setAttribute("aria-expanded", "false");
  if (refocus) button.focus();
}

function open() {
  list.hidden = false;
  button.setAttribute("aria-expanded", "true");
}

/** The button follows the items: shown while one is, and the list shut when none is. */
function sync() {
  const any = [...list.children].some((item) => !item.hidden);
  if (button.hidden === any) button.hidden = !any;
  if (!any) close(false);
}

// Watching the items' own `hidden` is what keeps every module that shows one from having to tell the menu.
new MutationObserver(sync).observe(list, { attributes: true, attributeFilter: ["hidden"], subtree: true });
// The view going away (back to Home) shuts the list.
new MutationObserver(() => { if ($("session").hidden) close(false); }).observe($("session"), { attributes: true, attributeFilter: ["hidden"] });

button.addEventListener("click", () => (list.hidden ? open() : close(false)));
// A choice closes the list; the item's own handler has run by the time the click reaches it.
list.addEventListener("click", () => close(false));
document.addEventListener("click", (event) => {
  if (!list.hidden && !list.contains(event.target) && !button.contains(event.target)) close(false);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !list.hidden) close(true);
});
sync();
