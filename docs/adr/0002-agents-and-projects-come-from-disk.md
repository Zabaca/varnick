# Agents and projects come from disk, not Varnick settings

Varnick has no profile format of its own. In a prompt, `@` lists Claude Code's agents (`.claude/agents` in the folder the session will start in, then `~/.claude/agents`) and `#` lists git repos under the project folders; both are read again each time a prompt starts, so a new agent file or repo shows up without any setup. We chose this over Varnick-owned profiles (agent plus model, folder and permissions) so an agent behaves the same in Varnick, in a terminal and as a subagent, and nothing has to be kept in sync.

## Consequences

What an agent file can't say, Varnick doesn't offer per agent: there is no per-agent folder or permission mode. Agents depend on the folder, so `#project @agent` lists that project's agents.
