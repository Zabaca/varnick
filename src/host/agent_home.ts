// The agent's Claude Code home, seeded so a Session opens on the prompt and not
// on a wizard. A fresh config dir makes Claude Code run its onboarding — a theme
// picker, then a login-method screen that appears before it looks at the token
// it was given — and ask, once per directory, whether to trust the folder. All
// three are answered here, in the file Claude Code reads them from.
//
// Field names checked against claude 2.1.265 on 2026-09-18 by answering the
// dialogs once by hand in a throwaway `CLAUDE_CONFIG_DIR` and diffing:
// `hasCompletedOnboarding` and `lastOnboardingVersion` at the top level,
// `projects[<absolute path>].hasTrustDialogAccepted` per directory. Nothing
// else in the file is touched, because Claude Code writes its own state there
// and a Host that overwrote it would log the agent out on every Session.

type Json = Record<string, unknown>;

function configFile(home: string): string {
  return `${home}/.claude.json`;
}

async function readConfig(home: string): Promise<Json> {
  try {
    const parsed = JSON.parse(await Deno.readTextFile(configFile(home)));
    return typeof parsed === "object" && parsed !== null ? parsed as Json : {};
  } catch {
    return {};
  }
}

async function writeConfig(home: string, config: Json): Promise<void> {
  await Deno.mkdir(home, { recursive: true });
  await Deno.writeTextFile(configFile(home), JSON.stringify(config, null, 2) + "\n");
}

// What `claude --version` says, for `lastOnboardingVersion`; Claude Code
// re-runs parts of onboarding when that field is behind, so it is set to the
// executable the Session will actually run. Unanswerable is recorded as "0".
async function claudeVersion(claudePath: string): Promise<string> {
  try {
    const { success, stdout } = await new Deno.Command(claudePath, {
      args: ["--version"],
      stdout: "piped",
      stderr: "null",
      stdin: "null",
      // A `claude` that does not answer must not hold the Session open.
      signal: AbortSignal.timeout(5_000),
    }).output();
    const match = success && new TextDecoder().decode(stdout).match(/\d+\.\d+\.\d+/);
    return match ? match[0] : "0";
  } catch {
    return "0";
  }
}

/** Mark onboarding complete in the agent's home, once; later calls change nothing. */
export async function seedAgentHome(home: string, claudePath: string): Promise<void> {
  const config = await readConfig(home);
  if (config.hasCompletedOnboarding === true) return;
  await writeConfig(home, {
    ...config,
    hasCompletedOnboarding: true,
    lastOnboardingVersion: await claudeVersion(claudePath),
  });
}

/** Mark one Worktree as a folder the agent trusts, merging into what is there. */
export async function trustWorktree(home: string, worktreePath: string): Promise<void> {
  const config = await readConfig(home);
  const projects = typeof config.projects === "object" && config.projects !== null
    ? config.projects as Record<string, Json>
    : {};
  const project = projects[worktreePath] ?? {};
  if (project.hasTrustDialogAccepted === true) return;
  await writeConfig(home, {
    ...config,
    projects: { ...projects, [worktreePath]: { ...project, hasTrustDialogAccepted: true } },
  });
}
