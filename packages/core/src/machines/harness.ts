import { setup, assign, fromPromise, stopChild, type ActorRefFrom } from 'xstate'
// A type and nothing else. `turn` is one of the three Harness subpaths that
// reach no Node built-in, which is what makes it importable from Core at all —
// see the lint rule in eslint.config.js.
import type { RuntimeReport, SlashCommand } from '@varnick/harness/turn'
import { canStartAgent, refusalFor, regionOf, LIVE_SESSION_ID } from '../domain.ts'
import type {
  CredentialKind,
  CredentialReading,
  PendingWorktree,
  SandboxPolicy,
  StartRefusal,
  SurfaceDescriptor,
} from '../domain.ts'
import { surfaceMachine } from './surface.ts'
import { worktreeDiffMachine } from './worktree-diff.ts'
import { sessionMachine, type SessionInput } from './session.ts'

/**
 * The Harness: parent machine, owning the facts that decide whether an agent
 * may run at all, plus one child per Surface and one Session.
 *
 * Three parallel regions because they are genuinely independent: a credential
 * can be rejected while the sandbox is fine, the sandbox can be unavailable
 * while a credential is present, and the agent process can crash without
 * changing either. One status enum here would make every combination a new
 * enum member and every transition a lie.
 */

export const HARNESS_STATE_PATHS = [
  'credential.absent',
  'credential.minting',
  'credential.storing',
  'credential.reading',
  'credential.present',
  'credential.rejected',
  'sandbox.unchecked',
  'sandbox.checking',
  'sandbox.available',
  'sandbox.unavailable',
  'agent.down',
  'agent.startRefused',
  'agent.starting',
  'agent.running',
  'agent.crashed',
  'review.listing',
  'review.listed',
  'review.empty',
  'review.listFailed',
] as const
export type HarnessStatePath = (typeof HARNESS_STATE_PATHS)[number]

export type CredentialState = 'absent' | 'minting' | 'storing' | 'reading' | 'present' | 'rejected'
export type SandboxState = 'unchecked' | 'checking' | 'available' | 'unavailable'
export type ReviewState = 'listing' | 'listed' | 'empty' | 'listFailed'

export interface HarnessContext {
  policy: SandboxPolicy
  /**
   * Each region publishes its own state here on entry.
   *
   * A guard in XState v5 receives only `{ context, event }` — it cannot read
   * a sibling region's value. Rather than reaching sideways, each region states
   * its fact in context and the start guard reads that. The UI reads the same
   * two fields, so the affordance and the rule cannot drift.
   */
  credentialState: CredentialState
  /**
   * What the credential turned out to be, once one has been read.
   *
   * `null` until a read succeeds, and back to `null` when one fails: a kind
   * left standing over a credential that is gone would be a decision made about
   * something that is no longer there. It is a fact on `credential.present`
   * rather than a state of its own — ADR-0011 adds two facts to a reading, and
   * a state per kind would double the region for a distinction no transition
   * depends on.
   *
   * Nothing in this machine now transitions on it at all: it decides which
   * variable the host spawns the agent with, which happens host-side. It once
   * also gated a `subscription` region, and ticket 31 cut that.
   *
   * Nothing here is or could be the value; see packages/harness/src/credentials.ts.
   */
  credentialKind: CredentialKind | null
  /**
   * Which keychain item a store is writing, while one is being written.
   *
   * The developer's choice on the setup screen, held here because the view is a
   * pure function of `(snapshot, send)` — a radio button whose selection lived
   * in a component would be a piece of this surface the states page could not
   * park in (ADR-0001). It is not a preference and nothing consults it later:
   * which credential varnick *uses* is still resolved by the host from what it
   * finds, on the read that follows every store (ADR-0011).
   *
   * Not the value, and there is deliberately no field for one. The pasted
   * credential travels as the store actor's *input*, which is not context, and
   * is gone the moment the actor settles.
   */
  storingKind: CredentialKind
  /**
   * Where to sign in, while a mint is waiting for someone to.
   *
   * The flow tries to open a browser and prints this as a fallback when it
   * cannot, and the fallback is what makes the whole feature survive contact
   * with a machine whose default browser is not set. Held in context because the
   * view is a pure function of `(snapshot, send)` — a URL living in a component
   * would be a piece of the minting screen the states page could not park in.
   *
   * `null` outside a mint, and cleared on the way in rather than on the way out,
   * so a second attempt never shows the first one's link.
   *
   * Not a credential and structurally cannot be one: it is an OAuth request the
   * developer's browser is about to make, parsed out of the render by a
   * function that requires a scheme and an authorize endpoint. See
   * `the_url_is_never_the_token` in src-tauri/src/mint.rs.
   */
  mintUrl: string | null
  sandboxState: SandboxState
  refusal: StartRefusal | null
  sandboxError: string | null
  agentError: string | null
  credentialError: string | null
  surfaces: ActorRefFrom<typeof surfaceMachine>[]
  /**
   * What the running agent says it is, once it has said anything.
   *
   * `null` before the first Turn of a Session and `null` again once the agent is
   * down, and the second half is the load-bearing one: a report is a description
   * of a process, so leaving the last one standing over a dead agent would be
   * the panel confidently describing something that is not there. That is the
   * exact failure the report exists to catch, one level up.
   *
   * A fact rather than a state — nothing transitions on it, and `agent.running`
   * already says whether there is a process. Names and counts only; see
   * `RuntimeReport`, which has no field a credential could arrive in.
   */
  runtime: RuntimeReport | null
  /**
   * Every command the running agent will accept, as it last said.
   *
   * Empty until a Turn has run, and empty again when the agent goes — the same
   * lifetime as the report above and for the same reason: it describes a
   * process, and offering a skill from an agent that is no longer there is the
   * menu claiming something exists when it does not.
   *
   * The window's own commands are not in here. They belong to machines that are
   * running whether or not an agent is, and they are composed in the view where
   * their `can()` gating lives.
   */
  commands: readonly SlashCommand[]
  session: ActorRefFrom<typeof sessionMachine> | null
  /**
   * What the Session is spawned with.
   *
   * The states page parks a Session in a named turn state, and the only way in
   * is through the parent that owns the spawn. Held in context rather than read
   * off the event so the entry point works on a machine created cold.
   *
   * A relaunch comes in through the same door with the transcript read off
   * disk, which is why resume needed no new state: a Session restored from the
   * mirror is `turn.idle` with messages, and that is a card the states page
   * already renders. See docs/adr/0009-resume-reads-the-mirror.md.
   */
  readonly sessionInput: SessionInput
  /**
   * The Worktrees holding Core changes nobody has merged, as git last described
   * them.
   *
   * Empty in `review.empty` — which is a state and not this field being short.
   *
   * **It survives a listing that failed, and that is a change.** It used to be
   * cleared, on the rule `credentialKind` follows on a failed read. Since the
   * end of every Turn re-lists, most failures are now failures to *refresh*,
   * and a git that would not answer this time has said nothing about what it
   * listed a minute ago. Whether these entries are current is what
   * `review.listFailed` says; whether there are any is this field, and holding
   * both is what lets the surface tell "these stood, and nobody could check"
   * from "nobody can tell".
   *
   * **Summaries, and no hunks.** See `PendingWorktree`: the decision is that a
   * list which read every diff of every branch to draw a row would spend the
   * whole of a large branch before showing anything, and a list is what you
   * read to decide which branch to open.
   */
  worktrees: readonly PendingWorktree[]
  /** Why the last listing failed, for as long as one has. */
  worktreeError: string | null
  /**
   * The Worktree whose changes somebody is reading, while somebody is.
   *
   * `null` the rest of the time, and at most one: opening a second over the
   * first is refused by a guard rather than by a hidden control, which is what
   * keeps the closing of the first from being something this machine has to
   * remember to do. Closing stops the child and drops the ref together.
   *
   * A child rather than a fifth region, like a Surface and for the same reasons
   * — see machines/worktree-diff.ts. It is deliberately *not* torn down by a
   * re-listing: the list is a fact about a filesystem that changes while varnick
   * runs, and refreshing it must not shut what somebody is reading.
   */
  worktreeDiff: ActorRefFrom<typeof worktreeDiffMachine> | null
  readonly enterCredential: string | null
  readonly enterSandbox: string | null
  readonly enterAgent: string | null
  readonly enterReview: string | null
}

