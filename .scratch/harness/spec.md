# Harness — v1

**Status:** ready-for-agent

## Problem Statement

A developer who wants an agent to work unattended on their own machine has no good options. Running it with permissions bypassed puts every SSH key, cloud credential, and unrelated repository on the machine within reach of an injected instruction in any file the agent reads. Running it with permission prompts on means answering prompts instead of working, which defeats the point. The tooling that exists treats the conversation as the destination, so there is nowhere for the work to accumulate and nothing to build around.

Worse, the failure mode is silent. The Claude Agent SDK ships a `sandbox` option that looks like a boundary and confines only shelled-out commands; `Read`, `Grep`, and `Glob` walk straight past it. A developer can believe they are confined, be wrong, and never find out.

The developer wants to hand an agent real autonomy, describe the blast radius in one sentence, and have the conversation survive whatever the agent does to the code.

## Solution

varnick is a desktop Harness for a coding agent with a chat inside it. The developer clones the repository, runs it in dev mode, and works with an agent that is confined by the kernel across its entire process tree — not by a prompt, and not by a mechanism that covers only some of its tools.

The Harness supplies four things the developer would otherwise build before they could trust the setup. Confinement: the agent runs under a sandbox scoped to the clone, with the home directory, other repositories, and the network denied except for an allowlist. Credentials: the agent authenticates without ever being able to reach the system keychain, because the host reads the credential and injects it. Secrets: the agent writes code that names a secret and never sees a value. Durability: the Session is persisted twice, so the transcript survives a crash, a restart, and a build the agent just broke.

Inside that, the developer builds their own Workspace by asking for it. Surfaces are discovered from the filesystem, so adding one never requires editing Core — which the agent cannot write anyway. When a Surface fails to load, it fails alone: the chat stays alive, and the conversation that caused the failure is the conversation that fixes it.

Everything the developer builds on top is theirs. What ships is a Harness small enough to read.

## User Stories

### Confinement

1. As a developer, I want the agent's entire process tree confined by the kernel, so that a tool added to the SDK later is covered without me changing anything.
2. As a developer, I want `Read`, `Grep`, and `Glob` to be denied the same paths that `Bash` is denied, so that the confinement I was promised is the confinement I get.
3. As a developer, I want my home directory unreadable to the agent, so that an injected instruction in a file it reads cannot exfiltrate my SSH keys, cloud credentials, or age keys.
4. As a developer, I want my other repositories unreadable to the agent, so that work on one project cannot leak the contents of another.
5. As a developer, I want the agent unable to execute `security`, `osascript`, `open`, and `sudo`, so that it cannot read my keychain, script other applications, launch anything outside its boundary, or elevate.
6. As a developer, I want the agent's network egress limited to an allowlist, so that its reach is bounded even when it is running unattended.
7. As a developer, I want to see exactly which paths and hosts the policy permits, so that I can decide whether I believe the boundary before I walk away from it.
8. As a developer, I want the README to state plainly where confinement is partial, so that I am not relying on a protection that does not exist.
9. As a developer cloning this on Linux or Windows, I want to be told clearly whether confinement is enforced on my platform, so that I do not assume macOS behaviour.
10. As a developer, I want the agent's run to fail loudly if the sandbox cannot be established, so that it never silently runs unconfined.

### Credentials

11. As a developer, I want to launch varnick and have the agent authenticate without me exporting anything, so that a desktop application behaves like a desktop application.
12. As a developer, I want the credential read by the host process and injected into the agent, so that the agent can authenticate without being able to read the keychain that holds it.
13. As a developer, I want a clear first-run path when no credential is available, so that a fresh clone tells me what to do instead of failing obscurely.
14. As a developer, I want the agent to refuse to start when no credential is present, so that I get one legible error rather than a stream of authentication failures mid-task.
15. As a developer, I want an expired or rejected credential surfaced as its own state, so that I can tell it apart from the agent being broken.

### Secrets

16. As a developer, I want to store an API key that the agent can never read, so that a secret in my Workspace is not one prompt injection away from leaving it.
17. As a developer, I want the agent to write code referencing a secret by name, so that it can build integrations without ever holding a value.
18. As a developer, I want the host to resolve secret names when it runs the code the agent wrote, so that the built Surface works while the agent that built it stayed blind.
19. As a developer, I want to add, rename, and remove secrets without restarting varnick, so that setting up an integration is not a restart cycle.
20. As a developer, I want the agent told which secret names exist, so that it can write correct code without knowing any values.
21. As a developer, I want secrets kept out of the transcript and out of logs, so that durability of the Session does not become durability of my keys.

