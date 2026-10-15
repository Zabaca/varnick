---
problem: work-cant-be-shared-with-other-people
title: Share one window, or a whole display, as live video with a guest, who watches it in a pane of their own Varnick
summary: Built on option 01's guest door. The user picks one window, or a display with Varnick's own windows and password managers left out, and shares it with a guest. Varnick captures it with ScreenCaptureKit, under the Screen Recording grant it already holds, encodes it with VideoToolbox H.264, and sends it over the tailnet through the host's page server to the guest, whose Varnick shows it in a pane. It covers what tab sharing can't reproduce, such as a browser on a logged-in page or any app outside Varnick. View only. The first build streams over the guest's websocket, with no new dependency. WebRTC (Google's libwebrtc as a binary package) is the step after, if the measured latency or quality calls for it. Behind its own Screen sharing switch in Settings › Experimental, off by default. Ordered after option 01. Rough effort is a spike of a day, then about seven days.
status: proposed
---

## Solution

### What is shared, and how it starts

- **One window, or one display.** `!share screen` (with the switch on) opens a picker in the panel, built from ScreenCaptureKit's list of shareable content:
  - the windows on screen, by app and title, with a small live thumbnail;
  - each display, as "Whole display".
- **The person.** Below the list, the people who reach this Mac through a Tailscale share, as in option 01's sheet.
- **What the sheet says.** "Sam will see this window live, as you see it, including anything that appears in it (messages, typed text, a page you're logged in to). Sam can't click or type in it."
  - **For a display,** it says instead "Sam will see everything on this display except Varnick and the apps listed below", with the exclusion list.
- **A window share follows the window,** whatever is in front of it. A window covering it isn't captured, and the shared window's own menus and sheets may not be (inferred: each is a window of its own).

### What is left out of a display share

- **Varnick's own windows:** the panel, which shows the user's other tabs, and the Arrow.
- **Password managers,** from a short default list of bundle ids the user can edit in Settings.
- **Notification banners.**
- **Everything else** on the display is shared, and the sheet says so.
- **Window shares need none of this,** since only the window is captured.

### The indicator, and stopping

- **A thin coloured frame** around the shared window, or along the display's edge, drawn by a click-through overlay like the Arrow and itself left out of the capture.
- **A line in the status menu,** "Sharing <window> with Sam", whose action is Stop sharing.
- **macOS's own screen-capture indicator** shows too (inferred).
- **Stopping.** The share ends on Stop sharing, when the window closes, when the guest loses the Tailscale share, when Varnick quits or restarts, and when the switch goes off. It doesn't come back by itself.
- **The display stays awake** while a share runs (an idle-sleep assertion, held only then).

### What the guest sees

- **Where it is listed.** Shared screens are listed under the shared Mac in the guest's session list, beside its shared tabs: "Sam's screen: Safari — Pull request 42".
- **The pane.** ↩ opens a pane of its own kind that shows the video scaled to fit, with the share's name in a bar. When the stream stalls, the bar says so, and a Stop on the host closes the pane with a line saying why.
- **It is never saved.** A restart closes it.
- **View only.** Nothing the guest does reaches the host.

### Frame rate and bandwidth