export interface HarnessInput {
  policy: SandboxPolicy
  credentialKind?: CredentialKind | null
  storingKind?: CredentialKind
  mintUrl?: string | null
  enterCredential?: string | null
  enterSandbox?: string | null
  enterAgent?: string | null
  enterReview?: string | null
  /** Seeded only by the states page, which parks a card over a listing. */
  worktrees?: readonly PendingWorktree[]
  worktreeError?: string | null
  sessionInput?: SessionInput
  /** Seeded only by the states page, which parks a machine with a report in it. */
  runtime?: RuntimeReport | null
  commands?: readonly SlashCommand[]
  refusal?: StartRefusal | null
  agentError?: string | null
  sandboxError?: string | null
  credentialError?: string | null
}

export type HarnessEvent =
  | { type: 'CHECK_SANDBOX' }
  | { type: 'READ_CREDENTIAL' }
  /**
   * A credential pasted into the window, on its way to the keychain.
   *
   * `kind` names the item to write and nothing else — the host still resolves
   * which credential to use by what it finds (ADR-0011). `value` is the one
   * string in Core that must not survive the interaction: it is read by the
   * store actor's `input` and never assigned into context, so the machine that
   * carried it holds nothing afterwards.
   */
  | { type: 'STORE_CREDENTIAL'; kind: CredentialKind; value: string }
  /**
   * Which of the two the developer is about to paste.
   *
   * A machine event rather than component state because the view is a pure
   * function of `(snapshot, send)` — a selection living in a `useState` would be
   * part of the setup screen the states page could not park in. It changes which
   * item a store would write and nothing else; the host still resolves the kind
   * from what it finds (ADR-0011).
   */
  | { type: 'CHOOSE_CREDENTIAL_KIND'; kind: CredentialKind }
  /**
   * Get a subscription token, rather than being told where to get one.
   *
   * The developer asked; nothing about the command is theirs to decide. It
   * carries no argument for exactly that reason — `claude setup-token` is a
   * constant on the host, and a field here would be a field something could put
   * a different command in. See src-tauri/src/mint.rs.
   */
  | { type: 'MINT_CREDENTIAL' }
  /**
   * The flow published a URL to sign in at.
   *
   * Something the world did, delivered as an event, the same shape as
   * `AGENT_EXIT` and `STREAM_DELTA` — an actor resolves once, and this arrives
   * while the mint is still running. Never a credential: see `mintUrl`.
   */
  | { type: 'MINT_URL'; url: string }
  | { type: 'CREDENTIAL_REJECTED'; detail: string }
  | { type: 'START' }
  | { type: 'STOP' }
  | { type: 'RESTART' }
  | { type: 'AGENT_EXIT'; detail: string }
  /**
   * The runtime described itself.
   *
   * Named for what happened rather than for what it produces, the same
   * convention as `AGENT_EXIT`: the runtime reported, and this machine records
   * it. Accepted in every state of the `agent` region rather than only in
   * `running`, because the report is read off the message stream and a machine
   * that refused it in `starting` would drop the only one a Session sends.
   */
  | { type: 'RUNTIME_REPORTED'; report: RuntimeReport }
  /**
   * The runtime said which commands it accepts.
   *
   * A replacement rather than an addition, which is what the SDK's own
   * `commands_changed` asks of a client: a merge would go on offering a skill
   * that has gone.
   */
  | { type: 'COMMANDS_REPORTED'; commands: readonly SlashCommand[] }
  | { type: 'DISCOVER_SURFACES'; descriptors: SurfaceDescriptor[] }
  | { type: 'UNLOAD_SURFACE'; id: string }
  /**
   * Ask git again which Worktrees hold unmerged Core changes.
   *
   * Named for the act rather than for the state it produces, like
   * `CHECK_SANDBOX` beside it. It carries nothing: the listing is of the clone
   * varnick is running in, which the host resolved once at launch (ADR-0012),
   * and a field here would be a field something could name another tree in.
   *
   * Accepted in the three resting states and not while a listing is in flight,
   * so a second ask cannot restart the actor answering the first.
   */
  | { type: 'LIST_WORKTREES' }
  /**
   * A developer opened one of the Worktrees on the list, to read what changed.
   *
   * `path` names **which of the entries the machine is already holding**, and
   * the guard checks it against them: this window says which of git's own
   * answers it wants, and does not get to say what the answer should be about.
   * The host checks again against git, and neither check is the other's excuse —
   * this one is what stops the surface offering to open something that was never
   * on it. See packages/harness/src/worktrees.ts.
   *
   * Accepted only in `review.listed`, because that is the only state with rows
   * in it, and only while nothing else is open.
   */
  | { type: 'OPEN_WORKTREE'; path: string }
  /**
   * Done reading. Named for what the developer did, like every other event here.
   *
   * At the root rather than in the `review` region, because what it closes is
   * not part of that region's state: the list can be re-read, fail, and empty
   * while a diff stays open, and a close that lived inside `listed` would be
   * refused in exactly those moments.
   */
  | { type: 'CLOSE_WORKTREE' }

