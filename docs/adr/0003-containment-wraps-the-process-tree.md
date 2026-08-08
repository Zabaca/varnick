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
/usr/bin/osascript -e '1+1'                    -> 2
/usr/bin/sudo -n true                          -> Operation not permitted
```

Two separate things were assumed to be one. `srt`'s generated macOS profile contains an unconditional `(allow process-exec)`, and `denyRead` emits `file-read-data` denials; `execve` is a different operation and is not covered. `sudo` fails for its own reason — it is setuid, and that needs more than exec.

Denying the keychain *files* does not help either. `security` does not read them; it asks `securityd` over Mach, and `srt`'s policy has no surface for Mach services.

- **The Keychain is reachable from inside the sandbox, and both things kept there are affected.** The credential ([ticket 02](../../.scratch/harness/issues/02-credential-read-and-injection.md)) and the Secrets Store ([ADR-0006](./0006-agents-author-secret-use-never-hold-secrets.md), ticket 10) are stored there because this ADR said the agent could not reach them. Host-side injection remains the right shape — the agent still never *needs* the Keychain — but it is no longer what stops it.
- **Adding entries to `DENIED_BINARIES` cannot close it.** That list is `denyRead`, and `denyRead` is the mechanism that failed. Closing it needs an execute deny `srt` does not currently express, or storage that is a file under the denied home directory rather than a daemon behind an IPC boundary.
- **The measurement lives in `packages/harness/src/sandbox.boundary.test.ts`**, as an inverted assertion against the real kernel. It goes red the day this closes, which is when these paragraphs get deleted.

This adopts the design and the measurements from `zbc/packages/agent/docs/adr/0002-containment-wraps-the-cli-process.md`.
