/**
 * What the agent may ask the host to do while nobody is watching.
 *
 * Two asks, and they are the same act: **the host performs a write the agent may
 * not, on the agent's request, decided host-side.** Landing a Worktree writes the
 * live tree; cutting a Pre-release writes the root manifest. Both paths are
 * closed to the agent by `denyWrite` and stay closed — see
 * docs/adr/0023-a-second-door-rather-than-a-wider-one.md, which argues the trade
 * once so neither half has to argue it again.
 *
 * ## Why this is beside ./preview.ts rather than inside it
 *
 * A Preview is a *launch*: nothing about the developer's clone changes, and the
 * host's whole share of the decision is "is this a name git reported". These two
 * change the clone. So they carry a second thing a Preview does not — a **gate**,
 * asked host-side against facts the agent cannot influence — and this module is
 * the confined half of both: the tool's shape, the sentences the agent reads
 * back, and the one line each request and answer crosses on.
 *
 * The gate itself is not here. It is `landWorktree` in ./landing.ts, which asks
 * `unattendedLanding` in ./fence.ts, and it runs in the Harness runtime where git
 * runs. Nothing in this file decides anything.
 *
 * ## The answers carry a sentence, and ./preview.ts's do not
 *
 * That is a deliberate departure and it is worth being exact about. A preview
 * answer is a **tag**, because the process that produces it is the Rust host —
 * the one holding the Credential and performing spawns — and a sentence composed
 * there is the string most likely to carry a path, an environment or an OS error
 * into a confined process.
 *
 * These answers are produced in the *runtime*, in TypeScript, by the same code
 * that performed the merge. That is exactly the division `report-merge` already
 * makes: `mergeBriefing` writes the sentence, the Rust host copies it onto the
 * pipe and composes nothing. So a `detail` here is a sentence some TypeScript
 * wrote about work it did, and the rule that matters is kept — **every outcome
 * the Rust host decides for itself arrives with no detail at all**, and its
 * sentence is authored below like a preview's. `src-tauri/src/unattended.rs`
 * asserts that.
 *
 * A refusal has to say *which rule refused and about what*, or a run report
 * prints "it would not land" and a developer wakes up to a branch and no reason.
 * That sentence is `unattendedLanding`'s and it is already written; carrying a
 * tag alone would mean writing it a second time on this side, out of fields, in
 * a process that never saw the branch.
 */

// ---------------------------------------------------------------------------
// Landing a Worktree
// ---------------------------------------------------------------------------

/** The Custom Tool's name, as the agent sees it. */
export const LAND_WORKTREE_TOOL = 'land_worktree'

/**
 * What the tool says it does — including what it will refuse and why.
 *
 * The refusals are described rather than left to be discovered, for the reason
 * `LAUNCH_PREVIEW_DESCRIPTION` describes its own: an agent that knows the Fence
 * is never landed unattended hands that branch over instead of calling this and
 * reading a refusal, and a tool call that was never made is the cheapest refusal
 * there is.
 *
 * The last paragraph is the one that stops a wrong Turn rather than a wasted
 * one. An agent that has merged its own branch is an agent whose next reasonable
 * thought is "my change is running", and it is not: varnick is still the build
 * from before, exactly as after a developer's merge (`RESTART_STILL_OWED`).
 */
export const LAND_WORKTREE_DESCRIPTION = [
  'Ask varnick to merge one of your worktrees into the live tree: squashed onto the live branch,',
  'the worktree removed and the branch deleted. This is how work you finished is delivered without',
  'a person awake to press anything.',
  '',
  'Takes the name of a worktree under .claude/worktrees/ — one path component, nothing else. It is',
  'not a path and not a command, and the merge is performed by the host, because a confined process',
  'cannot write the live tree.',
  '',
  'The host decides, from git rather than from anything you say. It reads what the branch changed',
  'out of git itself and refuses the whole branch if any of it is protected: packages/harness/**,',
  'src-tauri/**, the sandbox policy and its baseline, scripts/**, .githooks/**, .varnick/gitconfig,',
  'or a package.json diff that adds, changes or removes an install lifecycle script. A dirty live',
  'tree and a branch that does not merge cleanly are refused too. Every refusal comes back with the',
  'rule and the path that caused it, in words a run report can print — a refused branch is finished',
  'work waiting for a person, not a mistake to retry.',
  '',
  'A branch that lands is in the live tree and is still not running: varnick goes on serving the',
  'build it started with until it restarts. Do not assume the change is live because it merged.',
].join('\n')

/**
 * What happened to a request to land a Worktree.
 *
 * Seven, and they divide in three: one that landed, four the host refused about
 * *this* branch, and two where the question could not be put. The last two are
 * separated from the refusals on purpose — "protected, so a human merges it" is
 * a finished ticket to hand over, and "the host could not be asked" is a broken
 * machine to stop on. An orchestrator that read one for the other would either
 * park good work or retry a refusal all night.
 */