/**
 * Real-service contracts:
 *   checkSandbox   input  { policy }
 *                  output { ok: true }
 *                  error  thrown Error — srt could not be established. The run
 *                         must fail here rather than proceeding unconfined.
 *   readCredential input  {}
 *                  output { source: 'keychain' | 'env',
 *                           kind:   'api-key' | 'subscription' }
 *                         Two facts about the reading and no third. The value
 *                         is not representable on this side — ADR-0008, and
 *                         packages/harness/src/credentials.ts.
 *                  error  thrown Error — no credential available
 *   spawnAgent     input  { policy }
 *                  output { pid: number }
 *                  error  thrown Error — process failed to start
 */
/**
 * The START transition, declared once and used by both `down` and
 * `startRefused` so the two cannot drift.
 *
 * The second entry is an unguarded fallback, so a refusal explains itself
 * instead of swallowing the click. The consequence: `can({type:'START'})` is
 * permanently true, and nothing may bind a `disabled` attribute to it —
 * readiness comes from `canStartAgent()`.
 */
const startTransition = [
  { target: 'starting', guard: 'canStart' },
  { target: 'startRefused', actions: 'recordRefusal' },
] as const

/**
 * Opening a row, declared once and used by both states that can have rows.
 *
 * Hoisted for the reason `startTransition` above it is: two copies of a
 * transition are two things to keep the same, and the drift is invisible —
 * each state goes on working and the one that fell behind simply stops
 * offering something.
 *
 * There are two such states now. `review.listed` is the obvious one. The other
 * is `review.listFailed` *holding a list a refresh could not replace*: those
 * rows are on screen, so they are openable, and the guard is what makes that
 * safe rather than a second rule — `openable` requires the path to be one this
 * machine is already holding, and a first listing that failed holds none.
 *
 * Internal: reading a branch is not a state of the listing, and moving the
 * region would say the list had stopped being what it is because somebody
 * looked at one of its rows.
 */
const openWorktreeTransition = { guard: 'openable', actions: 'openWorktreeDiff' } as const

