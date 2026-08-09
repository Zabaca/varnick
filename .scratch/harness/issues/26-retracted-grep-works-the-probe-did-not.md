# 26 — RETRACTED: Grep works. The probe did not.

**Status:** invalid — the defect did not exist. What survives is at the bottom, and it is worth more than the ticket was.

**Blocked by:** None.

**Realizes:** no state path.

## What this ticket claimed, and why it was wrong

It claimed the agent's `Grep` and `Glob` tools were refused everywhere, including inside the clone, because `rg` is the Claude Code executable under `$HOME` and `denyRead` makes that binary unrunnable.

**Grep and Glob work. They always did.** The probe's control failed, and the control was wrong. What the tool actually returned:

```
"Found 1 file\n.varnick-probe-inside-74647/probe.txt"
```

That is a successful Grep. `Grep` and `Glob` answer with paths **relative to the working directory**; the probe checked `text.includes(absolutePath)` and so read a working tool as a denied one. `Read` was unaffected because it answers with contents and the marker matched — which is why exactly one control passed and two failed, a pattern that looked like evidence for the wrong story.

With the comparison fixed, every control passes and every denial still holds:

```
Read  outside                      denied
Grep  outside                      denied
Glob  outside                      denied
Read  inside  (control)            permitted
Grep  inside  (control)            permitted
Glob  inside  (control)            permitted
```

## The chain that produced a fictional defect

Worth writing out, because every step was plausible:

1. A control failed. Rather than reading what the tool answered, the failure was taken as the tool being broken.
2. A real and unrelated measurement — the Claude Code binary cannot run under `denyRead $HOME`, which is true — was to hand, and fitted.
3. `rg` really is that binary when invoked from a shell, which tightened the story.
4. This ticket was written, a fix was chosen, and `@vscode/ripgrep` was installed and tested against a defect that was not there. It has been removed.

What broke the chain was not a better hypothesis. It was printing the string the tool returned, which took one edit and should have been the first thing done.

## What survives, and it is the valuable part

**A probe that skips is a probe that is not running.** Probe 6 needs a credential and had never once executed since it was written. Behind that skip sat one real defect — ticket 27's broken Bash — and this fictional one, because an assertion nothing runs is an assertion nobody has checked.

The suite's own header says a control that can pass for the wrong reason is worse than none. This is the second control in that file to fail that test; the first was probe 7's `~/.zshrc`, fixed earlier the same day. Both were controls, and both failed toward a *false* result rather than a missed one.

## What was changed

- `agent.ts`'s tool probe matches the path in both absolute and working-directory-relative form, with the reason recorded at the comparison.
- When a tool does not reach the file the probe records **what it answered**, and probe 6 prints it. Without that, the suite can report a failure and never say what it saw.
- `@vscode/ripgrep` was added and removed. Nothing depends on it.

## The last box: a skip that a repository can hold

The suite's header rule — skip with a printed reason rather than fail, because a red suite everyone learns to ignore is worse than a skipped one — is right, and `expect(hasCredential).toBe(true)` was never the answer. A CI machine and a fresh clone legitimately have no credential; failing there produces exactly the ignored red the rule warns about.

What the rule does not cover is that a printed reason answers *"why is this skipped today"*, and nobody was asking that. The question nobody could ask was *"has this ever run at all"*, because a skip taken this morning and a skip taken every morning since the file was written are the same line of output. That is a property of the **repository**, not of the machine reading it, and a repository can hold it.

- **`packages/harness/probe-attestation.json`** is a committed record of probe 6's last end-to-end completion — date, commit, platform, and the six verdicts. `"lastCompleted": null` means nobody on any machine has ever run it, and it reads that way in review. Only a real run changes it: the probe writes it after its last assertion and there is no prose to tick. It sits under `packages/harness/**`, which the policy denies the agent write access to, so the agent cannot forge an attestation about a probe that measures the agent.
- **`bun run probe`** (`probe-cli.ts`) is where failing moved. No skip in it: wrong platform, missing dependency or missing credential all exit non-zero, and it finishes by checking that a completion was *recorded* rather than trusting the suite's exit code — probe 6 exits green when the Session never opened, and that path was previously indistinguishable from a pass.
- **`bun test packages` now fails in one new case**, and only for the person who asked for the measurement: a supported platform with a credential exported, where probe 6 did not complete. A fresh clone and CI never reach it. Verified with a deliberately invalid key — the Session ends `failed`, probe 6 stops, and the suite goes red where it used to go green.
- **The banner moved.** `if (blocked) console.log(...)` at the bottom of the file ran at module *evaluation*, before probe 1, and was then buried under ten report blocks. It is an `afterAll` now, which is as late as the file can reach: Bun's default reporter prints nothing for a passing or skipped test, so there is no such thing as a loud skip in the summary and the last console output is the loudest position available.
- The README's *Where confinement stops* says plainly that a green suite is not a measurement of that section, and names the one claim on the page whose confirming probe has never run.

What this does **not** do: make `bun test packages` red because probe 6 has never run. That failure would be identical on every clone and on CI, clearable only by a maintainer with a credential, which is the ignored red the header forbids. The honest summary is that the skip is now visible in a committed file, in the README, and in the last thing the suite prints — and a determined reader can still scroll past all three. What cannot be scrolled past is `bun run probe`, and the README points at it from the section it qualifies.

- [x] The path comparison is fixed and probe 6 passes end to end under a real credential
- [x] The probe records what a tool answered when it did not reach the file
- [x] `bun test packages` fails, or says something loud, when the only probe that drives a real Session has never run — a printed reason was not enough, because nobody read it
