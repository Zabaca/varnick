import type { HarnessInput } from '../machines/harness.ts'
import { HARNESS_STATE_PATHS } from '../machines/harness.ts'
import { SESSION_STATE_PATHS } from '../machines/session.ts'
import { SURFACE_STATE_PATHS } from '../machines/surface.ts'
import { WORKTREE_DIFF_STATE_PATHS } from '../machines/worktree-diff.ts'
import { MODELS, compactedTranscript, type PendingWorktree, type SurfaceDescriptor } from '../domain.ts'
import type { DiffOutcome, SurfaceOutcome } from '../actors/frozen.ts'
import { seedPolicy, seedMessages, statesSurface } from './seed.ts'

/**
 * Every state the chat surface can be in, as data.
 *
 * Plain data, no JSX, so `drive.ts` can assert coverage headlessly — the states
 * page and the coverage check read the same list, and neither can drift from
 * the other by being edited alone.
 *
 * A scenario is not a mock. It is the real Harness, created cold with an entry
 * point and frozen actors, so the card shows the same component the live app
 * shows, driven by the same machine.
 */

export type StatePath = string

/**
 * The sections of the states page, in the order they are shown.
 *
 * These were five comment banners in this file — `// -- Start-up ---` and so
 * on. A comment cannot be rendered, so the page had no grouping and the index
 * added in ticket 42 would have had to invent one beside them, which is two
 * answers to how the page is organised and one of them silently stale. They are
 * data now, and every scenario names one.
 */
export const GROUPS = [
  'Start-up',
  'Refusals and failures',
  'The conversation',
  'Surfaces',
  'Persistence',
  'Pending Core changes',
] as const
export type Group = (typeof GROUPS)[number]

export interface Scenario {
  /** Stable id; also the card a ticket links to — see ../routing.ts. */
  readonly id: string
  readonly title: string
  /** Which section of the page this card sits in. */
  readonly group: Group
  /** What this card shows. */
  readonly blurb: string
  /** The question the card answers for whoever is reading it. */
  readonly question: string
  /** The state paths this card demonstrates. Checked against the machines. */
  readonly covers: readonly StatePath[]
  readonly input: HarnessInput
  /**
   * Whether this card is a conversation restored from the mirror with a
   * redaction in it.
   *
   * Not a state, and deliberately not one: a resumed Session is `turn.idle`
   * with messages, which the machines already had. How the run started is a
   * prop on the surface, the same as the seeded marker's `mode`, so a card that
   * wants to show it has to say so here. See
   * docs/adr/0009-resume-reads-the-mirror.md.
   */
  readonly restoredRedacted?: boolean
  /**
   * Surfaces this card discovers, sent as `DISCOVER_SURFACES` once the actor is
   * running.
   *
   * Not part of `input`, because discovery is not something a Harness is
   * created with: a Surface arrives when the filesystem is scanned, and the
   * event is the only way in. The states page and drive.ts both send it, from
   * this one list.
   */
  readonly surfaces?: readonly SurfaceDescriptor[]
  /** What the frozen loader does with them. See actors/frozen.ts. */
  readonly surfaceOutcome?: SurfaceOutcome
  /**
   * The Worktree this card opens, sent as `OPEN_WORKTREE` once the actor runs.
   *
   * Not part of `input` for the reason `surfaces` is not: opening a diff is
   * something a developer does to a listing that is already on screen, and the
   * event is the only way in. The path has to be one of this scenario's own
   * `worktrees`, or the machine's guard refuses it — which is the same rule the
   * live surface follows and the reason a card cannot show a diff of something
   * the list beside it never mentioned.
   */
  readonly opensWorktree?: string
  /** What the frozen reader does with it. See actors/frozen.ts. */
  readonly diffOutcome?: DiffOutcome
}

