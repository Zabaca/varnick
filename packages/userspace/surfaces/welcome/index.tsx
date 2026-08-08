/**
 * The Surface a fresh clone comes with.
 *
 * Userspace, not Core. Nothing in Core imports this file — it was found on disk
 * and imported dynamically, which is the only reason it is on screen. Delete it,
 * or ask the agent to replace it with something you actually want; either way
 * Core is untouched.
 */
export default function Welcome() {
  return (
    <div className="space-y-3 text-[12.5px]" style={{ color: 'var(--fg-dim)' }}>
      <p style={{ color: 'var(--fg)' }}>This is a Surface, and it is yours.</p>
      <p>
        It lives at{' '}
        <code style={{ color: 'var(--fg-faint)' }}>
          packages/userspace/surfaces/welcome/index.tsx
        </code>
        . Core found it by scanning the directory beside it, so adding another one
        is creating another folder with an <code>index.tsx</code> in it — there is
        nothing to register.
      </p>
      <p>
        Ask the agent for what this should be instead. If what it writes does not
        compile, this panel says so and offers a retry; the conversation stays
        where it is.
      </p>
    </div>
  )
}
