# State decomposition for the Harness

Three machines. `harness` is the parent and owns the facts that decide whether an agent may run at all; `session` is one child, spawned when the agent first starts and outliving every restart; `surface` is one child per discovered Surface. Both the Harness and the Session are parallel: the Harness across `credential`, `sandbox`, `subscription`, and `agent`, the Session across `turn`, `persistence`, and `composer`.

The alternative was one status enum per machine, and it fails on the cases that matter. A credential can be rejected while the sandbox is fine; the sandbox can be unavailable while a credential is present; the agent process can crash without changing either. Collapsing those into one enum makes every combination a new member and every transition a lie. On the Session it is worse: a save can fail while a turn is streaming, and a flat status would make "the transcript survives a broken build" untrue in exactly the case the product exists for.

Spawning the Session from `agent.running` rather than owning it in the parent state is what makes durability structural. The agent process is restartable; the conversation is not attached to it.

## Consequences

- **Regions publish their state into context.** An XState v5 guard receives only `{ context, event }` — it cannot read a sibling region's value. Each region assigns its own state to `credentialState` / `sandboxState` on entry and the start guard reads those. The UI reads the same two fields, so the affordance and the rule cannot drift apart.

- **Nothing at the root may carry a target.** A root-level `on` transition with a target is external in a parallel machine: it exits and re-enters every region, destroying spawned children. `READ_SUBSCRIPTION` written that way tore down the Session — and the whole conversation — on first load. Events handled at the root are limited to actions (`EDIT_DRAFT`, `SET_MODEL`, `SET_EFFORT`, `SET_COMMANDS`, Surface discovery); anything with a target lives inside its region.

- **A refused start is a state, not a disabled button.** `START` is a guarded transition with an unguarded fallback into `startRefused`, so a refusal explains itself rather than swallowing the click. The consequence is that `can({type:'START'})` is permanently true and nothing may bind a `disabled` attribute to it — readiness comes from `canStartAgent()`. The one time `startRefused` handled `START` differently from `down`, a start that had since become valid was silently dropped.

- **Menu state is derived, never toggled.** The composer region computes whether the menu is open from the draft and the command names it has been told about, so it cannot drift from what is actually typed. The single exception is `menuDismissed`, which exists because Escape must close the menu while leaving a draft that still starts with `/`.

- **Every state is addressable.** Each machine exports its state paths (`HARNESS_STATE_PATHS`, `SESSION_STATE_PATHS`, `SURFACE_STATE_PATHS`) and each takes entry-point inputs. That is what lets `#/states` park the real component in a named state, what lets a ticket say `#/states → turn.failed` instead of restating a design, and what makes the coverage banner able to go amber when a state gains no card. Adding a state without a scenario is a visible regression rather than a silent one.

- **Delays are named, never numeric literals.** `interruptGrace` and `refusalTimeout` are overridden by the frozen build; a literal in `after` cannot be, and an explorer card that expires while it is being read is not showing the state it claims.

- **Pairs with [ADR-0001](./0001-pure-view-layer.md).** The machines declare actor contracts and never import an implementation, so the live app, the bare page, and the states page differ only in which implementations are provided and who owns start-up.