/** Harness held up, ready for a Session. */
const up = {
  policy: seedPolicy,
  enterCredential: 'present',
  // A credential that is present always turned out to be something. A card
  // parked in `credential.present` with no kind is a context the live machine
  // cannot reach, so the cards name one — a subscription, because it is what
  // the setup screen offers first and what a mint produces. Nothing on screen
  // now differs by kind: the strip that did was cut in ticket 31.
  credentialKind: 'subscription' as const,
  enterSandbox: 'available',
  enterAgent: 'running',
  /*
    What a running agent has reported about itself.

    Seeded, like the transcript beside it, and chosen to look like what a real
    varnick agent produces: a clone that carries a plugin, and the skills that
    come with it. It was all zeroes when `settingSources: []` meant the clone's
    own configuration was dropped too; ticket 38 reversed that, and a card still
    showing zeroes would be a card of a configuration the product left behind.
  */
  runtime: {
    // A plausible UUID and a resumed session, because that is what the second
    // and every later launch looks like. A card showing `resumed: false` would
    // be showing a first run as though it were the normal case.
    sessionId: '00000000-0000-0000-0000-000000000000',
    resumed: true,
    claudeCodeVersion: '2.1.0',
    model: 'claude-opus-5',
    permissionMode: 'bypassPermissions',
    outputStyle: 'default',
    cwd: '/Users/you/varnick',
    apiKeySource: 'CLAUDE_CODE_OAUTH_TOKEN',
    tools: ['Task', 'Bash', 'Glob', 'Grep', 'Read', 'Edit', 'Write', 'WebFetch', 'WebSearch'],
    skills: ['caveman', 'to-tickets'],
    slashCommands: ['compact', 'model', 'caveman'],
    agents: [],
    mcpServers: [],
    plugins: [{ name: 'caveman', path: '/Users/you/varnick/.claude/plugins/caveman', version: null }],
  },
} satisfies HarnessInput

/**
 * Three branches waiting: one that edits the Fence, one that does not, and one
 * that will not go in.
 *
 * Literal scenario data, like the mint card's URL: made up, and visibly so —
 * nothing on this page runs git. One list rather than one per card, because the
 * cards below it are one screen at several moments: a listing, and the same
 * listing with one of its rows opened. A second copy is how the row a card
 * opens comes to name a worktree the card does not show.
 *
 * The third entry earns its place by being the one with no merge control on it.
 * A list where everything lands designs the half of this band that needs no
 * design; the row that conflicts is the one whose copy has to name the files
 * and say whose job the fix is.
 */
const statesWorktrees: readonly PendingWorktree[] = [
  {
    path: '/Users/you/varnick/.claude/worktrees/ticket-48',
    branch: 'ticket/48-launch-preview',
    commits: 4,
    changed: ['src-tauri/src/lib.rs', 'packages/harness/src/agent.ts'],
    touchesFence: true,
    merge: { kind: 'fast-forward' },
  },
  {
    path: '/Users/you/varnick/.claude/worktrees/ticket-50',
    branch: 'ticket/50-diff-view',
    commits: 2,
    changed: ['packages/core/src/pages/DesignedPage.tsx'],
    touchesFence: false,
    merge: { kind: 'clean' },
  },
  {
    path: '/Users/you/varnick/.claude/worktrees/ticket-53',
    branch: 'ticket/53-heredoc',
    commits: 1,
    changed: ['sandbox-policy.baseline.json', 'packages/harness/src/sandbox.ts'],
    touchesFence: true,
    merge: {
      kind: 'conflicts',
      files: ['sandbox-policy.baseline.json', 'packages/harness/src/sandbox.ts'],
    },
  },
]

/** The one a diff card opens: the branch that edits the Fence. */
const openedWorktree = statesWorktrees[0]!.path

/** And the one a card opens to show a screen with no merge control on it. */
const conflictedWorktree = statesWorktrees[2]!.path

