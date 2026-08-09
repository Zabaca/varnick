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

  **There is now a way to ask, which is what makes the rule keepable** *(ticket 05)*. The rule was stated before anything could obey it: the agent process was spawned with `stdin` closed and its output uncaptured, so a caller that needed an answer from the session had no way to get one except by opening its own. The agent host's stdin and stdout are now pipes carrying newline-delimited JSON, and a Turn is a control request on them — `run-turn`, `interrupt`, and the events that come back. Anything else that needs the session, plan usage included, is a kind on that channel rather than a second `query()`. A rule with no mechanism behind it is a rule that gets broken by whoever needs the thing next.

  **And plan usage now uses it** *(ticket 09, the second half)*. `read-plan-usage` is the third kind on that channel; the type it belongs to is called `ControlRequest` rather than `TurnControl`, because the channel carries control requests of which a Turn is two. `readSubscriptionUsage` runs *inside* the confined process, against the session `runAgentHost` already holds, and only the two figures come back out. Nothing on the host side ever holds a `Query`.

  **The corollary is the part worth writing down, because it is the part that looks like a bug.** With no agent running there is no session, so the read *refuses*. It does not start one to have something to ask — that would put a Claude Code process on the host at the moment a developer glanced at a usage figure, which is a worse version of the original mistake rather than a smaller one. A refused read leaves whatever was last measured, which before the first run is nothing, and the strip renders nothing rather than a plausible number. `a_read_with_no_agent_running_refuses_rather_than_starting_one` in src-tauri/src/agent.rs is what holds that shut, and it needs no process precisely because the answer is that there is none.

  **The mechanism has now been used, which is the part that was untested** *(ticket 08)*. Compaction is the second kind on that channel — `compact`, carrying a Turn id and nothing else — and it is the case that most wants a second session: summarising is a model call, the host has an SDK, and `query()` with "summarise the following" is four lines. It would also not work, and that is worth writing down beside the rule, because it is the argument that survives someone deciding the rule is inconvenient: a summary produced by a session that is not *this* session frees no context at all. The context that is full belongs to the agent process, and the only thing that can compact a conversation is the thing holding it. A control request is not the safe way to do this; it is the only way it does anything.

  Two consequences of that, both narrow. The command the confined process runs is a constant in `packages/harness/src/turn.ts` rather than a field on the request, so no prompt crosses the bridge and there is nothing to smuggle through the one control kind that would otherwise want free text. And the port the loop drives the Session through grew a fifth method, `contextTokens()` — a read with no argument, answered by the SDK's `getContextUsage()` on the same session. Its alternative was a context meter showing a figure nobody measured.


## First correction: what actually protects the Keychain

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

**Pursuing an execute denial in `srt` is not worth it, and the list stays.** The knob does not exist: `(allow process-exec)` is a literal in `generateSandboxProfile` in `dist/sandbox/macos-sandbox-utils.js`, and `SandboxRuntimeConfigSchema` has no exec-related field at all, so getting one means changing `srt` upstream and then carrying a fork or a wait. What that buys is bounded and small. It does nothing for the Keychain, which is the thing anyone would want it for, because the Security framework links in-process — the agent writes forty lines of Swift and never touches `/usr/bin/security`. It does not close `open` or `osascript` either, only makes them louder: `allowAppleEvents: false` already denies `appleevent-send` and `lsopen`, which is what actually stopped them doing damage, and probe 9 is where that is measured rather than assumed. A program the agent compiles can call `NSWorkspace` the same way. An execute allowlist is a real boundary against a program that *runs* something; against a program that *is* something it is a speed bump, and every process the agent needs — `git`, `bun`, the compiler — has to be on the allowlist anyway. So: not pursued. `UNREADABLE_BINARIES` keeps its four entries, because a binary the agent cannot open is one it cannot copy or patch and these four are worth seeing in a violation log, and the name and the comment now say that is all it is. Revisit only if `srt` grows the option for its own reasons.

**The Keychain is protected regardless, and not by any of that.** The same item, in two keychains differing only in location:

```
keychain in /private/tmp (readable)  -> the value, in plaintext
keychain under $HOME (denyRead)      -> not found
security list-keychains              -> only /Library/Keychains/System.keychain
cat ~/Library/Keychains/login.keychain-db -> Operation not permitted
```

The login Keychain is invisible from inside the Sandbox. What gates it is `denyRead` on `$HOME` — the same kernel-enforced file denial that covers SSH keys and any repository kept under a home directory — because that is where the Keychain file lives. Both things varnick stores there, the credential and the Secrets Store, are covered.

