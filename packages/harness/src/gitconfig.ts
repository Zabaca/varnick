/**
 * The git configuration the confined agent gets: a **projection** of the
 * developer's, not a copy of it.
 *
 * ## The finding this exists for
 *
 * **Every git command inside the Sandbox exited 128**, on any machine whose
 * developer has a global git config:
 *
 * ```
 * fatal: unable to access '/Users/<you>/.gitconfig': Operation not permitted
 * ```
 *
 * `$HOME` is denied by design (ADR-0003), and git treats a global config it can
 * *see* and cannot *read* as fatal rather than as a warning. That is `git
 * worktree add`, `git commit` and `git merge` — the whole of ADR-0014, which is
 * how the agent authors Core — and `git --version` with them. It is invisible on
 * a machine with no `~/.gitconfig`, which is how it survived.
 *
 * The asymmetry is worth keeping, because it is what makes this a config problem
 * rather than a `$HOME` problem: `~/.config/git/ignore` under the same denial
 * produces a `warning:` and git carries on, and the *system* config is skipped
 * silently — on this machine it is `/opt/homebrew/etc/gitconfig`, `/opt` is not
 * in `allowRead`, and nothing complains. Only the global one is fatal.
 *
 * ## Why a projection, and not either of the two obvious fixes
 *
 * **Not reading `~/.gitconfig` back out of the denied root.** It widens the
 * Fence, and it widens it onto a file the developer edits for reasons that have
 * nothing to do with varnick. A gitconfig is *executable configuration*:
 * measured on this developer's, five entries already run commands —
 * `filter.lfs.clean`, `.smudge` and `.process` (git-lfs, and a `git worktree
 * add` does a checkout, so they fire), `alias.lg`, and two
 * `credential.<url>.helper` entries that are `!/opt/homebrew/bin/gh auth
 * git-credential`. Nobody put those there with an agent in mind. Allowing the
 * read would make the agent's capabilities a function of a file whose owner is
 * not thinking about the agent.
 *
 * **Not `GIT_CONFIG_GLOBAL=/dev/null`.** It costs nothing and it loses
 * authorship: commits would carry whatever git auto-detects from the hostname
 * and the passwd entry. ADR-0014's model is a human reading the agent's diffs
 * before merging them, so the authorship in that history is something a person
 * relies on. A run of agent commits attributed to `uptown@Jamess-MacBook.local`
 * is a history that has stopped saying who wrote what.
 *
 * So: **identity, and only identity**, read by the unconfined host out of the
 * developer's real config and written into a file the agent cannot write.
 *
 * ## The allowlist is the design, not a precaution
 *
 * {@link PROJECTED_GIT_KEYS} is two keys. The rejected alternative is a denylist
 * of the keys that execute, and it is rejected on ADR-0018's argument: such a
 * list is complete on the day it is written and stale the next time git adds a
 * key, and the failure is silent — an executing key nobody listed lands in the
 * projection and runs. The keys that execute today are already more than most
 * people would name from memory; they are enumerated once, as
 * {@link EXECUTING_GIT_KEYS}, and any list of them is a list to be caught out by.
 *
 * The allowlist is enforced by **what is asked for** rather than by filtering
 * what came back — {@link projectGitConfig} asks git for each allowed key by
 * name, so a key outside the list is never read, never held and never rendered.
 * A value is the one thing left that could smuggle a key in, and
 * {@link renderProjectedGitConfig} is where that is closed.
 *
 * If a future key earns its place here, it is argued in this file. Adding one
 * quietly is the failure mode.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/**
 * Where git looks for the global config, when it is told.
 *
 * Sufficient on its own, measured: with this set, no `/etc/gitconfig` on the
 * machine and the real system config at `/opt/homebrew/etc/gitconfig` — a path
 * `allowRead` does not name — git runs clean. It skips an unreadable *system*
 * config silently and fatals only on the global one, so there is no
 * `GIT_CONFIG_SYSTEM` beside this.
 */
export const GIT_CONFIG_GLOBAL_ENV_VAR = 'GIT_CONFIG_GLOBAL'

/**
 * The projected config, relative to the clone.
 *
 * Beside `.varnick/claude`, `.varnick/tmp` and `.varnick/bin`, and in the clone
 * for the reason they are: the Sandbox leaves nowhere else durable, so a
 * variable pointed at the clone costs nothing and moves nothing. Gitignored, per
 * clone, never committed — it is one machine's state, and it is regenerated on
 * every launch.
 *
 * **Unlike its three neighbours, it is denied in `denyWrite`**, and that is the
 * security half of this change rather than a detail of it. The three above are
 * agent-writable because a session store, a temp directory and a `node` shim
 * grant the agent nothing it does not already have. A gitconfig does: the agent
 * writes `core.hooksPath` into a file every git command in the Sandbox reads,
 * and it has chosen what runs on the developer's next commit. That is precisely
 * the hole ADR-0016's amendment closed for `.githooks/`, arriving through a file
 * varnick itself introduced. See `PROJECTED_GITCONFIG` in ./sandbox.ts.
 */