### Session durability

22. As a developer, I want my transcript to survive quitting and relaunching varnick, so that a day's work is not a day's conversation lost.
23. As a developer, I want my transcript to survive a crash, so that an unattended run that dies is recoverable rather than opaque.
24. As a developer, I want the transcript intact after the agent writes code that does not compile, so that the conversation that broke the build is the one that fixes it.
25. As a developer, I want to resume the Session where it left off rather than starting a new one, so that context is not rebuilt by hand.
26. As a developer, I want the Session stored somewhere I can read and back up, so that durability is not a claim I have to take on faith.

### Chat

27. As a developer, I want to send a message and watch the response stream, so that I can tell the difference between working and hung.
28. As a developer, I want to interrupt a running turn, so that a wrong direction costs seconds rather than minutes.
29. As a developer, I want to see the agent's tool calls as they happen, so that unattended work is auditable rather than a black box.
30. As a developer, I want sending refused with an explanation when the agent cannot run, so that a dead input box tells me why.
31. As a developer, I want the chat to keep working when a Surface fails, so that the failure is a thing I can talk about rather than a thing that removes my ability to talk.

### The Core/Userspace boundary

32. As a developer, I want the agent physically unable to write Core, so that it cannot break the chat I would use to recover.
33. As a developer, I want the agent physically unable to edit the build configuration or package scripts, so that it cannot reach the host by writing a plugin or an install hook.
34. As a developer, I want the agent to be told what it cannot write and why, so that it proposes an Escalation instead of retrying a denied write.
35. As a developer, I want to change Core myself in a separate session in the same repository, so that the harness stays improvable without weakening the boundary.

### Surfaces

36. As a developer, I want to ask for a Surface and have it appear without editing Core, so that the main loop of the product is not blocked by its own safety boundary.
37. As a developer, I want Surfaces discovered from the filesystem, so that adding one is creating a file rather than registering in a list.
38. As a developer, I want a Surface that fails to load to show me what failed and why, so that I can fix it from the chat.
39. As a developer, I want one broken Surface to leave the others running, so that a mistake in one part of my Workspace does not cost me the rest.
40. As a developer, I want to retry a failed Surface without restarting varnick, so that the fix-and-see loop stays short.

### Cloning and first run

41. As someone who did not write varnick, I want a fresh clone to run without personal configuration baked in, so that it is genuinely usable rather than nominally open source.
42. As someone cloning varnick, I want first launch to be an empty chat that works, so that I can start building immediately rather than configuring.
43. As someone cloning varnick, I want the Harness readable in a sitting, so that I can decide whether to trust it and know where to edit it.
44. As a developer, I want varnick isolated from my existing Claude Code configuration by default, so that its behaviour does not depend on machine state I forgot I set.
45. As a developer, I want a flag to inherit my Claude Code environment, so that my existing skills and MCP servers are available when I want them.

## Implementation Decisions

**Two packages.** The Harness is a package inside the repository — sandbox policy generation, credential resolution, the Secrets Store, and Session persistence — consumed by Core, which owns the chat and the Surface loader. The Harness is not published; it stays editable in the clone, because the thing a fork most wants to change is the sandbox policy. Extraction later is a move, not a rewrite.

**Containment is `@anthropic-ai/sandbox-runtime` around the agent's process tree.** The Agent SDK's own `sandbox` option is disabled and must stay disabled — the kernel refuses to apply a sandbox inside an existing one, so enabling both kills every Bash command. This is [ADR-0003](../../docs/adr/0003-containment-wraps-the-process-tree.md).

**Execution is denied by denying read.** `sandbox-runtime` has no execute allowlist, so a binary is blocked by making it unreadable. The denied set is `security`, `osascript`, `open`, and `sudo`. A narrow deny must win over the broad allow that re-opens system paths.

**The sandbox policy denies Core.** `packages/core/**`, the build configuration, and package scripts are unwritable by the Userspace Profile, per [ADR-0002](../../docs/adr/0002-core-userspace-boundary.md). This is what makes the boundary kernel-enforced rather than conventional, and it is also what closes the build-pipeline escape.

**Surfaces are discovered, never registered.** The loader scans a Userspace directory at load time. No imports array exists for the agent to append to, because the agent cannot write the file that would hold it.

