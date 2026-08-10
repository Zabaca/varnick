/**
 * How the agent writes, as an instruction the Profile carries.
 *
 * A Profile decides what an agent is — its instructions, tools, model, Sandbox
 * policy, and where it may act (CONTEXT.md). Everything except the instructions
 * was already here: `agentConfigurationOptions` decides the setting sources,
 * `agentEnvironment` the environment, `sandbox-policy.json` where it may act.
 * This is the instruction slot, and it was empty.
 *
 * ## Why the text is copied rather than loaded
 *
 * The style is the `caveman` plugin's, and the plugin already ships a way to
 * apply it: a `SessionStart` hook declared in its own `plugin.json`, which emits
 * the ruleset as hidden context. Under varnick that hook never runs. Its command
 * is `node "${CLAUDE_PLUGIN_ROOT}/src/hooks/caveman-activate.js"`, and the agent
 * is spawned with an environment `agentEnvironment` builds outright rather than
 * inherits — varnick runs on bun, and a hook that cannot spawn fails silently.
 * The evidence is the flag file the hook writes on every start: there has never
 * been one under the clone's `CLAUDE_CONFIG_DIR`.
 *
 * Fixing the hook was the other option and it is the better one for hooks in
 * general — every plugin hook in every clone is dead the same way. It is not
 * better for *this*, because a hook is the one kind of configuration the runtime
 * report cannot show. It reports skills, plugins and MCP servers precisely
 * because configured is not the same as loaded, and a style applied by something
 * invisible would be the same class of fact going unreported. An instruction in
 * the Profile is read in one place and is in the diff.
 *
 * So the plugin is where this came from, not something it depends on. Nothing
 * reads `.claude/plugins/` at run time, and a clone without the plugin sounds
 * exactly the same.
 *
 * ## Why `append` and not a whole system prompt
 *
 * The preset carries the working directory, the memory path and git status —
 * the SDK's "per-user dynamic sections". Replacing it rather than appending to
 * it is a measured failure already recorded at the `systemPrompt` option in
 * ./agent.ts: the agent ran `pwd` because that was the only way left to find out
 * where it was standing.
 *
 * ## Why a constant and not a file the clone owns
 *
 * Reading this from the clone would let the style track the plugin, and it would
 * also hand the agent its own system prompt to edit. The clone already supplies
 * memory files and hooks, both agent-writable, so the reach is not new — but
 * those are visible in a way the system prompt is not, and there is no reason to
 * add the one surface where an edit would never be seen.
 *
 * ## The exemption that matters most here
 *
 * Terse applies to the conversation and to nothing that outlives it. Commit
 * messages in this repository carry the reasoning for the change and are the
 * durable record of it; ADRs and `CONTEXT.md` are prose on purpose. A style that
 * compressed those would trade the thing the repository is for a few tokens in a
 * chat window.
 */

/**
 * The instruction, as it reaches the model.
 *
 * Every line is a rule the plugin's own `SKILL.md` states, at its `ultra`
 * intensity, with the level-switching removed: varnick applies one voice for the
 * life of the Session, because `append` belongs to the SDK's `initialize`
 * request and is fixed once the Session is open — see the note on
 * `DescribeSecretsRequest` in ./turn.ts.
 */
export const AGENT_VOICE = `Respond tersely. All technical substance stays; only fluff goes.

This applies to every response. Do not drift back into long-form prose after many turns.

Drop articles (a/an/the), filler (just, really, basically, actually, simply), pleasantries (sure, certainly, of course, happy to), and hedging. Fragments are fine. Prefer the short synonym: "big" not "extensive", "fix" not "implement a solution for". Strip conjunctions wherever cause and effect stay unambiguous without them. One word where one word is enough. State each fact once.

Never drop not, never, no, only, or except. Flipping a meaning costs more than any token it saves. Numbers and units exact. Technical terms exact. Code blocks unchanged. Error strings quoted exactly. Never alter a code symbol, function name, API name, or file path to make it shorter.

Never invent abbreviations (cfg, impl, req, res, fn, auth). The tokenizer splits an invented abbreviation into the same number of tokens as the full word, so nothing is saved and the reader still has to decode it. No arrows (X -> Y) — an arrow is its own token and replaces nothing.

No decorative tables and no emoji. Do not paste long raw error logs unless asked for them; quote the shortest decisive line.

Tool calls: make them directly. No preamble, no plan, and no progress note before or between calls. After a result, either make the next call or give the final answer — never announce the call you are about to make. Text before a call is for clarifying an ambiguity or warning about something irreversible, and nothing else.

Reply in the language the user writes in. Compress the style, never switch the language.

Never name or announce this style, and never refer to it. Do not write "caveman mode on" or tag responses in the third person. Never give a normal answer and then a compressed recap of it; there is one answer.

The shape is: [thing] [action] [reason]. [next step].
Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
Yes: "Bug in auth middleware. Token expiry check uses \`<\` not \`<=\`. Fix:"

Write ordinary prose, not this style, anywhere the words outlive the conversation: code, code comments, commit messages, documentation, issue and pull request text, memory files, and anything addressed to a third party.

Write ordinary prose for the whole of a security warning, a confirmation of an irreversible action, a multi-step sequence whose order could be misread without conjunctions, and anywhere compression would create a technical ambiguity. Resume afterwards.`

/**
 * The `systemPrompt` option, as the query takes it.
 *
 * A function rather than the object inline at the call site, because the call
 * site is a closure inside `runAgentHost` that no test can reach — the same
 * reason the rest of this Profile is assembled by exported functions.
 */
export function agentSystemPrompt(): {
  type: 'preset'
  preset: 'claude_code'
  append: string
} {
  return { type: 'preset', preset: 'claude_code', append: AGENT_VOICE }
}
