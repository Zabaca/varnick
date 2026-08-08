# Containment wraps the agent's process tree, not each Bash command

The Claude Agent SDK ships a `sandbox` option that looks like a boundary and is not: it restricts commands the agent *shells out to*, while `Read`, `Grep`, `Glob`, `Write`, and `Edit` run inside the process without ever shelling out, so nothing hands them to the kernel. We therefore run the agent under `@anthropic-ai/sandbox-runtime` (`srt`), the same engine applied to the whole process tree, which covers every tool by construction including ones added later.

Measured in `zbc/packages/agent` against SDK `0.3.220` on macOS, with `denyRead: [$HOME]` set:

```
Bash  cat ~/.zbc-read-probe/secret.txt  -> Operation not permitted
Read  ~/.zbc-read-probe/secret.txt      -> the file's contents
Grep  ~/.zbc-read-probe                 -> the file's contents
```

## Consequences

- **The two mechanisms cannot be combined.** The kernel refuses `sandbox_apply` inside an existing sandbox, so leaving the SDK's `sandbox` option enabled kills every Bash command with exit 71. The SDK option stays off.
- **Four binaries are made unreadable, and three of them run anyway.** `/usr/bin/security`, `/usr/bin/osascript`, `/usr/bin/open`, and `/usr/bin/sudo` are in `denyRead`. This was written down as "denying execution means denying read" and believed for two rounds; it is false, and the list is now called `UNREADABLE_BINARIES` so the name cannot carry the claim. It is a tripwire, not a boundary — see the correction below.
- **The agent must not be able to authenticate from the Keychain**, because an agent that can is an agent that can read every item in it. Tauri's main process reads the credential host-side and injects it as an environment variable into the sandboxed subprocess instead. This holds, but *not* because `security` is denied — see the correction below for what actually does it.
- **Any allowed network host is an exfiltration path.** The allowlist bounds blast radius, not data egress, and the README says so.
- **varnick never spawns a Claude Code process outside `srt` — not even to ask it a question.** The SDK's `query()` starts a Claude Code executable, and a session runs `SessionStart` hooks from the clone's `.claude/settings.json`, which the agent can write. So a host-side session — however short-lived, however read-only its intent — executes agent-authored code unconfined. Found while wiring plan usage, where reading a number needed a session and the obvious implementation opened its own. Any SDK control request must ride the confined session rather than open a second one. This is the rule most likely to be broken by accident, because the code that breaks it does not look like it starts an agent.

## Correction: what actually protects the Keychain

Two rounds of this were wrong before it was measured properly, so the measurement is written out in full. Darwin 25.5, `srt` 0.0.67, under the policy `sandboxPolicyFor` generates.

**The execution claim is false.** Denying read does not deny execution:

```
cat /usr/bin/security               -> Operation not permitted
/usr/bin/security ...               -> runs
/usr/bin/osascript -e 'return 6*7'  -> 42
/usr/bin/open --help                -> open's own usage error, so it ran
/usr/bin/sudo -n true               -> Operation not permitted (setuid, its own reason)
```

`srt`'s profile carries an unconditional `(allow process-exec)` while `denyRead` emits `file-read-data` denials. Those are different operations. Denying binaries could not have worked anyway: the Security framework links in-process, so a program the agent writes reaches the Keychain API with no `/usr/bin/security` involved.

**Pursuing an execute denial in `srt` is not worth it, and the list stays.** The knob does not exist: `(allow process-exec)` is a literal in `generateSandboxProfile` in `dist/sandbox/macos-sandbox-utils.js`, and `SandboxRuntimeConfigSchema` has no exec-related field at all, so getting one means changing `srt` upstream and then carrying a fork or a wait. What that buys is bounded and small. It does nothing for the Keychain, which is the thing anyone would want it for, because the Security framework links in-process — the agent writes forty lines of Swift and never touches `/usr/bin/security`. It does not close `open` or `osascript` either, only makes them louder: `allowAppleEvents: false` already denies `appleevent-send` and `lsopen`, which is what actually stopped them doing damage, and a program the agent compiles can call `NSWorkspace` the same way. An execute allowlist is a real boundary against a program that *runs* something; against a program that *is* something it is a speed bump, and every process the agent needs — `git`, `bun`, the compiler — has to be on the allowlist anyway. So: not pursued. `UNREADABLE_BINARIES` keeps its four entries, because a binary the agent cannot open is one it cannot copy or patch and these four are worth seeing in a violation log, and the name and the comment now say that is all it is. Revisit only if `srt` grows the option for its own reasons.

