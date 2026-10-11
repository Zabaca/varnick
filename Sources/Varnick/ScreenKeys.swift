import AppKit
import Carbon

// What `type` (ADR 0023) types and presses: the rules for its text, its key combos read against the current keyboard layout, the
// combos a session may not press, and the key events themselves. Decisions are here; the checks around them are in `ScreenAccess`.

enum ScreenKeys {
    static let maxCharacters = 500
    static let maxKeys = 10
    /// One event's Unicode string holds at most 20 UTF-16 units.
    static let maxUnits = 20

    /// The wait after each character's events, before the next: tuned by hand to the fastest pace TextEdit, a field in a Chrome page
    /// and Terminal all keep up with (where-it-breaks.md, Screen access). If it has to be slower, `maxCharacters` shrinks so the text
    /// still takes at most 2.5 s.
    static let characterPace: Duration = .milliseconds(5)
    /// A combo's key is held this long, and then the next thing waits `comboPace` in all.
    static let comboHold: Duration = .milliseconds(10)
    static let comboPace: Duration = .milliseconds(50)

    /// The most a combo's check off the main actor waits: the keyboard's owner and the focus are read side by side, each call 0.1 s.
    static let comboCheck: Duration = .milliseconds(200)

    /// How long a call's text and keys take, which its age limit is shortened by.
    static func duration(characters: Int, keys: Int) -> Duration {
        characterPace * characters + (comboPace + comboCheck) * keys
    }

    /// The most a call's own typing takes, in whole seconds: the longest text and ten combos.
    static var longestTyping: Int {
        let longest = duration(characters: maxCharacters, keys: maxKeys).components
        return Int(longest.seconds) + (longest.attoseconds > 0 ? 1 : 0)
    }

    // MARK: Text

    /// Why the text can't be typed, nil when it can. A text that can't is refused whole, never cut: a session can't read the field to
    /// see where a cut fell.
    static func problem(withText text: String) -> String? {
        guard text.count <= maxCharacters else {
            return "The text has \(text.count) characters and type takes at most \(maxCharacters). Send the rest in the next call, without an id, which types where this one would have stopped"
        }
        let breaks: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        guard !text.unicodeScalars.contains(where: { breaks.contains($0.properties.generalCategory) }) else {
            return "The text has a line break, a tab or another control character. Type those as keys: Return, shift+Return, Tab"
        }
        guard !text.contains(where: { $0.utf16.count > maxUnits }) else { return "A character in the text is too long to type" }
        return nil
    }

    // MARK: Combos

