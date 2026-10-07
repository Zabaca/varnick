// What every view of the page shares: building elements (always with textContent, never markup), the host's path as a phone shows it,
// and the page's two ways to ask the server, which never throw and say the same things for the same failures.

export function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** The host's path with the home folder as "~", since a phone screen is narrow. */
export const shortFolder = (folder) => folder.replace(/^\/(?:Users|home)\/[^/]+/, "~");

/** What a 403 means once the page has loaded: the device was removed from the host's list. */
export const notListed = "This device isn't on the host's list any more. Reload to see why.";

const refused = (response, result) => result.error ?? (response.status === 403 ? notListed : `The host answered ${response.status}.`);

/** GET: the JSON when the server said `ok`, else `{ok: false, error}`. */
export async function getJSON(url) {
  try {
    const response = await fetch(url, { cache: "no-store", headers: { accept: "application/json" } });
    const body = await response.json().catch(() => ({}));
    return response.ok && body.ok === true ? body : { ok: false, error: refused(response, body) };
  } catch {
    return { ok: false, error: "The host didn't answer. Check that you're on the tailnet." };
  }
}

/** POST a JSON body: the JSON the server answered with, or `{ok: false, error}`. `lost` is what a request that got no answer says. */
export async function postJSON(url, body, lost) {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(body),
    });
    const result = await response.json().catch(() => ({}));
    return response.ok && result.ok === true ? result : { ...result, ok: false, error: refused(response, result) };
  } catch {
    return { ok: false, error: lost };
  }
}