**The Keychain is protected regardless, and not by any of that.** The same item, in two keychains differing only in location:

```
keychain in /private/tmp (readable)  -> the value, in plaintext
keychain under $HOME (denyRead)      -> not found
security list-keychains              -> only /Library/Keychains/System.keychain
cat ~/Library/Keychains/login.keychain-db -> Operation not permitted
```

The login Keychain is invisible from inside the Sandbox. What gates it is `denyRead` on `$HOME` — the same kernel-enforced file denial that covers SSH keys and other repositories — because that is where the Keychain file lives. Both things varnick stores there, the credential and the Secrets Store, are covered.

Removing `com.apple.securityd.xpc` from `srt`'s Mach allowlist changes none of the above. It was measured because the allowlist looked like the cause; it is not.

- **The protection is incidental, not designed, and that is the risk worth carrying.** It holds because the Keychain happens to live under a denied path. Any future read-allow covering `$HOME` silently re-opens it — and there is real pressure toward exactly that, since a runtime installed under `~/.bun` or `~/.nvm` is unreadable for the same reason. Whatever is added must be narrow, and `packages/harness/src/sandbox.boundary.test.ts` asserts the Keychain stays unreachable so that widening it fails loudly.
- **`osascript` and `open` still execute.** Apple Events are denied, which removes the worst of it, but the deny-by-read reasoning does not work and should not be relied on anywhere else.

## Correction, second part: the other keychain was not covered, and now is

`denyRead` on `$HOME` protects the login Keychain because of where the file sits. `/Library/Keychains` sits nowhere near a home directory, so nothing covered it. It was recorded here as readable and described as "system certificates, not user secrets". That description was wrong. Dumped from inside the Sandbox, before any change:

```
security dump-keychain /Library/Keychains/System.keychain | wc -c   -> 30902
security dump-keychain /Library/Keychains/System.keychain | grep -c genp -> 37
cat /Library/Keychains/System.keychain | wc -c                      -> 97088
```

The 37 are generic passwords, and their labels are the Wi-Fi networks this machine has joined. That is a repository of the developer's secrets, reachable by an agent that was told it could not reach one.

**So it is denied — the whole directory, not the one file**, which also covers `apsd.keychain` and anything an administrator installs there later. `system-keychain-2.db` is mode 0600 and root-owned, so it was never reachable anyway.

The reason this was left open rather than closed was a guess that closing it would break TLS or code signing. Measured, with `/Library/Keychains` in `denyRead` and everything else identical:

```
cat /Library/Keychains/System.keychain            -> Operation not permitted
security dump-keychain .../System.keychain | wc -c -> 0
security list-keychains                            -> unchanged
curl https://api.anthropic.com/v1/messages         -> 405   (unchanged; a status means the handshake completed)
curl https://registry.npmjs.org/left-pad           -> 200   (unchanged)
codesign -v /bin/ls                                -> CSSMERR_TP_NOT_TRUSTED
```

TLS is unaffected: the roots the handshake needs are in `/System/Library/Keychains/`, which is a different path and stays readable. `codesign -v` does fail — and fails identically *without* the deny, so it was already broken inside the Sandbox for a reason this change did not introduce and did not investigate. Nothing in varnick verifies a signature from inside the Sandbox; if something ever does, that is the measurement to start from.

`packages/harness/src/sandbox.boundary.test.ts` now asserts both halves — the keychains unreachable, and both allowlisted hosts still reachable — so a future widening cannot quietly trade one for the other.

## Correction, third part: the fix above did not reach this repository

The deny shipped and the probe for it failed on merge, in this repository, because `sandbox-policy.json` had been generated an hour earlier without it. `ensureSandboxPolicy` wrote the file when absent and read it when present, so a clone kept the policy it was born with and every strengthening reached new clones only. Deleting the file made the probe pass. **Nobody deletes that file in a real clone**, and the failure is silent from both ends: the surface says `sandbox.available`, the policy is a policy, and it is simply not the one anyone thinks is running.