export const SCENARIOS: readonly Scenario[] = [
  // -- Start-up ------------------------------------------------------------
  {
    id: 'cold-start',
    group: 'Start-up',
    title: 'Cold start',
    blurb:
      'Nothing has been read or checked yet. The literal first frame after launch, before even the sandbox has been asked about.',
    question: 'Is the first thing asked for the first thing that is needed, and nothing else?',
    covers: ['credential.absent', 'sandbox.unchecked', 'agent.down'],
    input: { policy: seedPolicy },
  },
  {
    id: 'reading-credential',
    group: 'Start-up',
    title: 'Reading the credential',
    blurb: 'Tauri is asking the keychain. Nothing is claimed until it answers.',
    question: 'Is the wait legible without asserting an outcome?',
    covers: ['credential.reading'],
    input: { policy: seedPolicy, enterCredential: 'reading' },
  },
  {
    id: 'checking-sandbox',
    group: 'Start-up',
    title: 'Establishing the sandbox',
    blurb: 'Credential in hand, srt not yet established. The agent has not started.',
    question: 'Does the surface stay quiet while a step that usually succeeds is running?',
    covers: ['credential.present', 'sandbox.checking'],
    input: {
      policy: seedPolicy,
      enterCredential: 'present',
      credentialKind: 'subscription',
      enterSandbox: 'checking',
    },
  },
  {
    id: 'starting-agent',
    group: 'Start-up',
    title: 'Starting the agent',
    blurb: 'Both preconditions hold; the process is being spawned under srt.',
    question: 'Is "starting" distinguishable from "idle with nothing to say"?',
    covers: ['sandbox.available', 'agent.starting'],
    input: {
      policy: seedPolicy,
      enterCredential: 'present',
      credentialKind: 'subscription',
      enterSandbox: 'available',
      enterAgent: 'starting',
    },
  },

  // -- Refusals and failures ----------------------------------------------
  {
    id: 'sandbox-unavailable',
    group: 'Refusals and failures',
    title: 'Sandbox unavailable',
    blurb:
      'srt could not be established. There is no fallback to running unconfined — see ADR-0003.',
    question: 'Does the refusal read as a deliberate rule rather than a broken app?',
    covers: ['sandbox.unavailable'],
    input: {
      policy: seedPolicy,
      enterCredential: 'present',
      credentialKind: 'subscription',
      enterSandbox: 'unavailable',
      sandboxError: 'srt: sandbox could not be established',
    },
  },
  {
    id: 'credential-rejected',
    group: 'Refusals and failures',
    title: 'Credential rejected',
    blurb: 'The stored credential exists and the API refused it.',
    question: 'Is this distinguishable from having no credential at all?',
    covers: ['credential.rejected'],
    input: { policy: seedPolicy, enterCredential: 'rejected', enterSandbox: 'available' },
  },
  {
    id: 'no-credential',
    group: 'Refusals and failures',
    title: 'No credential — first run',
    blurb:
      'What a stranger sees on the first launch of a fresh clone: the read found nothing, and the way out is a field rather than a command to go and type somewhere else. The sandbox is fine.',
    question: 'Could someone who has never seen this get to a working agent without leaving the window?',
    covers: ['credential.absent'],
    input: {
      policy: seedPolicy,
      enterSandbox: 'available',
      credentialError: 'no credential found',
    },
  },
  {
    id: 'storing-credential',
    group: 'Refusals and failures',
    title: 'Storing the credential',
    blurb:
      'A subscription token was pasted into the setup screen and the host is writing the keychain item. The value crossed once and is held nowhere on this side.',
    question: 'Does the wait read as a write in progress rather than a form that stopped responding?',
    covers: ['credential.storing'],
    input: {
      policy: seedPolicy,
      enterCredential: 'storing',
      storingKind: 'subscription',
      enterSandbox: 'available',
    },
  },
  {
    id: 'minting-token',
    group: 'Refusals and failures',
    title: 'Minting a subscription token',
    blurb:
      'varnick is running `claude setup-token` on the host and waiting for a sign-in. The browser it tried to open may not have opened, so the URL is on screen — that fallback is the whole reason the flow can be driven from in here at all. Nothing about the token it produces reaches this side: it is read off a terminal and written to the keychain in the host process.',
    question:
      'Does a wait that depends on the developer doing something elsewhere say what that something is?',
    covers: ['credential.minting'],
    input: {
      policy: seedPolicy,
      enterCredential: 'minting',
      enterSandbox: 'available',
      // A literal, and visibly one. The seeded mint deliberately invents no
      // URL — a made-up authorize link is a link somebody eventually clicks —
      // so the card supplies its own where it can be read as scenario data.
      mintUrl:
        'https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-0000-0000-000000000000&response_type=code&scope=user%3Ainference&state=example',
    },
  },
  {
    id: 'start-refused',
    group: 'Refusals and failures',
    title: 'Start refused',
    blurb:
      'START was pressed while a precondition did not hold. The refusal explains itself instead of swallowing the click.',
    question: 'Does a refused start say which precondition refused it?',
    covers: ['agent.startRefused'],
    input: {
      policy: seedPolicy,
      enterSandbox: 'unavailable',
      enterAgent: 'startRefused',
      sandboxError: 'srt: sandbox could not be established',
      refusal: { kind: 'sandbox-unavailable', detail: 'sandbox-runtime could not be established.' },
    },
  },
  {
    id: 'agent-crashed',
    group: 'Refusals and failures',
    title: 'Agent crashed',
    blurb: 'The process exited on its own. The transcript is unaffected.',
    question: 'Is restarting offered without implying the conversation was lost?',
    covers: ['agent.crashed'],
    input: {
      policy: seedPolicy,
      enterCredential: 'present',
      credentialKind: 'subscription',
      enterSandbox: 'available',
      enterAgent: 'crashed',
      agentError: 'exit code 137',
    },
  },

  // -- The conversation ----------------------------------------------------
  {
    id: 'idle-empty',
    group: 'The conversation',
    title: 'Running, nothing said',
    blurb: 'The agent is up and the transcript is empty. The true first screen.',
    question: 'Does an empty transcript tell you what to type?',
    covers: ['agent.running', 'turn.idle', 'persistence.saved', 'composer.typing'],
    input: { ...up, sessionInput: { sessionId: 'states-idle' } },
  },
  /*
    An `api-key-no-plan` card was here, showing the same running session under
    an API key so the plan-usage strip's absence could be compared against its
    presence. Both it and the strip are gone: with nothing on screen differing
    by Credential Kind, the card had no second thing to be a comparison against.

    The kind itself is not gone and is still a fact the host decides — it
    chooses which variable the agent is spawned with. It simply has no card,
    because it has no appearance. See ticket 31.
  */
  {
    id: 'resumed',
    group: 'The conversation',
    title: 'Resumed on launch',
    blurb:
      'varnick was quit — or killed — and relaunched. The transcript came back from the mirror, which is redacted on the way in, so one message reads [redacted] where a secret value was.',
    question: 'Can you tell you are reading the record rather than what you typed?',
    // The same idle state, entered from disk instead of from a literal. A Turn
    // that was in flight at the crash comes back here too: the mirror is
    // written at Turn boundaries and holds no partial, so the transcript simply
    // ends at the last completed one.
    covers: ['turn.idle', 'persistence.saved'],
    restoredRedacted: true,
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-resumed',
        messages: [
          { id: 'm1', role: 'user', text: 'Call the runs API with [redacted] and show the last ten.' },
          { id: 'm2', role: 'agent', text: 'Done — userspace/surfaces/runs now lists them.' },
        ],
        tokensUsed: 18_200,
      },
    },
  },
  {
    id: 'sending',
    group: 'The conversation',
    title: 'Sending',
    blurb: 'The prompt is posted and the agent has not produced a token yet.',
    question: 'Is the gap between sending and the first token accounted for?',
    covers: ['turn.answering.sending'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-sending',
        messages: seedMessages,
        enterTurn: 'sending',
        tokensUsed: 12_400,
      },
    },
  },
  {
    id: 'streaming',
    group: 'The conversation',
    title: 'Streaming',
    blurb: 'Output is arriving. The partial is rendered as a message, not as a placeholder.',
    question: 'Does a half-arrived answer read as an answer?',
    covers: ['turn.answering.streaming'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-streaming',
        messages: seedMessages,
        partial: 'Adding the Surface. Reading userspace/surfaces to see what is already there',
        enterTurn: 'streaming',
        tokensUsed: 18_900,
      },
    },
  },
  {
    id: 'interrupting',
    group: 'The conversation',
    title: 'Interrupting',
    blurb:
      'Escape was pressed mid-stream. The partial is kept — an interrupted turn still said something.',
    question: 'Is it clear the work so far survives the interrupt?',
    covers: ['turn.interrupting'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-interrupting',
        messages: seedMessages,
        partial: 'Adding the Surface. Reading userspace',
        enterTurn: 'interrupting',
      },
    },
  },
  {
    id: 'turn-failed',
    group: 'The conversation',
    title: 'Turn failed',
    blurb: 'The turn threw. Retry and dismiss are both offered because both events are accepted.',
    question: 'Can the user tell whether their message was lost?',
    covers: ['turn.failed'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-failed',
        messages: seedMessages,
        enterTurn: 'failed',
        turnError: 'stream closed unexpectedly',
      },
    },
  },
  {
    id: 'compacted',
    group: 'The conversation',
    title: 'Summarised',
    blurb:
      'The agent compacted the conversation — because the window filled, or because the CLI was asked to. varnick did not ask and does not have a command for it; it heard.',
    question: 'Is it clear that nothing was discarded blindly, and that the meter is a reading?',
    covers: ['turn.idle'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-compacted',
        messages: compactedTranscript(
          seedMessages,
          'The developer asked about the harness and the agent answered. Nothing is outstanding.',
        ),
        tokensUsed: 34_000,
      },
    },
  },
  {
    id: 'command-menu',
    group: 'The conversation',
    title: 'Command menu',
    blurb: 'A draft that still matches a command name. Tab completes, Enter sends.',
    question: 'Does the list show only commands the machines will actually accept?',
    covers: ['composer.menu'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-menu',
        messages: seedMessages,
        draft: '/mo',
        /*
          Seeded, not left to the view.

          The machine derives menu state from the names it has been told about,
          and the view tells it on mount. Without them here the card would be
          right in a browser and wrong under drive.ts — which is the same as
          saying the scenario is not the thing being asserted.
        */
        // One row now, not one per value — see the composer's command list.
        // The card's draft is `/mo`, which this still answers.
        commandNames: ['/model', '/effort', '/compact'],
      },
    },
  },

  // -- Surfaces ------------------------------------------------------------
  //
  // The same Surface three times, because the three states are three things
  // that happen to one file. What is inside a loaded Surface is Userspace's and
  // differs per clone, so these cards show the frame Core draws and stop there —
  // inventing content would make them the mock this page exists to avoid.
  {
    id: 'surface-loading',
    group: 'Surfaces',
    title: 'Surface loading',
    blurb: 'A Surface was found on disk and its module is being imported.',
    question: 'Is a Surface that has not arrived yet distinguishable from one that failed?',
    covers: ['surface.loading'],
    input: { ...up, sessionInput: { sessionId: 'states-surface-loading', messages: seedMessages } },
    surfaces: [statesSurface],
    surfaceOutcome: 'holds',
  },
  {
    id: 'surface-loaded',
    group: 'Surfaces',
    title: 'Surface loaded',
    blurb:
      'The module imported and its default export is rendered here. Nothing in Core imports it — it was found by scanning the directory, which is why adding one never touches Core.',
    question: 'Does a Surface read as part of the window rather than as a panel bolted to it?',
    covers: ['surface.loaded'],
    input: { ...up, sessionInput: { sessionId: 'states-surface-loaded', messages: seedMessages } },
    surfaces: [statesSurface],
    surfaceOutcome: 'loads',
  },
  {
    id: 'surface-failed',
    group: 'Surfaces',
    title: 'Surface failed',
    blurb:
      'The module did not compile. One Surface is down, its siblings are not, and the conversation that caused it is still on the left to fix it — ADR-0004.',
    question: 'Does the error say enough to act on without opening a console?',
    covers: ['surface.failed'],
    input: { ...up, sessionInput: { sessionId: 'states-surface-failed', messages: seedMessages } },
    surfaces: [statesSurface],
    surfaceOutcome: 'fails',
  },

  // -- Persistence ---------------------------------------------------------
  {
    id: 'saving',
    group: 'Persistence',
    title: 'Saving',
    blurb: 'A save is in flight while the turn is idle. The two regions are independent.',
    question: 'Does persistence stay out of the way when it is working?',
    covers: ['persistence.saving'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-saving',
        messages: seedMessages,
        enterPersistence: 'saving',
      },
    },
  },
  {
    id: 'save-failed',
    group: 'Persistence',
    title: 'Save failed',
    blurb:
      'The session store could not be written. The transcript is intact and the turn is unaffected.',
    question: 'Is a failed save distinguishable from a failed turn?',
    covers: ['persistence.saveFailed'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-save-failed',
        messages: seedMessages,
        enterPersistence: 'saveFailed',
        saveError: 'could not write session store',
      },
    },
  },

  // -- Pending Core changes ------------------------------------------------
  //
  // The `review` region: which Worktrees hold Core changes nobody has merged,
  // taken from git host-side and never from the agent (ADR-0014).
  //
  // These cards carry the states before anything draws them. The list itself is
  // ticket 50's — this ticket is the data — so what a card shows today is the
  // window with the region parked, and the state line above it. They are here
  // rather than added with the rendering because the coverage banner is a gate:
  // a state that ships without a card is a state nobody has looked at, and that
  // is precisely the state that ships broken.
  //
  // Two of them are cards of *nothing being drawn*, and that is what they are
  // for. The band renders when it has something to show, so `review.empty` — the
  // state the surface is in almost all the time — costs no vertical space at
  // all, and neither does the listing a launch or a Turn ending starts behind
  // it. The thing to judge on those two cards is the chat: it should look like a
  // window with no panel in it, not like a window with a gap.
  {
    id: 'worktrees-listing',
    group: 'Pending Core changes',
    title: 'Asking git what is pending',
    blurb:
      'The region every launch starts in, and the region every Turn ends in. Nobody asked for it — there is no state meaning "not listed yet" — and with no rows behind it, nothing is drawn: a band that appeared and vanished on every Turn would be motion the machines did not make.',
    question: 'Is a listing in flight quiet enough to launch into, and to end every Turn in?',
    covers: ['review.listing'],
    input: { ...up, sessionInput: { sessionId: 'states-worktrees-listing', messages: seedMessages } },
  },
  {
    id: 'worktrees-listed',
    group: 'Pending Core changes',
    title: 'Two worktrees waiting',
    blurb:
      'Two branches hold commits the live tree does not, and one of them edits the Fence — the generator, the host, or the baseline. That flag is the field the diff view turns into colour, so a widening cannot sit unremarked in four hundred lines. Above the conversation, because it is the most consequential thing on the screen and the column beside the chat scrolls.',
    question: 'Can you tell at a glance which of these changes the boundary?',
    covers: ['review.listed'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktrees-listed', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
    },
  },
  {
    id: 'worktrees-empty',
    group: 'Pending Core changes',
    title: 'Nothing waiting',
    blurb:
      'git answered and there is nothing to merge. A real state rather than a list of length zero — and it says so by not being there: a panel earning a permanent slot for the state it is in almost all the time is how it ended up below the fold. *look again* is in the command menu while the band is away.',
    question: 'Does the window read as up to date, rather than as missing a panel?',
    covers: ['review.empty'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktrees-empty', messages: seedMessages },
      enterReview: 'empty',
    },
  },
  {
    id: 'worktrees-list-failed',
    group: 'Pending Core changes',
    title: 'The listing failed',
    blurb:
      'git could not be run, or would not answer, on the first listing of the run — so there is nothing standing behind it. Nothing is known about what is pending, which is why this is not the card above with an empty list: one says nothing is waiting, and this one says nobody can currently tell.',
    question: 'Is "we do not know" distinguishable from "there is nothing"?',
    covers: ['review.listFailed'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktrees-list-failed', messages: seedMessages },
      enterReview: 'listFailed',
      worktreeError: 'fatal: not a git repository',
    },
  },
  {
    id: 'worktrees-refresh-failed',
    group: 'Pending Core changes',
    title: 'The refresh failed, the list stood',
    blurb:
      'The same state as the card above and the opposite sentence, because a list survived it. Every Turn now re-lists, so most failures are failures to refresh — and a git that would not answer this time has said nothing about the branches it listed a minute ago. The rows stay, and stay openable, under a warning that nobody could check them.',
    question: 'Is it clear these are the last answer rather than the current one?',
    covers: ['review.listFailed'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktrees-refresh-failed', messages: seedMessages },
      enterReview: 'listFailed',
      worktrees: statesWorktrees,
      worktreeError: 'fatal: unable to read .git/HEAD',
    },
  },

  // The same listing with one of its rows opened, three ways. The branch opened
  // is the one that edits the Fence, because that is the reading this view
  // exists for: everything else about a diff renderer is a convenience.
  {
    id: 'worktree-diff-loading',
    group: 'Pending Core changes',
    title: 'Opening a worktree',
    blurb:
      'A branch was opened and git is being asked what changed in it. The list stays beside it — the summaries were cheap, and this is where the cost of reading one branch is paid.',
    question: 'Is a diff on its way distinguishable from a diff with nothing in it?',
    covers: ['worktreeDiff.loading'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-diff-loading', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
    },
    opensWorktree: openedWorktree,
    diffOutcome: 'holds',
  },
  {
    id: 'worktree-diff-loaded',
    group: 'Pending Core changes',
    title: 'Reading what changed',
    blurb:
      'Two files in one branch: a Core refactor, and an edit to the Sandbox policy generator that widens what the agent may write. The second is Fence — the code that decides what the agent may do — and the whole point of this card is whether you found it before reading this sentence.',
    question: 'Could a widening sit unremarked in four hundred lines of this?',
    covers: ['worktreeDiff.loaded'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-diff-loaded', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
    },
    opensWorktree: openedWorktree,
    diffOutcome: 'loads',
  },
  {
    id: 'worktree-diff-failed',
    group: 'Pending Core changes',
    title: 'The diff would not load',
    blurb:
      'git answered the listing and would not answer this. The reason is git’s own, and the retry is offered because `failed` accepts one — not because a control was left enabled.',
    question: 'Does the reason say enough to act on, and is the way back obvious?',
    covers: ['worktreeDiff.failed'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-diff-failed', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
    },
    opensWorktree: openedWorktree,
    diffOutcome: 'fails',
  },

  /*
    Landing one, which is the point of the four cards above.

    The first is not a merge at all: it is the branch that conflicts, opened, to
    check that the screen with *no* control on it says what to do instead. Every
    other card here is a moment after the click, and the two worth arguing about
    are `merged` — which has to make "you are running old code" impossible to
    read past — and the merge that landed with a directory still on disk, which
    is the outcome the shape of this feature makes most likely and the one a
    boolean would have flattened into "it worked".
  */
  {
    id: 'worktree-merge-refused',
    group: 'Pending Core changes',
    title: 'A branch that will not go in',
    blurb:
      'The conflicted branch, opened. There is no merge control and there is no disabled one either — what is here instead is the files it clashes in and the sentence that says whose job the fix is. varnick builds no conflict resolver: the agent merges `main` down into its own worktree, where it may write and where it knows what it meant.',
    question: 'Does this teach the loop, rather than inviting you to resolve someone else’s branch?',
    covers: ['worktreeMerge.unmerged'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-merge-refused', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
    },
    opensWorktree: conflictedWorktree,
    diffOutcome: 'loads',
  },
  {
    id: 'worktree-merging',
    group: 'Pending Core changes',
    title: 'Merging',
    blurb:
      'The squash, the commit, the check that it carried, and the cleanup — one wait, because from the developer’s side they are one act. Nothing has been deleted yet at any moment this card represents: every refusal happens before anything is written.',
    question: 'Is it clear that this is one operation rather than a button that has stuck?',
    covers: ['worktreeMerge.merging'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-merging', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
      enterWorktreeMerge: 'merging',
      merging: openedWorktree,
    },
  },
  {
    id: 'worktree-merged',
    group: 'Pending Core changes',
    title: 'It landed, and you are running old code',
    blurb:
      'One commit on the live branch, the worktree gone, the branch gone. The sentence that matters is the second one: until a restart, this window is running the build from before the change it just accepted — and an agent reasoning about a fix it believes is live is worse off than one that knows it is not.',
    question: 'Could you read this and still think the change is running?',
    covers: ['worktreeMerge.merged'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-merged', messages: seedMessages },
      enterReview: 'empty',
      enterWorktreeMerge: 'merged',
      mergeReport: {
        branch: 'ticket/48-launch-preview',
        commit: 'a1b2c3d',
        squashed: 4,
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      },
    },
  },
  {
    id: 'worktree-merged-held',
    group: 'Pending Core changes',
    title: 'It landed; something is standing in the directory',
    blurb:
      'The commit is on the live branch and the worktree is still there, because a process has it as its working directory — a Preview, or the agent that wrote the branch. Removing it anyway is not recoverable: the SDK treats a missing cwd as a terminal error before the agent can report it, ask, or step back. So the processes are named and the choice is the developer’s.',
    question: 'Does this read as a success with something left over, rather than as a failure?',
    covers: ['worktreeMerge.merged'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-merged-held', messages: seedMessages },
      enterReview: 'empty',
      enterWorktreeMerge: 'merged',
      mergeReport: {
        branch: 'ticket/48-launch-preview',
        commit: 'a1b2c3d',
        squashed: 4,
        worktreeRemoved: false,
        branchDeleted: false,
        heldBy: [{ pid: 52236, command: 'varnick' }],
        leftOver:
          'ticket/48-launch-preview landed as a1b2c3d. The worktree at /Users/you/varnick/.claude/worktrees/ticket-48 is still there because varnick (pid 52236) is standing in it — nothing will clear it up on its own, so stop it and run: git worktree remove /Users/you/varnick/.claude/worktrees/ticket-48 && git branch -D ticket/48-launch-preview',
      },
    },
  },
  {
    id: 'worktree-merge-failed',
    group: 'Pending Core changes',
    title: 'The merge was refused',
    blurb:
      'The live tree had uncommitted work in it, so nothing was merged — a merge over it is how a change nobody knew about is lost. The reason names the paths, because "the tree is dirty" is not something a developer can act on and a list of files is.',
    question: 'Is it obvious that the tree is exactly as it was?',
    covers: ['worktreeMerge.mergeFailed'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-merge-failed', messages: seedMessages },
      worktrees: statesWorktrees,
      enterReview: 'listed',
      enterWorktreeMerge: 'mergeFailed',
      // The diff this merge was asked from, so the card carries the retry the
      // ticket asks this state for. Without it the band draws its reason and no
      // way to act on it, which is the defect rather than the state.
      worktreeOpen: statesWorktrees[0]?.path ?? null,
      mergeError:
        'The live tree has uncommitted work in packages/core/src/App.tsx, DESIGN.md. A merge over it is how a change nobody knew about is lost, so varnick will not do one. Commit or set that work aside first.',
    },
  },
  {
    id: 'worktree-restarting',
    group: 'Pending Core changes',
    title: 'Restarting into the merged code',
    blurb:
      'The last frame this window is expected to draw: the host tears down the agent and the runtime and replaces its own image. If this card is ever reached in a real run and stays, the restart did not happen — which is the only outcome this side can observe, and the reason it is a state at all.',
    question: 'Is this the last thing on screen, rather than a spinner that outlives its cause?',
    covers: ['worktreeMerge.restarting'],
    input: {
      ...up,
      sessionInput: { sessionId: 'states-worktree-restarting', messages: seedMessages },
      enterReview: 'empty',
      enterWorktreeMerge: 'restarting',
      mergeReport: {
        branch: 'ticket/48-launch-preview',
        commit: 'a1b2c3d',
        squashed: 4,
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      },
    },
  },
]