export const LANDING_OUTCOMES = [
  /** The branch is on the live tree. */
  'landed',
  /** The protected-path predicate said no. The detail says which rule and what. */
  'refused',
  /** The live tree has uncommitted work in it, so a merge could lose something. */
  'dirty-live-tree',
  /** The branch conflicts, or git could not say whether it merges. */
  'unmergeable',
  /** No worktree of that name has commits the live tree does not. */
  'unknown-worktree',
  /** git could not be asked what worktrees exist, so nothing was checked. */
  'no-worktrees',
  /** The question reached nothing, or the merge did not finish. Nothing landed. */
  'no-landing',
] as const

export type LandingOutcome = (typeof LANDING_OUTCOMES)[number]

export function isLandingOutcome(value: unknown): value is LandingOutcome {
  return typeof value === 'string' && (LANDING_OUTCOMES as readonly string[]).includes(value)
}

/**
 * What the host answered, as it crosses into the Sandbox.
 *
 * `detail` is a sentence composed where the work happened, or `null`. See the
 * module header for which outcomes may carry one and which may never.
 */
export interface UnattendedAnswer<Outcome extends string> {
  readonly outcome: Outcome
  readonly detail: string | null
}

export type LandingAnswer = UnattendedAnswer<LandingOutcome>

/** What to tell the agent, in one sentence, selected by the tag. */
export function landingOutcomeMessage(outcome: LandingOutcome): string {
  switch (outcome) {
    case 'landed':
      return 'That worktree is merged into the live tree. varnick is still running the build it started with, so the change is not live until it restarts.'
    case 'refused':
      return 'varnick will not land that branch without a human, and the rule that refused it is:'
    case 'dirty-live-tree':
      return 'The live tree has uncommitted work in it. A merge over that is how a change nobody knew about is lost, so nothing was merged. Nothing here can commit it for you — this one waits for the developer.'
    case 'unmergeable':
      return 'That branch does not merge into the live tree as it stands, so nothing was merged. Merge the live branch down into the worktree, where you may write, and ask again.'
    case 'unknown-worktree':
      return 'That is not the name of a worktree under .claude/worktrees/ with commits the live tree does not have. The name is one path component — not a path, not the live clone — and a branch level with the live tree has nothing to land.'
    case 'no-worktrees':
      return 'The host could not ask git what worktrees exist, so nothing was checked and nothing was merged.'
    case 'no-landing':
      return 'The host could not carry out the landing. Nothing was merged, and this is a broken machine rather than a refusal — do not retry it in a loop.'
  }
}

/**
 * The tool's answer, as the agent reads it.
 *
 * A sentence and a flag, like `previewToolResult`. The flag is what makes "your
 * branch is still pending" a fact the agent can act on rather than prose it has
 * to interpret: six of these seven mean nothing was merged, and an agent that
 * went on to report the ticket delivered would be reporting a merge that never
 * happened.
 *
 * The detail is appended rather than interpolated, so an outcome that arrives
 * with none still reads as a whole sentence.
 */
export function landingToolResult(answer: LandingAnswer): {
  readonly landed: boolean
  readonly text: string
} {
  return {
    landed: answer.outcome === 'landed',
    text: sentence(landingOutcomeMessage(answer.outcome), answer.detail),
  }
}

/**
 * One request to land a Worktree, as one line on the agent host's stdout.
 *
 * The third shape on a pipe that carries Turn events and Preview requests, told
 * apart the same way: by which id and which kind it names. Two fields, because
 * there is nothing else a landing needs — the host resolves the name against
 * `git worktree list`, and there is deliberately no field for a base, a commit,
 * a message or a path list. What the branch changed is read from git, and a
 * field the agent could fill would be a way to answer the predicate's question
 * for it.
 */
export function encodeLandingRequest(requestId: string, worktree: string): string {
  return `${JSON.stringify({ kind: 'land-worktree', requestId, worktree })}\n`
}

// ---------------------------------------------------------------------------
// Cutting a Pre-release
// ---------------------------------------------------------------------------

/** The Custom Tool's name, as the agent sees it. */
export const CUT_PRE_RELEASE_TOOL = 'cut_pre_release'

/**
 * What the tool says it does, and the one thing it deliberately does not.
 *
 * Promotion is the developer's and stays the developer's, so the description
 * says so: an agent that knows a Pre-release is not served does not go looking
 * for the control that would serve it, and does not tell the developer in its
 * report that the new build is running.
 */
export const CUT_PRE_RELEASE_DESCRIPTION = [
  'Cut a pre-release from the work that has landed: a version, a changelog entry, an announcement',
  'written from the run\'s tickets, a build and a tag. This is how a night of finished tickets ends',
  'with one thing the developer can accept in the morning.',
  '',
  'Takes the feature slug the run is named by — the one under .scratch/, as in .scratch/<slug>/issues.',
  'One path component, nothing else. The host runs the release, because cutting one writes the root',
  'manifest and package.json is not yours to write.',
  '',
  'It does not change what varnick is serving and it does not promote anything. The developer',
  'promotes, from a band in the window. A run that cut a pre-release ends there.',
].join('\n')