The file cannot just be overwritten — it is deliberately editable, because the thing a fork most wants to change is the boundary, which is why it lives in the clone rather than in the package. Nor can a difference be refused outright: it holds absolute paths for one machine, so a clone moved between laptops or home directories differs legitimately. And a version number cannot separate "I edited this" from "the generator moved on", because both are a diff.

**So what the generator produced is recorded beside what is in force**, in `sandbox-policy.baseline.json`, and a difference is attributed rather than guessed at:

```
policy   vs. baseline    -> your edit
baseline vs. generator   -> varnick's strengthening
```

The merge is per field, not per file, so an edit to the allowlist does not hold back a denial that has nothing to do with it. A field you did not touch takes the generator's current value — that is the whole fix. A field you did touch, and varnick did not, is kept exactly. A field both moved resolves to the **stronger** of the two, never the weaker: a narrowing of yours therefore survives a strengthening of varnick's, and a widening of yours does not, and is reported so you can put it back deliberately. Everything is reported on stderr on every launch, which `src-tauri/src/bridge.rs` inherits, and the file is the last place it is said rather than the only one.

Paths are compared with the four machine roots — clone, home, users root, temp — replaced by tokens, and the baseline records the roots the policy file was last written against. That is what makes a moved clone a rewrite of the paths and not a report of tampering; without the recorded roots it reads as half of `denyRead` added and half removed, which the test caught before the code shipped.

A clone that carries a policy but no baseline — every clone in existence when this shipped — can attribute nothing, so it assumes nothing: the stronger side of every difference wins, once, and the report says why it could not do better. `packages/harness/src/sandbox.boundary.test.ts` plants exactly that clone and asks the kernel whether `/Library/Keychains` is refused, with nothing deleted by hand.

This adopts the design and the measurements from `zbc/packages/agent/docs/adr/0002-containment-wraps-the-cli-process.md`.

## Second correction: `sudo` is not stopped by the denied list either

The sentence above — sudo is refused "setuid, its own reason" — was still reasoned rather than measured. `packages/harness/src/containment.probe.test.ts` measures it, by generating the same policy with all four `DENIED_BINARIES` entries lifted out of `denyRead` into a throwaway clone and running the probe against that. Darwin 25.5, `srt` 0.0.67:

```
                          denied list on      denied list lifted
/usr/bin/security  read   not permitted       the binary's bytes
/usr/bin/sudo      read   not permitted       Permission denied   (EACCES, not EPERM)
/usr/bin/sudo      exec   not permitted       not permitted
```

Two things follow. Sudo's refusal survives removing every entry, so `denyRead` is not what causes it. And sudo is mode `-r-s--x--x`, unreadable to every non-root process on the machine before any policy applies — so its entry in `DENIED_BINARIES` denies nothing that was not already denied, and the two different errnos are the tell.

The list is kept anyway. It does deny the *contents* of `security`, `osascript` and `open`, which is worth having; what it never did was deny execution. Removing entries to make the documentation true would be editing the fence to fit its label.

## What the probes measure, and what they do not

`containment.probe.test.ts` is ticket 04. Five probes, each with a positive control beside it, run against the real policy on the real machine:

1. one file under `$HOME`, asked for four ways — `Bash`, and the `Read`, `Grep` and `Glob` *shapes* run in-process inside the real agent entry. All four denied; all four permitted against the same file inside the clone.
2. every `DENIED_BINARIES` entry, read and executed, with the same command run unconfined as the control.
3. an allowlisted host answers; an unlisted one gets `CONNECT tunnel failed, response 403`.
4. a clone whose policy the schema rejects raises rather than proceeding.
5. the SDK's *own* `Read`, `Grep` and `Glob` tools, driven by a real Session.

Probe 5 is the only one needing a credential, and it skips with a printed reason without one. That is a real gap and it is named here rather than papered over: probe 1 runs the syscalls those tools make, in the agent process, under the same kernel policy and inside the same process tree — which is why it is the load-bearing measurement and probe 5 is confirmation. There is deliberately no faked substitute, because the Sandbox denies local binding and every unlisted host, so a stub API is unreachable from inside and widening the policy to reach one would be widening the policy to make a probe pass.
