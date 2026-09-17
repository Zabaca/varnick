# XState stays; the apparatus around it goes

Machines are written with XState 5, latest, for anything whose state can be in flight or fail: Landing, a Session's lifecycle, a Restart. A list is not a Machine. Each ships with a headless test that drives its actor through the Door. A state is named in its Machine and nowhere else.

Not carried over from the previous version: the states page and its coverage check, the staged workflow with gates, the script that policed surface briefs, the bare page, and a decomposition ADR per feature. Those were the friction; the machine was the value. A states page returns only if someone wants to see every state at once, which is a want you notice rather than a rule to enforce.
