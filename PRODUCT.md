# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Tauri desktop shell with a React + TypeScript frontend, in a monorepo. The agent layer is the Claude Agent SDK (TypeScript) running in-process, confined by `@anthropic-ai/sandbox-runtime` around the whole agent process tree.

Terminology is defined in `CONTEXT.md`, which is canonical. This file does not restate it.

## Users

One user at a time: a developer running varnick on their own machine, on their own work.

Because the project is open source, a second kind of user exists — someone who clones the repository and grows their own Workspace inside it. They are never a tenant of anyone else's instance. This constrains the code (legible, runnable by a stranger, no personal data or private assumptions baked in) but introduces no multi-user architecture: no shared server, no accounts, no tenancy.

The two are the same person in different postures, and the product treats them that way. What ships is what a stranger can clone; what you build on top is yours.

## Product Purpose

varnick is a desktop harness for a coding agent, and a chat that runs inside it. The harness supplies the things nobody wants to build twice and everybody needs before they can let an agent run unattended: kernel-level confinement, a credential the host reads and injects so the agent never needs a keychain of its own, a secrets store the agent cannot read, and a session that survives a crash, a restart, and a build the agent just broke.

You clone it, run it in dev mode, and build your own Workspace inside it — Surfaces, integrations, whatever the work needs — by asking the agent for them. The chat is not the destination; it is the thing that constructs everything else.

Success is that a person can hand an agent real autonomy on their own machine and describe the blast radius in one sentence, and that the environment around the chat grows more fitted to them over time.

## Positioning

**The harness is the product; the chat is its first surface.** Agent UIs treat conversation as the destination — you talk to the tool and receive output. Here the conversation exists to extend the application around it, and the application is what accumulates value.

**v1 is a Claude Code client, and says so.** An earlier draft of this file claimed varnick is "explicitly not a terminal embedded in a window." That was aspiration about where the product goes, stated as though it were true of what ships, and it made the first surface harder to read for no gain. At v1 the chat is a faithful representation of a Claude Code session — the same transcript, tool calls, and composer a developer already knows — because familiarity is the right starting point for a surface whose job is to construct everything else. What varnick adds is the harness around it and the Workspace that grows from it, not a different way to hold a conversation.

The claim a competitor cannot copy by shipping a nicer chat window is the containment story: on macOS the agent runs under a kernel sandbox covering its entire process tree, cannot open either keychain on the machine, authenticates from a credential the host injects, and cannot write the code that holds the conversation. That is a set of decisions with measurements behind them, not a feature list — and the measurements are what bound the claim. The keychains are unreachable because their files are under denied paths, which is a file denial and not a capability denial: `security`, `osascript` and `open` all still execute inside the Sandbox, and the README says so. Linux and Windows are unmeasured, so nothing is claimed for them.

The second half of the position is the refusal to build a plugin API. Extension is by clone: you fork, you edit, the seam is filesystem discovery rather than a versioned contract. That is only credible because the harness is small enough to read.

## Operating Context

Single machine, local-first, desktop. The user is a developer; varnick has real filesystem and subprocess access through Tauri, and the work it drives is software work in real repositories.

Repository structure is the user's choice; the author uses a monorepo. Sessions are long-running and resumable across days.

## Capabilities and Constraints

Confirmed:

- Tauri desktop shell; React + TypeScript frontend; monorepo.
- Claude Agent SDK in-process, with `@anthropic-ai/sandbox-runtime` wrapping the agent's process tree. The SDK's own `sandbox` option is not used and cannot be combined with it — see `docs/adr/0003-containment-wraps-the-process-tree.md`.
- The agent runs with permissions bypassed *inside* its boundary; the boundary is the kernel sandbox, not a prompt.
- Isolated by default from the host's Claude Code environment, with a flag to inherit it.
- Two Profiles: Userspace edits the live clone; Core works in a disposable Clone reaching the project only by host-initiated Collect.
- Single Session in v1. Multiple sessions, forking, and session switching are deliberately left to forks.
- Single-user, local-first. No auth, no tenancy, no shared server.
- Open source: the repository is public and must be runnable by someone who did not write it.
- Extension is by cloning and editing, not by a plugin API. Surfaces are discovered from the filesystem.
- State machines, the bare page, and the states page are product code and ship (`docs/agents/workflow.md`); the view layer is pure (`docs/adr/0001-pure-view-layer.md`).

