# Spike: the terminal stack under Seatbelt

Not part of v1. There is no kernel sandbox in v1 and no code here is imported by
the Host (ADR-0004). This exists to answer the one fact a returning sandbox would
need: does ttyd's websocket still work when the command a Session runs is wrapped
in Seatbelt, and does the shell inside still refuse to write outside its Worktree?

```
deno task --config spikes/seatbelt-terminal/deno.json probe
```

Needs macOS (Seatbelt), `brew install ttyd zmx`, and network access for `npx` to
fetch `@anthropic-ai/sandbox-runtime`. It makes a temp directory, a uniquely named
zmx session and a ttyd on an ephemeral loopback port, and removes all three. On
anything but macOS it prints a skip and exits 0.

The shape it probes is the one `Wrap` would produce: ttyd and the zmx server run
unconfined on the Host, and only the Session's command is wrapped. The answer is
recorded in `.scratch/v1/spec.md` under Further Notes.