export const PROJECTED_GITCONFIG_RELATIVE_PATH = '.varnick/gitconfig'

/** The projected config in a given clone. */
export function agentGitConfigPath(cloneRoot: string): string {
  return join(cloneRoot, PROJECTED_GITCONFIG_RELATIVE_PATH)
}

/**
 * Everything that crosses from the developer's config into the agent's.
 *
 * Two keys, and they are the two that make a commit attributable. Read the
 * allowlist argument at the top of this file before adding a third: the cost of
 * being wrong here is unconfined code execution on the developer's machine, and
 * every candidate that has ever been suggested for this list — an alias, an
 * editor, a credential helper — is a command.
 *
 * Each entry is `section.key` with exactly one dot. That is not a coincidence to
 * be relied on quietly: {@link renderProjectedGitConfig} drops anything with a
 * subsection, which takes the whole `credential.<url>.helper` and
 * `filter.<name>.clean` shape out of reach of this file even if a key for one
 * were added by mistake.
 */
export const PROJECTED_GIT_KEYS = ['user.name', 'user.email'] as const

/**
 * Git config keys that run a command, enumerated **once**.
 *
 * Not a denylist — nothing filters on this, and the module docblock above says
 * why a denylist would be the wrong shape. It exists because the argument for
 * the allowlist is *"a gitconfig is executable configuration"*, and that
 * sentence is only convincing with the list beside it. It was written out by
 * hand in four places on the first pass — this module's docblock, the
 * `denyWrite` entry in ./sandbox.ts, a test comment, and the ticket — which is
 * four copies of a security-critical fact, free to drift.
 *
 * So it is a constant, and the two places that can interpolate one do:
 * `describeSandboxPolicy` puts it in the generated policy's prose, and
 * gitconfig.test.ts asserts the rendered projection contains none of it. Prose
 * that cannot interpolate points here rather than re-listing.
 *
 * Each entry is the substring a reader would grep for, not a glob, because what
 * the test needs to ask is "does this name appear in the rendered file at all".
 * `alias` and `credential` are the bare section names on purpose: any key under
 * them can carry a `!` prefix and become a shell command.
 */
export const EXECUTING_GIT_KEYS = [
  'core.hooksPath',
  'core.editor',
  'core.pager',
  'core.sshCommand',
  'alias',
  'credential',
  'filter',
  'diff.*.textconv',
  'merge.*.driver',
  'include.path',
  'includeIf',
] as const

/** One key and the value the developer's config gave it. */
export interface GitConfigEntry {
  readonly key: string
  readonly value: string
}

/**
 * Whether a value can be written into a config file without becoming something
 * other than a value.
 *
 * **A newline in a value is a section header waiting to happen.** git config
 * values really can contain one — `name = "a\nb"` parses, and `git config --get`
 * prints two lines — so a projection that pasted a value through unexamined
 * would let `user.name` carry `\n[core]\n\thooksPath = /tmp` and put an
 * executing key in a file built to have none. The value is the only thing here
 * that comes from outside, so it is the only place that check is worth making.
 *
 * Refused rather than escaped, and the reason is that escaping is a claim about
 * git's parser that this file would have to keep true. A dropped `user.name`
 * costs a commit its author name; an escaping bug costs the Fence. Any control
 * character goes, not only the newline, because the set of them that are
 * harmless is another list to be wrong about.
 */
export function isProjectableValue(value: string): boolean {
  if (value.length === 0) return false
  // eslint-disable-next-line no-control-regex -- refusing control characters is
  // the whole of what this function does.
  return !/[\u0000-\u001f\u007f]/.test(value)
}

/**
 * The projected config, as the bytes that go on disk.
 *
 * Quoted with git's own escaping — `\` becomes `\\` and `"` becomes `\"`, inside
 * `"` — so a name with a space or a quote in it survives the round trip
 * (measured both ways). Everything the quoting cannot express is dropped by
 * {@link isProjectableValue} before it gets here.
 *
 * Entries outside {@link PROJECTED_GIT_KEYS} are dropped, which makes the
 * allowlist true of this function as well as of its caller. That is deliberate
 * belt and braces: the caller enforces it by never asking for another key, and
 * a future caller that asked differently would still not be able to write one.
 *
 * The header says what the file is and what editing it will do, because the
 * first thing a developer who finds it will want to do is put their alias back.
 */
