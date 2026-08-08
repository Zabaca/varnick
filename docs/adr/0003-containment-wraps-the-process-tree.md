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
- **Denying `security` breaks Keychain authentication, which is the point.** An agent that can authenticate from the Keychain is an agent that can read every item in it. Tauri's main process reads the credential host-side and injects it as an environment variable into the sandboxed subprocess instead.
- **Any allowed network host is an exfiltration path.** The allowlist bounds blast radius, not data egress, and the README says so.
- **varnick never spawns a Claude Code process outside `srt` — not even to ask it a question.** The SDK's `query()` starts a Claude Code executable, and a session runs `SessionStart` hooks from the clone's `.claude/settings.json`, which the agent can write. So a host-side session — however short-lived, however read-only its intent — executes agent-authored code unconfined. Found while wiring plan usage, where reading a number needed a session and the obvious implementation opened its own. Any SDK control request must ride the confined session rather than open a second one. This is the rule most likely to be broken by accident, because the code that breaks it does not look like it starts an agent.

## Correction: denying read does not deny execution

The line above was an inference, not a measurement, and it is wrong. Measured on Darwin 25.5 with `srt` 0.0.67, under the policy `sandboxPolicyFor` generates:

```
cat /usr/bin/security                          -> Operation not permitted
/usr/bin/security find-generic-password ...    -> exit 44, securityd's own "item not found"
/usr/bin/security <read an item stored by us>  -> the value, in plaintext, exit 0, no prompt
/usr/bin/osascript -e 'return 6*7'             -> 42
/usr/bin/open --help                           -> open's own usage error, so it ran
/usr/bin/sudo -n true                          -> Operation not permitted
cat "$HOME/.zshrc"                             -> Operation not permitted
curl https://example.com                       -> no route, timed out
```

Three of the four denied binaries execute. `sudo` is the exception and fails for its own reason — it is setuid, which needs more than exec. The last two lines are the half that does hold, and they are the reason this is a correction rather than a retraction: **filesystem and network containment work.** `$HOME` is unreadable and an unlisted host is unreachable, both measured the same way on the same run.

Two separate things were assumed to be one. `srt`'s generated macOS profile contains an unconditional `(allow process-exec)`, and `denyRead` emits `file-read-data` denials; `execve` is a different operation and is not covered. `sudo` fails for its own reason — it is setuid, and that needs more than exec.

Denying the keychain *files* does not help either. `security` does not read them; it asks `securityd` over Mach IPC, and the keychain files are that daemon's private storage.

**The binary is not the mechanism, and denying binaries could never have closed this.** The Security framework is linkable in-process, so any program the agent writes reaches `securityd` without `/usr/bin/security` existing. Measured:

```
python3 -c "ctypes.CDLL(find_library('Security'))"  -> loaded, SecItemCopyMatching resolves
```

**Where it actually comes from.** `srt`'s profile opens `(deny default)` and allowlists Mach services individually, under a comment reading *"specific services only (no wildcard)"*. `com.apple.securityd.xpc` is on that allowlist. The keychain is reachable because it is permitted by name, not because Mach went unconsidered — which makes this a narrower and more fixable problem than "the sandbox does not cover IPC".

A later `(deny mach-lookup (global-name "com.apple.securityd.xpc"))` would close it, since later rules win in SBPL. Two things to establish before anyone does: what else needs `securityd` — TLS trust evaluation and code-signing checks go through it, and `srt` separately gates `com.apple.trustd.agent` behind `enableWeakerNetworkIsolation`, which suggests the trust path is deliberately distinct — and where the rule would live, because `srt`'s config surface is `network` and `filesystem` only, with no hook for extra profile rules. That means upstream or a fork.

- **The Keychain is reachable from inside the sandbox, and both things kept there are affected.** The credential ([ticket 02](../../.scratch/harness/issues/02-credential-read-and-injection.md)) and the Secrets Store ([ADR-0006](./0006-agents-author-secret-use-never-hold-secrets.md), ticket 10) are stored there because this ADR said the agent could not reach them. Host-side injection remains the right shape — the agent still never *needs* the Keychain — but it is no longer what stops it.
- **Adding entries to `DENIED_BINARIES` cannot close it.** That list is `denyRead`, `denyRead` is the mechanism that failed, and the binary is not the route anyway. An execute denial would fix `osascript` and `open`; it would not fix this.
- **Two things would fix this one.** Denying `com.apple.securityd.xpc` at `mach-lookup`, which needs an `srt` change and a measurement of what else breaks. Or storage that is a file under the denied home directory rather than a daemon behind an IPC boundary — `denyRead` is enforced per file by the kernel, so no API call routes around it, which is the same reason `$HOME` is unreadable above.
- **The measurement lives in `packages/harness/src/sandbox.boundary.test.ts`**, as an inverted assertion against the real kernel. It goes red the day this closes, which is when these paragraphs get deleted.

This adopts the design and the measurements from `zbc/packages/agent/docs/adr/0002-containment-wraps-the-cli-process.md`.
