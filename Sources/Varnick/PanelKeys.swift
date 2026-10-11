import AppKit
import Carbon

// `keys` (Panel access, ADR 0031, option 02 of `sessions-cant-read-or-drive-varnick`): text and key combos pressed into the panel's own key
// path. Each is made as a key event for the panel's window and handed to `NSApp.sendEvent`, which runs it through the panel's key monitor
// (`main.swift`), the view's handler and the first responder, as a key of the user's goes. No `CGEvent` is made and no permission is
// involved; the event reaches no other app. What is checked, and why, is in where-it-breaks.md, Panel access.

/// How many of a call's characters and keys.
struct PanelKeyCount: Equatable {
    var characters = 0
    var keys = 0

    /// "3 of 5 characters and 0 of 2 keys": what was sent of what was asked.
    func of(_ asked: PanelKeyCount) -> String {
        var parts: [String] = []
        if asked.characters > 0 { parts.append("\(characters) of \(asked.characters) character\(asked.characters == 1 ? "" : "s")") }
        if asked.keys > 0 { parts.append("\(keys) of \(asked.keys) key\(asked.keys == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    /// "12 characters and 3 keys".
    var text: String {
        var parts: [String] = []
        if characters > 0 { parts.append("\(characters) character\(characters == 1 ? "" : "s")") }
        if keys > 0 { parts.append("\(keys) key\(keys == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }
}

/// One key `keys` presses: a character of `text`, or a combo. A character carries itself and no modifiers, as the screen tool `type`'s do; a
/// combo is read against the current layout by `ScreenKeys.parse`. The key code is the layout's for both, so a handler that reads it (the board's
/// D, the Outline's ↩) and one that reads the characters (a text field) both see what the key would give.
struct PanelKey {
    let keyCode: UInt16
    /// ⌃ ⌥ ⇧ ⌘ as pressed.
    let modifiers: NSEvent.ModifierFlags
    let characters: String
    /// A character of `text`, not a combo.
    let isText: Bool

    var combo: KeyCombo { KeyCombo(keyCode: Int(keyCode), modifiers) }
    var label: String { isText ? "\"\(characters)\"" : combo.label }
    var isReturn: Bool { Int(keyCode) == kVK_Return || Int(keyCode) == kVK_ANSI_KeypadEnter }
    var isEscape: Bool { Int(keyCode) == kVK_Escape }

    // MARK: Making keys

    /// The keys that type `text`. The layout is read once for each distinct character; one it has no key for (an accent, a letter of another
    /// script) goes with key code 0, as `type`'s do, since a text view takes the characters.
    @MainActor static func keys(typing text: [Character]) -> [PanelKey] {
        var codes: [Character: UInt16] = [:]
        return text.map { character in
            if codes[character] == nil {
                if character == " " {
                    codes[character] = UInt16(kVK_Space)
                } else {
                    codes[character] = ScreenKeys.parse(String(character)).map(\.keyCode) ?? 0
                }
            }
            return PanelKey(keyCode: codes[character] ?? 0, modifiers: [], characters: String(character), isText: true)
        }
    }

    @MainActor static func key(pressing combo: KeyCombo) -> PanelKey {
        PanelKey(keyCode: combo.keyCode, modifiers: combo.flags, characters: Self.characters(of: combo), isText: false)
    }

    /// The function-key characters AppKit gives arrows and the like, which a text view's key bindings read.
    private static let functionCharacters: [Int: Int] = {
        var found: [Int: Int] = [kVK_UpArrow: 0xF700, kVK_DownArrow: 0xF701, kVK_LeftArrow: 0xF702, kVK_RightArrow: 0xF703,
                                 kVK_ForwardDelete: 0xF728, kVK_Home: 0xF729, kVK_End: 0xF72B, kVK_PageUp: 0xF72C, kVK_PageDown: 0xF72D]
        let function = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in function.enumerated() { found[code] = 0xF704 + index }
        return found
    }()

    private static let arrows: Set<Int> = [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow]

    /// What the combo's key gives as the event's characters.
    @MainActor private static func characters(of combo: KeyCombo) -> String {
        let code = Int(combo.keyCode)
        if let function = functionCharacters[code], let scalar = Unicode.Scalar(function) { return String(Character(scalar)) }
        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "\r"
        case kVK_Tab: return combo.flags.contains(.shift) ? "\u{19}" : "\t"
        case kVK_Escape: return "\u{1B}"
        case kVK_Delete: return "\u{7F}"
        case kVK_Space: return " "
        default: break
        }
        let name = KeyCombo.keyName(code).lowercased()
        guard name != "?" else { return "" }
        // ⌃ and a letter is the control character; ⇧ and a letter the capital.
        if combo.flags.contains(.control), name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic {
            return String(Character(Unicode.Scalar(scalar.value & 0x1F)!))
        }
        return combo.flags.contains(.shift) && name.count == 1 && name.first?.isLetter == true ? name.uppercased() : name
    }

    // MARK: The events

    /// The key-down and key-up for the panel's window, both carrying `stamp`, which is how the key monitor tells this key from the user's.
    func events(window: NSWindow, stamp: TimeInterval) -> (down: NSEvent, up: NSEvent)? {
        var flags = modifiers
        let code = Int(keyCode)
        if PanelKey.functionCharacters[code] != nil { flags.insert(.function) }
        if PanelKey.arrows.contains(code) { flags.insert(.numericPad) }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: window.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return nil }
        return (down, up)
    }
}

enum PanelKeys {
    /// How near two timestamps are to be one key's: a re-posted copy (the Outline's queue sends a key again) comes back requantized, by about
    /// 5e-10 s in the probe, while the user's own keys are never within this of a stamp, which are at least `stampGap` apart.
    static let stampTolerance: TimeInterval = 1e-6
    static let stampGap: TimeInterval = 0.001
    /// How long a stamp is kept: the Outline sends a queued key again within a second or so.
    static let stampLife: TimeInterval = 60

    // MARK: Arguments

    /// The keys a call asks for: its text, then its combos, each refused whole when it can't be read, never cut (`type`'s limits).
    @MainActor static func parse(_ args: PanelArguments) throws -> (keys: [PanelKey], asked: PanelKeyCount) {
        let text = args["text"] ?? ""
        if let problem = ScreenKeys.problem(withText: text, tool: "keys", rest: "Send the rest in the next call, which types where this one stopped") {
            throw PanelRefusal.bad(problem)
        }
        let written = try combos(args["keys"])
        guard written.count <= ScreenKeys.maxKeys else { throw PanelRefusal.bad("At most \(ScreenKeys.maxKeys) keys in one call") }
        var pressed: [PanelKey] = []
        for item in written {
            guard let combo = ScreenKeys.parse(item) else {
                throw PanelRefusal.bad("Can't read the key combo \"\(String(item.prefix(30)))\". Write modifiers (cmd, ctrl, opt, shift) and one key joined by +, such as cmd+z, shift+Tab or Return")
            }
            pressed.append(.key(pressing: combo))
        }
        let typed = PanelKey.keys(typing: Array(text))
        guard !typed.isEmpty || !pressed.isEmpty else { throw PanelRefusal.bad("Give text, keys or both") }
        return (typed + pressed, PanelKeyCount(characters: typed.count, keys: pressed.count))
    }

    /// `keys` arrives as a JSON array in text; a single combo sent as a plain string is taken as one.
    private static func combos(_ text: String?) throws -> [String] {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        if text.hasPrefix("["), let data = text.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            guard let strings = array as? [String] else { throw PanelRefusal.bad("keys is a list of key combos, each a string") }
            return strings
        }
        return [text]
    }

    // MARK: What is never pressed

    /// Why a session may not press the key in any view, nil when the view decides: what no state could make safe. Checked for every key of a
    /// call before anything is sent. The monitor runs before the shortcuts, so each of these would act: the End session, Mark session done
    /// and Restart session keys as bound; Varnick's own anywhere-shortcuts (`ScreenKeys.refusal`), which include Listening's; the keys that
    /// start a terminal or open Settings, whose switches govern sessions; ⌘Q; and paste, which would put the user's clipboard where the
    /// session can read it (the Outline, then `outline_read`).
    @MainActor static func neverSent(_ key: PanelKey) -> String? {
        if let why = ScreenKeys.refusal(of: key.combo) { return why }
        let actions: [(ShortcutAction, String)] = [
            (.endPane, "ends a session"), (.doneSession, "marks a session done"), (.restartSession, "restarts a session"),
            (.newTerminalTab, "starts a terminal"), (.settings, "opens Settings, whose switches govern sessions"),
        ]
        for (action, what) in actions where Settings.shared.combo(action) == key.combo {
            return "\(key.label) is bound to \"\(action.title)\", which \(what)"
        }
        if let paste = Settings.shared.combo(.paste), paste == key.combo { return "\(key.label) pastes the user's clipboard" }
        if key.modifiers.contains(.command) {
            if layoutCodes(of: "q").contains(Int(key.keyCode)) { return "\(key.label) quits Varnick" }
            if layoutCodes(of: "v").contains(Int(key.keyCode)) { return "\(key.label) pastes the user's clipboard, which a session could then read" }
        }
        return nil
    }

    /// The key codes that type a letter with ⌘ held on the current layout, and the US key's.
    @MainActor private static func layoutCodes(of letter: Character) -> Set<Int> {
        let us = letter == "q" ? kVK_ANSI_Q : kVK_ANSI_V
        return Set([us] + (ScreenKeys.parse("cmd+\(letter)").map { [Int($0.keyCode)] } ?? []))
    }
}

/// A view that takes no keys, with the reason (Settings, the Restart Varnick card, the split picker, the rename field).
struct NoKeys: PanelKeyView {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    @MainActor func refusal(of key: PanelKey) -> String? { reason }
}

/// The search: text, arrows and ⇥ are the field's. ↩ is refused where it would start a session, turn on the microphone or open a page in the
/// browser, and esc because it hides the panel, which a session may not do.
struct SearchPanelKeys: PanelKeyView {
    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    @MainActor func refusal(of key: PanelKey) -> String? {
        if key.isEscape { return "esc hides the panel, which a session may not do" }
        guard key.isReturn else { return nil }
        // ⌘↩ copies a link or starts a session, ⌥↩ and ⌃↩ are not the field's.
        if !key.modifiers.subtracting(.shift).isEmpty { return "\(key.label) in the search copies a link or starts a session" }
        switch model.mode {
        case .prompt:
            return "↩ on a prompt starts a Claude session with the field's text as its prompt"
        case .search:
            return "↩ on a ? result opens the page in the browser or resumes a session"
        case .command:
            let shown = model.commands
            return shown.indices.contains(model.commandSelection) && shown[model.commandSelection] == .listen
                ? "↩ on !listen turns on the microphone" : nil
        case .sessions:
            // An open tab comes up; Recent resumes a session and a paired Mac's opens a pane on its card.
            return !model.showsSessionList || model.tabs.indices.contains(model.sessionSelection)
                ? nil : "↩ on this row would resume a session or open a paired Mac's"
        }
    }
}

// MARK: The call

extension PanelAccess {
    /// Presses `text`, then `keys`, into the view the panel shows. One action at a time across all sessions (`ScreenAccess`'s queue). Every
    /// key is gated on the main actor right before it is sent, with nothing awaited between the gate and `sendEvent`: the first failure
    /// stops the call and the reply says how far it got.
    func keys(_ args: PanelArguments, _ model: LauncherModel, caller: UUID, arrived: ContinuousClock.Instant) async throws -> Answered {
        let (keys, asked) = try PanelKeys.parse(args)
        // What no state could make safe is refused before the first key goes.
        for key in keys {
            if let why = PanelKeys.neverSent(key) { throw PanelRefusal.keysRefused(why) }
        }
        await ScreenAccess.shared.acquire()
        defer { ScreenAccess.shared.release() }
        // The relay gives up at 15 s: a call that waited its turn too long would be answered after it was given up on.
        func remaining(after sent: PanelKeyCount) -> Duration {
            ScreenKeys.duration(characters: asked.characters - sent.characters, keys: asked.keys - sent.keys)
        }
        var sent = PanelKeyCount()
        guard arrived.duration(to: .now) + remaining(after: sent) < ScreenAccess.typingDeadline else {
            throw PanelRefusal.keysRefused("Another action held the keyboard too long for this call to finish in time: try again")
        }
        let now = ProcessInfo.processInfo.systemUptime
        postedStamps = postedStamps.filter { now - $0 < PanelKeys.stampLife }
        for key in keys {
            func stop(_ why: String) -> PanelRefusal {
                sent == PanelKeyCount() ? .keysRefused(why) : .keysStopped(why, sent: sent, asked: asked)
            }
            if Task.isCancelled { throw stop("The call was cancelled") }
            if arrived.duration(to: .now) + remaining(after: sent) >= ScreenAccess.typingDeadline {
                throw stop("There was not enough time left in the call for the rest")
            }
            if let why = send(key, model, caller: caller, first: sent == PanelKeyCount()) { throw stop(why) }
            if key.isText { sent.characters += 1 } else { sent.keys += 1 }
            try? await Task.sleep(for: key.isText ? ScreenKeys.characterPace : ScreenKeys.comboPace)
        }
        return Answered(text: "Sent \(sent.text). This says what was sent, not what it did: read panel, or board_read or outline_read with as_shown, to see.",
                        counts: "sent \(sent.of(asked))")
    }

    /// The gate and the post, in one synchronous turn. Nil once the key is sent, else why it was not.
    private func send(_ key: PanelKey, _ model: LauncherModel, caller: UUID, first: Bool) -> String? {
        guard mayAct(caller: caller) else { return "Panel access is off, or this pane is no longer one a session may act from" }
        // Not key means the keyboard is the user's elsewhere; Varnick not active means a pinned panel behind another app. Neither is brought up.
        guard let window = panelWindow, window.isVisible, window.isKeyWindow, NSApp.isActive else {
            return "The panel is not up with the keyboard (hidden, or another app is in front): keys never brings it up, so ask the user to open it"
        }
        if userTypedRecently { return "the user typed in the panel" }
        // Composing at the start is the user's; later it may be the call's own characters, which the call reports, and the view's text rules apply.
        if first, (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return "an input method is composing text in the panel" }
        if let why = PanelKeys.neverSent(key) ?? PanelViews.onScreen(model).refusal(of: key) { return why }
        let uptime = ProcessInfo.processInfo.systemUptime
        let stamp = max(uptime, (postedStamps.last ?? 0) + PanelKeys.stampGap)
        guard let (down, up) = key.events(window: window, stamp: stamp) else { return "Varnick could not make the key event" }
        postedStamps.append(stamp)
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        return nil
    }
}
