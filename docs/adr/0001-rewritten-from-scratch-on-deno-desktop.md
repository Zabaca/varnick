# Rewritten from scratch on Deno Desktop

Status: accepted, 2026-09-17.

The first varnick was a Tauri app: a Rust host, a React chat over the Claude Agent SDK, and a Bun harness bridged over stdio, with 23 ADRs, most of them about keeping an agent that edited the live tree from becoming running code without a human. That version is on the `archive` branch of this repository, tip commit 7c48885 and nothing here inherits from it. This branch starts over on Deno 2.9's `deno desktop`, with the system webview backend, because the whole host was already TypeScript except the parts Tauri forced into Rust, and because in-process is the shape a single-user desktop tool wants.

Considered: keeping Tauri and only replacing the chat; a new repository. Rejected because the Tauri layer was the source of the process split, and because the history is worth keeping in one place even if nothing is carried over.

Consequences: binaries are 40 to 68MB instead of 5MB, and there is no distribution story yet; see ADR-0008. Developed and run on macOS; Linux is plausible and untested, and the README says so.
