import { useCallback, useEffect, useRef, useState } from 'react'
import { useHarness, toPath } from '../hooks.ts'
import { ChatSurface } from '../components/chat-surface.tsx'
import { resolveActorMode, type ActorMode } from '../actors/index.ts'
import { restoreSession, type RestoredSession } from '../actors/live.ts'
import { discoverSurfaces, loadedSurface } from '../actors/surface-loader.ts'
import { LIVE_SESSION_ID } from '../domain.ts'
import type { SessionInput } from '../machines/session.ts'

/**
 * The live chat surface.
 *
 * This page owns exactly one thing the states page must not have: start-up. The
 * rendering is `ChatSurface`, unchanged between here and `#/states`, so what is
 * reviewed on a card is what ships.
 *
 * The harness starts itself. Loading a credential, establishing the sandbox and
 * spawning the agent are not user commands — a launch does them, and asking the
 * user to run them was debug wearing a product's clothes.
 *
 * Reading the transcript back is the step before all of those, and it is here
 * rather than in an actor because of where the Session comes from: the Harness
 * holds `sessionInput` in context and spawns the Session from it on entry to
 * `agent.running`, so the transcript has to be in hand before the machine is
 * created. That is start-up, and start-up is this page's job.
 */
export function DesignedPage() {
  const mode = resolveActorMode()
  const resume = useResume(mode)

  if (resume.status === 'reading') {
    return <StartupNote text="Reading the conversation…" />
  }

  /*
    A restore that failed does not fall through to an empty conversation.

    It would look like a first run, and the first save of that empty Session
    would rewrite the mirror — the transcript on disk is not a prefix of a
    transcript that starts from nothing, so the store replaces rather than
    appends. Losing a day's work to a read that failed is precisely what the
    mirror exists to prevent, so nothing starts until the read succeeds.
  */
  if (resume.status === 'failed') {
    return (
      <StartupNote
        text={`Could not read the conversation — ${resume.reason} Nothing has been started, so the transcript on disk is untouched.`}
        bad
        action={{ label: 'try again', run: resume.retry }}
      />
    )
  }

  return <LiveChat mode={mode} sessionInput={resume.input} redacted={resume.redacted} />
}

/**
 * The Harness, once there is a transcript to give it.
 *
 * A separate component because `useHarness` creates the machine on its first
 * render and the input is read once. Gating inside it would either create the
 * machine with an empty conversation and never correct it, or recreate the
 * machine underneath a live Session.
 */
function LiveChat({
  mode,
  sessionInput,
  redacted,
}: {
  mode: ActorMode
  sessionInput: SessionInput | undefined
  redacted: boolean
}) {
  const { snapshot, send } = useHarness(undefined, mode, sessionInput)

  const ctx = snapshot.context
  const agentState = toPath((snapshot.value as Record<string, unknown>).agent)

  /*
    Start-up runs each step at most once.

    An earlier version re-sent READ_CREDENTIAL whenever the credential was
    absent, which is a hot loop the moment a read fails: it lands back in absent
    and the effect fires again. Found by switching to live actors, where every
    read throws. Recovery is a deliberate act, not a retry storm.
  */
  const attempted = useRef({ credential: false, sandbox: false, agent: false })

  useEffect(() => {
    if (ctx.credentialState === 'absent' && !attempted.current.credential) {
      attempted.current.credential = true
      send({ type: 'READ_CREDENTIAL' })
    }
  }, [ctx.credentialState, send])

  useEffect(() => {
    send({ type: 'READ_SUBSCRIPTION' })
  }, [send])

  /*
    Surfaces are discovered at launch, not gated on the agent.

    Deliberately outside the start-up chain above: a Surface is a file that is
    already on disk, and holding it back until a credential is read would mean a
    clone with no key shows an empty window instead of the Workspace someone
    built. `DISCOVER_SURFACES` is idempotent, so re-running it costs nothing.
  */
  useEffect(() => {
    send({ type: 'DISCOVER_SURFACES', descriptors: discoverSurfaces() })
  }, [send])

  useEffect(() => {
    if (
      ctx.credentialState === 'present' &&
      ctx.sandboxState === 'unchecked' &&
      !attempted.current.sandbox
    ) {
      attempted.current.sandbox = true
      send({ type: 'CHECK_SANDBOX' })
    }
  }, [ctx.credentialState, ctx.sandboxState, send])

  useEffect(() => {
    if (
      ctx.credentialState === 'present' &&
      ctx.sandboxState === 'available' &&
      agentState === 'down' &&
      !attempted.current.agent
    ) {
      attempted.current.agent = true
      send({ type: 'START' })
    }
  }, [ctx.credentialState, ctx.sandboxState, agentState, send])

  return (
    <ChatSurface
      snapshot={snapshot}
      send={send}
      mode={mode}
      restoredRedacted={redacted}
      resolveSurface={loadedSurface}
      // A deliberate recovery re-arms start-up, so the steps after the one that
      // failed run again on their own.
      onRecover={() => {
        attempted.current = { credential: false, sandbox: false, agent: false }
      }}
    />
  )
}

type Resume =
  | { status: 'reading' }
  | { status: 'failed'; reason: string; retry: () => void }
  | ({ status: 'restored'; input: SessionInput | undefined } & Pick<RestoredSession, 'redacted'>)

/**
 * Read the conversation back from the Session mirror.
 *
 * Only in live mode. Seeded mode has no host to ask and nothing was ever
 * mirrored — `persistSession` is a stub there — so a read would be a call that
 * cannot succeed asked about a transcript that cannot exist. The machine's own
 * default input stands, and the conversation starts empty.
 */
function useResume(mode: ActorMode): Resume {
  const [attempt, again] = useState(0)
  const [state, setState] = useState<Resume>(
    mode === 'live'
      ? { status: 'reading' }
      : { status: 'restored', input: undefined, redacted: false },
  )
  const retry = useCallback(() => {
    setState({ status: 'reading' })
    again((n) => n + 1)
  }, [])

  useEffect(() => {
    if (mode !== 'live') return
    let current = true
    restoreSession(LIVE_SESSION_ID).then(
      (restored) => {
        if (current) setState({ status: 'restored', ...restored })
      },
      (error: unknown) => {
        if (current) {
          setState({
            status: 'failed',
            reason: error instanceof Error ? error.message : String(error),
            retry,
          })
        }
      },
    )
    return () => {
      current = false
    }
  }, [mode, attempt, retry])

  return state
}

/** A line before the chat exists. Nothing else is on screen at this point. */
function StartupNote({
  text,
  bad,
  action,
}: {
  text: string
  bad?: boolean
  action?: { label: string; run: () => void }
}) {
  return (
    <div className="flex h-full flex-col px-6 py-4" style={{ background: 'var(--ground)' }}>
      <div
        className="flex flex-wrap items-baseline gap-x-3"
        style={{ color: bad ? 'var(--bad)' : 'var(--fg-faint)', maxWidth: 'var(--prose)' }}
      >
        <span>
          {bad && <span aria-hidden>✗ </span>}
          {text}
        </span>
        {action && (
          <button onClick={action.run} style={{ color: 'var(--accent)' }}>
            {action.label}
          </button>
        )}
      </div>
    </div>
  )
}
