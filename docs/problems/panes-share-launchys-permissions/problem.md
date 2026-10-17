---
title: Processes in every Varnick pane share Varnick's macOS permissions
description: macOS attributes the processes in Varnick's panes to Varnick, zmx-hosted ones included, so they get whatever privacy permissions the user gave Varnick. Today that is the microphone and system audio. With Point at the screen granted, it is also Accessibility and Screen Recording: every Claude session, shell and tool in every pane can read and drive any app's UI and capture the screen, without asking.
impact: Granting Launchy Accessibility for Point at the screen grants it to every Claude session in its panes, including sessions started with Skip permissions, which act without a prompt. They can also click Allow in Launchy's own prompts, so no broker Launchy builds for sessions (`sessions-cant-see-or-act-on-the-screen`) can hold while this stands. Since builds are signed with Developer ID (ADR 0022), the grants survive rebuilds (measured 2026-10-09, 17a9ab6), so the exposure lasts until the user removes Launchy under Privacy & Security, not only until the next build. On 2026-10-09 the user accepted, with spoken-requests-cant-see-the-screen option 01, a plain line in Settings and SECURITY.md, which since 8e430d8 says every pane gets the grants.
severity: high
evidence: Raised by spoken-requests-cant-see-the-screen, accepted with its option 01 on 2026-10-09. Measured on 2026-10-09 from a zmx-hosted pane (sessions-cant-see-or-act-on-the-screen, Today). Code read on 2026-10-09 at 4090c28 and ca01eb4.
status: open
---

## Today

**Measured 2026-10-09: every pane, zmx-hosted ones included.**
- A process was run from a zmx-hosted pane. macOS's privacy service logged its attribution with Launchy (`com.zabaca.launchy`, at its build path) as responsible and the process's own binary as the binary.
- Accessibility and Screen Recording were then denied only because the Launchy on disk had been rebuilt after the user granted the running build.
- So a pane's process gets Launchy's grants whenever they match the build, and a grant to zmx or to the process's own binary is never consulted.
- **The effect is measured too.** With Launchy granted on a Developer-ID-signed build (ADR 0022), Accessibility and Screen Recording read true from a pane. They still did after `make build` and a restart with System Settings untouched.
- **So every pane keeps Launchy's screen grants across rebuilds.** A rebuild no longer switches them off.

This replaces two earlier readings:
- "only panes outside zmx share Launchy's grants; zmx panes are attributed to zmx", from `spoken-requests-cant-see-the-screen`'s eval;
- "each process is its own", from macOS's private responsibility lookup, which misled.

Why the eval saw a pane turn trusted after only zmx was granted is unexplained.

**How a pane starts.**
- `ClaudeSession.startInTerminal` runs a pane's command in zmx when Keep sessions running is on and zmx is there, and directly otherwise, as a child of Launchy, through SwiftTerm.
- Keep sessions running is off by default.
- A custom app's server always runs in zmx when zmx is there.

**No disclaim.** Neither Launchy nor SwiftTerm marks a child as responsible for itself: no such call is in `Sources/`, `Packages/` or SwiftTerm's checkout, and zmx imports only `fork`, `forkpty` and `setsid`. So responsibility very likely passes from Launchy to the first zmx and on to everything zmx starts, which fits the measurement.

**What Launchy holds:**
- the microphone and system audio, for Listening;
- Accessibility (ADR 0019) and Screen Recording (ADR 0021), for Point at the screen, once granted.

**The docs.** SECURITY.md, the Point at the screen detail text in Settings and `docs/agents/where-it-breaks.md` say every pane gets Launchy's grants, zmx-hosted ones included (fixed on 2026-10-09 in 8e430d8). The problem docs and ADRs 0019 and 0021 carry dated corrections.

## Left to decide

- **What holds until a fix.** Point at the screen stays available, with every session sharing its grants and the docs saying so, or Launchy's grants come off until the fix.
- **How to cut the link.** Possible directions:
  - start zmx and direct panes with responsibility disclaimed, through an undocumented macOS spawn attribute that SwiftTerm's spawn doesn't offer, so Launchy would spawn them itself. Measured on 2026-10-09 to work for a process started from a pane, not yet through zmx: option 01;
  - start panes through launchd, so their responsible process is their own.

  "Always run panes in zmx" no longer helps.
- **What a cut costs.** It cuts the microphone too: a tool in a pane that uses the mic would ask under its own name, or fail. Panes already running keep Launchy's responsibility until they are started again.
- **Exceptions.** Whether a pane the user picks may keep Launchy's grants: the per-pane idea `sessions-cant-see-or-act-on-the-screen` option 05 was reaching for.
- **zmx's rule.** "zmx is never granted" stays as a rule, though a grant to zmx was measured not to be consulted.