export function renderProjectedGitConfig(entries: readonly GitConfigEntry[]): string {
  const allowed: readonly string[] = PROJECTED_GIT_KEYS
  const sections = new Map<string, string[]>()
  for (const { key, value } of entries) {
    if (!allowed.includes(key)) continue
    if (!isProjectableValue(value)) continue
    const parts = key.split('.')
    // `section.key`, and nothing with a subsection — see PROJECTED_GIT_KEYS.
    if (parts.length !== 2) continue
    const [section, name] = parts as [string, string]
    const quoted = `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
    const lines = sections.get(section) ?? []
    lines.push(`\t${name} = ${quoted}`)
    sections.set(section, lines)
  }

  const body = [...sections].flatMap(([section, lines]) => [`[${section}]`, ...lines])
  return [
    '# Generated by varnick on every launch, and denied to the agent.',
    '#',
    "# This is a projection of your git config, not a copy of it: only your",
    `# identity crosses (${PROJECTED_GIT_KEYS.join(', ')}), because everything else a`,
    '# gitconfig can hold runs a command — aliases, credential helpers, filters,',
    '# core.hooksPath. The agent runs with GIT_CONFIG_GLOBAL pointed here, so',
    '# your own config stays outside the fence and its commits still say who',
    '# made them.',
    '#',
    '# Editing this achieves nothing: it is rewritten on the next launch. See',
    '# packages/harness/src/gitconfig.ts.',
    ...body,
    '',
  ].join('\n')
}

/**
 * Ask the developer's real config for one key, as the unconfined host.
 *
 * `git config --global --get` rather than a parse of `~/.gitconfig`, and the
 * reason is not laziness about INI syntax. `--global` is git's own notion of
 * "the developer's config" and it is two files: `~/.gitconfig` *and*
 * `$XDG_CONFIG_HOME/git/config`, which is where a good many people keep their
 * identity. Measured — with `~` empty and only the XDG file present, `git config
 * --global --get user.name` answers from it. A hand parser of one hardcoded path
 * would silently produce an empty projection for those developers, which is the
 * failure this whole file exists to make impossible to have quietly.
 *
 * Null for "not set", for "there is no config", and for "git could not run".
 * They are one answer here because they have one consequence: nothing to
 * project. The value's *content* is never trusted — see
 * {@link isProjectableValue}.
 *
 * **A key set more than once is not one of those cases.** Review suggested it
 * was, on the understanding that a multi-valued `--get` exits 2; measured on git
 * 2.52 it exits **0** and prints the last value, which is documented behaviour
 * (*"the last value if multiple key values were found"*) and is also the value
 * any ordinary git command would have used. So a developer with two `user.name`
 * lines gets the one git itself would honour, rather than nothing.
 *
 * Runs on the host, outside the Sandbox, which is the only process that can read
 * the file at all. Nothing derived from the clone reaches this: the key comes
 * from {@link PROJECTED_GIT_KEYS}, a constant in this repository.
 */
export function readGlobalGitConfigValue(key: string): string | null {
  try {
    const result = Bun.spawnSync({
      cmd: ['git', 'config', '--global', '--get', key],
      stdout: 'pipe',
      stderr: 'ignore',
    })
    if (result.exitCode !== 0) return null
    const value = result.stdout.toString().replace(/\n$/, '')
    return value.length === 0 ? null : value
  } catch {
    // No git on this machine's PATH. The agent has no git either, so there is
    // nothing this could have been useful for.
    return null
  }
}

/**
 * The projection, from a reader of the developer's config.
 *
 * The reader is asked for each allowed key **by name**. That is what makes the
 * allowlist structural rather than a filter: there is no call here that could
 * return `core.hooksPath`, so there is no branch that has to remember to drop
 * it.
 *
 * Injected so the tests can describe a machine that is not this one — a
 * developer with no config at all, one whose identity is per-repository, one
 * whose config the host cannot read. All three arrive here as the same thing:
 * a reader that answers null, and a projection with a header and no keys.
 */
export function projectGitConfig(
  read: (key: string) => string | null = readGlobalGitConfigValue,
): string {
  const entries: GitConfigEntry[] = []
  for (const key of PROJECTED_GIT_KEYS) {
    const value = read(key)
    if (value !== null) entries.push({ key, value })
  }
  return renderProjectedGitConfig(entries)
}

