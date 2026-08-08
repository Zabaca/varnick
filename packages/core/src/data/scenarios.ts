import type { HarnessInput } from '../machines/harness.ts'
import { HARNESS_STATE_PATHS } from '../machines/harness.ts'
import { SESSION_STATE_PATHS } from '../machines/session.ts'
import { MODELS } from '../domain.ts'
import { seedPolicy, seedMessages } from './seed.ts'

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
}

/** Harness held up, ready for a Session. */
const up = {
  policy: seedPolicy,
  enterCredential: 'present',
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
    blurb: 'Nothing has been read or checked yet. The first frame after launch.',
    question: 'Does an empty session look like a product, or like a form waiting to be filled in?',
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
      enterSubscription: 'reading',
    },
  },
  {
    id: 'checking-sandbox',
    title: 'Establishing the sandbox',
    blurb: 'Credential in hand, srt not yet established. The agent has not started.',
    question: 'Does the surface stay quiet while a step that usually succeeds is running?',
    covers: ['credential.present', 'sandbox.checking'],
    input: { policy: seedPolicy, enterCredential: 'present', enterSandbox: 'checking' },
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
    title: 'No credential',
    blurb: 'The read failed and said why. The sandbox is fine.',
    question: 'Does the recovery affordance point at the thing that actually failed?',
    covers: ['credential.absent'],
    input: {
      policy: seedPolicy,
      enterSandbox: 'available',
      credentialError: 'no credential found',
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
    id: 'sending',
    title: 'Sending',
    blurb: 'The prompt is posted and the agent has not produced a token yet.',
    question: 'Is the gap between sending and the first token accounted for?',
    covers: ['turn.sending'],
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
    covers: ['turn.streaming'],
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
 * Surfaces are absent for one reason only: nothing renders a Surface yet, so
 * there is no component to park in `loading`, `loaded` or `failed`. This is a
 * waiver with an expiry, not a decision that those states need no cards —
 * ticket 14 brings a minimal execution path into v1, and moving these paths in
 * here is one of its acceptance criteria.
 *
 * The distinction matters. "Out of scope" is the kind of waiver that survives
 * the reason for it and quietly becomes a gap.
 */
export const COVERED_PATHS: readonly StatePath[] = [
  ...HARNESS_STATE_PATHS,
  ...SESSION_STATE_PATHS,
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
