import type { HarnessInput } from '../machines/harness.ts'
import { HARNESS_STATE_PATHS } from '../machines/harness.ts'
import { SESSION_STATE_PATHS } from '../machines/session.ts'
import { SURFACE_STATE_PATHS } from '../machines/surface.ts'
import { MODELS, type SurfaceDescriptor } from '../domain.ts'
import type { SurfaceOutcome } from '../actors/frozen.ts'
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

export interface Scenario {
  /** Stable id; also the anchor a ticket can link to. */
  readonly id: string
  readonly title: string
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
}

/** Harness held up, ready for a Session. */
const up = {
  policy: seedPolicy,
  enterCredential: 'present',
  // A credential that is present always turned out to be something. A card
  // parked in `credential.present` with no kind is a context the live machine
  // cannot reach — and a subscription is the one with plan usage behind it,
  // which is what the strip in these scenarios is showing.
  credentialKind: 'subscription' as const,
  enterSandbox: 'available',
  enterAgent: 'running',
  enterSubscription: 'read',
  subscription: { fiveHourPct: 68, weeklyPct: 41, source: 'seeded' as const },
} satisfies HarnessInput

export const SCENARIOS: readonly Scenario[] = [
  // -- Start-up ------------------------------------------------------------
  {
    id: 'cold-start',
    title: 'Cold start',
    blurb:
      'Nothing has been read or checked yet. The literal first frame after launch, before even the sandbox has been asked about.',
    question: 'Is the first thing asked for the first thing that is needed, and nothing else?',
    covers: ['credential.absent', 'sandbox.unchecked', 'agent.down', 'subscription.unread'],
    input: { policy: seedPolicy },
  },
  {
    id: 'reading-credential',
    title: 'Reading the credential',
    blurb: 'Tauri is asking the keychain. Nothing is claimed until it answers.',
    question: 'Is the wait legible without asserting an outcome?',
    covers: ['credential.reading', 'subscription.reading'],
    input: {
      policy: seedPolicy,
      enterCredential: 'reading',
      // A plan-usage read is in flight, so the kind that let it start is still
      // in hand — this is a credential being read *again*, which is the only way
      // both regions are busy at once. Without it the card would be parked in a
      // context the live machine cannot reach, since `subscription.reading` is
      // now only entered under a subscription.
      credentialKind: 'subscription',
      enterSubscription: 'reading',
    },
  },
  {
    id: 'checking-sandbox',
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
    title: 'Credential rejected',
    blurb: 'The stored credential exists and the API refused it.',
    question: 'Is this distinguishable from having no credential at all?',
    covers: ['credential.rejected'],
    input: { policy: seedPolicy, enterCredential: 'rejected', enterSandbox: 'available' },
  },
  {
    id: 'no-credential',
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
    id: 'start-refused',
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
    title: 'Running, nothing said',
    blurb: 'The agent is up and the transcript is empty. The true first screen.',
    question: 'Does an empty transcript tell you what to type?',
    covers: ['agent.running', 'subscription.read', 'turn.idle', 'persistence.saved', 'composer.typing'],
    input: { ...up, sessionInput: { sessionId: 'states-idle' } },
  },
  {
    id: 'api-key-no-plan',
    title: 'Running on an API key',
    blurb:
      'The same running session, authenticated by an API key instead of a subscription. There is no plan, so there are no rolling windows and the plan-usage strip is not part of the window — absent, not empty. The `subscription` region stays `unread` and its actor never runs.',
    question: 'Does the window read as complete, or as one with a row missing from the top?',
    // No new state, which is the point: this is `subscription.unread` alongside
    // a running agent, and the only difference from the card above is a fact in
    // context. A fourth state meaning "not applicable" would have made this a
    // card about the machine rather than about what a developer sees.
    covers: ['subscription.unread'],
    input: {
      ...up,
      credentialKind: 'api-key',
      enterSubscription: 'unread',
      subscription: null,
      sessionInput: { sessionId: 'states-api-key' },
    },
  },
  {
    id: 'resumed',
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
    id: 'compacting',
    title: 'Compacting',
    blurb: 'The conversation is being summarised to free context. Nothing else is blocked.',
    question: 'Does compaction read as a maintenance step rather than as data loss?',
    covers: ['turn.compacting'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-compacting',
        messages: seedMessages,
        enterTurn: 'compacting',
        tokensUsed: 812_000,
      },
    },
  },
  {
    id: 'compact-failed',
    title: 'Compaction failed',
    blurb: 'Summarising threw. The conversation is explicitly unchanged.',
    question: 'Is "nothing happened" stated, or left to be inferred?',
    covers: ['turn.idle'],
    input: {
      ...up,
      sessionInput: {
        sessionId: 'states-compact-failed',
        messages: seedMessages,
        compactError: 'could not summarise the conversation',
        tokensUsed: 812_000,
      },
    },
  },
  {
    id: 'command-menu',
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
        commandNames: MODELS.map((m) => `/model ${m.label}`),
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
]

/** Paths with no scenario. Empty is the only green result. */
export function uncoveredPaths(scenarios: readonly Scenario[] = SCENARIOS): StatePath[] {
  const seen = new Set(scenarios.flatMap((s) => s.covers))
  return COVERED_PATHS.filter((p) => !seen.has(p))
}

/** Paths a scenario claims that no machine declares — the other direction. */
export function unknownPaths(scenarios: readonly Scenario[] = SCENARIOS): StatePath[] {
  const known = new Set<string>(COVERED_PATHS)
  return [...new Set(scenarios.flatMap((s) => s.covers))].filter((p) => !known.has(p))
}
