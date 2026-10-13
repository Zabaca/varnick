---
problem: tabs-past-the-strip-are-hidden
title: The strip keeps scrolling sideways, with faded edges and the tab on screen scrolled into view
summary: Recommended against. Today's sideways scrolling stays as the only way past the edge, made easier to notice. The strip fades at an edge that has more tabs past it, and showing a tab scrolls it into view. No setting, chip or list. The reason to reject it, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

The strip stays one row of tabs at today's widths, in a sideways scroll view, as it is now. Three things change:
- **Faded edges.** An edge with tabs past it fades out, so a cut-off tab reads as "more this way".
- **The tab on screen scrolls into view** whenever a tab is shown: ⌘⇧[ and ⌘⇧], search, the board or a new tab.
- **A plain scroll wheel scrolls it** sideways, as well as a trackpad's swipe.

## Trade-offs

- **Smallest change.** No setting, no new view, no new reads.
- **Tabs stay hidden.** A fade says that more tabs exist, but not how many or which. Reaching one still means scrolling or stepping through the tabs.
- **A hidden tab that waits on the user stays unseen,** which is half of the problem's cost.
- **Scrolling a strip in a floating panel is fiddly** with a mouse. And while the strip scrolls, its part of the header no longer drags the window, as the code's own comment on it says.

## User Stories

1. As the user, I want to see that more tabs lie past the strip's edge.
2. As the user, I want the tab on screen to scroll into view.

## Implementation Decisions

- The strip's scroll view scrolls to the tab on screen each time a tab is shown.
- The edges fade only while there is more to scroll that way.

## Testing Decisions

- `make build`, then by hand: with twelve tabs, ⌘⇧] past the edge scrolls the strip, and the edges fade as expected.

## Out of Scope

- Any list of hidden tabs, or any mark for waiting ones.

## Further Notes

- **Verified in the code at 38b6d42:** the strip already scrolls sideways when its tabs don't fit, with no scroll bar, and nothing scrolls the tab on screen into view.
- **Inferred, not tried:** a trackpad swipe scrolls today's strip. Whether a plain scroll wheel does is not known.
- **Scrolling the tab on screen into view** is part of option 01 anyway, as its run of tabs.
- **Reason, if rejected:** today's strip already scrolls, and that is the problem. Scrolling still hides which tabs are past the edge and whether one waits on the user.
