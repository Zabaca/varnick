// Renders the outputs into out/. Usage: node scripts/render.mjs [landscape] [square] [gif] [dark]   (no argument: landscape, square, gif)
import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "out");
mkdirSync(out, { recursive: true });

const run = (cmd, args) => {
  console.log(`$ ${cmd} ${args.join(" ")}`);
  const r = spawnSync(cmd, args, { cwd: root, stdio: "inherit" });
  if (r.status !== 0) process.exit(r.status ?? 1);
};
const mp4 = (id, file) =>
  run(join(root, "node_modules/.bin/remotion"), ["render", "src/index.ts", id, `out/${file}`, "--codec=h264", "--crf=14", "--pixel-format=yuv420p"]);

// A palette from the video itself, then the GIF dithered against it.
const gif = (src, dst) =>
  run("ffmpeg", [
    "-y", "-loglevel", "error", "-i", `out/${src}`,
    "-filter_complex",
    "[0:v]fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
    `out/${dst}`,
  ]);

const want = new Set(process.argv.slice(2));
if (!want.size) ["landscape", "square", "gif"].forEach((w) => want.add(w));

if (want.has("landscape") || want.has("gif")) mp4("Landscape", "varnick-landscape.mp4");
if (want.has("square")) mp4("Square", "varnick-square.mp4");
if (want.has("gif")) gif("varnick-landscape.mp4", "varnick-landscape.gif");
if (want.has("dark")) {
  mp4("LandscapeDark", "varnick-landscape-dark.mp4");
  mp4("SquareDark", "varnick-square-dark.mp4");
}
