---
problem: models-run-only-on-this-mac
title: Launchy installs its own llama.cpp server for Gemma on the Ryzen, beside foundry's embedding service
summary: The Ryzen side of Text generation on a server. Launchy's peer installer gains a flag that installs llama.cpp's Vulkan server, pinned to the build the GPU spike measured, serving Gemma 4 E2B Q4_0 on the RX 7800 XT. It runs as a systemd user unit, as the Phone page does, listening only on the Ryzen's tailnet address. Embeddings stay with foundry's `foundry-embeddings`. Foundry has to record a second GPU tenant first; that decision is foundry's, made in its own repo.
status: proposed
---

## Solution

`scripts/install-peer.sh <host> --models` installs a model server on a headless host, as `--page` installs the Phone page:

- **What runs.** llama.cpp's `llama-server`, from its Vulkan release for Ubuntu, pinned to the build the spike measured (b11467). It serves Gemma 4 E2B as ggml-org's Q4_0 GGUF (2,841,481,184 bytes), pinned by revision and checked by SHA-256. It offloads every layer, with a 4K context, two requests at a time and the model's own chat template.
- **On which card.** The RX 7800 XT, found by name each time the server starts. llama.cpp numbers Vulkan devices by position, and on the Ryzen the iGPU is `Vulkan0`. A fixed `Vulkan1` would silently land on the iGPU if the order ever changed.
- **Where it listens.** On the Ryzen's tailnet address only, on one fixed port chosen at implementation against what the Ryzen already listens on. Nothing on the LAN reaches it, whatever Docker or the firewall do.
- **How it is kept.** A systemd user unit, started at boot through linger (already required by the Phone page) and restarted on failure. Its log is the journal, at the server's default verbosity, which must not hold prompt text (checked once by hand).
- **Install, upgrade, remove.** `--models` installs it, `--no-models` removes the unit, the binary and the model, and `--uninstall` takes it away with the rest. Without either flag, a host that has it keeps it, as with the page. So the Ryzen row's Upgrade in Settings › Peers, which runs the installer, never drops it.

Launchy's Text generation (option 02) is then given `http://linux-box:<port>`.

Embeddings stay on foundry's service. The same server could also serve Qwen3-Embedding (a second instance with last-token pooling), which would make Launchy independent of foundry. It would load the same model on the card a second time. It is offered as a choice, not recommended (open question 1).

**Before installing, foundry decides.** Foundry's ADR-0032 and ADR-0001 say a second GPU tenant is a new decision. ADR-0033 assumes `foundry-embeddings` is the card's only tenant. So foundry needs an ADR recording Launchy's server as a second tenant, its VRAM and its restart policy, and maybe a probe like the one its embedding service has. That is the user's work in foundry's repo, and it comes before the first `--models` install.

## Trade-offs

- **The fastest path the spike found.** On the Vulkan build, a short title took 0.078 s and a long one 0.135 s, and generation ran at about 196 tokens/s, against about 126 for ROCm builds and Ollama. Its loads logged no page faults; the faults came from Ollama's ROCm image with the GFX override.
- **It fits.** About 1.6 GB of VRAM at a 4K context, beside the 3.2 GB `foundry-embeddings` holds, on a 16 GB card. About 1.7 GB of the model stays in host RAM by design.
- **It leaves foundry's service as its ADR describes it**, and Launchy pins the exact model and build it measured, rather than taking whatever a tag resolves to.
- **It is a second tenant on a card whose driver has hung before.** A wedged card can need a reboot, which ends every session the Ryzen hosts: they come back lost, and can be resumed. The embedding service on that card already runs the GFX-override path that logged faults in the spike. Launchy's server adds load, not that path.
- **Launchy installs more on the host.** A downloaded binary, a 2.8 GB model and a unit, all outside foundry's view unless foundry adds a probe. Foundry's ADR-0026 and ADR-0028 prefer that a repo converge its own guest through incus. Launchy's relay and page are host installs already, and a guest with the card passed through is more machinery for one small server (open question 3).
- **No authentication** by default, like `foundry-embeddings`. Any device on the tailnet can ask it for text; none can read anything from it (open question 2).

