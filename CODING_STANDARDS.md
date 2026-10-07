# Coding standards

How Launchy code is written. `launchy-builder` follows these; `launchy-reviewer` checks diffs against them (the Standards axis of `/code-review`). What a change can break even when it follows them is in `docs/agents/where-it-breaks.md`.

## Wiring

- **New shortcut:** add a `ShortcutAction` case with `title`, `group` and `defaultCombo` in `Settings.swift`, handle it in `AppDelegate.perform(_:)`, and show hints with `ShortcutHint(action:)` — never a hard-coded key label, since every shortcut is rebindable.
- **New saved field:** on `SessionRecord`, `SavedTab` or `State`, make it Optional (or give it a decoding default). One field that fails to decode drops all saved tabs. State is saved on every change (`saveSessions()`), not at quit — the app is stopped by signal.
- **New setting:** a `@Published` property on `Settings` that writes UserDefaults in `didSet`, read with a default in `init`, plus a `SettingRow` in `SettingsView`.
- **New launcher row or list:** add its height to `LauncherModel.panelHeight` in the same branch the view shows it, using a named `static let …Height` constant.
- **New claude flag:** add it in `ClaudeCommand.arguments` (`Packages/LaunchyPeer`; `ClaudeSession` and the headless relay both call it) as separate array elements, before the `--` and the prompt. Anything a session was started with must be stored on its record and passed again on resume.
- **Slow work** (disk walks, network): off the main thread, with the last result shown meanwhile (see `LauncherModel.scanProjects`).
- **Async work:** model and sessions are main-actor; hop back with `Task { @MainActor in … }` or `await MainActor.run`. Check `Task.isCancelled` after each `await` before writing state. Closures a session or tab holds capture it weakly (see `makeSession`).
- **Focus:** moving focus back to search goes through `focusToken += 1`; key handlers return `.ignored` for keys they don't act on.
- **UI:** use `Theme` tokens and the existing row patterns (`SessionRow`, `SuggestionRow`, `KeyHint`, `WordBadge`); match font sizes (13 medium titles, 11.5 secondary).

## Style

- Match the surrounding code. Doc comments (`///`) say why or what a user sees, in one or two lines; no comments that restate the code.
- Names follow what's there (`record`, `session`, `tab`).
- Keep changes as small as the feature allows — no drive-by refactors, no new abstractions for a single use, no new dependencies (SwiftTerm, plus mlx-swift, mlx-swift-lm and swift-transformers for embeddings, reranking and text generation; see ADRs 0003, 0006 and 0012; zmx, a prebuilt binary `make build` fetches, see ADR 0004).
