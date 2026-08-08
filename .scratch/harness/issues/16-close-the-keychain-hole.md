# 16 — Make the Keychain protection deliberate, and fix what deny-by-read does not cover

**What to build:** The Keychain turns out to be protected, but by accident rather than by design, and the reasoning written down for it was wrong twice. This ticket makes the protection intentional and tested, and deals with the parts that genuinely are not covered.

**Blocked by:** None. The measurements exist and the load-bearing assertion is already written.

**Status:** ready-for-agent

**Realizes:** no state path.

## What was actually measured

Ticket 10 set out to prove the Secrets Store unreadable from inside the Sandbox, measured the opposite, and correctly refused to weaken the policy to make its test pass. Its setup used a throwaway keychain in `/private/tmp` — a *readable* location — so what it proved was "a keychain in a readable place can be read", not "the login Keychain can be read". Repeated with the same item in both locations:

```
keychain in /private/tmp (readable)        -> the value, in plaintext
keychain under $HOME (denyRead)            -> not found
security list-keychains  (inside sandbox)  -> only /Library/Keychains/System.keychain
cat ~/Library/Keychains/login.keychain-db  -> Operation not permitted
```

**The login Keychain is not even in the sandboxed search list.** `denyRead` on `$HOME` is what does it, because that is where the file lives. Both things varnick stores there — the credential and the Secrets Store — are covered. Removing `com.apple.securityd.xpc` from `srt`'s Mach allowlist changes nothing; that was measured too, and the allowlist is not the mechanism.

## What is genuinely not covered

1. **Denying a binary by denying read does not stop it executing.** `security`, `osascript` and `open` all run. `sudo` does not, for its own setuid reason. The Security framework also links in-process, so no binary is required to reach the Keychain API — the deny list was never going to be the thing that worked.
2. **`/Library/Keychains/System.keychain` is readable and dumpable from inside.** System certificates rather than user secrets, but "the Keychain is protected" is too broad a sentence to leave standing on its own.
3. **The protection is incidental.** Nothing was designed to put the Keychain out of reach; it is out of reach because of where Apple stores it. `packages/harness/src/sandbox.boundary.test.ts` now asserts the login Keychain stays invisible, so a policy change that reopens it fails loudly rather than silently.

## Why this matters right now

Ticket 03 has to widen `allowRead` so a runtime under `~/.bun` or `~/.nvm` can be executed — unreadable today for exactly the same reason the Keychain is. **A wide enough addition there removes the Keychain's protection as a side effect.** The addition must be narrow, must not be an ancestor of the denied binaries, and must leave the boundary test green.

- [ ] `DENIED_BINARIES` is renamed or re-commented so it does not read as an execute denial — it is a read denial and that is all it is
- [ ] Whether an execute denial is worth pursuing in `srt` is decided and recorded; it would fix `osascript` and `open`, and would do nothing for the Keychain
- [ ] `System.keychain` readability is either denied or written down in ticket 13
- [ ] `README.md` and `PRODUCT.md` describe the boundary that was measured — including that the Keychain protection follows from `denyRead` on `$HOME` rather than from the deny list
- [ ] The boundary test's login-Keychain assertion survives whatever ticket 03 adds to `allowRead`

Relates to stories 16, 17, 19, 20, and to ticket 13, which writes down where confinement stops.
