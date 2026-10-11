---
problem: sessions-cant-see-or-act-on-the-screen
title: `look` can return a picture of every display, or of one, with nothing blacked out
summary: Accepted on 2026-10-10 at the user's request ("let's add now. don't need to leave varnick's own window out, and don't worry about the gap"). `look` gains `screen: true` for a picture of every display and `display: N` for one, with `rect` to crop. Varnick captures each display with ScreenCaptureKit, Varnick's own windows included, and blacks out nothing, since it never read the windows on the screen. The reply lists the displays with their frames, and says each picture's area and pixels per point. It lists no controls unless an app is also named. It needs Screen Recording. A screen picture shows everything on every display, Varnick's panel and other sessions included, typed text and password fields included, and goes to Anthropic with the session.
status: accepted
---

## Solution

`look` takes two more arguments. `screen: true` returns a picture of every display, each as its own image in the one reply. `display: N` returns the one display numbered N, and needs no `screen`. `rect`, an area in screen points, crops the pictures to that area: a display it does not reach is left out. `picture` is not needed with them and is not taken as well; the screen pictures include the window.

The reply's text starts with a short "Displays:" list, one line per display with its number and its frame in screen points, the same top-left-origin coordinates as every other tool. Then it says, for each picture, its pixel size and the area it shows in screen points with its pixels per point, so a session can turn a spot in a picture into a point for `click` or `point`. The running Varnick takes the pictures, as it does everything. The relay only passes them on.

## Trade-offs

- **Nothing is blacked out, and the user chose that.**
  - Option 07 hid the password fields its walk of one window found. A screen picture shows windows `look` never read, so there is no walk to find their fields. The gap is the whole of it, and the reply says so plainly.
  - The privacy doc, which holds the one list of the gaps, gets this one: a screen picture hides nothing.
- **Varnick's own windows are in it,** by the user's choice. A picture of the screen shows Varnick's panel, with other sessions' text, and the Arrow when one is up. Option 07 kept Varnick's windows out; this one does not try.
- **It is the largest thing a session can be shown.** Everything on every display goes to Anthropic with the session and stays in its transcript on this Mac. The tool's description tells a session to ask only when a window's listing and picture are not enough.
- **The listing stays out of a screen picture.** A whole screen's controls would be large, and a picture is what was asked for. Naming an app as well gives that app's listing as usual, and then ids are replaced as for any look; a screen look without an app leaves the last look's ids as they were.
- **Several displays share one reply,** and the reply has the socket's line cap to fit under. Each picture is scaled down more the more displays there are, so a three-display Mac sends smaller pictures than a one-display one.

## User Stories

1. As a Varnick user, I want a session to see my whole screen when the thing it needs is not in one window (a menu bar, two windows side by side, a dialog from another app).
2. As a Varnick user, I want a session to ask for one display, or one area, when that is enough.
3. As a Varnick user, I want a session to turn a place in a picture into a point it can click or point at.
4. As a Varnick user, I want the switch's detail to say that a screen picture shows everything on every display and hides nothing.
5. As a Varnick user, I want Varnick's log never to hold what a picture showed.

## Implementation Decisions

- **Arguments.** `screen: true` or `display: N`; `rect` as for option 07. A `display` that is not a whole number from 1 to the number of displays is refused, and so is a `rect` that was sent and cannot be read, or that reaches none of the chosen displays. Both may be sent as text, as a model sends them.
- **Numbering.** The main display is 1, then the others from left to right and top to bottom by their frames. The numbers hold while the arrangement does.
- **The capture** is ScreenCaptureKit's display filter, one per display, at the display's pixel size. Varnick's own windows are not excluded and nothing is painted over. The pointer is not drawn.
- **No listing without an app.** A screen look names an app only if the session does; with one, the listing is that app's, as for any look, ahead of the screen part of the reply.
- **Size.**
  - The socket's lines are capped at 1,000,000 bytes, in both directions. All the pictures and the text must fit under it, so the budget is worked out from the cap as for option 07 and shared out: each picture gets an equal share of what is left after the pictures before it.
  - A single display's long side is at most 1568 pixels. With more displays it starts smaller, so that all the pictures together have about the pixels of one: the long side divided by the square root of the count, and not under 640.
  - Each picture is encoded as JPEG, or as PNG when that is smaller, and made again at lower quality and then at a smaller size until it fits, as for option 07. The cap does not move.
- **The reply** has one image content item per picture, in the order the text names them. The text says, for each: the display, the format, the pixel size, the area in screen points and the pixels per point. It then says that nothing was blacked out and what the pictures show.
- **Needs Screen Recording.** Without it the call is refused with the same words as option 07. Any other failure (a timeout, a capture error, no such display) is refused with a short reason.
- **The log** holds the kind, the count of pictures, and each one's format, pixel size and byte count. Never a picture, a frame or anything on the screen.
- **No peer protocol change, and the request's version stays 1.** The request gets two optional arguments and the reply an optional list of images. An older Varnick ignores the arguments and answers with a window listing alone; an older server shows a screen reply's text and no image.
- **Docs.** ADR 0023's amendment, the privacy and security doc, the guide, the README's line, the glossary's Screen access term, the Screen access switch's detail in Settings, and the where-it-breaks doc, which says plainly that a screen picture shows everything on every display, Varnick's panel and other sessions included, typed text and password fields included, and goes to Anthropic with the session.

## Testing Decisions

- **No test target yet.** Verification is `make build`, then hand checks after the user restarts Varnick. A builder captures nothing and sends no tool call to a real tool.
- **Seams for a test target later:** the display order, the long side for a count, the budget share, and the fit loop with the encoder as an input.
- **`Varnick --mcp` on its own, with stdin from a file:** `tools/list` shows `screen` and `display` on `look`.
- **By hand, in a session restarted with the switch on:**
  - `look` with `screen` returns the Displays list and one image per display, and the text's areas match the frames.
  - With `display` 2, one image of that display; with a number past the last, a refusal.
  - With `rect` over part of one display, only that display's part comes back.
  - With `app` as well, that app's listing comes before the screen part.
  - On a Mac with two or three displays the whole reply arrives and each picture is readable.
  - A click at a spot worked out from a picture's area and scale lands on that spot.
  - With Screen Recording off, the call is refused.
  - Varnick's log holds kind, count, sizes and bytes only.

## Out of Scope

- Excluding or hiding anything: Varnick's own windows, other apps, secure fields in windows `look` never read.
- A picture of a window other than the one `look` reads, other than as part of a display.
- Reading text out of the pictures on Varnick's side; the text step stays as it is.
- Video, repeated captures, or a picture while a drag or typing is under way.
- Permissioning, deferred as for option 01.

## Further Notes

- **Accepted on 2026-10-10** at the user's request: "let's add now. don't need to leave varnick's own window out, and don't worry about the gap". The gap is that password fields in windows Varnick never read cannot be painted black. Written with the build, on the same branch; the user can change any decision here.
- **Decided while writing:**
  - **Names.** `screen` and `display` sit beside `app`, `text`, `picture` and `rect`; `display` alone is enough, so a session names what it wants once.
  - **No listing without an app,** and no new ids from a screen look, so a session's last ids stay good.
  - **The pointer is not drawn,** as in the window picture.
  - **The version stays 1.**
- **Unverified:** how large a three-display reply comes out on a busy desktop, and whether Claude Code limits the images in one tool result below the socket's cap.