/**
 * What happened to a request to cut a Pre-release.
 *
 * The same three-way split the release script's own exit codes make, and it is
 * the split that matters to whatever is orchestrating: `cut` is a night
 * delivered, `refused` is a decision the release made on purpose — every ticket
 * parked, nothing landed to announce — and `no-release` is the world broken
 * underneath it. See `packages/core/scripts/release.ts`, which is where those
 * three are decided.
 */
export const RELEASE_OUTCOMES = [
  /** A pre-release exists, is tagged, and is not being served. */
  'cut',
  /** There was nothing to release, and the detail says what the release said. */
  'refused',
  /** The slug is not a feature slug. Nothing ran. */
  'not-a-feature',
  /** The release could not be run or did not answer. Nothing was cut. */
  'no-release',
] as const

export type ReleaseOutcome = (typeof RELEASE_OUTCOMES)[number]

export function isReleaseOutcome(value: unknown): value is ReleaseOutcome {
  return typeof value === 'string' && (RELEASE_OUTCOMES as readonly string[]).includes(value)
}

export type ReleaseAnswer = UnattendedAnswer<ReleaseOutcome>

/** What to tell the agent, in one sentence, selected by the tag. */
export function releaseOutcomeMessage(outcome: ReleaseOutcome): string {
  switch (outcome) {
    case 'cut':
      return 'A pre-release is cut, recorded and tagged. It is not being served: the developer promotes it, and until they do varnick goes on running the build it started with.'
    case 'refused':
      return 'Nothing was cut, and that is a decision the release made rather than a failure:'
    case 'not-a-feature':
      return 'That is not a feature slug. It is one path component naming the run — the directory under .scratch/ the tickets are in — and it is not a path, a flag or a version.'
    case 'no-release':
      return 'The release could not be run, so nothing was cut, tagged or announced. This is a broken machine rather than a refusal — do not retry it in a loop.'
  }
}

/**
 * The tool's answer, as the agent reads it.
 *
 * `cut` is the flag rather than "not refused", so the two ways of not cutting
 * stay apart at the one place the agent reads them: a run that reported a
 * pre-release because the tool did not fail would be a run that announced work
 * nobody can accept.
 */
export function releaseToolResult(answer: ReleaseAnswer): {
  readonly cut: boolean
  readonly text: string
} {
  return {
    cut: answer.outcome === 'cut',
    text: sentence(releaseOutcomeMessage(answer.outcome), answer.detail),
  }
}

/**
 * One request to cut a Pre-release, as one line on the agent host's stdout.
 *
 * One field beside the id, and it is the slug. There is no field for a version,
 * a tag, a changelog or an artifact: all four are decided by
 * `packages/core/release.ts` from what actually landed, and a request that could
 * name a version would be an agent announcing whatever it liked.
 */
export function encodeReleaseRequest(requestId: string, feature: string): string {
  return `${JSON.stringify({ kind: 'cut-release', requestId, feature })}\n`
}

/**
 * Whether a string is the slug of a run, in the one shape that may reach argv.
 *
 * Asked in the Harness runtime, which is the process that spawns
 * `bun run release <slug>` — the string becomes a command's argument there and
 * nowhere else, so that is where the shape is decided. The Rust host forwards it
 * unexamined, for the reason it forwards a worktree diff's path: a validation
 * written on both sides is a validation that drifts, and the side that must be
 * right is the side holding the spawn.
 *
 * It is `is_plain_worktree_name` in src-tauri/src/preview.rs by another name,
 * and the same three shapes it refuses are the ones that matter here: a
 * separator, so the slug cannot climb out of `.scratch/`; a leading `-`, so it
 * cannot be read as a flag by the script it is handed to; and a leading `.`, so
 * it is not `..` in disguise. `release.ts` refuses the first two itself, which is
 * a second answer rather than the only one — a script's own argument check is
 * one edit away from being relaxed by somebody who does not know an agent's
 * string reaches it.
 */
export function isFeatureSlug(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= 100 &&
    !value.startsWith('-') &&
    !value.startsWith('.') &&
    [...value].every(
      (character) =>
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') ||
        character === '-' ||
        character === '_' ||
        character === '.',
    )
  )
}

/**
 * The sentence for a tag, and the detail after it when there is one.
 *
 * Trimmed, because the details are composed from git output and from a script's
 * last line, and a trailing newline in the middle of a tool result is a sentence
 * that reads as two.
 */
function sentence(message: string, detail: string | null): string {
  const said = detail === null ? '' : detail.trim()
  return said.length === 0 ? message : `${message} ${said}`
}