### v1 scope

In: `srt` sandbox around the agent process tree, scoped to the clone; Tauri-side credential read and environment injection; Secrets Store with host-side resolution; a minimal Surface execution path, enough to run one real Userspace module; durable Session (SDK persistence plus a host-side mirror); chat transcript; the Core/Userspace boundary enforced in the sandbox policy; a network allowlist as a config file.

**A minimal Surface execution path is in v1 — decided after it was ruled out.** An earlier draft had full dynamic Surface loading in v1, reasoning from the boundary ADRs; that was cut, on the grounds that those ADRs govern how a Surface behaves once one exists and do not require one to ship. Cutting it turned out to take something else with it.

Host-side secret resolution happens at the moment the host runs code the agent wrote. With nothing in the product running Userspace code, that moment does not exist, and the Secrets Store ships as a store with no consumer — which makes "the agent authors secret use and never holds a secret" a claim rather than a demonstrated property. The alternative considered was resolving when the host runs a plain script with no Surface involved; it was rejected in favour of the loader that is already modelled, already proven by `drive.ts`, and already the thing the product is for.

So: **enough of the Surface loader to run one real Userspace module**, and no more. Not a Surface framework, not a layout system, not a registry. The rest of the Workspace remains what a fork builds.

Still out: the canvas or artifact panel, multiple sessions, session forking, a settings and provenance panel, an allowlist UI, and the Core Profile and Escalation path (v1 changes Core by opening a separate Claude Code session in the repository).

Explicitly undecided — record, do not invent:

- **Persistence mechanism** for the Secrets Store. *(The host-side session mirror is decided: JSON Lines, one file per Session, under the app-data directory — see the spec's Implementation Decisions.)*
- **Open-source licence.**
- **Distribution.** Whether built binaries are released, or the project is source-only.
- **Whether the dev server can run inside the sandbox.** If it can, the remaining escape in `docs/adr/0002-core-userspace-boundary.md` closes; nobody has checked.
- **Linux and Windows confinement.** `sandbox-runtime` has bubblewrap and WFP backends; neither has been exercised here.

## Brand Commitments

The name is `varnick`. Nothing else is committed — no logo, wordmark, palette, typography, voice, or visual reference has been established.

## Evidence on Hand

A working harness, and measurements against the kernel. The repository holds Core, the Harness, three pages, and a test suite; `packages/harness/src/sandbox.boundary.test.ts` runs a real agent under the real policy and reports what it can and cannot reach. That suite is the only evidence for the containment claims, and the claims are written to match it.

What there is still none of: users other than the author, customers, deployments, benchmarks, and any measurement on Linux or Windows. Nothing in this repository should imply otherwise.

Prior art exists in adjacent repositories by the same author and is the source of the containment design: `zbc/packages/agent` (sandbox-runtime containment, Profiles, Traits, disposable clones, Collect, and the measurements in its ADR-0002), `hudsonts/packages/nix/claude-sandbox` (a hand-written Seatbelt profile predating `srt`), and `cedarpad` (a hosted multi-workspace canvas platform on Cloudflare — a different deployment model, useful for canvas opinions).

There are no users besides the author, no customers, no testimonials, no benchmarks, no pricing, and no deployment. Future work must not fabricate any of these, and must not describe varnick as used by anyone other than its author.

## Product Principles

1. **The harness earns the autonomy.** Every claim about what the agent may do has to be enforced by something that is not a prompt. A boundary that reads as stronger than it is, is worse than no boundary.
2. **Describe the blast radius honestly.** Where confinement is partial — the built application runs outside the sandbox; any allowed host is an exfiltration path — say so in the README rather than implying otherwise.
3. **The chat must survive what the agent does.** The conversation that broke the build is the conversation that fixes it. Durability and failure isolation come before features.
4. **When something is missing, build it — in Userspace.** The workspace is extended from inside itself. Core changes are rare, gated, and applied through a Clone.
5. **No plugin API.** Extension is by cloning and editing. A versioned contract is a burden paid before a second user exists, and the thing forks most want to edit is the harness itself.
6. **One user, public code.** Optimize every interaction for a single known person, and write every line as if a stranger will clone it. No tenancy, no private data.
