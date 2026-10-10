// Scratch: a Vite dev server (HMR, React Fast Refresh) over the scratch area of the pane this
// app was split from, <project>/.varnick/scratch/<VARNICK_SPLIT_FROM>/. Claude writes the page
// there; see skill/SKILL.md beside this file (linked as ~/.claude/skills/scratch while Scratch is on in Settings > Apps).
//
// Layout: the scratch root, <project>/.varnick/scratch/, holds the page packages
// (package.json, node_modules) and one folder per Claude pane, which is a Vite root. Pages
// resolve packages from the root above them. The root's .gitignore ignores everything, so
// the project's own ignore file needs no edit.
import react from "@vitejs/plugin-react";
import { appendFileSync, existsSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { createLogger, createServer, type Plugin } from "vite";

const port = Number(process.env.PORT);
const project = process.env.VARNICK_PROJECT;
const paneId = process.env.VARNICK_SPLIT_FROM;
if (!port || !project || !paneId) {
  console.error("Scratch needs PORT, VARNICK_PROJECT and VARNICK_SPLIT_FROM; Varnick sets them.");
  process.exit(1);
}
if (!isAbsolute(project) || basename(paneId) !== paneId || paneId === "." || paneId === "..") {
  console.error("VARNICK_PROJECT must be an absolute path and VARNICK_SPLIT_FROM a single folder name.");
  process.exit(1);
}

// Vite resolves module ids to real paths and compares them with fs.allow as given, so every
// path handed to it must be real: VARNICK_PROJECT can go through a link (/tmp, /var).
mkdirSync(join(project, ".varnick", "scratch", paneId), { recursive: true });
const appDir = realpathSync(import.meta.dirname);
const scratchRoot = realpathSync(join(project, ".varnick", "scratch"));
const area = join(scratchRoot, paneId);

function writeIfMissing(path: string, contents: string) {
  if (!existsSync(path)) writeFileSync(path, contents);
}

writeIfMissing(join(scratchRoot, ".gitignore"), "*\n");
writeIfMissing(
  join(scratchRoot, "package.json"),
  JSON.stringify(
    {
      private: true,
      type: "module",
      // Exact versions, as the catalog's rules ask: no lockfile covers this install.
      dependencies: { react: "19.3.0", "react-dom": "19.3.0" },
      devDependencies: { "@types/react": "19.3.0", "@types/react-dom": "19.3.0" },
    },
    null,
    2,
  ) + "\n",
);

// First use, or a fresh clone: the page packages. Claude adds more to the root's package.json
// and runs this itself.
if (!existsSync(join(scratchRoot, "node_modules"))) {
  console.log("Installing page packages in", scratchRoot);
  const install = Bun.spawn([process.execPath, "install"], {
    cwd: scratchRoot,
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await install.exited) !== 0) {
    console.error("bun install failed in", scratchRoot);
    process.exit(1);
  }
}

// Vite's output goes to the area's .vite.log (for Claude to read when the user reports a
// problem) and to this process's output, which the pane shows if the server dies.
const logFile = join(area, ".vite.log");
writeFileSync(logFile, "");
const logger = createLogger("info", { allowClearScreen: false });
for (const level of ["info", "warn", "warnOnce", "error"] as const) {
  const write = logger[level];
  logger[level] = (message, options) => {
    appendFileSync(logFile, `[${level}] ${message}\n`);
    write(message, options);
  };
}

const placeholder = `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Scratch</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 3rem; max-width: 40rem; }
      code { font-family: ui-monospace, Menlo, monospace; }
    </style>
  </head>
  <body>
    <h2>Scratch is waiting for a page</h2>
    <p>Ask Claude in the pane this was split from to show you something. It writes
    <code>index.html</code> in <code>${area}</code> and the page replaces this one by itself.</p>
    <p>Nothing writes there if that pane isn't a Claude pane.</p>
  </body>
</html>
`;

// Until the area has an index.html, "/" shows the placeholder; writing the page reloads it.
const placeholderUntilPage = (): Plugin => ({
  name: "scratch-placeholder",
  configureServer(server) {
    const page = join(area, "index.html");
    server.watcher.on("add", (file) => {
      if (file === page) server.ws.send({ type: "full-reload" });
    });
    server.middlewares.use(async (req, res, next) => {
      const path = (req.url ?? "/").split("?")[0];
      if ((path !== "/" && path !== "/index.html") || existsSync(page)) return next();
      res.setHeader("content-type", "text/html");
      res.setHeader("cache-control", "no-store");
      res.end(await server.transformIndexHtml(req.url ?? "/", placeholder));
    });
  },
});

const server = await createServer({
  root: area,
  configFile: false,
  customLogger: logger,
  clearScreen: false,
  // One dependency cache per area: panes of one project serve at once.
  cacheDir: join(scratchRoot, "node_modules", ".vite", paneId),
  // Vite starts before the page exists in a new area, so react-dom/client would be found only
  // at request time and optimized into a second copy of React ("Invalid hook call").
  optimizeDeps: { include: ["react-dom/client"] },
  plugins: [react(), placeholderUntilPage()],
  server: {
    host: "127.0.0.1",
    port,
    strictPort: true,
    fs: { allow: [scratchRoot, appDir] },
    watch: { ignored: ["**/.vite.log"] },
  },
});
await server.listen();
server.printUrls();