**Core loads Surfaces dynamically and never statically imports them**, per [ADR-0004](../../docs/adr/0004-core-never-statically-imports-userspace.md), enforced by a lint rule rather than by discipline. Each Surface load is wrapped so a failure is contained to that Surface.

**The credential is read by the host and injected as an environment variable** into the sandboxed subprocess. The host process is outside the sandbox by construction, which is the same property that makes Custom Tools the sanctioned escape hatch.

**Secrets resolve at the point the host runs built code**, never inside the agent's process. The agent is given the list of names and no values. Egress substitution was considered and rejected — it requires owning a proxy, and clients that validate credential format locally break on a placeholder. This is [ADR-0006](../../docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).

**The Session is persisted twice**: by the Agent SDK for resumption, and mirrored host-side so it survives a broken build and gives the UI a queryable store. The storage mechanism for the host-side mirror is an open decision.

**The network allowlist is a configuration file in v1**, not a UI. Its contents are readable and editable, and the honest limit is documented: any allowed host is an exfiltration path, so the allowlist bounds blast radius rather than data egress.

**Machine decomposition is proposed, not settled.** The shape this spec assumes is one parent machine owning agent-process lifecycle and credential state, with one child actor per Surface. Independent facts — credential present, sandbox available, agent process running — look like parallel regions rather than one status enum. The decomposition is confirmed at the start of the machine stage and this spec is amended if it differs.

**Every actor declares its real-service contract when the machine is written** — input shape, output shape, error shape — for `spawnAgent`, `readCredential`, `persistSession`, and `loadSurface`. Failure and retry branches are asserted against seeded failures, not just happy paths.

## Testing Decisions

A good test here asserts external behaviour and, more than usual, asserts **refusals**. Most of what this feature promises is something not happening: a path not readable, an event not accepted, a failure not spreading. A test that only exercises the happy path proves almost nothing about a containment boundary.

**Seam 1 — the harness machine, driven headlessly.** No DOM, no framework, no components. Assertions: send refused with no credential; send refused while the agent process is down; interrupt legal only while streaming; a failed Surface leaves its siblings and the transcript intact; a Session restored after a simulated crash carries its transcript; a seeded actor failure recovers on retry; a final state accepts nothing. Actors are provided as seeds here, so latency and failure states are proven rather than assumed.

**Seam 2 — containment probes against a real sandboxed process.** This seam exists because a mocked sandbox proves nothing about the only claim the product rests on, and because the `Read`/`Grep` hole in the SDK's sandbox option was found only by running the real thing and reading the output. Assertions: a probe file outside the boundary is unreadable by `Bash`, `Read`, `Grep`, and `Glob` alike; each denied binary reports as not found; a non-allowlisted host is unreachable; an allowlisted host is reachable; the run fails rather than proceeding when the sandbox cannot be established. This seam is slow and needs a real machine, and that is accepted.

**Prior art** is `zbc/packages/agent` — its `sandboxed.test.ts` and `e2e/smoke.ts` are the closest existing examples of seam 2, and its ADR-0002 is the record of what happens when containment is asserted from documentation rather than measurement.

## Out of Scope

The canvas or artifact panel. Multiple concurrent Sessions, session switching, and session forking — the data layer models Sessions as a collection because that is a one-way door, but the v1 UI shows one. A settings and provenance panel. A UI for the network allowlist. Any plugin API, versioned extension contract, or published Harness package.

The Core Profile and the Escalation path are out of v1. Changing Core in v1 means opening a separate Claude Code session in the repository; the Clone, Collect, and double-gated Escalation described in [ADR-0005](../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md) are the design those will follow when built.

Also out: multi-user anything, authentication, tenancy, hosted deployment, and the morning-inbox workflow, which is a Userspace build on top of this and not part of the product.

## Further Notes

**The boundary is partial by design, and the documentation must say so.** Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run — that is the point of the product and cannot be closed without abandoning it. The Sandbox protects the home directory, other repositories, and the network. It does not protect the clone from the code the agent writes into it. Git is the undo.

**One question could close part of that hole and nobody has checked it:** whether the dev server can itself run inside the sandbox. If it can, the remaining escape narrows considerably at low cost. Worth answering during the machine stage.

**Platform confinement is macOS-only until proven otherwise.** `sandbox-runtime` has bubblewrap and Windows backends; neither has been exercised here, and the README should claim only what has been measured.

Open decisions carried from `PRODUCT.md`: the persistence mechanism for the host-side Session mirror and the Secrets Store, the open-source licence, and whether built binaries are distributed.
