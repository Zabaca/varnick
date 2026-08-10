# 68 — The credential row says `none` while the agent is authenticated

**What to build:** The runtime panel reports which credential variable the confined process actually found, and warns when it found neither.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path. One field on `RuntimeReport` and the row that renders it.

## Measured

A working Session, mid-conversation, agent answering:

```
runtime
PROCESS
claude code   2.1.226
model         claude-opus-5
permissions   bypassPermissions
output style  default
credential    none
cwd           /Users/…/varnick
memory        resumed — it has the conversation above
```

Every row is true except one. The agent is authenticated — it is answering — and
the panel says `credential none`.

## Why it is the panel's worst row

`apiKeySource` is the SDK's word for which store an **API key** came from. Under a
subscription credential there is no API key, so the SDK says `none`, correctly,
about a question nobody asked. varnick injected `CLAUDE_CODE_OAUTH_TOKEN` and the
process found it; that is the fact the row exists to report, and the row has no
way to say it.

The comment above that row in `runtime-panel.tsx` states the job outright: *it is
the one thing on screen that shows injection worked.* It has never once shown
that for a subscription Session, which is most of them — and it is
indistinguishable from the genuine failure, where nothing was injected at all.

This is the failure mode the panel was ported from forge to catch — a system
confidently describing a thing that is not so — reproduced inside the panel
itself.

## What to build

**`RuntimeReport` gains `credentialSource: string`.** The name of the credential
environment variable the agent host observes in **its own** environment, or the
empty string when neither is set. A name, never a value, exactly as
`apiKeySource` already is; there remains no field on this type a credential could
arrive in.

Computed in `agent.ts` from `CREDENTIAL_ENV_VAR_NAMES` and passed to
`runtimeReportFrom` as an argument, the way `resumed` already is. It cannot come
off the init message: the SDK does not know what varnick injected, and reading it
from there would be inventing an answer. It travels the same wire and is rebuilt
field by field in `parseRuntimeReport`, like every other member.

**The row has three readings:**

| `credentialSource` | `apiKeySource` | Row |
| --- | --- | --- |
| a name | anything | the name — varnick injected it and the process found it |
| empty | a name | that name — the runtime found one by a route varnick did not take |
| empty | empty or `none` | a warning: running with no credential varnick can account for |

The warning uses the colour the `memory` row already uses for the fresh-agent
case, and says what it means rather than printing a word to be interpreted.

## Testing

`bun test packages`. `turn.test.ts` already pins `apiKeySource` in three places
and is the prior art:

- `runtimeReportFrom` under each credential variable, and under neither
- the round trip through `parseRuntimeReport`, which is where a field nobody
  agreed to would be dropped

A states-page card whose report carries no credential source, so the warning is a
thing that was looked at during design rather than only when it fires.

## Out of scope

Making `apiKeySource` correct. It is the SDK's field and its meaning is the SDK's
to define; varnick reports beside it, never over it.

Any change to how a credential is read, stored or injected. This ticket changes
only what is *said* about one.
