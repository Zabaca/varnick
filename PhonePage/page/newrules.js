// New session's pure rules, with no DOM: what is preselected, how the filter works, and what the page keeps for next time.
// `bun test` checks them (PhonePage/launch.test.ts). What is kept lives in localStorage, which is per origin and so per host.

/** How many folders' agents, and agents-last-used entries, the page keeps. */
export const keptFolders = 30;

/**
 * The page's name for "no project": the host's own Home folder. Never a host path (those start with a slash), so it can't be taken for one,
 * and it is what is kept for Home as a project's path is for a project. The server is told `null`, not this (`startFolder`).
 */
export const homeFolder = "home:";

/** What the server is sent as a start's folder: a project's path, or null for Home. */
export const startFolder = (folder) => (folder === homeFolder ? null : folder);

/** A path a kept map may be keyed by: a host path, or Home. Anything else (`__proto__`) is dropped. */
const isKeptFolder = (folder) => folder.startsWith("/") || folder === homeFolder;

/** The name of a project: the last part of its path. */
export const projectName = (path) => path.split("/").filter(Boolean).pop() ?? path;

/**
 * What was started last from this phone on this host: the project, and for each project the agent started with it
 * (null: none). Anything unreadable, or of another shape, is nothing remembered.
 */
export function parseLast(text) {
  const empty = { folder: null, agents: {} };
  try {
    const value = JSON.parse(text);
    if (typeof value !== "object" || value === null) return empty;
    const agents = {};
    if (typeof value.agents === "object" && value.agents !== null && !Array.isArray(value.agents)) {
      for (const [folder, agent] of Object.entries(value.agents)) {
        // Keys are host paths, or Home: nothing else (`__proto__`) is kept.
        if (isKeptFolder(folder) && (typeof agent === "string" || agent === null)) agents[folder] = agent;
      }
    }
    return { folder: typeof value.folder === "string" ? value.folder : null, agents };
  } catch {
    return empty;
  }
}

/** The project started last, if the host still lists it (the caller lists Home among the paths). Nothing is picked otherwise. */
export function pickProject(paths, last) {
  return last.folder !== null && paths.includes(last.folder) ? last.folder : null;
}

/** The agent started last with this project, if the project still has it. Nothing is picked otherwise. */
export function pickAgent(names, last, folder) {
  const agent = last.agents[folder];
  return typeof agent === "string" && names.includes(agent) ? agent : null;
}

/** After a start: this project is the last, and this agent (or none) the last with it. The oldest entries go past the cap. */
export function rememberStart(last, folder, agent) {
  const agents = { ...last.agents };
  delete agents[folder];
  agents[folder] = agent;
  const kept = Object.entries(agents).slice(-keptFolders);
  return { folder, agents: Object.fromEntries(kept) };
}

/** The agents the host listed for a folder, kept to show while a fresh answer loads. The oldest folders go past the cap. */
export function rememberAgents(cache, folder, agents) {
  const next = { ...cache };
  delete next[folder];
  next[folder] = agents;
  return Object.fromEntries(Object.entries(next).slice(-keptFolders));
}

/** The host's projects as kept, a list of `{path, lastUsed}`: anything else, or a damaged copy, is no list. */
export function parseProjects(text) {
  try {
    const value = JSON.parse(text);
    if (!Array.isArray(value)) return [];
    return value
      .filter((project) => project && typeof project.path === "string" && project.path.startsWith("/"))
      .map((project) => ({ path: project.path, lastUsed: typeof project.lastUsed === "number" ? project.lastUsed : null }));
  } catch {
    return [];
  }
}

/** What a kept map of folders to agents is read back as: an object keyed by host paths and Home, or nothing. */
export function parseKept(text) {
  try {
    const value = JSON.parse(text);
    if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
    return Object.fromEntries(Object.entries(value).filter(([folder]) => isKeptFolder(folder)));
  } catch {
    return {};
  }
}

/** Projects that match every word of the query, in the name or the path, ignoring case. The list's own order is kept. */
export function filterProjects(projects, query) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return projects;
  return projects.filter((project) => {
    const path = project.path.toLowerCase();
    return words.every((word) => path.includes(word));
  });
}

/** What the session view calls a new session before the host has said: the prompt's first line, else the project's name (Home's, "Home"). */
export function startTitle(prompt, folder) {
  const line = prompt.split(/\r?\n/).map((text) => text.trim()).find((text) => text !== "");
  return line ? line.slice(0, 80) : folder === homeFolder ? "Home" : projectName(folder);
}
