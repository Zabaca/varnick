---
name: varnick
description: A desktop harness for a coding agent, drawn as instrumentation around a terminal session.
colors:
  ground: "#1a1b26"
  ground-raised: "#1f2030"
  rule: "#2c2e40"
  fg: "#c0caf5"
  fg-dim: "#8b8fa3"
  fg-faint: "#565f89"
  accent: "#7dcfff"
  ok: "#4ea96f"
  warn: "#e0af68"
  bad: "#f7768e"
  transcript-rose: "#cd694a"
  transcript-gray: "#949494"
typography:
  body:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.6
  transcript:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  chrome:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.6
  micro:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: 1.6
  numeric:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.6
    fontFeature: "tnum"
rounded:
  none: "0"
  scroll: "6px"
spacing:
  hairline: "1px"
  tight: "4px"
  snug: "6px"
  base: "8px"
  gutter: "12px"
  shell-x: "24px"
  shell-y: "16px"
components:
  action-inline:
    textColor: "{colors.accent}"
    rounded: "{rounded.none}"
    padding: "0"
    typography: "{typography.body}"
  choice-button:
    textColor: "{colors.fg}"
    backgroundColor: "{colors.ground}"
    rounded: "{rounded.none}"
    padding: "6px 12px"
    typography: "{typography.body}"
  choice-button-selected:
    textColor: "{colors.fg}"
    rounded: "{rounded.none}"
    padding: "6px 12px"
  field-secret:
    textColor: "{colors.fg}"
    backgroundColor: "{colors.ground}"
    rounded: "{rounded.none}"
    padding: "6px 12px"
    typography: "{typography.body}"
  panel:
    backgroundColor: "{colors.ground-raised}"
    textColor: "{colors.fg-dim}"
    rounded: "{rounded.none}"
    padding: "12px"
  admission:
    textColor: "{colors.warn}"
    rounded: "{rounded.none}"
    padding: "0"
    typography: "{typography.body}"
---

# Design System: varnick

## Overview

**Creative North Star: "The Instrument Panel"**

A terminal that grew a housing. The transcript at the centre is a faithful Claude Code session — the same messages, tool calls and composer a developer already recognises — and everything varnick draws around it is instrumentation: a strip that reports what the machines think, a setup screen for the one thing that must be supplied, a panel for whatever the developer built. The housing never competes with the instrument it houses.

This is why the surface is monospace throughout, flat throughout, and square throughout. Not minimalism as taste — a panel is legible because nothing on it is styled for attention. Depth is carried by two greys, `ground` and `ground-raised`, in the way a recessed bezel is darker than the face around it. There is no motion anywhere in the product, because motion in a transcript reads as something happening, and the only things happening are the ones the machines report.

The palette was not chosen. It was read off the transcript components so the application and the session it holds are one surface rather than two, and that provenance is a constraint rather than a fact about the past — see The Inherited Palette Rule. What the product refuses is equally load-bearing: it is not a dashboard of invented numbers, and it is not themeable.

**Key Characteristics:**
- Monospace only; 13px ceiling with two quieter steps for chrome
- No shadows, no motion, no radius — depth is tonal, state is textual
- Colour is semantic and rare; most of the screen is three greys
- Controls are text, and exist only when the machine accepts the event
- Full-width shell; only prose is capped, at 110ch

## Colors

Ten tokens, inherited from the transcript, and most of a screen uses three of them.

### Primary
- **Signal Cyan** (`accent`): the one colour that means *you can act on this*. Every inline action, the focus outline, the caret, and the selected state of a choice. It appears a few times per screen and never as decoration.

### Secondary
- **Instrument Amber** (`warn`): the build admitting something about itself — the seeded-data marker, a transcript restored with redactions, a Surface that would not load. Caution about the *reporting*, not about the work.

### Tertiary
- **Fault Rose** (`bad`): a thing that did not happen. Sandbox unavailable, credential rejected, turn failed, agent crashed. Paired with the sentence that says what to do.
- **Confirm Green** (`ok`): reserved for a positive measured state. Deliberately the rarest colour in the product.