These are starting figures, set in the spike and measured on the tailnet:
- **Frame rate.** Frames are captured only when the content changes, at most 30 a second, so a still window costs almost nothing.
- **Size.** The window's pixels, with the long edge capped at 1920 by default. A Retina window is scaled down unless the user picks Sharp text, which sends its full pixels.
- **Bitrate.** A ceiling of about 6 Mbps at the default size. Text needs bits more than motion does, and a window-sized ceiling tied to its pixel count is the lever (petal's experience: about 0.18 bits per pixel per frame, clamped).
- **When the link can't keep up.** The sender never queues video. When the guest's socket backs up, it drops frames up to the next keyframe, asks the encoder for one at once, and lowers the ceiling. It raises it again slowly once the socket is clear.
- **Over Tailscale.** A direct path carries this easily. Through Tailscale's relays (DERP) throughput is lower and latency higher, and the guest sees a softer, slower picture (inferred). The pane's bar shows the frame rate it gets.

### Transport

- **First build: H.264 over the guest's websocket.**
  - Encoded frames go from Varnick to the host's page server over an owner-only local socket. The page server sends them on a video websocket of the guest interface, which the guest's Varnick opened (a connection the guest starts, which is the only direction Tailscale's machine sharing allows).
  - The guest's pane decodes them in hardware (a sample-buffer display layer).
  - No new dependency.
- **Later, if measured to be needed: WebRTC.**
  - Google's libwebrtc as a prebuilt binary package (an xcframework fetched like zmx and Bun), with signalling over the guest interface.
  - It brings congestion control, a jitter buffer, loss recovery, audio and a browser-compatible stream for the web viewer under Later.
  - It costs a large binary framework to fetch, sign and notarize inside the app, and a new dependency `CODING_STANDARDS.md` would have to list.
  - It needs ICE to work over a one-way share, where the host can't open a path to the guest (unverified).

## Trade-offs

- **It shows what tabs can't.** A logged-in browser, a design tool, a simulator, a native app: pixels, as they are, with no proxy and no second session on the guest's side. Tab sharing (option 01) stays better for Varnick's own panes: text, any size, and a Scratch that is live on the guest's side.
- **Pixels leak more than panes do.** Whatever appears in the window or on the display is sent: a notification inside an app, a password field's dots and what is typed elsewhere in the window. The exclusions cover the known cases for a display. A window share is the safer default, and the picker lists windows first.
- **No new dependency first.** ScreenCaptureKit, VideoToolbox and AVFoundation are system frameworks. The websocket is the guest door option 01 builds.
- **TCP is not made for video.** A lost packet holds up the frames behind it. On a direct tailnet path that is rare. The rule of dropping to the next keyframe bounds the delay, but this is a screen share for reading, not for watching video. WebRTC fixes that at its own cost.
- **The Screen Recording grant gains a new use.** Varnick holds it already, for pointing at the screen and Screen access. Here it is used only after the user picks a window or display and a person, and is visible through the frame, the menu line and macOS's indicator.

## User Stories

1. As the user, I want to share one window of any app with a colleague who runs Varnick, so that they see a page I'm logged in to or an app outside Varnick.
2. As the user, I want to share a whole display without Varnick's panel, my password manager or my notifications in it.
3. As the user, I want to be told what the guest will see before the share starts.
4. As the user, I want a frame around what I'm sharing and a line in the status menu, so that I always know a share is running.
5. As the user, I want to stop the share in one click, and have it stop by itself when the window closes or Varnick quits.
6. As the guest, I want to open the shared window in a pane beside my own work and read its text.
7. As the guest on a slow path, I want a softer picture rather than one that falls further and further behind.
8. As the user with Screen sharing off, I want no capture, no video channel and nothing of it in the UI.

## Implementation Decisions

- **The switch.** Settings › Experimental › Screen sharing, off by default, separate from Tab sharing.
  - **Off:** no `!share screen`, no picker, no frame, no menu line, no capture, no video channel in the page server, and screen shares removed from the shares file.
  - **The guest door** answers a guest who holds a tab share or a screen share, so either switch can be on alone.
- **Shares.** Option 01's shares file gains screen shares: what is captured (a window id with its app and title, or a display id), the guest, when it began. The running Varnick writes them and removes them when the capture stops.
- **The capture runs in Varnick,** which holds the Screen Recording grant and draws the indicator. One stream per share, configured for the window's or display's size and the frame interval.
  - **For a display,** the content filter leaves out Varnick's own windows, the frame overlay, the apps on the exclusion list and Notification Center.
  - **Encoding** is VideoToolbox's hardware H.264, real-time, with a keyframe at the start, on request and every few seconds.
- **Frames reach the page server over an owner-only local socket** in the support folder, which the page server connects to. They are not carried by the relay or the peer protocol, so there is no peer protocol bump.
  - **The guest interface** gains a video channel (a minor version), admitted only for the guest the share names and only while it stands.
  - **Each guest has its own caps:** a few video channels.
- **The picker is Varnick's own,** from ScreenCaptureKit's shareable content, so the exclusions are under Varnick's control. Whether to use macOS's own content picker instead is a spike finding: on recent macOS it may spare the periodic capture prompt (unverified).
- **The guest's pane** is a new pane kind that decodes into a sample-buffer display layer and is never saved, so an older build never meets it in the saved file.
- **The order.** After option 01, since it needs option 01's guest identity, shares file, guest interface and the guest's shared-Mac transport.

### The spike (first ticket)

- Capture one window, encode it, send it over a websocket across the two Tailscale accounts of option 01's spike, and decode it in a pane.
- Measure the frame rate, the bitrate, the delay and the CPU on both Macs, for a text editor and for a scrolling page, on a direct path and through a relay.
- Check what a display filter leaves out, and how the shared window's menus and sheets appear.
- Find out whether macOS's content picker gives a filter Varnick can add exclusions to, and whether it avoids the recurring prompt.

Figures are kept locally in the problem's scratch folder. No daemon or launchd change is involved.

### Recorded

- An ADR once accepted: the capture, the exclusions and the transport.
- `docs/privacy-and-security.md` gains a section: what a guest sees, and that it goes over the tailnet only.

## Testing Decisions

- **Pure rules with tests:**
  - the exclusion list's matching;
  - the drop-to-keyframe rule and the ceiling's steps, from a simulated socket that backs up and clears;
  - the guest interface's admission for a video channel, for a guest with and without a screen share.
- **By hand, after a restart, with option 01's two accounts:**
  - share a Safari window on a logged-in page, a terminal and a whole display;
  - check that the panel, a password manager and a banner don't appear on the guest's side;
  - type and scroll on the host and read the guest's pane;
  - Stop sharing, close the window and quit Varnick, each of which must end the guest's pane with its reason;
  - turn the switch off and check that nothing of it shows.

## Out of Scope

- **The viewer acting on the screen.** Pointer, annotations and remote control. The pointer and annotations are the next step: the guest's pointer drawn on the host with the Arrow. Remote control would need Accessibility on the host and a consent prompt for each request, and is not planned.
- Audio.
- More than one share at a time.
- Sharing to the user's own paired Macs.
- A browser viewer.
- A public screen share.

## Further Notes

- **petal** (Apache-2.0, Rust and Tauri) was read for ideas, not code. These match its experience:
  - one ScreenCaptureKit stream per window;
  - hardware H.264;
  - a bitrate ceiling tied to the window's pixels, since small text suffers first;
  - an explicit exclusion list for display shares;
  - a display-sleep assertion while sharing;
  - a consent prompt for each remote-control request.
  
  It carries media over WebRTC through a hosted LiveKit server. A server in the middle is what this option avoids by staying on the tailnet.
- **Why not first.** It needs option 01's door. Built alone, it would have to build that door anyway, with a capture pipeline on top.
