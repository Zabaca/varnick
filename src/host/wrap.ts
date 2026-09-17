// Wrap: the one function that turns the agent's command into the command a
// Session runs. In v1 it returns the command unchanged — there is no kernel
// sandbox — and it is the only place one would go if it returned (ADR-0004).
// Nothing else in the Host may build the Session's command.

export type Wrap = (command: string[]) => string[];

export const wrap: Wrap = (command) => command;
