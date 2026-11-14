# Varnick video

A Remotion project that renders the animated hero from `site/src/page.html` (search "Animated hero") as a video for the README and social media: title card, the seven scenes, end card. About 38 s at 30 fps.

Marketing asset, not app code. It shares nothing with the Swift app or the site build.

## Setup

```sh
cd video
npm ci
```

Needs Node 20+ (tested on 24). The first render downloads Remotion's headless Chrome.

## Preview

```sh
npm run studio
```

Compositions: `Landscape` (1920x1080), `Square` (1080x1080), and `LandscapeDark`, `SquareDark`.

## Render

```sh
node scripts/render.mjs                  # landscape + square MP4 and the GIF
node scripts/render.mjs landscape        # one of: landscape, square, gif, dark
```

Output goes to `out/` (gitignored):

| File | What |
|---|---|
| `varnick-landscape.mp4` | 1920x1080, H.264, CRF 14 |
| `varnick-square.mp4` | 1080x1080, H.264, CRF 14 |
| `varnick-landscape.gif` | 960 px wide, 15 fps, 128-colour palette from the video (needs `ffmpeg`), under 8 MB |
| `*-dark.mp4` | the dark theme, with `dark` |

Or one by one: `npx remotion render src/index.ts Square out/square.mp4 --codec=h264 --crf=14`.

## How it works

- `src/hero/timeline.ts` replays the page's hero script on a virtual clock: every wait advances the clock and every change to the panel is recorded as a snapshot. A frame reads the snapshot at its time, so nothing depends on timers and renders are frame-exact. When the script on the page changes, port the change here.
- `src/hero/data.ts` is the page's made-up data, prompt grammar and ranking.
- `src/hero/Panel.tsx` draws a snapshot with the page's markup and classes. `src/hero/hero.css` is the page's CSS (transitions removed). The page's CSS animations are kept and seeked: paused, with a negative delay equal to the time since they began.
- `src/Video.tsx` has the title card, the end card, the caption, the progress bars and the two layouts (scale and positions in `LAYOUTS`).
- Text uses the system font stacks the page uses (`-apple-system`, `ui-monospace`), so render on a Mac to match the page; elsewhere they fall back.

## Licence

Remotion is free for individuals and companies of up to 3 people. A larger company needs a Remotion company licence: https://www.remotion.dev/license

Dependencies are pinned to exact versions, and the lockfile was resolved with `npm install --before=<date>` so nothing transitive is newer than two weeks when it was last updated.
