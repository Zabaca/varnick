---
problem: sessions-cant-read-or-drive-varnick
title: Let the screen tools reach Varnick's own panel, as they reach any app
summary: The baseline, and the least to build. The screen tools stop leaving Varnick out. `look` reads the panel's Accessibility tree, as Hey Varnick already does, and `app: "Varnick"` names it. `click`, `drag` and `type` act on the panel with posted events, refused only over Settings and the Restart Varnick card, and `picture` can capture it. No new tools. But this is the pixels-and-events approach the user asked to move past. `look` never gives a field's value, so the Outline's bullets don't show, and a terminal pane exposes no text. Acting means taking the keyboard and the front. Recommended: not as the answer.
status: rejected
reason: Rejected by the user on 2026-10-11 (relayed by the coordinator). It works through pixels and posted events, the approach the user asked to move past, and it can't read a bullet's text, since the screen tools never read a field's value. Option 01 reads and acts through Varnick's model instead, and option 02 tests the panel's own key path.
---

## Solution

Screen access's six tools treat the panel like any other window:
- **`look`** reads Varnick's own process when the panel is key and visible, or when `app` is "Varnick". It uses Hey Varnick's panel-first read (`ScreenReader.panel()`), detached, with the main actor only awaiting it. With no `app`, it reads the app behind when the panel lists nothing the session asked about, as Hey Varnick does.
- **`click`, `drag` and `type`** may target the panel. They are refused over Settings and the Restart Varnick card, by frame and by what the model shows, so the controls that govern sessions stay out.
- **`picture`** may capture the panel.

## Trade-offs

- **The least to build:** a few refusals lifted, and new ones drawn around Settings.
- **It reads what Accessibility exposes,** not Varnick's model:
  - SwiftUI labels and buttons come through;
  - a text view's value doesn't, by the screen tools' own rule, so no bullet's text (a picture shows it);
  - a terminal pane exposes nothing (SwiftTerm's Accessibility is an empty stub).
- **To act, it must take the front.** A posted click or key needs the panel key, so it races whatever the user is doing. Keys meant for the panel can land in the session's own terminal.
- **The exclusion's reason needs redrawing.** The tools would reach every control on the panel except those carved out, instead of none. Every new control in Settings, or a new card that ends sessions, would need its own refusal.
- **Nothing for using Varnick's features.** An agent working in the Outline would type into it through the screen like a person: the reads can't see bullet text, and each edit races the user's typing.

## User Stories

1. As a Varnick user, I want a session to see and click Varnick's panel the way it sees and clicks any app.

## Implementation Decisions

- **`focusedApplication` and `application(named:)`** stop skipping Varnick's pid for sessions only. Hey Varnick's fall-through read keeps skipping it.
- **The own-pid and `varnickCovers` refusals** become refusals of Settings' frame and of the Restart Varnick card. The Arrow's panel is still never counted.
- **`varnickKey`** stays for typing aimed at another app. A `type` aimed at the panel posts only while the panel is key.
- **Docs:** ADR 0023 and `docs/privacy-and-security.md` (the panel is read and acted on), and where-it-breaks' Screen access.

## Testing Decisions

- `make build`. By hand after a restart: `look` with the panel key lists its buttons; `click` on the board's tab button switches tabs; `click` in Settings is refused.

## Out of Scope

- Reading a bullet's text through Accessibility, which would break the screen tools' rule on field values.

## Further Notes

- **Recommended: not as the answer.** It is the approach the user asked to move past ("not pixels and synthetic events"), and option 01 gives more for less risk.
- **One piece could follow later,** if a hand test needs the panel's control labels: `look` with `app: "Varnick"` reading the panel, without the actions.
