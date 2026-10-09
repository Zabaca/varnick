---
problem: spoken-requests-cant-see-the-screen
title: Option 01, then Gemma 4 E2B looks at a screenshot of the window on this Mac and says where the thing is
summary: Option 01 as it stands, plus one fallback. When the Accessibility tree has nothing that fits, Launchy captures the focused window into memory and gives it to the Gemma 4 E2B already installed for Text generation, loaded through MLX's vision path. The checkpoint Launchy downloads already holds the vision weights, and the pinned mlx-swift-lm already has the code. Gemma replies with a point on the image or "none", and Launchy points there. This is the only local option that can find an unlabelled icon. Whether a 2-billion-parameter model can place a point on a UI screenshot well enough is unknown, so a spike decides before anything is built. Nothing leaves the Mac, but it needs Screen Recording and more memory.
status: proposed
---

## Solution

Everything in option 01 holds. This option adds one step, run only when option 01's choice found nothing:

1. Launchy captures the focused window alone, into memory, as option 02 does.
2. Gemma 4 E2B on this Mac gets the image and the request. It is asked for the point where the thing is, as two numbers from 0 to 1000 across and down the image, or for "none".
3. A point inside the window gets option 01's arrow, with a small ring at the point (there is no frame to ring). "None", an unreadable reply or a point outside the window is "I can't see that on your screen."

The image is dropped after the reply. It never leaves the process.

## Trade-offs

- **It can see icons.** It is the only local option that can find "the gear" or "the red button" when the app gave them no label and they carry no text.
- **Everything stays on this Mac.** Nothing goes to TypeSafe or to a server for this step, whatever the filter says. Text generation on a server isn't used for images (see Out of Scope).
- **Its accuracy is unknown, and could be poor.**
  - Gemma 4 E2B isn't documented here to locate things in images; that is unverified.
  - The image is scaled to about 645,000 pixels, roughly 1,000 × 640 for a 16:10 window. On a large window, small text and icons are a few pixels across.
  - A wrong point is worse than no arrow, so the spike sets a bar before anything else is built.
- **No confidence.** Gemma's point carries no probability, so a wrong point can't be told from a right one, unlike Jev's choice.
- **No new download, but a new load.**
  - The installed checkpoint already holds the vision tower, and the pinned mlx-swift-lm has Gemma 4's vision model and image processor. Launchy only has to link that library.
  - Today's load is text only. Loading the vision path costs more memory (unmeasured), either once for every Text generation use or as a second copy just for images. The spike decides which.
- **Slower on a miss.** Encoding the image, prefilling about 280 image tokens and a short reply are estimated at 1 to 2 s warm, plus about 4 s more if Gemma has unloaded. All unmeasured.
- **A second permission:** Screen Recording, as in option 02, with the same caveats.

## User Stories

1. As a Launchy user, I want "where's the gear icon" answered with an arrow even when the app left the gear unlabelled.
2. As a Launchy user, I want a picture of my window to be looked at only on this Mac, never sent anywhere.
3. As a Launchy user, I want no arrow at all rather than one in the wrong place.
4. As a Launchy user, I want everything else as in option 01.

## Implementation Decisions

**Everything not below** is as in option 01, and the capture and permission as in option 02.

**When it runs**
- After option 01's choice gives `none`, falls below the threshold, or had no candidates, and only with this Mac's Gemma installed.
- With option 02 also accepted, after option 02 finds nothing.

**The model**
- **The same checkpoint,** loaded through mlx-swift-lm's vision-language path. That library is a product of the package already pinned, so it is no new dependency.
- **One loaded copy or two:** decided by the spike.
  - One copy, if titles and spoken answers come out the same through the vision path, checked with `--title` and `--ask` on the usual made-up requests.
  - Otherwise a second copy for images, loaded on demand and unloaded when idle, as the text one is.
- **MLX's process-wide rules hold:** check the metallib first, load in `withError`, touch no MLX in an initializer, and share the cache cap.

**The ask**
- **A fixed prompt, kept in one place:** the request, and a reply of one line, either the point as two numbers from 0 to 1000 (across, then down) or "none".
- Greedy, a few tokens. The reply is read leniently: the first two numbers, or "none".
- **The image** is the window capture, at the size the processor scales it to. No marks are drawn on it in the first version (see Further Notes).

**Pointing and the note**
- The point is mapped from the image to the window to the screen, through option 01's single conversion.
- **The arrow** ends at the point, with a small ring.
- **The note** is "There." and a short description Gemma adds after the numbers, cut to one sentence. If it adds none, the note is "There it is." This is Gemma's text, spoken, as option 01's answers are.

**Logs, command line, state**
- The timing line adds the vision step's duration and outcome kind, never the point or the reply.
- `--ask --app` prints the point and the reply.
- No new saved state.

## Testing Decisions

- **Spike first, before anything else is built.**
  - About 30 made-up window screenshots, not the user's own: a dialog, a toolbar of icons, a settings pane, a web form.
  - Each comes with a request and the target's box.
  - Count the points inside the box, and the "none" answers for requests about things not in the image.
  - Fewer than about 20 of 30 inside, or any confident point on an absent thing in more than a few, rejects this option.
  - Time each, warm and cold, and measure the memory of the vision load.
- The reply reader (text in, a point or none out) and the image-to-screen mapping are pure seams.
- **By hand, after a restart,** with the spike passed: ask for an unlabelled icon in a native app, and for something not on screen.

## Out of Scope

- The image to a Text generation server, even the user's own. Whether its chat route accepts images is unverified, and a picture of the screen is a new kind of data for it.
- Marks drawn on the image for Gemma to choose from (see Further Notes).
- Descriptions of what an image or video on screen shows.

## Further Notes

- **Accept with option 01, or after it.** Stacks after option 02.
- **If the spike fails on points, it can still succeed on choosing.** Draw numbered marks on the image at option 02's text boxes and the tree's frames, and ask Gemma for a number ("set of marks"). That needs option 02's recognition, and still can't mark an unlabelled icon, which was this option's reason. So it is a fallback for the spike, not the plan.
- **ADR:** option 01's, adding a screenshot read by Gemma on this Mac, and Text generation's model loaded with its vision weights.
- **Verified on this Mac:**
  - the installed checkpoint's vision weights and image processor config;
  - mlx-swift-lm 3.32.3's Gemma 4 vision model and processor, and the processor's scaling rule;
  - Launchy's text-only load.
- **Unverified:** Gemma 4 E2B's ability to locate things, the memory and time of the vision path, and whether the vision path changes text replies.