## User Stories

1. As a MacBook Air user, I want a Gemma server on the Ryzen that Launchy installs and upgrades, so that my sessions get titles with no model on the Air.
2. As the person who runs the Ryzen, I want the model server installed, kept and removed by the same installer as the relay and the page, with the same flags' rules.
3. As the person who runs the Ryzen, I want it to listen only on the tailnet and to log no prompts.
4. As the person who runs the Ryzen, I want an upgrade from Settings › Peers to keep the server, and a pin bump to reach it by that same Upgrade.

## Implementation Decisions

- **The installer.**
  - `--models` and `--no-models` follow `--page` and `--no-page` exactly: they refuse each other, `--uninstall` refuses both, and with neither flag an installed server is kept.
  - The pins (the release, the model's revision and both checksums, the port) live in the installer's far half. The far half is already among the files the relay comparison counts, so a changed pin shows the Ryzen's row as behind and offers Upgrade. It does so on a host without the server too, the same known limit the page has.
  - The far half adds `MODELS` to its `# supports:` line.
  - A download goes to a partial file and is checked before it is moved into place, as Launchy's model downloads are.
- **The unit.**
  - It runs a small start script that finds the 7800 XT among llama.cpp's listed devices by its name, and refuses to start without it, rather than falling back to the iGPU.
  - It listens on the tailnet address read at start. With Tailscale not up yet at boot, the unit fails and systemd restarts it.
  - It sets no prompt logging.
- **The report.** The installer's result lines gain the unit's state, the device found and one test title's time, as the page's lines report the page's unit.
- **Docs, once accepted:**
  - ADR 0009's install section gains the model server, or ADR 0014 holds it, whichever exists.
  - `where-it-breaks.md`'s Ryzen installer bullet gains the `--models` rules (kept with the page's flags, the device found by name, tailnet-only).
  - Foundry's ADR is in foundry's repo, and this option links to it once it exists.

## Testing Decisions

- No test target. Run the installer against the Ryzen with `--models`, and judge it by its result lines, never its exit status, as a headless install already is.
- **Checks on the Ryzen:**
  - The unit runs on the 7800 XT (`offloaded 36/36 layers`, and the card busy during a title).
  - It answers on the tailnet address and not on the LAN address.
  - `foundry-embeddings` still answers, at the same speed, during a run of titles.
  - The journal holds no prompt text after a title.
  - A reboot brings it back.
  - An Upgrade from Settings › Peers keeps it, and `--no-models` removes everything it added.
- **The 31-prompt title comparison** from option 02's testing, run against this server.

## Out of Scope

- Launchy's side: option 02.
- Foundry's ADR and probes.
- Serving the embedding model (open question 1).
- A container image or an incus guest (open question 3).
- Other models, a router in front of several models, and serving anything to devices or the Phone page.

## Further Notes

- **Verified 2026-10-07:**
  - the installer's `--page` rules (kept without a flag, removed by `--no-page`, refused with `--uninstall`);
  - that the far half is among the files the relay comparison counts;
  - foundry's ADR-0001, ADR-0026, ADR-0028, ADR-0032 and ADR-0033 as quoted;
  - `foundry-embeddings`' settings (problem.md).
- **From the spike's report, not rerun:**
  - the timings, VRAM and device numbering;
  - that the Vulkan build was a bare binary on the host, not a container (the spike didn't try Vulkan in a container).
- **Open questions, each with a recommendation:**
  1. *Also serve the embedding model:* no. Foundry's service serves it already and stays loaded. A second copy only buys independence from foundry's changes, which option 01's Check already turns into a fallback.
  2. *A key:* none, bound to the tailnet address, as `foundry-embeddings` is. The server holds nothing to read. Add one (the Model server key row already exists) if devices shared into the tailnet should be kept off it.
  3. *Host unit, container or incus guest:* a systemd user unit running the pinned binary. It is what the spike measured and how Launchy already lives on the Ryzen. A guest would follow foundry's ADR-0026, at the cost of passing the card through for one small server.
