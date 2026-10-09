# A spoken request can point at the screen, read from the focused window's Accessibility tree, with Jev picking the element

With **Point at the screen** on, a spoken request about something on the screen ("where's the Allow button", "which one turns off the startup sound") is answered with an **Arrow** as well as aloud. Launchy reads the Accessibility tree of the window that has keyboard focus, in its own process. It describes each visible element by its label, its kind, its enclosing groups and the text beside it on the same row. One call to TypeSafe's Jev asks which element the request means and whether the thing is in the window at all. When that second answer is 0.5 or more, Launchy draws a click-through arrow and a sign at the element and says the sign's note. No screenshot is taken. Nothing is opened, clicked or focused.

This amends ADR 0015, under which a spoken request was answered only aloud with nothing shown. It also amends ADR 0016, under which Jev received only the request text. The user chose this on 2026-10-09, after an eval measured Jev and Gemma on made-up screen requests over eight windows:
- Jev picked the right element 87 times in 97, and 95 counting the control's own row text.
- Jev pointed at something for 1 of 28 absent things, in 0.12 s.
- Gemma picked right 72 times in 97 and pointed at 13 of the 28 absent things, and its probabilities can't tell right from wrong.

The problem and its options are in `docs/problems/spoken-requests-cant-see-the-screen/`; this records option 01.

## Only Jev points

- **Pointing needs the decide step's gate:** the relevance filter on TypeSafe with a key saved. Without it, the switch can't be turned on, and Jev's questions stay as they were. With it, a Jev failure is spoken as "I can't point at things right now".
- **Gemma never points.** A wrong arrow misleads where silence doesn't. Gemma stays the fallback for the decide step, whose prompt offers `screen` too.

## What goes to TypeSafe

With the switch on, each screen request sends the request, the window's title, and each element's label, kind, enclosing groups and the text beside it. That is the window's visible text near its controls, such as a message list's subjects, a tab's file name or an account name in a sidebar. It is a new kind of data for TypeSafe, beyond ADR 0016's request text and ADR 0017's page rows.

Some things never go:
- what a text field or text area holds;
- anything of a secure field;
- an app's name, a frame or an image.

Nothing is logged but durations and kinds. Settings, the README and SECURITY.md say this.

## The decide step

- **New questions, only with the switch on.** Jev's `source` question gains `screen`, and its `action` question gains `point` before `other`. Without `point`, Jev read "point at the wifi switch" as off-topic in every repeat.
- **Off-topic is still read before the source.** Off-topic requests ("set a timer") take `screen` as their source.
- **The measured wording is fixed.** The model stays pinned. `offTopicFrom` held at 0.5 with the new questions, and `alsoSessionsFrom` wasn't re-measured.

## The permission stays Launchy's

- **Launchy needs Accessibility.** While builds are signed ad hoc, a rebuild may stop the grant from applying (`runs-only-from-a-checkout`).
- **The read runs only in Launchy's process.** zmx is never granted Accessibility. A Claude session's processes run under zmx, which macOS very likely treats as their responsible app, so a grant to zmx would let every hosted session read and drive any app's UI.
- **Panes started without zmx are a gap.** They run as Launchy's direct children, and probably share its grant. With Keep sessions running off, the default, that is every pane. The user accepted this with a plain line in the switch's detail and in SECURITY.md, and the fix is a problem of its own: `panes-share-launchys-permissions`.

## Considered Options

- **Gemma choosing the element** (open question 2 of option 01): rejected by the user on the eval's figures. It would have let the feature work with nothing leaving the Mac.
- **The top choice's probability, with a "none of these" option, as the threshold**: the separate yes-or-no separated present from absent better, and needs no tuning at 0.5.
- **Code matching on the request's words** (bigarrow's exact, prefix and substring match): "where do I approve this" never matches "Allow", and a switch's own label is only its state.
- **Running bigarrow or a helper from a pane**: it would need zmx granted (above).
- **Screenshots: text recognition on this Mac (option 02), Gemma's vision on this Mac (option 03) and Claude (option 04).** Not built. They stay proposed as fallbacks for windows whose tree lacks the thing. The user answered on 2026-10-09 that a screenshot may leave this Mac, so option 04 isn't ruled out.

## Consequences

- **A spoken request can now draw on the screen.** The **Arrow** never activates Launchy or moves focus, ignores the mouse, and goes by itself 8 s after the speech. A new request, or turning the switch, Hey Launchy or Listening off, removes it. The note is a fixed sentence, spoken through `Speaker` as every answer is.
- **Coverage is what apps expose to Accessibility:**
  - Electron apps build their web tree when asked, and keep it until they quit.
  - Chrome's page content stays out of reach without its accessibility flag, and Launchy says so.
  - An unlabelled icon is missed.
- **The read and the choice run during the hold, as search and filter do (ADR 0017).** A partial request's element descriptions may reach Jev and be discarded.
- **Changing the screen questions changes the measured thresholds' meaning,** as for the decide step's. So does anything added to what the call carries: that is a privacy change needing this ADR, the README and SECURITY.md amended.
