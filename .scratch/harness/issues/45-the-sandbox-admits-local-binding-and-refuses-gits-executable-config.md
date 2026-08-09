# 45 — The Sandbox admits local binding and refuses git's executable config

**What to build:** The agent can run a dev server, a test server and a headless browser. It cannot arrange for code to execute on the developer's machine through a path no diff shows.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## Two changes, one file, opposite directions

They ship together because they are the same file and the same test, and because shipping only the first would be a widening with no compensating close.

**`network.allowLocalBinding: true`** — [ADR-0015](../../../docs/adr/0015-the-agent-binds-local-ports.md). It was `false` with no comment beside it, unique in a file where every other field carries its argument: srt's default, carried through, never decided. It cost the agent the whole of its ability to observe its own work.

Measured in srt 0.0.67, the flag adds three Seatbelt rules, and srt's own comments say the egress allowlist is deliberately preserved under it (issues #225, #88). What it does grant is ingress on any interface — the bind rule is `local ip "*:*"`, not loopback, because dual-stack runtimes bind `127.0.0.1` as `::ffff:127.0.0.1` and Seatbelt's `localhost` token does not match it — and loopback egress. Neither reaches the Harness or the Tauri host, which speak NDJSON over stdio.

**`.git/hooks/**` and `.git/config` join `denyWrite`** — [ADR-0016](../../../docs/adr/0016-gits-own-directory-is-outside-the-review-path.md). `.git` is not versioned, so it is in no diff and no merge. A written `pre-commit` runs unconfined on the next commit — including the merge commit that was supposed to be the gate. `.git/config` goes with it for two reasons: it holds `core.hooksPath`, so denying the directory alone is decorative, and it defines the `filter.<name>.clean`/`.smudge` commands that `.gitattributes` invokes.

Then set `core.hooksPath` to a tracked `.githooks/`, which is what husky and lefthook do. Hooks come back **better** than they were — as tracked files they travel through the merge and a human reads them, which was never true of `.git/hooks`.

## Watch for

- **The boundary assertions in `sandbox.boundary.test.ts` may only be strengthened.** Never weaken one to make a claim pass.
- **`git worktree add` does not write `.git/config`** — measured, md5 identical before and after. If a test suggests otherwise, the test is describing something else. What a worktree needs is `.git/worktrees/**`, `.git/objects/**`, `.git/refs/**`, none of them denied.
- The generated policy has a baseline beside it. A strengthening must reach existing clones (ticket 17's rule) — check what the new `denyWrite` entries do to a clone whose baseline predates them.
- Say in the policy's own comment block what `allowLocalBinding` grants and what it does not. Someone will read that file before they read the ADR.

- [ ] The agent can bind a local port and serve over it
- [ ] The network allowlist is unchanged, and a request to an unlisted host is still refused
- [ ] A write to `.git/hooks/pre-commit` is refused by the kernel
- [ ] A write to `.git/config` is refused by the kernel
- [ ] `git worktree add`, `git commit` and `git merge` still work inside the clone
- [ ] `core.hooksPath` resolves to a tracked directory, and a hook placed there runs
- [ ] The policy's comment block explains both changes
