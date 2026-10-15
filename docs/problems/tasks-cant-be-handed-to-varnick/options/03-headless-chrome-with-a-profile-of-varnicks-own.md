---
problem: tasks-cant-be-handed-to-varnick
title: The same loop drives headless Chrome with a profile of Varnick's own, through Chrome's DevTools protocol, as the pilots did
summary: Option 01's harness, Jev, Claude and gates, but the surface is the engine the pilots measured. Varnick starts the installed Google Chrome headless, with a fresh profile folder of its own, and drives it through Chrome's DevTools protocol. It reads pages from Chrome's accessibility tree, with password fields redacted, and acts through the same protocol. The figures carry over most directly, and Chrome renders sites as most users see them. But the user has no page to watch or type into, only pictures sent to a pane. A password has to be relayed by Varnick from a field of its own, the task depends on Chrome being installed, and Varnick would be starting a remotely controlled browser, the kind of process that malware detection watches for. Not recommended first. Kept as the fallback if option 01's WebKit fails real sites that Chrome passes.
status: proposed
---

## Solution

- **Starting.** As option 01: `!task` or the Task tile, then an address and the task. The pane shows a picture of the headless page, refreshed after each step, and the steps column.
- **Chrome.** The user's installed Google Chrome, started headless by Varnick with a new profile folder under Varnick's support folder, deleted when the task ends. It talks over a pipe, never a debugging port on the network, and has no window. Chrome refuses remote debugging on the user's default profile (inferred from Chrome's published change in 2025), so a profile of Varnick's own is required anyway.
- **The client.** A DevTools-protocol client in Varnick, or Playwright through the bundled Bun. Whether Playwright runs on Bun is unverified.
- **Reading.** Chrome's accessibility tree, with password fields redacted before anything else sees it: the leak the pilots found was Playwright's snapshot showing a typed password. Text blocks carry their landmark, and links inside text blocks are listed, the parser bug the pilots fixed.
- **Passwords.** The user types the password into a secure field in the pane, and Varnick relays it into the page. It passes through Varnick's process, though never a model or a log.
- **Taking over.** There is no page to click. "Take over" opens the page's address in a Browser pane, without the task's cookies, or ends the task and leaves the user to start again.

## Trade-offs

- **For:**
  - **the engine the pilots measured,** so their figures transfer best;
  - **Chrome's compatibility** with sites built for it;
  - **no screen and no permission,** like option 01.
- **Nothing to watch or touch.** Pictures are a poor view of a moving page, and the user can't step in where they are.
- **A password through Varnick's hands.** Option 01 never holds it.
- **Chrome must be installed,** and Chrome's updates change the protocol and the headless mode under Varnick.
- **A remotely controlled browser started by Varnick.** Infostealers use the same mechanism to reach a browser's cookies, so malware detection may watch for it. XProtect has already killed a Claude process for a mix of installs, launchctl and a downloaded binary (ADR 0013). This is inferred risk, not a measured one, and the spike can't settle it.
- **Weight.** Playwright and its driver, or a protocol client written and maintained in Varnick.
- **Headless Chrome is often flagged as a bot** by the sites themselves (inferred).

## User Stories

1. As the user, I want tasks to behave on sites as Chrome does, so that a site that works in my browser works for the task.
2. As the user, I want nothing of my own Chrome profile touched, so that my logins and history stay mine.

## Implementation Decisions

- The harness core, Jev, Claude and the gates are option 01's. Only the page seam changes.
- Chrome is started per task, as a child of Varnick, and killed when the task ends. It is never a daemon or a LaunchAgent, and nothing of it outlives Varnick.

## Testing Decisions

- agent-lab's hybrid-browser-13 is this option's measurement already, on the practice shop. Follow-up tests 4 and 5 of option 01 would run here in Chrome instead of WebKit.

## Out of Scope

- The user's own Chrome profile, or a visible Chrome window.

## Further Notes

- Not recommended first. Option 01 gives the user a page to watch and touch, keeps passwords out of Varnick, and needs nothing installed. If option 01's follow-up test 4 shows WebKit failing sites that Chrome passes, this is the fallback, behind the same switch and the same seam.