Removing `com.apple.securityd.xpc` from `srt`'s Mach allowlist changes none of the above. It was measured because the allowlist looked like the cause; it is not.

- **The protection is incidental, not designed, and that is the risk worth carrying.** It holds because the Keychain happens to live under a denied path. Any future read-allow covering `$HOME` silently re-opens it — and there is real pressure toward exactly that, since a runtime installed under `~/.bun` or `~/.nvm` is unreadable for the same reason. Whatever is added must be narrow, and `packages/harness/src/sandbox.boundary.test.ts` asserts the Keychain stays unreachable so that widening it fails loudly.
- **`osascript` and `open` still execute.** Apple Events are denied, which removes the worst of it and is measured by probe 9, but the deny-by-read reasoning does not work and should not be relied on anywhere else.

## Second correction: the other keychain was not covered, and now is

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

## Third correction: the fix above did not reach this repository

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

## A further correction to the first: `sudo` is not stopped by the denied list either

*Not an ordinal of its own — it corrects one sentence of the first correction, and the numbered run below continues from the third.*

The sentence above — sudo is refused "setuid, its own reason" — was still reasoned rather than measured. `packages/harness/src/containment.probe.test.ts` measures it, by generating the same policy with all four `UNREADABLE_BINARIES` entries lifted out of `denyRead` into a throwaway clone and running the probe against that. Darwin 25.5, `srt` 0.0.67:

```
                          denied list on      denied list lifted
/usr/bin/security  read   not permitted       the binary's bytes
/usr/bin/sudo      read   not permitted       Permission denied   (EACCES, not EPERM)
/usr/bin/sudo      exec   not permitted       not permitted
```

Two things follow. Sudo's refusal survives removing every entry, so `denyRead` is not what causes it. And sudo is mode `-r-s--x--x`, unreadable to every non-root process on the machine before any policy applies — so its entry in `UNREADABLE_BINARIES` denies nothing that was not already denied, and the two different errnos are the tell.

The list is kept anyway. It does deny the *contents* of `security`, `osascript` and `open`, which is worth having; what it never did was deny execution. Removing entries to make the documentation true would be editing the fence to fit its label.

## Fourth correction: reads are allow-by-default, so a repository outside a home directory was never covered

Three documents said the Sandbox put "other repositories" out of the agent's reach. It puts repositories *under a home directory* out of reach, which is where they usually are and not where they have to be. `denyRead` is a deny list — `/Users`, the home directory inside it, `/Library/Keychains`, and four binaries — and `srt` reads everything not on it. `allowWrite` is the opposite shape, a genuine allowlist naming the clone and the OS temp directory, which is why the two halves of the boundary do not describe each other.

Probe 7 in `containment.probe.test.ts` is the measurement. A git repository planted outside every home directory:

```
read  secret.txt              READABLE — exit 0
read  under $HOME  (control)  denied — exit 1
write into it                 refused — exit 1
```

The control is the point: the same read is refused under `$HOME`, so this is about location and not about a broken wrapper.

**Probe 2b had already shown this and nobody read it that way.** Lifting `/usr/bin/security` out of `denyRead` only makes `cat` succeed if `/usr` was readable all along, which it was. A measurement can sit in the output of a green suite for a release without being seen, because it was taken to answer a different question.

**Nothing is widened or narrowed here; what changed is what is claimed.** `sandbox.ts` says which shape it uses at the `denyRead` list, `README.md` states the asymmetry under *Where confinement stops* rather than implying a filesystem-wide boundary, and ADR-0002 no longer says the protection covers repositories generally. The fix for a repository on `/opt`, `/srv`, `/Volumes` or an external disk is to add the path to `denyRead` yourself.

**Whether reads should be deny-by-default at all is open, and is a decision rather than an implementation.** `srt`'s filesystem config accepts a `denyAllExcept` shape; inverting the boundary is strictly stronger and would have made three of this project's four wrong turns impossible to make. The cost is that an interpreter, its standard library, `git`, the system libraries every process links, and the CA bundle all have to be reachable and are not in one place, and an allowlist that is nearly right fails as a startup error with no obvious cause. Ticket 18 holds the trade-off and stays `needs-info` until someone weighs it; a deny-by-default policy that has not started an agent would not be evidence of anything.

### Two things the inversion needs first, and they are in

Both are prerequisites rather than the inversion, and neither changes what the Sandbox permits today.

**varnick now hears the kernel.** `srt` has watched the deny log all along — `startMacOSSandboxLogMonitor`, which nothing here called — so a missing allowlist entry was `exit 133` and nothing else. `establishSandbox` starts the monitor once the restrictions are real and prints an unexpected denial to stderr, the same channel and the same reason as the policy report beside it: `src-tauri/src/bridge.rs` inherits it, and the alternative is a file nobody opened. A correct policy prints nothing, which took a filter, because the noise floor is not zero:

```
one command run under the policy   3 denials
  sysctl-read kern.iossupportversion   2   (the wrapping shell, and the command)
  file-read-data  ~/.zshrc              1   (the fence working)
  reported to the developer             0
```

Silent are: anything that is not a read — `sysctl-read` twice per command, `network-outbound` under `strictAllowlist`, `appleevent-send` under `allowAppleEvents: false` — and any read under a path `denyRead` *names*. The filesystem root is deliberately not one of those names, which is the part written for the inversion: `denyRead: ['/']` puts every path under a denial, and a filter asking only "is this denied?" would go quiet at exactly the moment it becomes the only thing saying why the agent will not start. Probe 10 measures both halves, with the same real denial classified against a policy that never denied `$HOME` as the control.

**And the read allowlist is computed rather than written down.** `readAllowlistFor` in `packages/harness/src/sandbox.ts` derives the interpreter's install root from `process.execPath`, the SDK's tree from `agentSdkEntry()`, and the developer toolchain from `developerToolsBin()` — `git` on macOS lives under Xcode or under the Command Line Tools, and those are different trees. `~/.bun` is the whole argument: this machine's interpreter is there, the next machine's is under Homebrew or nvm, and a constant would be right here and `exit 133` there. Only `MEASURED_SYSTEM_READ_PATHS` — `/usr`, `/bin`, `/System`, `/Library`, `/etc`, `/dev`, `/private/var/db`, `/private/var/select` — stays a constant, and each was verified load-bearing by dropping it and watching the agent fail.

**It is deliberately not in the policy, and that is the load-bearing judgement.** Under allow-by-default reads it is a pure weakening: every path on it is already readable, so it permits nothing new, while `allowRead` beats `denyRead` — `/usr` hands back all four `UNREADABLE_BINARIES` and `/Library` hands back `/Library/Keychains`, the directory the second correction denied after dumping 37 generic passwords out of it. All cost, no benefit. `sandbox.test.ts` asserts exactly that overlap, so wiring the list in fails there with the reason rather than in a probe with a keychain dump. The inversion cannot be "add these lines": it has to restore those denials some other way in the same change.

## What the probes measure, and what they do not

`containment.probe.test.ts` is ticket 04. Ten probes and one variant, each with a positive control beside it, run against the real policy on the real machine. The list is written from the suite's printed output, because the previous version of it was written from memory and named five:

1. one file under `$HOME`, asked for four ways — `Bash`, and the `Read`, `Grep` and `Glob` *shapes* run in-process inside the real agent entry. All four denied; all four permitted against the same file inside the clone.
2. every `UNREADABLE_BINARIES` entry, read and executed, with the same command run unconfined as the control.
   - **2b**, the variant: the same policy with all four entries lifted out into a throwaway clone, which is what shows the list is not what stops `sudo`.
3. an allowlisted host answers; an unlisted one gets `CONNECT tunnel failed, response 403`.
4. a clone whose policy the schema rejects raises rather than proceeding.
5. the write boundary — Core, the Harness, the root `package.json`, the generated policy and a root `vite.config` refused, with Userspace, its own manifest and the OS temp directory writable in the same run.
6. the SDK's *own* `Read`, `Grep` and `Glob` tools, driven by a real Session.
7. a git repository outside every home directory: readable, and refused a write.
8. `/Users` and `/Users/Shared` — the root above every home directory, and a path under it that is under no home directory.
9. Apple Events and Launch Services: an event only a running application can answer is refused, and so is `open`.
10. the violation monitor: the kernel's denials reach varnick, and none of them is said out loud while the policy is correct — with the same real denial, classified against a policy that never denied `$HOME`, as the control that proves the channel is not simply dead.

Probe 6 is the only one needing a credential, and it skips with a printed reason without one. That is a real gap and it is named here rather than papered over: probe 1 runs the syscalls those tools make, in the agent process, under the same kernel policy and inside the same process tree — which is why it is the load-bearing measurement and probe 6 is confirmation. There is deliberately no faked substitute, because the Sandbox denies local binding and every unlisted host, so a stub API is unreachable from inside and widening the policy to reach one would be widening the policy to make a probe pass.

Probe 9 is worth one more sentence, because it is the probe most likely to be re-run and misread. AppleScript answers a *static* property of an application specifier — `get name`, `get version` — out of the target's bundle, sending no event; those succeed inside the Sandbox. Only a round trip measures anything, which is why the probe asks Finder to count its windows and System Events to list processes.
