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
    /// hook, the turn hooks of ADR 0010 and, with `problems`, the work-link hooks of ADR 0020 (`WorkHooks`): the host that runs
    /// the session decides, from its Problems board switch (Settings › Experimental, or the relay's `--problems`). With it off
    /// the settings are the same less the `WorkHooks` entries. The hook for a session's own message (`PaneMessage`) and the allowance for
    /// `notify` are there with it on or off. The rules for the entries are in `docs/agents/where-it-breaks.md`.
    public static func hookSettings(problems: Bool) -> String {
        let question = "AskUserQuestion", plan = "ExitPlanMode"
        func turn(_ turn: Turn, matcher: String? = nil) -> HookSettings.Entry {
            .init(matcher: matcher, command: turnCommand(turn))
        }
        var hooks: [String: [HookSettings.Entry]] = [
            "SessionStart": [.init(command: #"cat > "$VARNICK_SESSION_FILE""#),
                             .init(matcher: "clear", command: clearCommand), .init(matcher: "clear", command: messageClearCommand),
                             turn(.waiting, matcher: "resume")],
            "UserPromptSubmit": [.init(command: promptCommand), .init(command: leadEndedCommand(.working)), .init(command: messageClearCommand)],
            "Stop": [turn(.waiting), .init(command: stopInputCommand), .init(command: leadEndedCommand(.waiting))],
            "StopFailure": [turn(.waiting), .init(command: stopInputKeepCommand), .init(command: leadEndedCommand(.waiting))],
            "Notification": [turn(.waiting, matcher: "idle_prompt")],
            "PermissionRequest": [.init(matcher: "^(?!(\(question)|\(plan))$)", command: askedCommand),
                                  turn(.question, matcher: question), turn(.plan, matcher: plan)],
            "PostToolUse": [turn(.working, matcher: "\(question)|\(plan)"), .init(matcher: messageMatcher, command: messageInputCommand)],
            "PostToolBatch": [.init(command: answeredCommand)],
            "SubagentStop": [.init(command: answeredCommand)],
            "Elicitation": [turn(.input)],
            "ElicitationResult": [turn(.working)],
        ]
        if problems {
            // Each entry goes last in its event's list, where it stood before the switch; PreToolUse has no other.
            hooks["SessionStart", default: []].append(.init(command: WorkHooks.sessionStart))
            hooks["PreToolUse"] = [.init(matcher: WorkHooks.writeMatcher, command: WorkHooks.autoLink)]
            hooks["PostToolUse", default: []].append(.init(matcher: WorkHooks.markMatcher, command: WorkHooks.mark))
            hooks["SubagentStop", default: []].append(.init(command: WorkHooks.subagentStop))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Plain strings and arrays: encoding can't fail, and a silent fallback would drop every hook.
        return String(decoding: try! encoder.encode(HookSettings(hooks: hooks)), as: UTF8.self)
    }

    private struct HookSettings: Encodable {
        var hooks: [String: [Entry]]
        /// `notify` is allowed in every session, so calling it never stops the turn on a permission dialog (which would itself raise Needs you).
        /// A list in `--settings` adds to the user's own (checked on Claude Code 2.1.300).
        var permissions = Permissions()

        struct Permissions: Encodable {
            var allow = [NotifyTool.qualifiedName]
        }

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

    /// The shell command of a turn hook: writes the word to the turn file beside `$VARNICK_SESSION_FILE`, by
    /// rename and only when it differs, and exits 0 whatever happens.
    static func turnCommand(_ turn: Turn) -> String {
        writeCommand(choosing: "", word: turn.rawValue)
    }

    /// `PermissionRequest` for an ordinary tool: marks the pane permission and notes the asker, keeping the word to give back.
    /// The mechanism is in `docs/agents/where-it-breaks.md`.
    static let askedCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.turnFileName)"; [ -n "$VARNICK_SESSION_FILE" ] && { inp=$(cat); \#(askerShell) "#
        + #"[ -d "$f.askers" ] || { [ "$(cat "$f" 2>/dev/null)" = permission ] || { cp -p "$f" "$f.before" || rm -f "$f.before"; }; }; "#
        + #"mkdir -p "$f.askers" && : > "$f.askers/$asker"; "#
        + #"[ "$(cat "$f" 2>/dev/null)" = permission ] || { printf permission > "$f.$$" && mv "$f.$$" "$f"; }; } >/dev/null 2>&1; exit 0"#

    /// `PostToolBatch` and `SubagentStop`: the asker's dialog is answered or its agent gone, and the last asker gives the saved
    /// word back.
    static let answeredCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.turnFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && [ -d "$f.askers" ] && { inp=$(cat); \#(askerShell) "#
        + #"[ -f "$f.askers/$asker" ] && { rm -f "$f.askers/$asker"; rmdir "$f.askers" 2>/dev/null && { "#
        + #"if [ "$(cat "$f" 2>/dev/null)" != permission ]; then rm -f "$f.before"; "#
        + #"elif [ -f "$f.before" ]; then mv "$f.before" "$f"; "#
        + #"else printf working > "$f.$$" && mv "$f.$$" "$f"; fi; }; }; } >/dev/null 2>&1; exit 0"#

    /// `Stop`, `StopFailure` and `UserPromptSubmit`: the lead's own dialog can't be open now (a Deny fires no hook), so its mark
    /// goes; with other askers left, the word to give back is the one just written.
    static func leadEndedCommand(_ turn: Turn) -> String {
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.turnFileName)"; "#
            + #"[ -n "$VARNICK_SESSION_FILE" ] && [ -d "$f.askers" ] && { rm -f "$f.askers/lead"; "#
            + #"if rmdir "$f.askers" 2>/dev/null; then rm -f "$f.before"; "#
            + #"else printf \#(turn.rawValue) > "$f.before.$$" && mv "$f.before.$$" "$f.before"; fi; } >/dev/null 2>&1; exit 0"#
    }

    /// Sets `asker` to the hook input's `agent_id`, else `lead`. Only the fields before `hook_event_name` are searched: a
    /// subagent's own are there (2.1.295), and the `tool_input` after it can hold any key.
    private static let askerShell =
        #"h=${inp%%\"hook_event_name\"*}; "#
        + #"asker=$(printf '%s' "$h" | grep -oE '[{,]"agent_id":"[A-Za-z0-9_-]+"' | head -n 1 | cut -d'"' -f4); [ -n "$asker" ] || asker=lead;"#

    /// `Stop`'s input, which lists the background tasks still running, saved as it comes (no jq in a hook's shell) to the
    /// stop file beside the turn file, by rename. `PaneFolder.runningTasks` reads it.
    static let stopInputCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.stopFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && { cat > "$f.$$" && mv "$f.$$" "$f" || rm -f "$f.$$"; } 2>/dev/null; exit 0"#

    /// `StopFailure`'s input has no task list, and a turn that ends on an API error leaves the shells of the turn before
    /// running: the stop file is kept by dating it again, so the reader doesn't drop it as an earlier turn's.
    static let stopInputKeepCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.stopFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && [ -f "$f" ] && touch "$f" 2>/dev/null; exit 0"#

    /// The tools whose calls are messages to the user: Varnick's `notify` and Claude Code's own PushNotification (option 04 of
    /// `phone-page-is-only-a-browser-tab`). Anchored, so no other tool's name matches.
    static let messageMatcher = "^(\(NotifyTool.qualifiedName)|\(PaneMessage.pushNotificationTool))$"

    /// `PostToolUse` for those tools: the hook's input saved as it comes (no jq in a hook's shell) to the message file beside the turn file, by
    /// rename. It is the only writer of that file, and `PaneMessage` reads it. A call that fails fires `PostToolUseFailure`, not this.
    static let messageInputCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.messageFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && { cat > "$f.$$" && mv "$f.$$" "$f" || rm -f "$f.$$"; } 2>/dev/null; exit 0"#

    /// `UserPromptSubmit` and a `/clear`: a message lasts until the user's next prompt or the conversation is cleared.
    static let messageClearCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.messageFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && rm -f "$f" 2>/dev/null; exit 0"#

    /// The variable that points Claude Code's client-presence check at the host's marker (option 04): while the file exists Claude Code skips
    /// its own Remote Control mobile pushes, because the host's page server keeps it while it has a push subscription of its own.
    public static let presenceVariable = "CLAUDE_CLIENT_PRESENCE_FILE"
    /// The marker's name in the page server's folder (`pushserver.ts`).
    public static let presenceMarkerName = "claude-client-present"

    /// The environment entry for a host whose page server's folder is `phoneFolder`.
    public static func presenceEntry(phoneFolder: URL) -> String {
        "\(presenceVariable)=\(phoneFolder.appendingPathComponent(presenceMarkerName).path)"
    }

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
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.turnFileName)"; \#(choosing)"#
            + #"[ -n "$VARNICK_SESSION_FILE" ] && "#
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

    /// What follows `claude` in the script's arguments: the MCP config, the hooks' settings, skip permissions and agent,
    /// then `--resume <conversation>` or `--session-id <sessionID>` and the prompt after `--`. The order is
    /// part of the contract, and user text stays one argument each. `agent` is the one the host has found
    /// to exist, since claude exits on an unknown one. `problems` is the running host's own Problems board switch, read at each start
    /// like `mcpConfig` and not stored on the record. `mcpConfig` (Screen access) goes first: `--mcp-config` takes several values
    /// and stops at the next option, `--settings`.
    public static func arguments(skipPermissions: Bool, agent: String?, resuming conversation: String?,
                                 sessionID: String, prompt: String, problems: Bool, mcpConfig: String? = nil) -> [String] {
        (mcpConfig.map { ["--mcp-config", $0] } ?? [])
            + ["--settings", hookSettings(problems: problems)]
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
