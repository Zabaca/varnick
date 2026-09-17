# The agent never holds the Credential

The Credential lives in `secrets.yaml`, sops-encrypted to an age key under your home, and the Host decrypts it with `sops -d` at launch. The agent's environment carries a placeholder and `ANTHROPIC_BASE_URL` pointing at the Host's loopback Proxy, which swaps the placeholder for the Credential on the way out. An `env` dump or a prompt injection inside the Sandbox yields nothing usable.

Considered: injecting the real token into the agent's environment, which is what the previous version did and what leaves it one `env` away; the macOS Keychain, which needs an index item and shell-outs for one file's worth of benefit; the TLS-terminating MITM proxy from `zabaca/claude-mitm-proxy`, which covers every host and not just the API but needs a local CA in the Sandbox. The reverse proxy is the smallest thing that keeps the token out, and the MITM form is the recorded upgrade if egress ever needs gating.
