# 02 — A protected-path predicate, and a command that answers with it

**What to build:** a way to ask, of a branch, whether it may be landed without a
human — and to get a named reason when it may not. The orchestrator asks this
before it starts a ticket, so a night is not spent authoring work that cannot be
delivered, and again before it merges.

The answer is *no* for the Fence, for the generated policy and its baseline, for
the host-invoked scripts, for the tracked hooks directory, and for a root
manifest diff that changes an install lifecycle script. It is *yes* for
everything else, including the rest of that manifest — dependencies land, the
fields that execute on the developer's machine do not.

This is the security-critical artifact of the whole feature. There are now three
lists answering three different questions: what may not be previewed
unconfined, what may not be landed unattended, and what may not be written in
the live tree. None derives from another and all three must be able to move
independently, so this ships with a test that asserts how they relate rather
than a comment that describes it.

This is a Fence change and lands through a human merge.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A pure function answers, from a set of changed paths and the before/after install lifecycle fields of the root manifest, whether the change may land unattended
- [ ] A refusal carries which rule refused it, in terms a report can print
- [ ] The function is exported from the module that already holds the Fence question, and imports nothing that would stop it running headlessly
- [ ] A command runs it against a branch and prints the verdict
- [ ] Tests cover every protected entry, the sibling paths that must not match them, a manifest diff that only changes dependencies, and a manifest diff that changes a lifecycle script
- [ ] A test asserts the containment relationship between the three lists, and fails if a future entry breaks it
- [ ] An ADR records why the auto-merge list is separate from the Fence list and from the sandbox's own denials, and why they are not derived from one another
