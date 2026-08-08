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
- **Denying execution means denying read.** `srt` has no execute allowlist, so a binary is blocked by making it unreadable. `/usr/bin/security`, `/usr/bin/osascript`, `/usr/bin/open`, and `/usr/bin/sudo` are denied. **This does not work, measured while building ticket 10 — see the correction below.**
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
- **`/Library/Keychains/System.keychain` is readable and dumpable from inside.** System certificates, not user secrets. Recorded because "the Keychain is protected" is otherwise too broad a sentence to be true.
- **`osascript` and `open` still execute.** Apple Events are denied, which removes the worst of it, but the deny-by-read reasoning does not work and should not be relied on anywhere else.

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
