# 16 — Close the Keychain hole, or stop claiming it is closed

**What to build:** The Secrets Store and the credential become unreachable from inside the Sandbox, or the product stops saying they are. Right now the code is right, the design is right, and one sentence in three documents is false — and it is the sentence the whole security story rests on.

**Blocked by:** None — can start immediately. The measurement already exists.

**Status:** needs-info — the choice below is the developer's, not an implementer's.

**Realizes:** no state path. Nothing about this is visible in a machine; that is part of why it went unnoticed.

## What was measured

Ticket 10 tried to prove the third acceptance criterion — "the store is unreadable from inside the sandbox, proven rather than assumed" — and disproved it instead. Reproduced independently:

```
cat /usr/bin/security                          -> Operation not permitted
/usr/bin/security find-generic-password ...    -> exit 44, securityd's own error
/usr/bin/osascript -e 'return 6*7'             -> 42
/usr/bin/sudo -n true                          -> Operation not permitted
cat "$HOME/.zshrc"                             -> Operation not permitted
curl https://example.com                       -> no route
```

`srt`'s generated macOS profile carries an unconditional `(allow process-exec)`, while `denyRead` emits `file-read-data` denials. Reading a binary and executing it are different operations, and only the first was ever denied. Denying the Keychain *files* does not help: `security` does not read them, it asks `securityd` over Mach, which the policy has no surface for.

**Filesystem and network containment are unaffected and are real.** This is a hole in one specific claim, not in the Sandbox.

## Why adding to `DENIED_BINARIES` cannot fix it

That list *is* `denyRead`, and `denyRead` is the mechanism that failed. A fix has to come from somewhere else.

## The options, for a human to choose between

1. **Move the store off the Keychain and into a file under the denied home directory.** `denyRead` demonstrably works on files — that is the same mechanism that makes `$HOME` unreadable in the measurement above. It trades the Keychain's at-rest encryption for a denial that is actually enforced. Worth being honest that a plaintext file readable by any *unsandboxed* process on the machine is a different threat model, not a strictly better one.
2. **Get an execute denial.** `srt` does not express one today. This is upstream work or a fork, and it fixes `osascript` and `open` at the same time — which the file-based option does not.
3. **Change the claim and keep the design.** The agent handles names and never needs a value; that is worth having even when it is not enforced. `README.md` and `PRODUCT.md` would say the Sandbox contains the filesystem and the network, and that secret handling is a design the agent has no reason to defeat rather than a wall it cannot climb.

Option 3 is not a cop-out and can be combined with either of the others — the claim has to be corrected regardless, because it is false today. Options 1 and 2 change what is true; option 3 changes what is said.

- [ ] The choice is made and recorded in ADR-0003 and ADR-0006
- [ ] `README.md` and `PRODUCT.md` describe the boundary that was measured, not the one that was intended
- [ ] The inverted assertion in `packages/harness/src/sandbox.boundary.test.ts` is updated — it currently asserts the hole exists, so it must go red when the hole closes and be rewritten when the claim changes instead
- [ ] Ticket 10's third criterion and ticket 01's third criterion are re-stated to match whatever is now true

Relates to stories 16, 17, 19, 20 and to ticket 13, which documents where confinement stops and cannot be written until this is settled.