/**
 * Paths the coverage banner checks.
 *
 * Every state every machine declares, with nothing waived. Surfaces used to be:
 * nothing rendered one, so there was no component to park in `loading`,
 * `loaded` or `failed`, and the banner said so with ticket 14's number on it.
 * Ticket 14 built the loader, so the waiver is gone rather than reworded —
 * "out of scope" is the kind of waiver that outlives the reason for it and
 * quietly becomes a gap.
 */
export const COVERED_PATHS: readonly StatePath[] = [
  ...HARNESS_STATE_PATHS,
  ...SESSION_STATE_PATHS,
  ...SURFACE_STATE_PATHS.map((p) => `surface.${p}`),
  ...WORKTREE_DIFF_STATE_PATHS.map((p) => `worktreeDiff.${p}`),
]

/** Paths with no scenario. Empty is the only green result. */
/**
 * One predicate, used by the index and the grid.
 *
 * Written once and passed to both, rather than each filtering for itself: two
 * copies is how a nav comes to say "6 of 24" over a grid showing five.
 *
 * Here rather than beside the page it renders, because `drive.ts` asserts it
 * and this module is the one the script can import — `StatesPage.tsx` reaches
 * hooks.ts, which reaches the Surface loader, which calls `import.meta.glob`
 * and exists only under Vite. Same reason surfaces.ts takes its record as an
 * argument.
 */
export function matches(query: string, group: Group | 'all') {
  const q = query.trim().toLowerCase()
  return (scenario: Scenario): boolean => {
    if (group !== 'all' && scenario.group !== group) return false
    if (q.length === 0) return true
    // The state paths are searchable too, and that is the point of the filter:
    // "what does `turn.failed` look like" is the question this page exists for,
    // and it is not answered by a title search.
    return (
      scenario.title.toLowerCase().includes(q) ||
      scenario.id.includes(q) ||
      scenario.covers.some((path) => path.toLowerCase().includes(q))
    )
  }
}

export function uncoveredPaths(scenarios: readonly Scenario[] = SCENARIOS): StatePath[] {
  const seen = new Set(scenarios.flatMap((s) => s.covers))
  return COVERED_PATHS.filter((p) => !seen.has(p))
}

/** Paths a scenario claims that no machine declares — the other direction. */
export function unknownPaths(scenarios: readonly Scenario[] = SCENARIOS): StatePath[] {
  const known = new Set<string>(COVERED_PATHS)
  return [...new Set(scenarios.flatMap((s) => s.covers))].filter((p) => !known.has(p))
}
