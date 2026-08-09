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

- [x] The path comparison is fixed and probe 6 passes end to end under a real credential
- [x] The probe records what a tool answered when it did not reach the file
- [ ] `bun test packages` fails, or says something loud, when the only probe that drives a real Session has never run — a printed reason was not enough, because nobody read it