### Neutral
- **Deep Slate** (`ground`): the field everything sits on, and the terminal's own background.
- **Raised Slate** (`ground-raised`): one step forward — tooltips, the Surface panel, anything that reads as laid on top. The entire elevation vocabulary.
- **Hairline** (`rule`): every border and divider in the product, always 1px.
- **Pale Periwinkle** (`fg`): body text and anything the developer is meant to read.
- **Muted Periwinkle** (`fg-dim`): supporting text — panel prose, secondary lines, the tooltip body.
- **Ghost Periwinkle** (`fg-faint`): placeholders, disabled-looking chrome, the quiet pointer to the terminal route. Also the selection background.
- **Transcript Rose** (`transcript-rose`) and **Transcript Gray** (`transcript-gray`): owned by the brainless components, not by varnick's chrome. Listed so nobody re-derives them; do not reach for them outside the transcript.

### Named Rules

**The Inherited Palette Rule.** Every value here was read off the transcript components rather than chosen, so the application and the session are one surface. A new colour must already exist in the transcript or it does not ship. There is no varnick palette independent of the session it holds.

**The Three Greys Rule.** If a screen is using more than `ground`, `ground-raised` and `rule` for structure, the structure is wrong. Colour is for meaning, not for arranging things.

## Typography

**Body Font:** `ui-monospace` (with `SF Mono`, `SFMono-Regular`, `Menlo`, `Consolas`, `monospace`)
**Display Font:** none — there is no display face and no second family.
**Label/Mono Font:** the same stack; the product is monospace end to end.

**Character:** A single system monospace across a range of three sizes so narrow it reads as one. Hierarchy comes from colour and position; the size steps do one job only, which is to keep varnick's chrome quieter than the transcript inside it.

### Hierarchy
- **Transcript** (400, 13px, 1.5): the brainless components' own rhythm. Left as they set it; matching them would mean editing the session to suit the housing.
- **Body** (400, 13px, 1.6): everything varnick draws at full weight — setup copy, problem lines, the composer. The same size as the transcript, because it is the same kind of content.
- **Chrome** (400, 12px, 1.6): the Surface panel's own furniture — its header, its loading line, its failure text. One step down because the panel is beside the conversation rather than in it.
- **Micro** (400, 11.5px, 1.6): the conditions strip, and the coverage codes on `#/states`. The quietest text in the product, for rows that report rather than say.
- **Numeric** (400, 13px, 1.6, `tnum`): anything that changes in place. Applied through `[data-numeric]` so figures do not jitter as they update.

### Named Rules

**The Quiet Chrome Rule.** 13px is the ceiling and the transcript owns it. Anything varnick draws *around* the conversation steps down — 12px for panel furniture, 11.5px for reporting rows — and nothing steps up. A heading is a heading because of what it says and where it sits, never because it is larger.

**The exception, named so the rule stays true.** `#/states` uses 15px for its page title and 11px for card timestamps. It is a coverage surface for whoever is building the product rather than a surface the product presents, and it is the only place in the codebase above 13px. Nothing in the chat surface may follow it.

**The Wide Measure Rule.** Prose caps at 110ch, not the 65ch an essay wants. A transcript is interleaved with tool output, diffs and absolute paths that must not wrap, and a comfortable reading measure would break the thing being read.

## Layout

A full-width shell, as a terminal is: the window is the frame and nothing is centred inside it. The chat column flexes and scrolls; the Surface panel sits beside it and is present only when a Surface is loaded.

Rhythm is small and regular. The shell pads `24px` horizontally and `16px` vertically; the transcript stacks at `12px`; controls sit `8px` apart; a bordered control is `6px 12px`. Everything is a multiple of two and nothing is looser than the gutter.

Only prose is constrained, by `--prose: 110ch`, and it is applied per block rather than to a page container — so a diff or a tool result can run to the full width of the window while the sentence above it stays readable.

There are no breakpoints. This is a desktop application in a window the developer sizes; it reflows continuously and has no mobile form.

## Elevation & Depth

**There are no shadows in this product.** Not "few" — the codebase contains no `box-shadow` and no shadow utility. Depth is entirely tonal: `ground` is the field, `ground-raised` is one step forward, and a 1px `rule` border separates anything that needs separating. A tooltip is raised because it is a lighter grey with a hairline around it, and for no other reason.

**There is also no motion.** No transition, no animation, no duration token anywhere in the surface. A terminal does not animate, and in a transcript, movement reads as activity — which would be a claim the machines are not making.

### Named Rules

