/*
  What the running agent says it is, beside the conversation that is driving it.

  **Ported from forge**, which built it after a profile declared two plugins,
  the SDK silently dropped them, and every file in that repo went on saying they
  were loaded. Nothing errored. The only reason it surfaced was that the agent
  happened to read its own skill list and notice an absence.

  varnick has the same hole in the same place and one more reason to care about
  it: the agent runs inside a Sandbox that denies `$HOME`, so `~/.claude` — user
  settings, skills, plugins — is unreachable whether or not configuration is
  inherited. That is a deliberate property of ADR-0003, and until this panel
  existed there was nothing on screen that showed it happening. "No skills
  loaded" is not a bug report here; it is the boundary, visible.

  Named Runtime rather than harness, which is what forge calls it. `Harness` in
  this repo is Core's runtime half — the thing that *confines* this process — and
  two meanings for one word is what CONTEXT.md exists to prevent.

  A function of its arguments, like every other component here (ADR-0001): it
  takes the report and the agent's state, and renders. Nothing is fetched, and
  there is no branch in it the states page cannot park in.
*/
import type { ReactNode } from 'react'
import type { RuntimeReport } from '@varnick/harness/turn'

export interface RuntimePanelProps {
  /** What the runtime last said, or `null` if it has not said anything. */
  readonly report: RuntimeReport | null
  /**
   * Which state the `agent` region is in.
   *
   * Read rather than inferred from `report === null`, because the two empty
   * cases are different problems: no agent is a thing to start, and a running
   * agent that has not reported is a Session that has not run a Turn yet.
   */
  readonly agentState: string
}

const Fact = ({ name, children }: { name: string; children: ReactNode }) => (
  <div className="flex min-w-0 items-baseline gap-2 py-px">
    <span className="w-[92px] shrink-0" style={{ color: 'var(--fg-dim)' }}>
      {name}
    </span>
    {/* `anywhere` rather than `break-word`: a clone path has no spaces to break at. */}
    <span className="min-w-0 flex-1 [overflow-wrap:anywhere]" style={{ color: 'var(--fg)' }}>
      {children}
    </span>
  </div>
)

const Chips = ({ items, empty }: { items: readonly string[]; empty: string }) =>
  items.length === 0 ? (
    <p className="m-0 italic" style={{ color: 'var(--fg-faint)' }}>
      {empty}
    </p>
  ) : (
    <div className="flex flex-wrap gap-1">
      {items.map((item) => (
        <span
          key={item}
          className="px-[5px] [overflow-wrap:anywhere]"
          style={{
            color: 'var(--accent)',
            backgroundColor: 'var(--ground-raised)',
            border: '1px solid var(--rule)',
          }}
        >
          {item}
        </span>
      ))}
    </div>
  )

const Section = ({
  title,
  count,
  children,
}: {
  title: string
  count?: number
  children: ReactNode
}) => (
  <section className="px-4 py-2" style={{ borderBottom: '1px solid var(--rule)' }}>
    <h3
      className="m-0 mb-1 flex items-baseline gap-1.5 uppercase"
      style={{ color: 'var(--fg-faint)', letterSpacing: '0.08em' }}
    >
      {title}
      {count === undefined ? null : (
        <span data-numeric style={{ color: 'var(--fg-dim)', letterSpacing: 0 }}>
          {count}
        </span>
      )}
    </h3>
    {children}
  </section>
)

/** The last path segment — what a plugin directory is actually called. */
const nameOf = (path: string): string => path.split('/').filter(Boolean).pop() ?? path

/**
 * Why there is nothing to show, said as the thing to do about it.
 *
 * Three cases and not one, because "nothing reported" has three different
 * causes and only one of them is waiting. Authored here rather than in the
 * component for the same reason `seededDetail` is: a branch inside a `.tsx`
 * cannot be reached by `drive.ts`, which cannot import a component.
 */
export function runtimeAbsence(agentState: string): string {
  if (agentState === 'running') {
    return 'The agent is running but has not described itself yet. It reports when the first turn starts.'
  }
  if (agentState === 'crashed') {
    return 'The agent stopped, so what it reported went with it. A report describes a process that exists.'
  }
  return 'No agent is running. Start one and it reports what it loaded when the first turn begins.'
}

export function RuntimePanel({ report, agentState }: RuntimePanelProps) {
  return (
    <section
      aria-label="runtime"
      className="text-[11.5px]"
      style={{ borderBottom: '1px solid var(--rule)' }}
    >
      <div className="px-4 py-2 text-[12px]" style={{ borderBottom: '1px solid var(--rule)' }}>
        <h2 style={{ color: 'var(--fg)' }}>runtime</h2>
      </div>

      {report === null ? (
        <p className="m-0 px-4 py-3 italic" style={{ color: 'var(--fg-faint)' }}>
          {runtimeAbsence(agentState)}
        </p>
      ) : (
        <>
          <Section title="process">
            <Fact name="claude code">{report.claudeCodeVersion || '—'}</Fact>
            <Fact name="model">{report.model || '—'}</Fact>
            <Fact name="permissions">{report.permissionMode || '—'}</Fact>
            <Fact name="output style">{report.outputStyle || '—'}</Fact>
            {/*
              Which store the runtime says answered — a name, never a value, and
              the same class of fact as Credential Source. It is here because it
              is the one thing on screen that shows injection worked: the host
              read a credential and the confined process found it.
            */}
            <Fact name="credential">{report.apiKeySource || '—'}</Fact>
            <Fact name="cwd">{report.cwd || '—'}</Fact>
          </Section>

          <Section title="tools" count={report.tools.length}>
            <Chips items={report.tools} empty="none" />
          </Section>

          {/*
            Expected to be empty, and worth a sentence rather than a shrug.
            Skills live under `~/.claude`, which the Sandbox denies read on, and
            `settingSources: []` would drop the clone's own besides. An empty
            list here is the boundary holding — see ADR-0003.
          */}
          <Section title="skills" count={report.skills.length}>
            <Chips items={report.skills} empty="none — $HOME is denied, which is the boundary working" />
          </Section>

          <Section title="plugins" count={report.plugins.length}>
            {report.plugins.length === 0 ? (
              <p className="m-0 italic" style={{ color: 'var(--fg-faint)' }}>
                none loaded
              </p>
            ) : (
              report.plugins.map((plugin) => (
                <Fact key={plugin.path} name={plugin.name || nameOf(plugin.path)}>
                  {plugin.version ?? 'no version'}
                </Fact>
              ))
            )}
          </Section>

          <Section title="mcp servers" count={report.mcpServers.length}>
            {report.mcpServers.length === 0 ? (
              <p className="m-0 italic" style={{ color: 'var(--fg-faint)' }}>
                none
              </p>
            ) : (
              report.mcpServers.map((server) => (
                <Fact key={server.name} name={server.name}>
                  {server.status}
                </Fact>
              ))
            )}
          </Section>

          <Section title="subagents" count={report.agents.length}>
            <Chips items={report.agents} empty="none" />
          </Section>

          <Section title="slash commands" count={report.slashCommands.length}>
            <Chips items={report.slashCommands} empty="none" />
          </Section>
        </>
      )}
    </section>
  )
}
