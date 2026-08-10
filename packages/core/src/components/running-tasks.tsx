import { taskMeter } from '../domain.ts'
import type { RunningTask } from '@varnick/harness/turn'

/**
 * The subagents running right now, under the working line.
 *
 * ## Why it exists
 *
 * A Turn that spawned subagents was indistinguishable from a Turn that had
 * hung. A `/code-review` ran four of them over ten minutes and the window
 * showed one `⚙ Agent(…)` line and then a spinner; the developer asked three
 * times whether anything was still happening, and answering it meant reading
 * the SDK's own transcripts off disk from outside the app.
 *
 * ## What it is not
 *
 * **Not a transcript.** This list is gone the moment the Turn ends, and that is
 * deliberate — a panel of subagents that finished ten minutes ago describes
 * nothing. The durable half is the `task-line` each one writes when it starts
 * and finishes, which goes into the answer and therefore into the Session
 * mirror.
 *
 * **Not a component with its own state.** A function of `(tasks)`, like
 * everything else here — see [ADR-0001](../../../../docs/adr/0001-pure-view-layer.md).
 * The elapsed figures come from the runtime rather than from a timer, so two
 * renders of the same snapshot draw the same thing and the states page can hold
 * a card of this without it drifting while somebody reads it.
 */
export function RunningTasks({ tasks }: { tasks: readonly RunningTask[] }) {
  if (tasks.length === 0) return null
  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={`${tasks.length} ${tasks.length === 1 ? 'agent' : 'agents'} running`}
      className="mt-1 flex flex-col gap-0.5 pl-4 text-[11.5px]"
      style={{ color: 'var(--fg-faint)', fontFamily: 'var(--font-mono, ui-monospace, monospace)' }}
    >
      {tasks.map((task, index) => (
        <div key={task.id} className="flex items-baseline gap-2">
          {/* Box-drawing, so the list reads as attached to the working line
              above it rather than as loose rows. The last one closes. */}
          <span aria-hidden style={{ color: 'var(--fg-faint)' }}>
            {index === tasks.length - 1 ? '└' : '├'}
          </span>
          <span className="truncate" style={{ color: 'var(--fg-dim)' }}>
            {task.subagentType.length > 0 ? task.subagentType : 'agent'}
          </span>
          {task.description.length > 0 && (
            <span className="min-w-0 flex-1 truncate">{task.description}</span>
          )}
          {/* Numeric, so the meters line up between rows the way the context
              meter does in the status line. */}
          <span data-numeric className="shrink-0 tabular-nums">
            {taskMeter(task)}
          </span>
        </div>
      ))}
    </div>
  )
}
