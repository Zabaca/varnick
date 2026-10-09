import Foundation

/// The pieces of the claude command line, for one definition across hosts: a Mac's `ClaudeSession` and the
/// headless relay, each running the account's login shell, both run
/// `<shell> -l -i -c <script> claude <arguments>` with them.
public enum ClaudeCommand {
    // Runs as an interactive login shell (-l -i) so it loads the account shell's startup files like a
    // terminal does: that's where ~/.local/bin (claude, node for hooks) gets onto PATH.
    // The prompt is passed as "$1", never interpolated into the script, so quotes in it can't break the command.
    public static let script = #"exec claude "$@""#

    /// The settings claude is started with (`--settings`), added to the user's own hooks: ADR 0001's SessionStart
    /// hook, the turn hooks of ADR 0010 and the work-link hooks of ADR 0019 (`WorkHooks`). The rules for the entries are in
    /// `docs/agents/where-it-breaks.md`.
    public static func hookSettings(skipPermissions: Bool) -> String {
        let question = "AskUserQuestion", plan = "ExitPlanMode"
        func turn(_ turn: Turn, matcher: String? = nil) -> HookSettings.Entry {
            .init(matcher: matcher, command: turnCommand(turn))
        }
        var hooks: [String: [HookSettings.Entry]] = [
            "SessionStart": [.init(command: #"cat > "$LAUNCHY_SESSION_FILE""#),
                             .init(matcher: "clear", command: clearCommand), turn(.waiting, matcher: "resume"),
                             .init(command: WorkHooks.sessionStart)],
            "UserPromptSubmit": [.init(command: promptCommand)],
            "Stop": [turn(.waiting), .init(command: stopInputCommand)],
            "StopFailure": [turn(.waiting), .init(command: stopInputKeepCommand)],
            "Notification": [turn(.waiting, matcher: "idle_prompt")],
            "PermissionRequest": [turn(.permission, matcher: "^(?!(\(question)|\(plan))$)"),
                                  turn(.question, matcher: question), turn(.plan, matcher: plan)],
            "PreToolUse": [.init(matcher: WorkHooks.writeMatcher, command: WorkHooks.autoLink)],
            "PostToolUse": [turn(.working, matcher: "\(question)|\(plan)"),
                            .init(matcher: WorkHooks.markMatcher, command: WorkHooks.mark)],
            "SubagentStop": [.init(command: WorkHooks.subagentStop)],
            "Elicitation": [turn(.input)],
            "ElicitationResult": [turn(.working)],
        ]
        if !skipPermissions { hooks["PostToolBatch"] = [turn(.working)] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Plain strings and arrays: encoding can't fail, and a silent fallback would drop every hook.
        return String(decoding: try! encoder.encode(HookSettings(hooks: hooks)), as: UTF8.self)
    }

    private struct HookSettings: Encodable {
        var hooks: [String: [Entry]]

        struct Entry: Encodable {
            var matcher: String?
            var hooks: [Command]

            init(matcher: String? = nil, command: String) {
                self.matcher = matcher
                hooks = [Command(command: command)]
            }
        }

        struct Command: Encodable {
            var type = "command"
            var command: String
        }
    }

    /// The shell command of a turn hook: writes the word to the turn file beside `$LAUNCHY_SESSION_FILE`, by
    /// rename and only when it differs, and exits 0 whatever happens.
    static func turnCommand(_ turn: Turn) -> String {
        writeCommand(choosing: "", word: turn.rawValue)
    }

    /// `Stop`'s input, which lists the background tasks still running, saved as it comes (no jq in a hook's shell) to the
    /// stop file beside the turn file, by rename. `PaneFolder.runningTasks` reads it.
    static let stopInputCommand =
        #"f="${LAUNCHY_SESSION_FILE%/*}/\#(PaneFolder.stopFileName)"; "#
        + #"[ -n "$LAUNCHY_SESSION_FILE" ] && { cat > "$f.$$" && mv "$f.$$" "$f"; } 2>/dev/null; exit 0"#

    /// `StopFailure`'s input has no task list, and a turn that ends on an API error leaves the shells of the turn before
    /// running: the stop file is kept by dating it again, so the reader doesn't drop it as an earlier turn's.
    static let stopInputKeepCommand =
        #"f="${LAUNCHY_SESSION_FILE%/*}/\#(PaneFolder.stopFileName)"; "#
        + #"[ -n "$LAUNCHY_SESSION_FILE" ] && [ -f "$f" ] && touch "$f" 2>/dev/null; exit 0"#

    /// `UserPromptSubmit` writes working even over working: a prompt starts a new working period, and Esc leaves
    /// the file at working.
    static let promptCommand = writeCommand(choosing: "", word: Turn.working.rawValue, always: true)

    /// `/clear` writes waiting, except over a plan: approving it with "clear context" resolves the plan as a
    /// denial, so no `PostToolUse` follows, and Claude goes on working in the new conversation.
    static let clearCommand = writeCommand(choosing: #"w=waiting; [ "$(cat "$f" 2>/dev/null)" = plan ] && w=working; "#,
                                           word: #""$w""#)

    /// `choosing` is shell run once `$f` is set, and `word` is shell for the word to write, only when it
    /// differs from the file's unless `always`.
    private static func writeCommand(choosing: String, word: String, always: Bool = false) -> String {
        #"f="${LAUNCHY_SESSION_FILE%/*}/\#(PaneFolder.turnFileName)"; \#(choosing)"#
            + #"[ -n "$LAUNCHY_SESSION_FILE" ] && "#
            + (always ? "" : #"[ "$(cat "$f" 2>/dev/null)" != \#(word) ] && "#)
            + #"{ printf \#(word) > "$f.$$" && mv "$f.$$" "$f"; } 2>/dev/null; exit 0"#
    }

    /// The word a pane that starts claude writes first: working with a first message on the command line, else
    /// waiting.
    public static func firstTurn(resuming conversation: String?, prompt: String) -> Turn {
        conversation == nil && !prompt.isEmpty ? .working : .waiting
    }

    /// What the login shell is given: an interactive login shell (`-l -i`) running the script, with `claude`
    /// as `$0` and `claudeArguments` as `"$@"`.
    public static func shellArguments(_ claudeArguments: [String]) -> [String] {
        ["-l", "-i", "-c", script, "claude"] + claudeArguments
    }

    /// What follows `claude` in the script's arguments: the hooks' settings, skip permissions and agent,
    /// then `--resume <conversation>` or `--session-id <sessionID>` and the prompt after `--`. The order is
    /// part of the contract, and user text stays one argument each. `agent` is the one the host has found
    /// to exist, since claude exits on an unknown one.
    public static func arguments(skipPermissions: Bool, agent: String?, resuming conversation: String?,
                                 sessionID: String, prompt: String) -> [String] {
        ["--settings", hookSettings(skipPermissions: skipPermissions)]
            + (skipPermissions ? ["--dangerously-skip-permissions"] : [])
            + (agent.map { ["--agent", $0] } ?? [])
            + (conversation.map { ["--resume", $0] }
                ?? ["--session-id", sessionID] + (prompt.isEmpty ? [] : ["--", operand(prompt)]))
    }

    /// The prompt as claude's first operand. `--` before it makes a prompt that starts with a dash a prompt, not an
    /// option, but claude's argument parser (commander) still reads the first operand as a subcommand when it
    /// equals a command's name: the prompt `doctor` would run `claude doctor`. A command name has no whitespace, so a
    /// prompt that has none gets a trailing space, which no name equals and which the prompt doesn't miss.
    static func operand(_ prompt: String) -> String {
        prompt.contains(where: \.isWhitespace) ? prompt : prompt + " "
    }
}
