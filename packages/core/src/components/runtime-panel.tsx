/*
  What the running agent says it is, beside the conversation that is driving it.

  **Ported from forge**, which built it after a profile declared two plugins,
  the SDK silently dropped them, and every file in that repo went on saying they
  were loaded. Nothing errored. The only reason it surfaced was that the agent
  happened to read its own skill list and notice an absence.

  varnick has the same hole in the same place and one more reason to care about
  it: the agent runs inside a Sandbox that denies `$HOME`, so `~/.claude` — the
  settings, skills and plugins a developer has *installed* — is unreachable
  whatever any option says. So what this panel lists is what the *clone* carries
  (ticket 38), and the gap between "I installed that" and "the agent has it" is
  exactly the gap this panel exists to show.

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

/**
 * The SDK's own word for "no API key store answered".
 *
 * Read as an absence rather than forwarded as a name, because it is not one. It
 * is the literal this row printed for every subscription Session varnick ever
 * ran — there is no API key in one, so the SDK says `none` about a question
 * nobody asked, and the row that exists to prove injection worked said the
 * opposite of the truth.
 */
const NO_API_KEY_STORE = 'none'

/**
 * Which name the `credential` row prints, or `null` when there is no name.
 *
 * Two fields and three readings. `credentialSource` is varnick's own
 * measurement, taken inside the confined process — the variable it found in its
 * environment — so it wins when it is there: it is the fact the row was built to
 * report. Failing that, an `apiKeySource` that names a store is still a real
 * answer, and printing it is the row admitting that the runtime found a
 * credential by a route varnick did not take. Nothing at all is the third
 * reading, and it is the one this row exists for.
 *
 * varnick reports *beside* `apiKeySource` and never over it. The field belongs
 * to the SDK and its meaning is the SDK's to define; what changed here is what
 * the panel says, not what the SDK measures.
 *
 * A pure function rather than a branch inside the component, for the reason
 * {@link runtimeAbsence} above is one: a branch inside a `.tsx` cannot be
 * reached by `drive.ts`, which cannot import a component.
 */
export function credentialRowName(credentialSource: string, apiKeySource: string): string | null {
  if (credentialSource !== '') return credentialSource
  if (apiKeySource !== '' && apiKeySource !== NO_API_KEY_STORE) return apiKeySource
  return null
}

/**
 * What the row says when there is no name to print.
 *
 * A sentence rather than a word, on the same argument the `memory` row makes:
 * `none` is a thing a reader has to interpret, and the interpretation most of
 * them reached was "this is broken" on Sessions that were working perfectly.
 * This says which two things are both true, so that a developer whose agent is
 * nevertheless answering knows they are looking at a credential varnick did not
 * supply rather than at a bug.
 */
export const CREDENTIAL_UNACCOUNTED =
  'no credential varnick can account for — nothing it injected is here, and the runtime named no store'

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
              Which credential the confined process is holding, by the name of
              the variable it arrived in — a name, never a value, and the same
              class of fact as Credential Source. It is here because it is the
              one thing on screen that shows injection worked: the host read a
              credential and the confined process found it.

              It read `apiKeySource` alone until ticket 68, and so it had never
              once shown that. A subscription Session has no API key, the SDK
              says `none` about it, and the row printed `none` beside an agent
              that was answering — the failure mode this panel was ported from
              forge to catch, reproduced inside the panel itself. The three
              readings are argued in `credentialRowName` above; the warning is
              the colour the `memory` row below uses, because it is the same kind
              of admission.
            */}
            <Fact name="credential">
              {credentialRowName(report.credentialSource, report.apiKeySource) ?? (
                <span style={{ color: 'var(--warn)' }}>{CREDENTIAL_UNACCOUNTED}</span>
              )}
            </Fact>
            <Fact name="cwd">{report.cwd || '—'}</Fact>
            {/*
              The two rows that answer "does it remember?".

              `memory` is the one fact on this panel a person acts on. A window
              showing a full transcript over an agent that has never seen it is
              the failure this pair exists to make impossible to miss — so the
              fresh case is coloured and says what it means, rather than being a
              `false` someone has to interpret.
            */}
            <Fact name="memory">
              {report.resumed ? (
                'resumed — it has the conversation above'
              ) : (
                <span style={{ color: 'var(--warn)' }}>
                  new — this agent has not seen the conversation above
                </span>
              )}
            </Fact>
            <Fact name="session">{report.sessionId || '—'}</Fact>
          </Section>

          <Section title="tools" count={report.tools.length}>
            <Chips items={report.tools} empty="none" />
          </Section>

          {/*
            No longer expected to be empty. The clone's skills and plugins load
            now (ticket 38) — what stays out of reach is `~/.claude`, which the
            Sandbox denies, so a skill exists for this agent only if it is in the
            clone. An empty list means the clone carries none.
          */}
          <Section title="skills" count={report.skills.length}>
            <Chips items={report.skills} empty="none in this clone — ~/.claude is out of reach" />
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