export const harnessMachine = setup({
  types: {
    context: {} as HarnessContext,
    events: {} as HarnessEvent,
    input: {} as HarnessInput,
  },
  actors: {
    surface: surfaceMachine,
    worktreeDiff: worktreeDiffMachine,
    session: sessionMachine,
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => ({
      ok: true,
    })),
    readCredential: fromPromise<CredentialReading, Record<string, never>>(
      async () => ({ source: 'keychain' as const, kind: 'api-key' as const }),
    ),
    /*
      Real-service contract for storeCredential:
        input  { kind, value } — which keychain item to write, and what a
               developer pasted into the window. The one actor input in this
               system that is secret, and the reason it is an input rather than
               context: an input is handed to the actor and gone, and context is
               what the surface renders and the mirror is built from.
        output nothing. A store has nothing to report, so there is no shape on
               the success path a value could come back in.
        error  thrown Error — the keychain refused, or there was nothing usable
               to write. Authored from a tag; nothing `security` said is in it.
               See packages/harness/src/credentials.ts.
    */
    storeCredential: fromPromise<void, { kind: CredentialKind; value: string }>(
      async () => {},
    ),
    /*
      Real-service contract for mintSubscriptionToken:
        input  {} — there is nothing to decide. The command is a constant on the
               host, so there is no field here something could put a different
               one in.
        output nothing. The token is minted, read off a pty and written to the
               keychain inside the host process, so there is no shape on the
               success path a credential could come back in — and unlike the
               store, this side never holds one at all.
        error  thrown Error — the sign-in was declined, the account has no
               subscription, the token could not be read back whole, the
               keychain refused it. Authored from a tag; nothing the command
               printed is in it. See packages/harness/src/credentials.ts.

      What it says while it runs — the URL to sign in at — arrives as
      `MINT_URL` rather than as a result, because an actor resolves once and
      that happens well before this one does.
    */
    mintSubscriptionToken: fromPromise<void, Record<string, never>>(async () => {}),
    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => ({
      pid: 0,
    })),
    /*
      Real-service contract for listWorktrees:
        input  {} — and it is empty on purpose. The renderer asks what is
               pending; it does not get to say what the answer should be about.
               A worktree name here would be agent-reachable input to a
               host-side git call, which is the shape ADR-0014 is careful about
               for `launch_preview`.
        output { worktrees } — one entry per Worktree holding commits the live
               tree does not: branch, path, how far ahead, which paths changed,
               and whether any of them is Fence. Summaries; the hunks are
               fetched for the one worktree a developer opens.
        error  thrown Error — git could not be run or would not answer. Distinct
               from an empty list, which is a listing that worked and found
               nothing: `review.listFailed` against `review.empty`.

      Produced host-side by running git, and never by the agent — this is the
      mechanism that shows what the agent changed. See
      packages/harness/src/worktrees.ts.
    */
    listWorktrees: fromPromise<
      { worktrees: readonly PendingWorktree[] },
      Record<string, never>
    >(async () => ({ worktrees: [] })),
  },
  guards: {
    canStart: ({ context }) =>
      canStartAgent({ credential: context.credentialState, sandbox: context.sandboxState }),
    /*
      Something was actually pasted.

      The same shape as the Session's send guard, and for the same reason: the
      control comes from `can()`, so an empty field has to make the machine say
      no rather than make the surface remember to. A store of nothing would
      otherwise be a round trip to the host to be told what the field already
      knew, and it would create a keychain item that reads back as empty.
    */
    credentialPasted: ({ event }) =>
      event.type === 'STORE_CREDENTIAL' && event.value.trim().length > 0,
    /*
      Nothing is waiting to be merged.

      A guard rather than a field the surface reads, because `review.empty` is a
      state: nothing pending and a listing that failed are different problems
      with different copy, and a view branching on `worktrees.length === 0`
      would have to invent that difference back — which is the branch that
      eventually says "nothing is waiting" over a git that never answered.
    */
    nothingPending: ({ event }) =>
      'output' in event &&
      (event.output as { worktrees: readonly PendingWorktree[] }).worktrees.length === 0,
    /*
      A Worktree this machine is holding, and nothing already open.

      Two questions in one guard because they answer the same control: the row's
      `open` appears when the machine would accept opening *that* row, which is
      false for a path nobody listed and false for every row while one is open.
      Both are the affordance rather than a rule the view has to remember.
    */
    openable: ({ context, event }) =>
      event.type === 'OPEN_WORKTREE' &&
      context.worktreeDiff === null &&
      context.worktrees.some((entry) => entry.path === event.path),
    somethingOpen: ({ context }) => context.worktreeDiff !== null,
  },
  actions: {
    recordRefusal: assign({
      refusal: ({ context }) =>
        refusalFor({ credential: context.credentialState, sandbox: context.sandboxState }),
    }),
    /*
      Spawn the child that reads one Worktree's changes.

      The entry is taken from this machine's own list rather than from the
      event: the guard has already established it is there, and reading it back
      out of git's answer is what keeps the branch and the count above the hunks
      the same facts the row showed.

      The `event.type` check is the type system asking a question the guard has
      already answered. It returns the ref unchanged rather than throwing,
      because a named action is reachable from anywhere a name can be written
      and an action that can only be used in one place should say so quietly.
    */
    openWorktreeDiff: assign({
      worktreeDiff: ({ context, event, spawn }) => {
        if (event.type !== 'OPEN_WORKTREE') return context.worktreeDiff
        const worktree = context.worktrees.find((entry) => entry.path === event.path)
        if (worktree === undefined) return context.worktreeDiff
        return spawn('worktreeDiff', {
          id: 'worktree-diff',
          syncSnapshot: true,
          input: { worktree },
        })
      },
    }),
  },
  delays: {
    refusalTimeout: 6000,
  },
}).createMachine({
  id: 'harness',
  type: 'parallel',
  context: ({ input }) => ({
    policy: input.policy,
    credentialState: (input.enterCredential as CredentialState | undefined) ?? 'absent',
    credentialKind: input.credentialKind ?? null,
    // A subscription by default, for the same reason it wins in `resolve()`: a
    // developer already paying for a plan should not be shown a bill-per-request
    // key as the obvious choice.
    storingKind: input.storingKind ?? 'subscription',
    mintUrl: input.mintUrl ?? null,
    sandboxState: (input.enterSandbox as SandboxState | undefined) ?? 'unchecked',
    refusal: input.refusal ?? null,
    sandboxError: input.sandboxError ?? null,
    agentError: input.agentError ?? null,
    credentialError: input.credentialError ?? null,
    surfaces: [],
    runtime: input.runtime ?? null,
    commands: input.commands ?? [],
    session: null,
    sessionInput: input.sessionInput ?? { sessionId: LIVE_SESSION_ID },
    worktrees: input.worktrees ?? [],
    worktreeError: input.worktreeError ?? null,
    worktreeDiff: null,
    enterCredential: input.enterCredential ?? null,
    enterSandbox: input.enterSandbox ?? null,
    enterAgent: input.enterAgent ?? null,
    enterReview: input.enterReview ?? null,
  }),
  on: {
    // Surfaces are discovered, never registered — adding one must not require
    // editing Core, which the agent cannot write anyway (ADR-0002).
    DISCOVER_SURFACES: {
      // Idempotent by construction. Discovery re-runs whenever the Surfaces
      // directory changes, so appending unconditionally would spawn a second
      // actor for a Surface that is already loaded — and both would answer to
      // the same id. Caught by driving the bare page: React reported duplicate
      // keys, which was the symptom of two live actors per Surface.
      actions: assign({
        surfaces: ({ context, event, spawn }) => {
          const known = new Set(context.surfaces.map((ref) => ref.getSnapshot().context.descriptor.id))
          const added = event.descriptors
            .filter((descriptor) => !known.has(descriptor.id))
            .map((descriptor) =>
              spawn('surface', {
                id: `surface-${descriptor.id}`,
                syncSnapshot: true,
                input: { descriptor },
              }),
            )
          return added.length === 0 ? context.surfaces : [...context.surfaces, ...added]
        },
      }),
    },
    UNLOAD_SURFACE: {
      actions: assign({
        surfaces: ({ context, event }) =>
          context.surfaces.filter((ref) => ref.getSnapshot().context.descriptor.id !== event.id),
      }),
    },
    /*
      At the root rather than inside `agent.running`, and that is the whole
      decision. The report is read off the Session's message stream by the
      runtime, replayed at the start of each Turn, and it can arrive at moments
      the `agent` region has no opinion about. A transition scoped to one state
      would drop it whenever it was late, and a dropped report is indistinguish-
      able on screen from an agent that reported nothing — which is the one
      reading this panel must never produce.
    */
    RUNTIME_REPORTED: {
      actions: assign({ runtime: ({ event }) => event.report }),
    },
    // At the root for the same reason, and it is the same fact one level along:
    // the list is read off the message stream and replayed at the start of each
    // Turn, so it can arrive when the `agent` region has no opinion about it.
    COMMANDS_REPORTED: {
      actions: assign({ commands: ({ event }) => event.commands }),
    },
    /*
      Done reading a diff, wherever the listing has got to since it was opened.

      At the root rather than in `review`, because the two are not the same
      subject: the list can be re-read, fail and empty while somebody reads a
      branch, and a close scoped to `listed` would be refused in exactly those
      moments — a view somebody could not get out of.

      The child is stopped and the ref dropped in one action. Dropping alone
      would leave an actor running with nothing pointing at it, which is the
      leak `UNLOAD_SURFACE` avoids by never sending the child's own event.
    */
    CLOSE_WORKTREE: {
      guard: 'somethingOpen',
      actions: [stopChild(({ context }) => context.worktreeDiff!), assign({ worktreeDiff: null })],
    },
  },
  states: {
    credential: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'present', guard: ({ context }) => context.enterCredential === 'present' },
            { target: 'rejected', guard: ({ context }) => context.enterCredential === 'rejected' },
            { target: 'reading', guard: ({ context }) => context.enterCredential === 'reading' },
            { target: 'storing', guard: ({ context }) => context.enterCredential === 'storing' },
            { target: 'minting', guard: ({ context }) => context.enterCredential === 'minting' },
            { target: 'absent' },
          ],
        },
        absent: {
          entry: assign({ credentialState: 'absent' as const }),
          on: {
            READ_CREDENTIAL: 'reading',
            // The way out of `absent` that is not a terminal. Only here: a paste
            // over a credential that is present would replace a working one by
            // accident, and one during a read would race the read it invalidates.
            STORE_CREDENTIAL: { target: 'storing', guard: 'credentialPasted' },
            // The other way out, and the one that needs nothing pasted. Offered
            // in the same state as the paste and for the same reason: a mint
            // over a credential that is present would replace a working one,
            // and this one takes minutes and opens a browser while it does it.
            MINT_CREDENTIAL: 'minting',
            // Accepted only where a store is, so the two controls appear and
            // disappear together rather than leaving a choice with nothing to
            // choose for.
            CHOOSE_CREDENTIAL_KIND: {
              actions: assign({ storingKind: ({ event }) => event.kind }),
            },
          },
        },
        /*
          The sign-in, while it is happening.

          A state of its own because it is a long operation that can fail, and
          because there is something to say for the whole of it: the URL to sign
          in at, which is what a developer whose browser did not open needs and
          the only thing they need. `MINT_URL` is accepted here and nowhere
          else, so a late one from an attempt that has already ended cannot put
          a stale link on a screen that has moved on.

          What it is *not* is a place a credential passes through. The token is
          minted, read and stored inside the host process; this side learns
          whether it worked. That makes this state stricter than `storing`,
          which does at least hand a value on — see
          packages/harness/src/credentials.ts.

          A success re-reads, exactly as a store does, and for the same reason:
          one code path establishes the credential however it got there, and the
          host decides what it is holding by resolving rather than by being
          told (ADR-0011).
        */
        minting: {
          entry: assign({ credentialState: 'minting' as const, credentialError: null }),
          /*
            Cleared on the way out, and only there.

            Out is enough: every way of leaving this state goes through it, so a
            mint always starts with nothing to show and a second attempt can
            never display the first one's link — which would send a developer to
            an authorization that finishes into a process that is gone.

            And in would be wrong. The states page parks a card here through
            `enterCredential`, with a URL supplied as input, and an entry action
            would wipe it before the card rendered — leaving a scenario about
            the fallback that could not show the fallback.
          */
          exit: assign({ mintUrl: null }),
          on: {
            MINT_URL: { actions: assign({ mintUrl: ({ event }) => event.url }) },
          },
          invoke: {
            src: 'mintSubscriptionToken',
            input: () => ({}) as Record<string, never>,
            onDone: 'reading',
            // Back where it started, saying why — the same shape a failed read
            // and a failed store take, so the surface has one field to render
            // whichever of the three went wrong. Nothing of the token is in the
            // message: it is authored from a tag in
            // packages/harness/src/credentials.ts.
            onError: {
              target: 'absent',
              actions: assign({
                credentialError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
                credentialKind: null,
              }),
            },
          },
        },
        /*
          The paste, on its way to the keychain.

          A state rather than a fire-and-forget, because writing to a keychain
          can fail, can prompt, and can take long enough to need a screen that
          says what is happening. What it is *not* is a place a credential is
          kept: the value is the actor's input and the machine holds no field for
          one, so this state exists for as long as the write takes and carries
          nothing away from it.

          A success re-reads rather than declaring the credential present.
          That is one code path establishing the credential whether it was stored
          a minute ago or a year ago — and a write that somehow produced an
          unreadable item fails here, in front of the developer who just made it,
          rather than at the next launch.
        */
        storing: {
          entry: assign({
            credentialState: 'storing' as const,
            credentialError: null,
            storingKind: ({ context, event }) =>
              event.type === 'STORE_CREDENTIAL' ? event.kind : context.storingKind,
          }),
          invoke: {
            src: 'storeCredential',
            // Read straight off the event and handed on. The states page enters
            // this state without one, through `enterCredential`, and its actors
            // never settle — so the empty value below is a card holding still,
            // never a store of nothing. The guard on the transition above is
            // what makes that true of every other way in.
            input: ({ context, event }) => ({
              kind: event.type === 'STORE_CREDENTIAL' ? event.kind : context.storingKind,
              value: event.type === 'STORE_CREDENTIAL' ? event.value : '',
            }),
            onDone: 'reading',
            // Back where it started, saying why — the same shape a failed read
            // takes, so the surface has one field to render whichever of the two
            // went wrong. Nothing of the value is in the message: it is authored
            // from a tag in packages/harness/src/credentials.ts.
            onError: {
              target: 'absent',
              actions: assign({
                credentialError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
                credentialKind: null,
              }),
            },
          },
        },
        reading: {
          entry: assign({ credentialState: 'reading' as const }),
          invoke: {
            src: 'readCredential',
            input: () => ({}) as Record<string, never>,
            onDone: {
              target: 'present',
              actions: assign({
                credentialError: null,
                // The reading's second fact. Taken off the event rather than
                // asked for again, because the kind belongs to the credential
                // that was resolved and a second read could resolve another.
                credentialKind: ({ event }) => event.output.kind,
              }),
            },
            // Keep the reason. Without it a failed read is indistinguishable
            // from never having been attempted, and the view has nothing to say.
            onError: {
              target: 'absent',
              actions: assign({
                credentialError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
                // And forget the kind. A kind left standing over a credential
                // that could not be read is a fact about something that is not
                // there, and everything downstream of it would be decided on it.
                credentialKind: null,
              }),
            },
          },
        },
        present: {
          entry: assign({ credentialState: 'present' as const }),
          on: {
            CREDENTIAL_REJECTED: 'rejected',
            READ_CREDENTIAL: 'reading',
          },
        },
        rejected: {
          entry: assign({ credentialState: 'rejected' as const }),
          on: { READ_CREDENTIAL: 'reading' },
        },
      },
    },

    sandbox: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'available', guard: ({ context }) => context.enterSandbox === 'available' },
            {
              target: 'unavailable',
              guard: ({ context }) => context.enterSandbox === 'unavailable',
            },
            { target: 'checking', guard: ({ context }) => context.enterSandbox === 'checking' },
            { target: 'unchecked' },
          ],
        },
        unchecked: {
          entry: assign({ sandboxState: 'unchecked' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
        checking: {
          entry: assign({ sandboxState: 'checking' as const }),
          invoke: {
            src: 'checkSandbox',
            input: ({ context }) => ({ policy: context.policy }),
            onDone: { target: 'available', actions: assign({ sandboxError: null }) },
            onError: {
              target: 'unavailable',
              actions: assign({
                sandboxError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        available: {
          entry: assign({ sandboxState: 'available' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
        // No fallback to running unconfined: the only way out is an explicit
        // re-check.
        unavailable: {
          entry: assign({ sandboxState: 'unavailable' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
      },
    },

    /*
      A `subscription` region was here — `unread`, `reading`, `read`, fed by a
      `readSubscriptionUsage` actor and gated on the Credential Kind.

      It is gone because it described something that does not happen. The gate
      asked whether the credential was a subscription; the strip needed to know
      whether the credential *reports rolling windows*, and no credential
      varnick can hold does. Measured against a real `claude setup-token`
      credential driving a real Session: `subscription_type: null`,
      `rate_limits_available: false`, `rate_limits: null`. Claude Code's own
      banner calls such a session `Claude API` — it is API authentication, not a
      plan. Four routes to a figure were measured and all four are closed; the
      only credential that answers is the interactive OAuth login, which
      ADR-0011 refuses to hold for reasons that have not changed.

      So the region could only ever sit in `unread`, and a state machine that
      describes something that does not happen is worse than no machine at all.
      See ticket 31 and ADR-0011.
    */
    agent: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'running', guard: ({ context }) => context.enterAgent === 'running' },
            { target: 'starting', guard: ({ context }) => context.enterAgent === 'starting' },
            { target: 'crashed', guard: ({ context }) => context.enterAgent === 'crashed' },
            {
              target: 'startRefused',
              guard: ({ context }) => context.enterAgent === 'startRefused',
            },
            { target: 'down' },
          ],
        },
        down: { on: { START: startTransition } },
        startRefused: {
          after: { refusalTimeout: 'down' },
          exit: assign({ refusal: null }),
          // START must behave here exactly as it does in `down`. An earlier
          // version sent it to `down` as a way to dismiss the refusal, which
          // swallowed a START that had since become valid: the user fixed the
          // cause, clicked again, and nothing happened. Caught by driving the
          // bare page, not by the headless script — which never pressed START
          // twice.
          on: { START: startTransition },
        },
        starting: {
          invoke: {
            src: 'spawnAgent',
            input: ({ context }) => ({ policy: context.policy }),
            onDone: 'running',
            onError: {
              target: 'crashed',
              actions: assign({
                agentError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        running: {
          // The Session is spawned once and outlives every agent restart. That
          // is what makes "the transcript survives" true rather than aspirational.
          entry: assign({
            session: ({ context, spawn, self }) => {
              if (context.session !== null) return context.session
              const session = spawn('session', {
                id: 'session',
                syncSnapshot: true,
                input: context.sessionInput,
              })
              /*
                The end of a Turn, turned into a reason to ask git again.

                **This is the whole of the cross-machine wiring, and both halves
                of it are deliberately ignorant.** The Session emits
                `TURN_ENDED` — a fact about itself, addressed to nobody, naming
                no worktree and no event of this machine's (see
                `SessionEmitted`). This machine hears that a Turn ended and
                decides, on its own, that the answer to "what is waiting to be
                merged" may have changed. Neither reads the other's states,
                context or actors, and either would go on working with the other
                deleted.

                It is here, at the spawn, rather than in whoever owns the
                Harness, for a reason that is practical rather than tasteful:
                every rendering of this system hands its own actors to the
                Session through `.provide()` — hooks.ts, frozen.ts, drive.ts —
                and a join written at any of those call sites is a join the
                other two silently do not have. The ref is the one thing they
                all share. It also puts the trigger where `drive.ts` can reach
                it, which is the difference between behaviour that is proved and
                behaviour that is only wired (ADR-0013).

                Not I/O, and so not the thing ADR-0001 keeps out of machines:
                `.on` is parent-to-child plumbing, the same category as the
                `spawn` on the line above it. Nothing here reads a clock, a
                filesystem or a network.

                `LIST_WORKTREES` and no new event, because there is nothing new
                to say: this is the existing ask, from a second asker. The
                `review` region refuses it while a listing is already in flight,
                which is the behaviour that was already wanted and is now also
                what keeps a Turn ending mid-listing from restarting one.

                The subscription is attached once, with the Session, and both
                outlive every agent restart — see the `??` this replaced.
              */
              session.on('TURN_ENDED', () => self.send({ type: 'LIST_WORKTREES' }))
              return session
            },
            agentError: null,
          }),
          // A report describes a process. Whichever way this state is left the
          // process is gone, so the description goes with it rather than
          // outliving what it describes — the panel says "no agent has reported"
          // instead of confidently describing a runtime that is not there.
          exit: assign({ runtime: null, commands: [] }),
          on: {
            STOP: 'down',
            AGENT_EXIT: {
              target: 'crashed',
              actions: assign({ agentError: ({ event }) => event.detail }),
            },
          },
        },
        crashed: {
          on: { RESTART: 'starting', STOP: 'down' },
        },
      },
    },

    /*
      What is waiting to be merged.

      A fourth region, and independent of the other three in both directions: a
      git that will not answer says nothing about the credential, the sandbox or
      the agent, and an agent that crashed says nothing about which branches are
      finished. The Worktrees exist whether or not varnick is running an agent
      at all — they are a fact about the clone, not about this process — which is
      the same argument ADR-0007 makes for keeping the first three apart.

      **It starts in flight, with no resting state before it, and that is the
      one thing here that differs from its neighbours.** Each of those waits for
      something a person decides: a credential is read when someone asks, the
      sandbox is checked, an agent is started. Nothing decides to list — the
      listing is three read-only git commands, and the user story is that
      *nothing the agent finished waits unnoticed*, which a state meaning "not
      asked yet" would quietly defeat. So there is no `unlisted`: the region is
      `listing` from the moment the machine exists.

      ## And it lists again at the end of every Turn

      Listing once on entry was the same omission one step along. The pending
      list is a fact about a filesystem that changes while varnick runs, and the
      thing changing it is the agent in the window beside it — so a developer who
      has just watched an agent say "committed" was then asked to press *look
      again* before the entry appeared. The end of a Turn is exactly when the
      answer may have changed, it is a signal varnick already has, and it costs
      no poll, no watcher and no timer.

      The Session announces it and this machine sends itself the `LIST_WORKTREES`
      it already had; the wiring is at the spawn in `agent.running`, and the
      reason it is there rather than anywhere else is written out beside it.
      *look again* stays, because an agent is not the only thing that can commit.

      ## Summaries here, hunks in the diff view

      An entry is a branch, a path, a count and a flag — see `PendingWorktree`.
      The hunks are deliberately not carried: a list that read every diff of
      every branch before drawing a row would spend the whole of a large branch
      to show a row that says which branch it is, and this list is what a
      developer reads to *choose* the branch whose diff they want.
      `OPEN_WORKTREE` spawns the child that fetches the contents of the one they
      opened — see machines/worktree-diff.ts, and `worktreeDiff` in context for
      why it is a child rather than a fifth region. Path names are carried
      because they are cheap and because they are what makes the Fence flag
      auditable — a row claiming Fence with no path that is one is a row nobody
      can check.

      ## Nothing here is composed by the agent

      The list is produced host-side by running git — see
      packages/harness/src/worktrees.ts and the route in src-tauri/src/bridge.rs.
      This is the mechanism that shows what the agent changed, and a report the
      agent composes is a report the agent can shade. The actor takes no input
      for the same reason.
    */
    review: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'listed', guard: ({ context }) => context.enterReview === 'listed' },
            { target: 'empty', guard: ({ context }) => context.enterReview === 'empty' },
            { target: 'listFailed', guard: ({ context }) => context.enterReview === 'listFailed' },
            { target: 'listing' },
          ],
        },
        listing: {
          // Cleared on the way in, so a second attempt never shows the first
          // one's reason beside a listing that is still running.
          entry: assign({ worktreeError: null }),
          invoke: {
            src: 'listWorktrees',
            input: () => ({}) as Record<string, never>,
            onDone: [
              // Order matters and the first entry is the ticket's own rule:
              // nothing pending is `empty`, never `listed` with a count of zero.
              {
                target: 'empty',
                guard: 'nothingPending',
                actions: assign({ worktrees: [] }),
              },
              {
                target: 'listed',
                actions: assign({ worktrees: ({ event }) => event.output.worktrees }),
              },
            ],
            /*
              A listing that failed keeps whatever list it already had.

              It used to clear it, on the rule a failed credential read follows
              with the kind it can no longer vouch for — and that rule is right
              for the listing a launch makes, where there is nothing to clear
              anyway. It is wrong for the refresh that now happens at the end of
              every Turn: a git that would not answer *this time* has said
              nothing about the branches it listed a minute ago, and throwing
              them away replaces a good list with an error message.

              **The two cases need no flag to tell them apart.** A first listing
              is entered with `worktrees` empty and leaves it empty; a refresh
              over a good list is the only way this can carry entries at all. So
              `listFailed` with rows means "these stood, and nobody could
              check", and `listFailed` with none means "nobody can tell" — the
              two sentences the surface already had to write, now decided by the
              same field they are about rather than by a second one.

              The reason for the old rule survives in where it moved to: a
              stale answer must not be presented as the current one, which is
              now the surface's job to *say* rather than the machine's to
              prevent by forgetting. See components/worktree-review.tsx.
            */
            onError: {
              target: 'listFailed',
              actions: assign({
                worktreeError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
          /*
            A row on screen can be opened, including while the listing that
            would replace it is still running.

            The rows already survive a refresh — that is what keeping
            `worktrees` on the way through this state is for. Refusing
            `OPEN_WORKTREE` here made them survive as *pictures*: the surface
            draws each row's control from `snapshot.can(...)`, so every
            automatic re-listing blanked the open buttons for as long as the
            actor ran, and the end of every Turn starts one. The rows held
            still and the controls flickered underneath them, once per Turn,
            for as long as varnick was open.

            That is the same motion this region was reshaped to remove — the
            band no longer appears and vanishes per Turn — one level down, and
            it is the argument `listFailed` already makes a line below: a list
            you can see and cannot open is half-discarded.

            `LIST_WORKTREES` is deliberately still refused. Two askers share it
            and neither may restart an actor that is already answering; a
            control that disappears while the thing it asks for is happening is
            honest in a way a dead open button is not.
          */
          on: { OPEN_WORKTREE: openWorktreeTransition },
        },
        /*
          Three resting states, each with the same way out. None is terminal:
          the filesystem changes while varnick runs — an agent finishes a
          branch, a developer merges one — so any of them can be asked again.

          `LIST_WORKTREES` is what a developer sends with *look again*, and it
          is also what this machine sends itself when the Session announces that
          a Turn ended (see `agent.running`). One event, two askers, and the
          same refusal while a listing is in flight: a Turn ending during a
          listing cannot restart the actor answering it.
        */
        listed: {
          on: {
            LIST_WORKTREES: 'listing',
            OPEN_WORKTREE: openWorktreeTransition,
          },
        },
        empty: { on: { LIST_WORKTREES: 'listing' } },
        // Rows here are the ones a refresh could not replace, so they can be
        // opened exactly as they could a moment ago — the guard refuses a path
        // this machine is not holding, which is every path after a first
        // listing fails.
        listFailed: {
          on: {
            LIST_WORKTREES: 'listing',
            OPEN_WORKTREE: openWorktreeTransition,
          },
        },
      },
    },
  },
})
