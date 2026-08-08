/**
 * The command list, in Claude Code's grammar.
 *
 * brainless ships a ClaudeSlashMenu, but it owns its own state and renders its
 * own composer. State here lives in the session machine, so this is the list
 * only — same colours, same fixed name column, same listbox semantics.
 */

export type Command = {
  name: string
  description: string
  /** Only listed when this is true. A command that cannot run is not offered. */
  available: boolean
  run: () => void
}

const ACTIVE = '#afd7ff'
const INACTIVE = '#949494'
const NAME_COLS = 24

export function SlashMenu({
  commands,
  activeIndex,
  onHover,
  onPick,
}: {
  commands: Command[]
  activeIndex: number
  onHover: (i: number) => void
  onPick: (i: number) => void
}) {
  if (commands.length === 0) {
    return (
      <div className="mb-2 px-1 py-0.5" style={{ color: INACTIVE }}>
        No command matches. Escape to keep typing.
      </div>
    )
  }

  return (
    <ul
      role="listbox"
      aria-label="Commands"
      aria-activedescendant={`slash-${activeIndex}`}
      className="mb-2 space-y-0.5"
    >
      {commands.map((c, i) => {
        const active = i === activeIndex
        return (
          <li
            key={c.name}
            id={`slash-${i}`}
            role="option"
            aria-selected={active}
            onMouseEnter={() => onHover(i)}
            onMouseDown={(e) => {
              // Down, not click: the composer must not lose focus first.
              e.preventDefault()
              onPick(i)
            }}
            className="cursor-pointer truncate px-1 py-0.5"
            style={{ color: active ? ACTIVE : INACTIVE }}
          >
            <span className="inline-block" style={{ width: `${NAME_COLS}ch` }}>
              {c.name}
            </span>
            {c.description}
          </li>
        )
      })}
    </ul>
  )
}