**The Tonal Depth Rule.** Two greys and a hairline are the entire depth vocabulary. If something needs to feel further forward, it becomes `ground-raised` with a `rule` border; if that is not enough separation, the layout is wrong rather than the elevation.

**The Still Surface Rule.** Nothing moves that the machines did not move. No transitions, no animations, no easing tokens. Streaming text arriving is motion the product is reporting; everything else would be motion the product is performing.

## Shapes

Square, without exception in anything drawn: `rounded-none` is the only radius that appears in the components, and borders are always exactly 1px in `rule`. Panels, buttons, fields and tooltips all share the same corner, which is none, so nothing reads as a card or a pill.

The one radius in the codebase is `6px` on the scrollbar thumb (`rounded.scroll`), which is chrome the browser draws rather than a surface varnick composes. It is a token rather than only a sentence, so a tool checking the code against this file finds it documented instead of finding a violation — the rule below is about what varnick draws, and the scrollbar is not that.

### Named Rules

**The Square Corner Rule.** No `border-radius` on anything varnick draws. A rounded corner makes an element read as an object placed on the surface; here every element *is* the surface.

## Components

### Inline actions
- **Character:** the dominant control in the product, and it is a word.
- **Style:** bare text in `accent`, no border, no background, no padding — `try again`, `retry`, `restart`, `unload`, sitting inside the sentence that explains why they exist.
- **States:** presence is the state. A control is rendered because `snapshot.can()` accepted the event, so there is no disabled treatment and no greyed variant to design.

### Choice buttons
- **Character:** used only where a genuine choice must be made between options — currently the credential kind on the setup screen.
- **Shape:** square (0 radius), 1px `rule` border, `6px 12px` padding.
- **Selected:** the border becomes `accent` and the label `fg`; unselected keeps `rule` and `fg-dim`. No fill in either state.

### Secret field
- **Style:** `type="password"`, square, 1px `rule` border, `ground` background, `6px 12px` padding, placeholder in `fg-faint`.
- **Behaviour:** Enter submits. The value lives in component state and is cleared the moment it is sent; nothing about it is persisted or echoed.

### Panels
- **Corner:** square. **Background:** `ground-raised`. **Border:** 1px `rule`. **Padding:** `12px`.
- Used for the Surface panel and for the seeded tooltip. The only two surfaces that sit forward of the field.

### Problem line
- **Character:** the product's way of saying something did not happen.
- **Style:** `✗ ` in `bad`, the sentence, then an inline action in `accent` if there is one thing to do about it.
- **Rule:** never present without either a next action or an explanation of why there is none.

### The seeded admission
- **Character:** the one component whose job is to reduce trust in what is beside it.
- **Style:** a bare `warn` control reading *seeded data — nothing here is measured*, expanding to a `ground-raised` panel naming what is unimplemented and how to leave seeded mode.
- **Rule:** it gates on the run being seeded and on nothing else. It once rode another component and disappeared with it; it now owns its own row for that reason.

## Do's and Don'ts

### Do:
- **Do** take every new colour from the transcript components. If it is not already in the session, it is not in the product (The Inherited Palette Rule).
- **Do** express hierarchy with colour and position, keeping 13px as the ceiling and stepping *down* for chrome (The Quiet Chrome Rule).
- **Do** render a control only when the machine accepts the event, and let its presence be the affordance — no disabled states to style.
- **Do** cap prose at 110ch per block, and let tool output, diffs and paths run full width (The Wide Measure Rule).
- **Do** carry depth with `ground-raised` plus a 1px `rule` border, and nothing else (The Tonal Depth Rule).
- **Do** apply `[data-numeric]` to any figure that updates in place, so it does not jitter.

### Don't:
- **Don't** add `box-shadow`, a transition, an animation or an easing token. Nothing moves that the machines did not move (The Still Surface Rule).
- **Don't** add `border-radius` to anything varnick draws (The Square Corner Rule).
- **Don't** show a number the product did not measure — no status pills, health dots, sparklines or usage figures without a live reading behind them. A strip that could never populate was cut for exactly this.
- **Don't** add a light mode, a theme switcher or a configurable palette. One world, inherited from the transcript; a clone that wants another edits the tokens.
- **Don't** introduce a second font family, and don't add a size above 13px to anything the product presents.
- **Don't** style varnick's chrome louder than the transcript it surrounds.
