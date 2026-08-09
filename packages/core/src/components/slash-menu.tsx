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
/**
 * How wide the name column is, in characters.
 *
 * 28 rather than 24, measured against the names that are actually there:
 * `/mattpocock-skills:prototype` fits exactly, and the plugin-qualified names
 * are what pushed this past the old width. Wider would buy the longest few
 * names at every description's expense.
 */
const NAME_COLS = 28

/**
 * How tall the list may get before it scrolls.
 *
 * **A cap rather than a preference.** The list was ninety-three rows on a real
 * runtime, and unbounded it grew the composer's column until the flex row
 * outgrew the window — which pushed the Surface panel off the side and left it
 * blank. A menu is a thing you look at the top of; the rest scrolls.
 */
const MOST_OF_THE_LIST = '38vh'

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
      /*
        Its own surface, one step up from the transcript.

        The list used to sit on the chat's own background, which made a
        ninety-row menu read as part of the conversation rather than as
        something laid over it. `--ground-raised` is the token that already
        means "one step nearer" — the same one the chips in the runtime panel
        sit on — so this borrows the ramp rather than inventing a colour.
      */
      className="mb-2 overflow-y-auto"
      style={{
        maxHeight: MOST_OF_THE_LIST,
        background: 'var(--ground-raised)',
        border: '1px solid var(--rule)',
      }}
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
            className="flex cursor-pointer items-baseline gap-3 py-0.5 pr-2"
            /*
              The selected row is a band, not a shade of text.

              It was a text colour alone, which on a list this long is nearly
              invisible — you lose your place the moment you look away. The
              accent rule down the left is what carries it at a glance; the
              wash behind is what makes the band read as one row rather than as
              coloured words.
            */
            style={{
              color: active ? ACTIVE : INACTIVE,
              background: active ? 'color-mix(in srgb, var(--accent) 14%, transparent)' : 'transparent',
              borderLeft: `2px solid ${active ? 'var(--accent)' : 'transparent'}`,
              paddingLeft: '6px',
            }}
          >
            {/*
              A fixed column, clipped rather than pushed.

              Three arrangements, and the reasons are worth keeping. Fixed and
              overflowing was the first: a long name drew *under* the
              description and the two rendered in the same place. Auto-width
              fixed that and cost the thing the column is for — with
              `/model opus-5|sonnet-5|haiku-4.5` in it, every description in the
              list moved right by however long the widest name happened to be,
              so a ninety-row list had no column at all.

              Fixed and clipped keeps the scan line. What is lost is the tail of
              a long name, which is the part you have already typed.

              The argument hint is not here. It belongs to the one command you
              have chosen, not to a list you are searching — see the signature
              bar in chat-surface.tsx, which is where it went and where it is
              the only thing worth reading.
            */}
            <span
              className="shrink-0 overflow-hidden text-ellipsis whitespace-nowrap"
              style={{ width: `${NAME_COLS}ch` }}
            >
              {commandLabel(c)}
            </span>
            <span className="min-w-0 flex-1 truncate">{c.description}</span>
            {c.source === 'agent' && (
              <span className="shrink-0" style={{ color: INACTIVE, opacity: 0.55 }}>
                agent
              </span>
            )}
          </li>
        )
      })}
    </ul>
  )
}
