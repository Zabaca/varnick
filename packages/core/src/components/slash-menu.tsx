/**
 * The command list, in Claude Code's grammar.
 *
 * brainless ships a ClaudeSlashMenu, but it owns its own state and renders its
 * own composer. State here lives in the session machine, so this is the list
 * only — same colours, same fixed name column, same listbox semantics.
 *
 * It shows two kinds of row now. varnick's own commands are events the machines
 * accept; the rest come from the runtime — the CLI's commands, and every skill
 * and plugin the agent loaded. They are marked rather than separated, because
 * what someone hunting for a command wants is one ranked list, and which half a
 * row came from only matters once they have found it.
 */
import { commandLabel, type MenuCommand } from '../domain.ts'

const ACTIVE = '#afd7ff'
const INACTIVE = '#949494'
const NAME_COLS = 24

export function SlashMenu({
  commands,
  activeIndex,
  onHover,
  onPick,
}: {
  commands: readonly MenuCommand[]
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
              {commandLabel(c)}
              {/*
                What the command takes, beside its name rather than in place of
                its description. It is the one piece of a command's frontmatter
                that changes what you type next.
              */}
              {c.argumentHint && (
                <span style={{ color: INACTIVE, opacity: 0.7 }}> {c.argumentHint}</span>
              )}
            </span>
            {c.description}
            {/*
              Whose command this is, said once and quietly. A varnick row is an
              event this window sends; an agent row is text the Session runs.
              Unmarked, a menu that suddenly lists thirty entries gives no way to
              tell the two apart — and they fail in different places.
            */}
            {c.source === 'agent' && (
              <span style={{ color: INACTIVE, opacity: 0.55 }}> · agent</span>
            )}
          </li>
        )
      })}
    </ul>
  )
}
