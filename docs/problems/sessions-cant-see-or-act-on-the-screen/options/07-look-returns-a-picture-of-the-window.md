---
problem: sessions-cant-see-or-act-on-the-screen
title: `look` can also return a picture of the window, with password fields blacked out
summary: Accepted on 2026-10-10 at the user's request ("can we just build it"). `look` gains `picture: true` and an optional `rect`. Varnick captures the target window with ScreenCaptureKit, the capture the text step uses, blacks out the secure text fields its walk found, scales and encodes it to fit the socket, and returns it as an image next to the usual listing. Never Varnick's own windows. It needs Screen Recording. The picture shows everything on the window, typed text included, which the listing leaves out, and it goes to Anthropic with the session.
status: shipped
---

## Solution

`look` takes two more arguments. `picture: true` returns an image of the window it reads, in the same reply as the listing. `rect`, an area in screen points, crops the picture to that area. The reply's text says what the picture is: its pixel size and which part of the screen it shows, so a session can turn a spot in the picture into a point for `click`.

The running Varnick takes the picture, as it does everything. The relay only passes it on.

## Trade-offs

- **A picture shows what the listing never does.**
  - The listing leaves out what a field holds (ADR 0019) and the text step drops lines inside fields (ADR 0021). A picture of the window shows a message being typed, an unsaved draft, a number in a form, anything on the page.
  - It goes to Anthropic with the session and stays in its transcript. The switch's detail, the privacy docs and the ADR say so.
  - A session that only needs controls and short labels should not ask for a picture; the tool's description says so.
- **Password fields are hidden where Varnick can see them, and shown where it can't.**
  - The same walk `look` does finds the secure text fields, and their frames are painted black before the picture is encoded.
  - The gaps are the ones ADR 0021 accepted for reading and option 06 accepted for typing, and a few more (a walk cut short, a password shown in a plain field). The privacy doc lists them once.
  - When nothing is hidden the reply says "no password fields seen", unless the walk was cut short or Chrome hid its page, where it says it could not tell.
- **The picture is a little behind the walk.** The fields were found a moment before the capture. If the window moved, their frames move with it; if it changed size, the call is refused rather than guess.
- **A picture costs the session tokens and Varnick a second capture** when the session also asks for `text`. Taken as two captures, since one pipeline for both would change the text step Hey Varnick shares.

## User Stories

1. As a Varnick user, I want a session to see a window as I do, when its controls and labels don't say enough (a chart, a layout, a rendering bug).
2. As a Varnick user, I want a session to ask for just the part of the window it needs.
3. As a Varnick user, I want a password field that Varnick can see never to be in a picture.
4. As a Varnick user, I want the switch's detail to tell me that a picture shows everything on the window.
5. As a Varnick user, I want Varnick's log never to hold what a picture showed.

## Implementation Decisions

- **The capture** is the text step's: ScreenCaptureKit, the one window of the app that `look` read, so Varnick's panel and the Arrow are not in it, and no legacy-capture prompt. The window is chosen as the text step chooses it, by its overlap with the frame the walk read.
- **Which window.** The one `look` reads. Varnick's own windows are never read, as for `look`: an `app` of Varnick finds nothing.
- **Size.** The long side is scaled down to at most 1568 pixels, never up. The picture is encoded as JPEG at quality about 0.8, or as PNG when that is smaller.
- **It must fit the socket.**
  - The socket's lines are capped at 1,000,000 bytes, in both directions (peer requests included). A picture's base64 and the listing must fit under that, so the encoded picture is held to a limit worked out from the cap with headroom for the text.
  - A picture over it is encoded again at lower quality and then at a smaller size until it fits. The cap is not raised: it stays what it is for the relay's peer requests and for every reply.
  - Reading a line from the socket must stay linear in its length, since a reply is now hundreds of kilobytes.
- **`rect`** is in screen points as `point`'s is, taken relative to the captured window and cut to it. An area with no part in the window is refused.
- **Password fields.** The walk records the frame of every secure text field it meets, and of the focused one when it is secure. Each is painted black, with a few points of margin, in the scaled image after the crop, before encoding. The frames follow the window if it moved between the walk and the capture; a different size refuses the call.
- **Needs Screen Recording.** Without it the call is refused with the text step's words. Any other failure (no window, a timeout, a capture error) is refused with a short reason.
- **The reply** gets an image beside its text: an MCP image content item with the base64 data and the mime type. The picture's pixel size, the part of the screen it shows, and how many password fields were hidden are in the text.
- **The log** holds the picture's kind, pixel size and byte count, and how many fields were hidden. Never the picture, a title or a label.
- **The request's version stays 1.** The reply gets an optional field, and the new arguments are ignored by an older Varnick, which answers with the listing alone. Peers are untouched: a screen request still has no `op`.
- **A `rect` that was sent and can't be read is refused,** not dropped: a dropped one would return the whole window. Numbers as text, and the rectangle as JSON text, are read.
- **Docs.** ADR 0023's amendment, the privacy and security doc (which holds the one list of the black-out's gaps), the guide, the README's line, the Screen access switch's detail in Settings, the glossary's Screen access term, and the where-it-breaks doc, which says plainly that a picture shows everything on the window, typed text included, and goes to Anthropic with the session.

## Testing Decisions

- **No test target yet.** Verification is `make build`, then hand checks after the user restarts Varnick. A builder captures nothing and sends no tool call to a real tool.
- **Seams for a test target later:** the scale and the crop's pixel rectangle, the mapping of a field's frame into the picture, and the fit loop (with the encoder as an input).
- **`Varnick --mcp` on its own, with stdin from a file:** `tools/list` shows `picture` and `rect` on `look`.
- **By hand, in a session restarted with the switch on:**
  - `look` with `picture` at TextEdit returns the listing and an image of the window.
  - With `rect` on a corner of the window, the image is that corner, and its text says where.
  - Safari or System Settings with a password field: the field is black in the picture, and the text says one was hidden.
  - Chrome on a login page: the field shows (the gap, now measured).
  - A busy window (a photo, a spreadsheet) arrives under the cap.
  - With Screen Recording off, the call is refused.
  - Varnick's log holds kind, size and bytes only.

## Out of Scope

- A picture of the whole screen, of a window other than the one `look` reads, or of Varnick's own windows.
- Hiding anything but secure text fields: other fields, names, or anything a person might not want sent. A user who doesn't want typed text sent leaves the switch off.
- Reading text back out of the picture on the session's side; the text step stays as it is.
- Video, repeated captures, or a picture of a window while a drag or typing is under way.
- Permissioning, deferred as for option 01.

## Further Notes

- **Accepted on 2026-10-10** at the user's request, relayed by the coordinator: "can we just build it". Written with the build, on the same branch; the user can change any decision here.
- **Decided while writing (and after review):**
  - **One tool, one more argument,** not a tool of its own: a picture is a view of the same window the listing describes.
  - **A walk that was cut short is not a refusal.** The gap is recorded and the reply says it, as for a hidden Chrome page.
  - **The cap stays,** since the picture can be made to fit it.
  - **No version bump.**
- **Unverified:** how often a real window's secure fields are missed by the walk's limits (3000 nodes, one second); whether Claude Code limits an image in a tool result below the socket's cap.
