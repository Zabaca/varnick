import { useEffect, useRef } from 'react'
import { useHarness, toPath } from '../hooks.ts'
import { ChatSurface } from '../components/chat-surface.tsx'

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
 */
export function DesignedPage() {
  const { snapshot, send, mode } = useHarness()

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
      // A deliberate recovery re-arms start-up, so the steps after the one that
      // failed run again on their own.
      onRecover={() => {
        attempted.current = { credential: false, sandbox: false, agent: false }
      }}
    />
  )
}
