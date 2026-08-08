import { cn } from '../lib/utils.ts'

/**
 * Authored crease glyphs. The world's vocabulary for state is the square and
 * what has been folded into it — never a lamp, a dot, or an emoji.
 *
 * One consistent stroke weight throughout. Vermilion is the identity here, so
 * it can never mean alarm; a condition that is wrong reads as a square that
 * did not close.
 */

export type CreaseState = 'open' | 'creased' | 'folded' | 'released'

const STROKE = 1.25

export function CreaseSquare({
  state,
  className,
  title,
}: {
  state: CreaseState
  className?: string
  title?: string
}) {
  return (
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      fill="none"
      className={className}
      role="img"
      aria-label={title}
      strokeLinecap="square"
    >
      {/*
        The sheet.

        `released` draws the square with its top-right corner lifted away, so a
        failed condition is a different silhouette rather than a different line
        style — the whole point is reading state from across the room, and a
        dashed variant of the same mark does not survive that distance.
      */}
      {state === 'released' ? (
        <>
          <path
            d="M2.5 2.5 H14 M21.5 10 V21.5 H2.5 V2.5"
            stroke="currentColor"
            strokeWidth={STROKE}
            strokeLinejoin="miter"
          />
          {/* The corner, lifted and turned back. */}
          <path
            d="M14 2.5 L21.5 10 L15.5 10.5 Z"
            stroke="currentColor"
            strokeWidth={STROKE}
            strokeLinejoin="miter"
            opacity={0.85}
          />
        </>
      ) : (
        <rect
          x="2.5"
          y="2.5"
          width="19"
          height="19"
          stroke="currentColor"
          strokeWidth={STROKE}
          strokeDasharray={state === 'open' ? '3 3' : undefined}
          opacity={state === 'open' ? 0.55 : 1}
        />
      )}
      {/* First crease: the diagonal. Present once anything has been folded. */}
      {(state === 'creased' || state === 'folded' || state === 'released') && (
        <path d="M2.5 2.5 L21.5 21.5" stroke="currentColor" strokeWidth={STROKE} opacity={0.75} />
      )}
      {/* Second crease: the sheet is fully based. */}
      {state === 'folded' && (
        <path d="M21.5 2.5 L2.5 21.5" stroke="currentColor" strokeWidth={STROKE} opacity={0.75} />
      )}
    </svg>
  )
}

/** The gold dot. Marks the active fold, and marks nothing else. */
export function ActiveDot({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 8 8" width="6" height="6" className={className} aria-hidden>
      <circle cx="4" cy="4" r="4" fill="var(--gold)" />
    </svg>
  )
}

/** A row in the condition ledger: label, crease glyph, and its reading. */
export function Condition({
  label,
  state,
  reading,
  detail,
}: {
  label: string
  state: CreaseState
  reading: string
  detail?: string | null
}) {
  return (
    <div className="flex items-start gap-2.5 py-1.5">
      <CreaseSquare state={state} title={`${label}: ${reading}`} className="mt-0.5 shrink-0" />
      <div className="min-w-0">
        <div
          className="font-display text-[10px] uppercase leading-none"
          style={{ letterSpacing: '0.16em', color: 'var(--fold-on-vermilion)' }}
        >
          {label}
        </div>
        <div className="mt-1 text-[12.5px] leading-snug text-[var(--fold)]">{reading}</div>
        {detail ? (
          <div
            className={cn('mt-1 text-[11.5px] leading-snug')}
            style={{ color: 'var(--fold-on-vermilion)' }}
          >
            {detail}
          </div>
        ) : null}
      </div>
    </div>
  )
}