/**
 * What happened when varnick tried to write the projection.
 *
 * Three outcomes rather than a boolean, because **the two failures are not the
 * same size** and the first version of this function reported them as though
 * they were. It swallowed both and its comment justified the swallow with *"a
 * `GIT_CONFIG_GLOBAL` naming a file that is not there is a git that works with
 * no identity"* — which is true of one of them and false of the other.
 *
 *   * `written`  — the file is there, and its contents are what
 *                  {@link projectGitConfig} produced.
 *   * `unwritten` — the directory exists and the file could not be written.
 *                  This is the survivable one, and it is the one the old comment
 *                  described: git runs, and commits fall back to whatever it
 *                  auto-detects.
 *   * `uncreatable` — `.varnick/` itself could not be created. **Nothing
 *                  survives this**, and it has nothing to do with git: srt
 *                  denies `file-write-create` on every ancestor of a denied
 *                  path, so a confined Claude Code cannot create
 *                  `.varnick/claude` either and does not start at all. Reported
 *                  as its own outcome so that the sentence varnick prints is
 *                  about the launch that is about to fail rather than about a
 *                  missing git identity.
 *
 * Both failures carry git's own `reason`, because "varnick could not write your
 * git config" with no errno is a sentence that sends someone to the wrong file.
 */
export type ProjectedGitConfigOutcome =
  | { readonly kind: 'written'; readonly path: string }
  | { readonly kind: 'unwritten'; readonly path: string; readonly reason: string }
  | { readonly kind: 'uncreatable'; readonly path: string; readonly reason: string }

/**
 * What varnick should say about an outcome, or null when there is nothing to
 * say.
 *
 * Separate from the write so the sentence is a pure function of the outcome and
 * can be asserted without a filesystem. Prefixed `varnick:` to match every other
 * line this product prints to stderr — see `establishSandbox`, which is what
 * puts it on that channel.
 *
 * **The `unwritten` sentence names the rejected alternative by name.** A clone
 * whose projection failed to write produces commits under git's auto-detected
 * identity, which is exactly the outcome `GIT_CONFIG_GLOBAL=/dev/null` was
 * rejected for. Arriving there silently would be worse than having chosen it,
 * because at least choosing it would have been a decision somebody made.
 */
export function projectedGitConfigReport(outcome: ProjectedGitConfigOutcome): string | null {
  if (outcome.kind === 'written') return null
  if (outcome.kind === 'unwritten') {
    return [
      `varnick: ${outcome.path} could not be written — ${outcome.reason}`,
      '  git will run in the Sandbox, and its commits will carry whatever identity',
      '  git auto-detects rather than yours. That is the outcome varnick rejected',
      '  when it chose a projected config over GIT_CONFIG_GLOBAL=/dev/null, so it',
      '  is said out loud rather than left to be discovered in a git log.',
    ].join('\n')
  }
  return [
    `varnick: ${dirname(outcome.path)} could not be created — ${outcome.reason}`,
    '  This is not only about git. The agent writes its session store and its',
    '  temporary directory inside that directory, and the Sandbox denies creating',
    '  it from in there, so the agent is unlikely to start at all.',
  ].join('\n')
}

/**
 * Write the projection into a clone, and say what happened.
 *
 * **Called by the runtime, before the Sandbox wraps anything**, for two reasons
 * that both have to hold. The runtime is unconfined, so it is the only process
 * that can read the developer's config. And it runs before the agent does, which
 * is what the deny needs: srt blocks `file-write-create` on every ancestor of a
 * denied path, so `.varnick/` has to exist by the time the confined process
 * tries to make `.varnick/claude` inside it.
 *
 * **Rewritten every launch**, like the `node` shim, so a developer who changes
 * their name gets it on the next start and a corrupted file repairs itself. The
 * agent cannot have edited it in between.
 *
 * **Nothing here throws.** The path is answered whatever happened and the caller
 * sets the variable either way, because a `GIT_CONFIG_GLOBAL` naming a file that
 * is not there is a git that works with no identity, while leaving the variable
 * unset is a git that exits 128 on every command. Those are not close. What this
 * does *not* do any more is treat the two failures as one — see
 * {@link ProjectedGitConfigOutcome}.
 */
export function writeProjectedGitConfig(
  cloneRoot: string,
  deps: {
    read?: (key: string) => string | null
    mkdir?: (path: string) => void
    write?: (path: string, contents: string) => void
  } = {},
): ProjectedGitConfigOutcome {
  const path = agentGitConfigPath(cloneRoot)
  const mkdir = deps.mkdir ?? ((at: string) => void mkdirSync(at, { recursive: true }))
  const write = deps.write ?? ((at: string, contents: string) => writeFileSync(at, contents, 'utf8'))

  try {
    mkdir(dirname(path))
  } catch (error) {
    return { kind: 'uncreatable', path, reason: messageOf(error) }
  }

  try {
    write(path, projectGitConfig(deps.read ?? readGlobalGitConfigValue))
  } catch (error) {
    return { kind: 'unwritten', path, reason: messageOf(error) }
  }

  return { kind: 'written', path }
}

/** git's own words for what went wrong, or the value if it was not an Error. */
function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
