# The agent never holds the Credential

The Credential lives in `secrets.yaml`, sops-encrypted to an age key under your home, and the Host decrypts it with `sops -d` at launch. The agent's environment carries a placeholder and `ANTHROPIC_BASE_URL` pointing at the Host's loopback Proxy, which swaps the placeholder for the Credential on the way out. An `env` dump, a logged config or a pasted environment yields nothing usable. With no kernel sandbox (ADR-0004) this is protection against accident, not against an agent that goes looking for your age key.

Considered: injecting the real token into the agent's environment, which is what the previous version did and what leaves it one `env` away; the macOS Keychain, which needs an index item and shell-outs for one file's worth of benefit; the TLS-terminating MITM proxy from `zabaca/claude-mitm-proxy`, which covers every host and not just the API but needs a local CA in the agent's environment. The reverse proxy is the smallest thing that keeps the token out, and the MITM form is the recorded upgrade if egress ever needs gating.

## Amendment, 2026-09-17: the Proxy is opt-in

The Proxy runs only when `secrets.yaml` is present at launch. Without one the Host injects no credential, sets no `ANTHROPIC_BASE_URL` and no placeholder, and Claude Code authenticates the way it does anywhere else: `/login` once inside a Session, the token kept in the agent's home under `.varnick/claude` (ADR-0009). The Snapshot of `host` says which mode is in force.

This is the day-one path for anyone cloning the repo, and it matches a subscription login rather than requiring `claude setup-token`. Considered and rejected: "off" meaning the real Credential goes into the agent's environment, which keeps every cost of the Secrets file while giving up the one thing the Proxy buys. A launch that finds `secrets.yaml` and cannot decrypt it still stops, because a file that exists and cannot be read is a choice the launch cannot make out.