    private static let names: [String: Int] = {
        var names: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "space": kVK_Space,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { names["f\(index + 1)"] = code }
        return names
    }()

    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option, "shift": .shift,
    ]
    private static let modifierSymbols: [Character: NSEvent.ModifierFlags] = ["⌘": .command, "⌃": .control, "⌥": .option, "⇧": .shift]

    /// The combo as written, or nil when it can't be read: modifiers (words joined by +, or the symbols ⌘ ⌃ ⌥ ⇧) and one key, a name
    /// or a character. A character is the key that types it on the current layout, never assumed to be on a US one. On the main actor,
    /// where the layout is read.
    @MainActor
    static func parse(_ text: String) -> KeyCombo? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers: NSEvent.ModifierFlags = []
        while !rest.isEmpty {
            if let first = rest.first, let flag = modifierSymbols[first] {
                modifiers.insert(flag)
                rest = rest.dropFirst()
            } else if let plus = rest.firstIndex(of: "+"), plus != rest.startIndex, let flag = modifierNames[rest[..<plus].lowercased()] {
                modifiers.insert(flag)
                rest = rest[rest.index(after: plus)...]
            } else {
                break
            }
        }
        guard !rest.isEmpty else { return nil }
        if let code = names[rest.lowercased()] { return KeyCombo(keyCode: code, modifiers) }
        // With ⌘ held the layout may differ (Dvorak–QWERTY ⌘ types the QWERTY letters), and a ⌘ combo is looked up as the keys are pressed.
        guard rest.count == 1, let character = rest.first, let key = layoutKey(for: character, command: modifiers.contains(.command)) else {
            return nil
        }
        if key.shift { modifiers.insert(.shift) }
        return KeyCombo(keyCode: key.code, modifiers)
    }

    /// Why a session may not press the combo, nil when it may. Varnick's own shortcuts that work anywhere, as bound now: they would act
    /// on Varnick, and showing the panel would send the rest of the call into it. And log out, lock screen and Force Quit at macOS's
    /// default bindings: they end Varnick and every session, or take the Mac from the user. Every other combo goes to the app in front.
    @MainActor
    static func refusal(of combo: KeyCombo) -> String? {
        let own: [ShortcutAction] = [.toggleLauncher, .pinLauncher, .toggleListening]
        if own.contains(where: { Settings.shared.combo($0) == combo }) {
            return "\(combo.label) is one of Varnick's own shortcuts, which a session may not press"
        }
        let system = [KeyCombo(keyCode: kVK_ANSI_Q, [.command, .shift]), KeyCombo(keyCode: kVK_ANSI_Q, [.command, .shift, .option]),
                      KeyCombo(keyCode: kVK_ANSI_Q, [.command, .control]), KeyCombo(keyCode: kVK_Escape, [.command, .option])]
        if system.contains(combo) { return "\(combo.label) would log the user out, lock the screen or open Force Quit, which a session may not press" }
        return nil
    }

    // MARK: The layout

    /// The main block's keys, never the keypad's, which type the same characters.
    private static let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// The key that types a character on the current layout, with whether it needs ⇧. A letter is its key whatever its case. Nil when
    /// no key types it. The layout is the current one, else the current ASCII-capable one when the current is an input method.
    @MainActor
    private static func layoutKey(for character: Character, command: Bool) -> (code: Int, shift: Bool)? {
        guard let layout = layoutData() else { return nil }
        let wanted = String(character)
        var shifted: Int?
        for code in 0..<128 where !keypad.contains(code) {
            if let plain = translate(layout, code, shift: false, command: command) {
                if plain == wanted || (character.isLetter && plain.lowercased() == wanted.lowercased()) { return (code, false) }
            }
            // Shifted without ⌘: with ⌘ held a layout ignores ⇧ and names the unshifted character.
            if shifted == nil, translate(layout, code, shift: true, command: false) == wanted { shifted = code }
        }
        return shifted.map { ($0, true) }
    }

    @MainActor
    private static func layoutData() -> Data? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources {
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Data(Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data)
        }
        return nil
    }

    private static func translate(_ layout: Data, _ code: Int, shift: Bool, command: Bool) -> String? {
        var dead: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let state = (shift ? UInt32((shiftKey >> 8) & 0xFF) : 0) | (command ? UInt32((cmdKey >> 8) & 0xFF) : 0)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let table = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(table, UInt16(code), UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.unicodeScalars.contains { $0.properties.generalCategory == .control } ? nil : text
    }

    // MARK: Posting

    /// A character as one key-down and key-up carrying it as the events' Unicode string, so it types the same on any layout. No
    /// modifiers, whatever the user holds down. At the HID level, as click's mouse events are.
    static func post(_ character: Character) {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
            event.post(tap: .cghidEventTap)
        }
    }

    /// A combo's key-down, with its modifiers as the event's flags: the modifiers are never pressed as keys of their own, so none is
    /// left held down. Synchronous, so the caller's checks and the event have nothing awaited between; `release` always follows.
    static func press(_ combo: KeyCombo) {
        post(combo, down: true)
    }

    static func release(_ combo: KeyCombo) {
        post(combo, down: false)
    }

    private static func post(_ combo: KeyCombo, down: Bool) {
        var flags: CGEventFlags = []
        if combo.flags.contains(.command) { flags.insert(.maskCommand) }
        if combo.flags.contains(.shift) { flags.insert(.maskShift) }
        if combo.flags.contains(.option) { flags.insert(.maskAlternate) }
        if combo.flags.contains(.control) { flags.insert(.maskControl) }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
