import AppKit
import Carbon
import ServiceManagement
import VarnickPeer
import SwiftUI

extension Zmx {
    /// Whether panes run in zmx: the setting, and zmx next to the binary. The setting is the app's, so
    /// the package's `Zmx` doesn't know it.
    @MainActor static var isEnabled: Bool { Settings.shared.keepSessionsRunning && isAvailable }
}

/// A key plus modifiers, as pressed. `keyCode` is the physical key, so a binding keeps
/// working whatever the keyboard layout; the label is worked out from the current layout.
struct KeyCombo: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt   // NSEvent.ModifierFlags, only ⌃ ⌥ ⇧ ⌘

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    init(_ event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }

    /// Key caps for KeyHint: modifiers in macOS order, then the key.
    var tokens: [String] {
        var t: [String] = []
        if flags.contains(.control) { t.append("⌃") }
        if flags.contains(.option) { t.append("⌥") }
        if flags.contains(.shift) { t.append("⇧") }
        if flags.contains(.command) { t.append("⌘") }
        return t + [Self.keyName(Int(keyCode))]
    }

    var label: String { tokens.joined() }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// What the key types with no modifiers in the current layout ("E", "[", "=").
    static func keyName(_ keyCode: Int) -> String {
        if let name = named[keyCode] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case toggleLauncher, pinLauncher, toggleListening, settings
    case backToSearch, newTerminalTab, renameTab, endPane, doneSession, restartSession, paste, previousTab, nextTab, toggleFiles, sessionBoard
    case splitSideBySide, splitStacked, splitSideBySideOther, splitStackedOther, focusLeft, focusDown, focusUp, focusRight
    case webAddress, webReload
    case fontBigger, fontSmaller, fontReset

    var id: String { rawValue }

    /// Registered system-wide, so never matched against keys pressed in the panel.
    var isGlobal: Bool { self == .toggleLauncher || self == .pinLauncher || self == .toggleListening }

    var title: String {
        switch self {
        case .toggleLauncher: "Show / hide Varnick (anywhere)"
        case .pinLauncher: "Pin Varnick (keep open when focus leaves)"
        case .toggleListening: "Start / stop Listening (anywhere)"
        case .settings: "Settings"
        case .backToSearch: "Back to search / new session"
        case .newTerminalTab: "New terminal tab"
        case .renameTab: "Rename tab"
        case .endPane: "End session (focused pane)"
        case .doneSession: "Mark session done (focused Claude pane)"
        case .restartSession: "Restart session (focused Claude pane)"
        case .paste: "Paste text or image"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .toggleFiles: "Show / hide file tree"
        case .sessionBoard: "Show / hide session board"
        case .splitSideBySide: "Split side by side"
        case .splitStacked: "Split top and bottom"
        case .splitSideBySideOther: "Split side by side, choose Claude / terminal / browser"
        case .splitStackedOther: "Split top and bottom, choose Claude / terminal / browser"
        case .focusLeft: "Focus pane left"
        case .focusDown: "Focus pane below"
        case .focusUp: "Focus pane above"
        case .focusRight: "Focus pane right"
        case .webAddress: "Edit address (web pane)"
        case .webReload: "Reload (web pane)"
        case .fontBigger: "Bigger text"
        case .fontSmaller: "Smaller text"
        case .fontReset: "Default text size"
        }
    }

    var group: String {
        switch self {
        case .toggleLauncher, .pinLauncher, .toggleListening, .settings: "Varnick"
        case .backToSearch, .newTerminalTab, .renameTab, .endPane, .doneSession, .restartSession, .paste, .previousTab, .nextTab, .toggleFiles, .sessionBoard: "Tabs"
        case .splitSideBySide, .splitStacked, .splitSideBySideOther, .splitStackedOther, .focusLeft, .focusDown, .focusUp, .focusRight: "Splits"
        case .webAddress, .webReload: "Web"
        case .fontBigger, .fontSmaller, .fontReset: "Terminal"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleLauncher: KeyCombo(keyCode: kVK_Space, .control)
        case .pinLauncher: KeyCombo(keyCode: kVK_Space, [.control, .shift])
        case .toggleListening: KeyCombo(keyCode: kVK_ANSI_L, [.control, .option])
        case .settings: KeyCombo(keyCode: kVK_ANSI_Comma, .command)
        case .backToSearch: KeyCombo(keyCode: kVK_ANSI_N, .command)
        case .newTerminalTab: KeyCombo(keyCode: kVK_ANSI_T, [.command, .shift])
        case .renameTab: KeyCombo(keyCode: kVK_ANSI_R, [.command, .shift])
        case .endPane: KeyCombo(keyCode: kVK_ANSI_W, .command)
        case .doneSession: KeyCombo(keyCode: kVK_ANSI_D, [.command, .shift])
        case .restartSession: KeyCombo(keyCode: kVK_ANSI_R, [.command, .option])
        case .paste: KeyCombo(keyCode: kVK_ANSI_V, .command)
        case .previousTab: KeyCombo(keyCode: kVK_ANSI_LeftBracket, [.command, .shift])
        case .nextTab: KeyCombo(keyCode: kVK_ANSI_RightBracket, [.command, .shift])
        case .toggleFiles: KeyCombo(keyCode: kVK_ANSI_F, [.command, .shift])
        case .sessionBoard: KeyCombo(keyCode: kVK_ANSI_B, [.command, .shift])
        case .splitSideBySide: KeyCombo(keyCode: kVK_ANSI_E, [.command, .shift])
        case .splitStacked: KeyCombo(keyCode: kVK_ANSI_O, [.command, .shift])
        case .splitSideBySideOther: KeyCombo(keyCode: kVK_ANSI_E, [.command, .control, .shift])
        case .splitStackedOther: KeyCombo(keyCode: kVK_ANSI_O, [.command, .control, .shift])
        case .focusLeft: KeyCombo(keyCode: kVK_ANSI_H, [.command, .shift])
        case .focusDown: KeyCombo(keyCode: kVK_ANSI_J, [.command, .shift])
        case .focusUp: KeyCombo(keyCode: kVK_ANSI_K, [.command, .shift])
        case .focusRight: KeyCombo(keyCode: kVK_ANSI_L, [.command, .shift])
        case .webAddress: KeyCombo(keyCode: kVK_ANSI_L, .command)
        case .webReload: KeyCombo(keyCode: kVK_ANSI_R, .command)
        case .fontBigger: KeyCombo(keyCode: kVK_ANSI_Equal, .command)
        case .fontSmaller: KeyCombo(keyCode: kVK_ANSI_Minus, .command)
        case .fontReset: KeyCombo(keyCode: kVK_ANSI_0, .command)
        }
    }
}

/// User settings, saved in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Also read by the peer relay, which runs without Settings.
    nonisolated static let keepSessionsRunningKey = "keepSessionsRunning"
    static let skipPermissionsKey = "skipPermissions"
    static let screenAccessKey = "screenAccess"
    static let relevanceFilterOnKey = "relevanceFilterOn"
    static let relevanceFilterKey = "relevanceFilter"
    static let defaultFontSize: Double = 12.5
    static let defaultProjectFolders = ["~/Projects"]
    static let fontRange: ClosedRange<Double> = 9...24

    /// Folder new Claude sessions start in; empty uses VARNICK_CLAUDE_DIR, else the launch folder from a checkout, else the home folder.
    @Published var claudeDirectory: String { didSet { defaults.set(claudeDirectory, forKey: "claudeDirectory") } }
    @Published var skipPermissions: Bool { didSet { defaults.set(skipPermissions, forKey: Self.skipPermissionsKey) } }
    /// Gives the Claude sessions started or restarted while it is on the look, point, click, type, drag and window tools (`ScreenAccess`); off until
    /// turned on. Read at every call, so turning it off stops running sessions too. Independent of Point at the screen.
    @Published var screenAccess: Bool { didSet { defaults.set(screenAccess, forKey: Self.screenAccessKey) } }
    /// Claude and terminal panes run inside zmx and outlive Varnick (ADR 0004). Applies to panes
    /// started after it changes; use `Zmx.isEnabled` to act on it, since the binary may be missing.
    @Published var keepSessionsRunning: Bool { didSet { defaults.set(keepSessionsRunning, forKey: Self.keepSessionsRunningKey) } }
    /// Runs the Phone page's server in zmx (ADR 0011, `PhonePageServer`); off by default. Varnick applies it at launch and
    /// when it changes.
    @Published var servePhonePage: Bool { didSet { defaults.set(servePhonePage, forKey: Self.servePhonePageKey) } }
    static let servePhonePageKey = "servePhonePage"
    /// Experimental (Settings › Experimental): the board's Problems tab, `!problems`, and the work-link hooks (ADR 0020) in the Claude
    /// sessions this Mac starts. Off by default, for every install. The work links already recorded are kept either way.
    @Published var problemsBoard: Bool { didSet { defaults.set(problemsBoard, forKey: Self.problemsBoardKey) } }
    static let problemsBoardKey = "problemsBoard"
    /// Searched for git repos to start a session in (`#name`); `~` allowed.
    @Published var projectFolders: [String] { didSet { defaults.set(projectFolders, forKey: "projectFolders") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "terminalFontSize") } }
    /// Voice Varnick speaks in (an `AVSpeechSynthesisVoice` identifier); empty is the system voice.
    /// With an ElevenLabs voice chosen it is the fallback voice, spoken when ElevenLabs fails (ADR 0028).
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    /// The ElevenLabs voice's id Varnick speaks in; empty means the installed voice `voice` speaks. Kept when the key is removed.
    @Published var elevenLabsVoice: String { didSet { defaults.set(elevenLabsVoice, forKey: "elevenLabsVoice") } }
    /// The account's voices as last fetched, shown meanwhile and offline.
    @Published private(set) var elevenLabsVoices: [ElevenLabs.Voice] {
        didSet { defaults.set(try? JSONEncoder().encode(elevenLabsVoices), forKey: "elevenLabsVoices") }
    }
    /// The last ElevenLabs failure, a line's or the voice list's, whichever came later; shown under the Voice picker, in memory only.
    /// A line that plays from ElevenLabs clears it, and a fetched list clears it only if the list's failure put it there.
    @Published private(set) var elevenLabsNote: String?
    private var elevenLabsNoteIsFromList = false
    /// Answers a mic phrase that starts "Hey Varnick" aloud, while Listening is on (ADR 0015); off until turned on.
    @Published var heyVarnick: Bool { didSet { defaults.set(heyVarnick, forKey: "heyVarnick") } }
    /// Lets a spoken request point at the screen: Varnick reads the focused window's controls and draws an arrow (ADR 0019); off
    /// until turned on. `screenPointingOn` says whether its other conditions hold too.
    @Published var pointAtScreen: Bool { didSet { defaults.set(pointAtScreen, forKey: "pointAtScreen") } }
    /// Only changed bindings are stored; nil means deliberately unbound.
    @Published private(set) var overrides: [ShortcutAction: KeyCombo?] { didSet { saveOverrides() } }
    /// Action waiting for its new shortcut; the next key press is captured for it.
    @Published var recording: ShortcutAction?
    /// Whether search also finds by meaning, and whether the minute sync embeds (Settings › Search); on for everyone
    /// who has never touched it. Vectors already stored stay while it is off.
    @Published var semanticSearch: Bool { didSet { defaults.set(semanticSearch, forKey: "semanticSearch") } }
    /// Where Search embeddings run (Settings › Models), and the model server's address and model for Server (ADR 0014).
    @Published var searchEmbeddingsRunOn: ModelRunOn { didSet { defaults.set(searchEmbeddingsRunOn.rawValue, forKey: "searchEmbeddingsRunOn") } }
    @Published var embeddingServerAddress: String { didSet { defaults.set(embeddingServerAddress, forKey: "embeddingServer") } }
    @Published var embeddingServerModel: String { didSet { defaults.set(embeddingServerModel, forKey: "embeddingServerModel") } }
    /// Where Text generation runs (Settings › Models), and the model server's address and model for Server. Absent reads as Claude
    /// Code (ADR 0029); `storeTextGenerationIfAbsent` keeps the installs that already answer with this Mac's model on `local`.
    @Published var textGenerationRunOn: TextRunOn { didSet { defaults.set(textGenerationRunOn.rawValue, forKey: Self.textGenerationRunOnKey) } }
    static let textGenerationRunOnKey = "textGenerationRunOn"
    @Published var textGenerationServerAddress: String { didSet { defaults.set(textGenerationServerAddress, forKey: "textGenerationServer") } }
    @Published var textGenerationServerModel: String { didSet { defaults.set(textGenerationServerModel, forKey: "textGenerationServerModel") } }
    /// Whether the relevance filter runs (Settings › Search). Searches read it each time, so a change applies to the next search.
    /// While neither this nor `relevanceFilter` is stored it is on only with a TypeSafe key, and not stored.
    @Published var relevanceFilterOn: Bool {
        didSet { if !workingOutFilterSwitch { defaults.set(relevanceFilterOn, forKey: Self.relevanceFilterOnKey) } }
    }
    private var workingOutFilterSwitch = false
    /// Who judges it (Settings › Models); kept while the filter is off.
    @Published var relevanceFilter: RelevanceBackend {
        didSet {
            defaults.set(relevanceFilter.rawValue, forKey: Self.relevanceFilterKey)
            // The old `off` is overwritten here, and the switch's state is only derived from it while unsaved.
            if defaults.object(forKey: Self.relevanceFilterOnKey) == nil { defaults.set(relevanceFilterOn, forKey: Self.relevanceFilterOnKey) }
        }
    }
    /// TypeSafe key for the relevance filter: the Keychain (Settings › Models), else
    /// TYPESAFE_API_KEY from the environment or, in a checkout, `.env`. Never stored in UserDefaults.
    @Published private(set) var typesafeKey: String?
    @Published private(set) var typesafeKeyInKeychain: Bool
    @Published private(set) var typesafeKeyError: String?
    private static let typesafeAccount = "TYPESAFE_API_KEY"
    /// The optional key for a model server (Settings › Models › Keys): the Keychain only, no `.env`, and not kept in memory;
    /// `ModelServer` reads it when it sends a request.
    @Published private(set) var modelServerKeyInKeychain: Bool
    @Published private(set) var modelServerKeyError: String?
    /// The ElevenLabs key (Settings › Models › Keys): the Keychain only, no `.env` or environment, and not kept in memory;
    /// `ElevenLabs` reads it when it sends a request.
    @Published private(set) var elevenLabsKeyInKeychain: Bool
    @Published private(set) var elevenLabsKeyError: String?
    static let defaultEmbeddingServerModel = Embedder.modelKey

    /// Whether Varnick's lines go to ElevenLabs: a voice is chosen and a key is saved. Otherwise the installed voice speaks and
    /// nothing is sent.
    var speaksInElevenLabs: Bool { !elevenLabsVoice.isEmpty && elevenLabsKeyInKeychain }

    /// The judge the next search uses; nil is no filter. VARNICK_EVAL_FILTER (typesafe, local, off) overrides
    /// both settings, so `--search-eval` can compare filters without writing them.
    var activeRelevanceFilter: RelevanceBackend? {
        let chosen = relevanceFilterOn ? relevanceFilter : nil
        switch ProcessInfo.processInfo.environment["VARNICK_EVAL_FILTER"] {
        case "off": return nil
        case let name?: return RelevanceBackend(rawValue: name) ?? chosen
        case nil: return chosen
        }
    }

    /// The TypeSafe key while the relevance filter is on TypeSafe: the gate of Jev's choice of where to look and of which element to
    /// point at (ADR 0016, 0019).
    var typesafeGateKey: String? {
        activeRelevanceFilter == .typesafe ? typesafeKey : nil
    }

    /// Whether a spoken request may go to the screen: the switch, Hey Varnick and the gate. When false the decide questions have
    /// no screen in them, and the switch acts as off.
    var screenPointingOn: Bool {
        pointAtScreen && heyVarnick && typesafeGateKey != nil
    }

    /// Where the next search or sync embeds. VARNICK_EMBEDDINGS overrides the settings in every process, the app included:
    /// `local`, `server` (the saved address), or an address (`http…`), which is that server with the saved model.
    var activeEmbeddings: ServerChoice {
        Self.choice(env: "VARNICK_EMBEDDINGS", saved: searchEmbeddingsRunOn, address: embeddingServerAddress,
                    model: embeddingServerModel, defaultModel: Self.defaultEmbeddingServerModel)
    }

    /// Where the next text is written, overridden by VARNICK_TEXT_GENERATION the same way, and by `claude`: Claude Code.
    var activeTextGeneration: TextChoice {
        let server = Self.choice(env: "VARNICK_TEXT_GENERATION", saved: .local, address: textGenerationServerAddress,
                                 model: textGenerationServerModel, defaultModel: ServerGenerator.defaultModel)
        switch ProcessInfo.processInfo.environment["VARNICK_TEXT_GENERATION"]?.trimmingCharacters(in: .whitespaces) {
        case "claude": return (.claude, server.address, server.model)
        case "local": return (.local, server.address, server.model)
        case "server": return (.server, server.address, server.model)
        case let given? where given.lowercased().hasPrefix("http"): return (.server, server.address, server.model)
        default: return (textGenerationRunOn, server.address, server.model)
        }
    }

    private static func choice(env: String, saved: ModelRunOn, address: String, model: String, defaultModel: String) -> ServerChoice {
        let address = address.trimmingCharacters(in: .whitespaces)
        let model = model.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : model.trimmingCharacters(in: .whitespaces)
        switch ProcessInfo.processInfo.environment[env]?.trimmingCharacters(in: .whitespaces) {
        case "local": return (.local, address, model)
        case "server": return (.server, address, model)
        case let given? where given.lowercased().hasPrefix("http"): return (.server, given, model)
        default: return (saved, address, model)
        }
    }

    private let defaults = UserDefaults.standard

    /// Stores Skip permissions once when absent: on if a sessions file exists (an install from before the default
    /// changed), else off. Runs first in `applicationDidFinishLaunching` (see where-it-breaks).
    static func storeSkipPermissionsIfAbsent() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: skipPermissionsKey) == nil else { return }
        defaults.set(FileManager.default.fileExists(atPath: SessionStore.fileURL.path), forKey: skipPermissionsKey)
    }

    /// Stores `local` once for Text generation when it was never chosen and this Mac already answers with its model (Hey Varnick is on,
    /// or Gemma is installed): Claude Code is the default for new installs only, and a default worked out on each read would move
    /// under the user later. Otherwise the key stays absent and reads as Claude Code. Runs beside `storeSkipPermissionsIfAbsent`.
    static func storeTextGenerationIfAbsent() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: textGenerationRunOnKey) == nil else { return }
        if defaults.bool(forKey: "heyVarnick") || TextGenerator.isInstalled {
            defaults.set(TextRunOn.local.rawValue, forKey: textGenerationRunOnKey)
        }
    }

    private var neitherRelevanceKeyStored: Bool {
        defaults.object(forKey: Self.relevanceFilterOnKey) == nil && defaults.string(forKey: Self.relevanceFilterKey) == nil
    }

    private init() {
        claudeDirectory = defaults.string(forKey: "claudeDirectory") ?? ""
        skipPermissions = defaults.object(forKey: Self.skipPermissionsKey) as? Bool ?? false
        screenAccess = defaults.bool(forKey: Self.screenAccessKey)
        keepSessionsRunning = defaults.bool(forKey: Self.keepSessionsRunningKey)
        servePhonePage = defaults.bool(forKey: Self.servePhonePageKey)
        problemsBoard = defaults.bool(forKey: Self.problemsBoardKey)
        projectFolders = defaults.stringArray(forKey: "projectFolders") ?? Self.defaultProjectFolders
        fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? Self.defaultFontSize
        voice = defaults.string(forKey: "voice") ?? ""
        elevenLabsVoice = defaults.string(forKey: "elevenLabsVoice") ?? ""
        elevenLabsVoices = defaults.data(forKey: "elevenLabsVoices")
            .flatMap { try? JSONDecoder().decode([ElevenLabs.Voice].self, from: $0) } ?? []
        heyVarnick = defaults.bool(forKey: "heyVarnick")
        pointAtScreen = defaults.bool(forKey: "pointAtScreen")
        semanticSearch = defaults.object(forKey: "semanticSearch") as? Bool ?? true
        searchEmbeddingsRunOn = defaults.string(forKey: "searchEmbeddingsRunOn").flatMap(ModelRunOn.init) ?? .local
        embeddingServerAddress = defaults.string(forKey: "embeddingServer") ?? ""
        embeddingServerModel = defaults.string(forKey: "embeddingServerModel") ?? Self.defaultEmbeddingServerModel
        textGenerationRunOn = defaults.string(forKey: Self.textGenerationRunOnKey).flatMap(TextRunOn.init) ?? .claude
        textGenerationServerAddress = defaults.string(forKey: "textGenerationServer") ?? ""
        textGenerationServerModel = defaults.string(forKey: "textGenerationServerModel") ?? ServerGenerator.defaultModel
        modelServerKeyInKeychain = Keychain.exists(ModelServer.keyAccount)
        elevenLabsKeyInKeychain = Keychain.exists(ElevenLabs.keyAccount)
        let storedKey = Keychain.read(Self.typesafeAccount)
        typesafeKeyInKeychain = storedKey != nil
        let key = storedKey ?? Self.typesafeKeyFromEnvironment()
        typesafeKey = key
        // `relevanceFilter` once held `off`: that reads as the switch off with TypeSafe chosen. With neither key
        // stored the switch is on only when there is a TypeSafe key, which is why the key is read first.
        let storedFilter = defaults.string(forKey: Self.relevanceFilterKey)
        relevanceFilter = storedFilter.flatMap(RelevanceBackend.init) ?? .typesafe
        relevanceFilterOn = defaults.object(forKey: Self.relevanceFilterOnKey) as? Bool
            ?? (storedFilter.map { $0 != "off" } ?? (key != nil))
        let stored = defaults.data(forKey: "shortcuts")
            .flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, combo in
            ShortcutAction(rawValue: key).map { ($0, combo) }
        })
    }

    private func saveOverrides() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "shortcuts") }
    }

    /// Empty removes the saved key, falling back to TYPESAFE_API_KEY or `.env` if there is one.
    func setTypesafeKey(_ key: String) {
        typesafeKeyError = nil
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Keychain.delete(Self.typesafeAccount)
            typesafeKeyInKeychain = false
            typesafeKey = Self.typesafeKeyFromEnvironment()
            workOutRelevanceFilterOn()
            return
        }
        do {
            try Keychain.save(key, for: Self.typesafeAccount)
            typesafeKeyInKeychain = true
            typesafeKey = key
            workOutRelevanceFilterOn()
        } catch {
            typesafeKeyError = error.localizedDescription
        }
    }

    /// Empty removes the saved key.
    func setModelServerKey(_ key: String) {
        modelServerKeyError = nil
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Keychain.delete(ModelServer.keyAccount)
            modelServerKeyInKeychain = false
            return
        }
        do {
            try Keychain.save(key, for: ModelServer.keyAccount)
            modelServerKeyInKeychain = true
        } catch {
            modelServerKeyError = error.localizedDescription
        }
    }

    /// Empty removes the saved key; the chosen voice stays, and the installed voice speaks until a key is saved again.
    func setElevenLabsKey(_ key: String) {
        elevenLabsKeyError = nil
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Keychain.delete(ElevenLabs.keyAccount)
            elevenLabsKeyInKeychain = false
            elevenLabsNote = nil
            return
        }
        do {
            try Keychain.save(key, for: ElevenLabs.keyAccount)
            elevenLabsKeyInKeychain = true
            elevenLabsNote = nil
            Task { await refreshElevenLabsVoices() }
        } catch {
            elevenLabsKeyError = error.localizedDescription
        }
    }

    /// Fetches the account's voices (the network wait is off the main actor) and keeps them. A failure leaves the last list and says
    /// why under the Voice picker.
    func refreshElevenLabsVoices() async {
        guard elevenLabsKeyInKeychain else { return }
        do {
            let voices = try await ElevenLabs.voices()
            guard !Task.isCancelled else { return }
            elevenLabsVoices = voices
            if elevenLabsNoteIsFromList { elevenLabsNote = nil }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, elevenLabsKeyInKeychain else { return }
            noteElevenLabs((error as? ElevenLabs.Failure)?.note ?? "ElevenLabs not answering", fromList: true)
        }
    }

    /// Sets, or with nil clears, `elevenLabsNote`.
    func noteElevenLabs(_ note: String?, fromList: Bool = false) {
        elevenLabsNote = note
        elevenLabsNoteIsFromList = fromList && note != nil
    }

    /// While neither relevance key is stored, a key added or removed in Settings moves the switch with it, so a new
    /// user who adds a key sees the filter on without a restart. Not stored: the switch's own change does that.
    private func workOutRelevanceFilterOn() {
        guard neitherRelevanceKeyStored else { return }
        workingOutFilterSwitch = true
        relevanceFilterOn = typesafeKey != nil
        workingOutFilterSwitch = false
    }

    /// `.env` is read only from a checkout; the installed app takes the key from the Keychain or the environment.
    private static func typesafeKeyFromEnvironment() -> String? {
        Reranker.loadAPIKey(env: ProcessInfo.processInfo.environment,
                            directory: LaunchSnapshot.checkout == nil ? nil : FileManager.default.currentDirectoryPath)
    }

    func combo(_ action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action] { return override }
        return action.defaultCombo
    }

    func isDefault(_ action: ShortcutAction) -> Bool { overrides[action] == nil }

    /// Binds `combo` to `action`; any other action using it is unbound, so one key
    /// never does two things.
    func set(_ action: ShortcutAction, _ combo: KeyCombo?) {
        var next = overrides
        if let combo {
            for other in ShortcutAction.allCases where other != action && self.combo(other) == combo {
                next[other] = .some(nil)
            }
        }
        next[action] = combo == action.defaultCombo ? nil : .some(combo)
        overrides = next
    }

    func reset(_ action: ShortcutAction) {
        // Taking the default back may steal it from whatever was rebound to it.
        set(action, action.defaultCombo)
    }

    func resetAllShortcuts() { overrides = [:] }

    /// The local action for a key press. ⌘= also answers to ⌘+ (⇧=), the way it's labelled.
    func action(for event: NSEvent) -> ShortcutAction? {
        let pressed = KeyCombo(event)
        let local = ShortcutAction.allCases.filter { !$0.isGlobal }
        if let hit = local.first(where: { combo($0) == pressed }) { return hit }
        if pressed.flags.contains(.shift), Int(pressed.keyCode) == kVK_ANSI_Equal {
            let unshifted = KeyCombo(keyCode: kVK_ANSI_Equal, pressed.flags.subtracting(.shift))
            return local.first { combo($0) == unshifted }
        }
        return nil
    }

    /// Next key press while recording: esc cancels, ⌫ unbinds, a bare letter needs a modifier.
    func record(_ event: NSEvent) {
        guard let action = recording else { return }
        let pressed = KeyCombo(event)
        switch Int(event.keyCode) {
        case kVK_Escape where pressed.flags.isEmpty:
            break
        case kVK_Delete where pressed.flags.isEmpty, kVK_ForwardDelete where pressed.flags.isEmpty:
            set(action, nil)
        default:
            let isFunctionKey = KeyCombo.keyName(Int(event.keyCode)).hasPrefix("F") && KeyCombo.keyName(Int(event.keyCode)).count > 1
            guard !pressed.flags.isEmpty || isFunctionKey else { NSSound.beep(); return }
            set(action, pressed)
        }
        recording = nil
    }

    func adjustFont(_ delta: Double) {
        fontSize = min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, fontSize + delta))
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var embedder: Embedder
    @ObservedObject var localReranker: LocalReranker
    @ObservedObject var textGenerator: TextGenerator
    @ObservedObject var embeddingServer: ModelServerState
    @ObservedObject var textGenerationServer: ModelServerState
    @ObservedObject var claudeCode: ClaudeCodeState
    let close: () -> Void
    /// Opens the Restart Varnick card (`LauncherModel.askRestart`): a restart without a build.
    let askRestart: () -> Void
    /// Folder names of the apps that open panes run (`LauncherModel.openAppFolders`): turning a catalog app off waits for them.
    let openAppFolders: () -> Set<String>
    @State private var typesafeKeyDraft = ""
    @State private var modelServerKeyDraft = ""
    @State private var elevenLabsKeyDraft = ""
    /// Last section viewed, so Settings reopens where you left it.
    @AppStorage("settingsSection") private var sectionID = SettingsSection.claude.rawValue

    private var section: SettingsSection { SettingsSection(rawValue: sectionID) ?? .claude }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { KeyHint(label: "Close", keys: ["esc"]) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, Theme.gutter)
            .frame(height: LauncherModel.searchHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)

            HStack(spacing: 0) {
                sidebar
                Theme.hairline.frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .font(.system(size: 20, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        switch section {
                        case .claude:
                            SettingRow(title: "Default folder", detail: "Where new sessions start when no #project is picked. Resumed sessions keep their own folder.") {
                                Text(folderLabel)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(settings.claudeDirectory.isEmpty ? .secondary : .primary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…") {
                                    if let path = pickFolders(multiple: false, from: LauncherModel.claudeDirectory).first {
                                        settings.claudeDirectory = path
                                    }
                                }
                                if !settings.claudeDirectory.isEmpty {
                                    Button("Default") { settings.claudeDirectory = "" }
                                }
                        }
                        SettingRow(title: "Project folders", detail: "Searched for git repos to start in with #name.") {
                            Text(settings.projectFolders.joined(separator: ", "))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let folders = pickFolders(multiple: true, from: settings.projectFolders.first ?? "~")
                                if !folders.isEmpty {
                                    settings.projectFolders = folders.map { ($0 as NSString).abbreviatingWithTildeInPath }
                                }
                            }
                            if settings.projectFolders != Settings.defaultProjectFolders {
                                Button("Default") { settings.projectFolders = Settings.defaultProjectFolders }
                            }
                        }
                        SettingRow(title: "Skip permissions",
                                   detail: "Start sessions with --dangerously-skip-permissions: Claude runs tools without asking.") {
                            Toggle("", isOn: $settings.skipPermissions).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        SettingRow(title: "Screen access",
                                   detail: "Sessions started or restarted while this is on get tools to look at a window, point at things with the arrow, click, type, drag and move or resize windows, on this Mac's screen. What they are shown (a window's title, its controls' names and visible text, which control has focus, and short text read from a picture of it) goes to Anthropic with the session. So does a picture of the window when they ask for one: it shows everything on the window, including what you typed, with password fields Varnick can see painted black. A picture of the screen, which they can also ask for, shows everything on every display or the one asked for: Varnick's own window and other sessions, what you typed, and password fields, none of it blacked out. Nothing asks before an action: the arrow shows on the target for a second first. Nothing is typed into a password field Varnick can see. Every pane already has Varnick's permissions: see SECURITY.md.") {
                            ScreenPermissionsView(askRestart: askRestart)
                            Toggle("", isOn: $settings.screenAccess).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        SettingRow(title: "Keep sessions running",
                                   detail: "Claude and terminal panes keep running when Varnick restarts, quits or crashes, and reconnect when it is back. Closing a pane ends it.") {
                            if !Zmx.isAvailable {
                                Text("Needs zmx: build with make").font(.system(size: 12)).foregroundStyle(.orange)
                            }
                            Toggle("", isOn: $settings.keepSessionsRunning).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(!Zmx.isAvailable)
                        }
                        if ResourceFolder.current.inBundle { OpenAtLoginRow() }
                        SettingRow(title: "Text size", detail: "Terminal font size in points.") {
                            Button { settings.adjustFont(-0.5) } label: { Image(systemName: "minus") }
                            Text(String(format: "%.1f", settings.fontSize))
                                .font(.system(size: 12).monospacedDigit())
                                .frame(width: 34)
                            Button { settings.adjustFont(0.5) } label: { Image(systemName: "plus") }
                            if settings.fontSize != Settings.defaultFontSize {
                                Button("Default") { settings.fontSize = Settings.defaultFontSize }
                            }
                        }
                        case .apps:
                        AppsSettingsView(openAppFolders: openAppFolders)
                        case .search:
                        SettingRow(title: "Semantic search",
                                   detail: "Also finds pages and sessions by meaning, not only matching words. Runs on \(embeddingsPlace).") {
                            if settings.semanticSearch, let need = embedderNeed {
                                modelsLink(need)
                            }
                            Toggle("", isOn: $settings.semanticSearch).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        SettingRow(title: "Relevance filter",
                                   detail: "On a ? search, after you pause typing, moves the results that match what you meant to the top. Runs on \(settings.relevanceFilter.place).") {
                            if settings.relevanceFilterOn, let need = relevanceNeed {
                                modelsLink(need)
                            }
                            Toggle("", isOn: $settings.relevanceFilterOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        case .listening:
                        SettingRow(title: "Hey Varnick",
                                   detail: "While Listening is on, say \"Hey Varnick\" and ask for a page, a bookmark or a Claude session. Varnick answers out loud from History, Bookmarks and your sessions, and opens nothing (it shows an arrow only with Point at the screen, below). With the relevance filter on TypeSafe (Settings › Search) and a key saved, the words you say after \"Hey Varnick\" are sent to TypeSafe to choose where to look, and the words it then searches for go with the titles, sites and descriptions of the top 20 pages, as a typed search sends them, to judge which match. Choosing TypeSafe sends what its features need; with On this Mac, or the filter off, nothing goes to TypeSafe. With Text generation on Claude Code (the default), what you say and the results it reads go to Anthropic to write the answer. With an ElevenLabs voice chosen below, the answers Varnick speaks go to ElevenLabs.") {
                            if Listener.shared.state.isUnavailable {
                                Text(Listener.shared.state.note ?? "Needs macOS 26").font(.system(size: 12)).foregroundStyle(.orange)
                            } else if let need = textGenerationNeed {
                                modelsLink(need)
                            } else if textGenerationFallsBack {
                                modelsLink("Using this Mac's model")
                            }
                            Toggle("", isOn: $settings.heyVarnick).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(!settings.heyVarnick && (Listener.shared.state.isUnavailable || textGenerationNeed != nil))
                        }
                        SettingRow(title: "Point at the screen",
                                   detail: "Ask \"Hey Varnick, where's the Allow button\" and Varnick draws an arrow on it. It reads the window's elements and, if they lack it, a picture of the window, both on this Mac; the picture is never saved or sent. Needs the relevance filter on TypeSafe with a key: your words, the window's title and its visible short text go there, and so may short text typed in a field Varnick can't place. With Varnick's panel open, it is read too, so its session, project, Mac and page names go. A rebuild may need both permissions again. Every session and shell in Varnick's panes gets them too, kept running in zmx or not: see SECURITY.md.") {
                            // Above the permissions in one column, at its natural width: beside them the note would get no width.
                            VStack(alignment: .trailing, spacing: 6) {
                                if !settings.heyVarnick {
                                    Text("Needs Hey Varnick").font(.system(size: 12)).foregroundStyle(.orange)
                                } else if !screenGateOpen {
                                    Button("Needs the filter on TypeSafe: Settings › Search") { sectionID = SettingsSection.search.rawValue }
                                        .buttonStyle(.link)
                                        .font(.system(size: 12))
                                }
                                ScreenPermissionsView(askRestart: askRestart)
                            }
                            .fixedSize()
                            Toggle("", isOn: $settings.pointAtScreen).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(!settings.pointAtScreen && (!settings.heyVarnick || !screenGateOpen))
                        }
                        SettingRow(title: "Voice",
                                   detail: "What Varnick speaks in. An ElevenLabs voice sends every line Varnick speaks to ElevenLabs, answers included, which can repeat words of your request and name your pages, sessions and folders; the voices installed on this Mac send nothing.") {
                            VStack(alignment: .trailing, spacing: 4) {
                                if !settings.elevenLabsKeyInKeychain {
                                    Button("ElevenLabs voices: add a key in Settings › Models") { sectionID = SettingsSection.models.rawValue }
                                        .buttonStyle(.link)
                                        .font(.system(size: 12))
                                }
                                VoicePicker(settings: settings)
                                if let note = settings.elevenLabsNote {
                                    Text(note).font(.system(size: 12)).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        // With no key the installed voice is the main voice, and the Voice row above is its picker.
                        if settings.speaksInElevenLabs {
                            SettingRow(title: "Fallback voice", detail: "Speaks on this Mac when ElevenLabs fails or is slow.") {
                                InstalledVoicePicker(settings: settings)
                            }
                        }
                        case .peers:
                        PeersSettingsView()
                        case .models:
                        SettingRow(title: "Search embeddings",
                                   detail: "Qwen3-Embedding 0.6B. Semantic search uses it to find pages and sessions by meaning. It is the only choice: another model would mean embedding the whole archive again.") {
                            Picker("", selection: $settings.searchEmbeddingsRunOn) {
                                ForEach(ModelRunOn.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                        }
                        switch settings.searchEmbeddingsRunOn {
                        case .server:
                            ServerSettingRow(
                                detail: "Sends your searches, the words of what you ask out loud with Hey Varnick, the prompts you type in the panel, and the text of your pages and Claude sessions (titles, sites, descriptions, search terms and prompts, with Claude's last reply to each, your paired Macs' too) to \(ModelServer.name(of: settings.embeddingServerAddress) ?? "the server below"), over your tailnet.",
                                addressPlaceholder: "http://linux-box:11434", address: $settings.embeddingServerAddress,
                                model: $settings.embeddingServerModel, server: embeddingServer)
                        case .local:
                        SettingRow(title: "On this Mac",
                                   detail: "8-bit, runs on this Mac after a one-time \(Embedder.downloadSize) download.") {
                            switch embedder.state {
                            case .unavailable:
                                Text("Needs mlx.metallib: build with make").font(.system(size: 12)).foregroundStyle(.orange)
                            case .missing:
                                Button("Download") { Task { await embedder.download() } }
                            case .downloading(let fraction):
                                ProgressView(value: fraction).frame(width: 120)
                                Text("\(Int(fraction * 100))%")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            case .ready:
                                Text("Installed").font(.system(size: 12)).foregroundStyle(.secondary)
                            case .failed(let message):
                                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                                    .lineLimit(1).truncationMode(.tail)
                                Button("Retry") { Task { await embedder.download() } }
                            }
                        }
                        }
                        SettingRow(title: "Relevance filter",
                                   detail: "Judges which of the top 20 results of a ? search, or of a request to Hey Varnick, match what it is after.") {
                            Picker("", selection: $settings.relevanceFilter) {
                                ForEach(RelevanceBackend.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                        }
                        switch settings.relevanceFilter {
                        case .typesafe:
                            SettingRow(title: "TypeSafe",
                                       detail: "Sends your search and the titles, sites and page descriptions (not full addresses) of the top 20 results to TypeSafe. A request to Hey Varnick sends the words you say after \"Hey Varnick\" to choose where to look, and then its search words with the top 20 pages the same way. With Point at the screen on, a request about the screen sends the window's title and its controls' names, kinds and nearby text instead, and after a miss the window's short lines of text read from a picture of it. Choosing TypeSafe sends what its features need; with On this Mac, or the filter off, nothing goes to TypeSafe.") {
                                if settings.typesafeKeyInKeychain {
                                    Text("Key saved").font(.system(size: 12)).foregroundStyle(.secondary)
                                } else if settings.typesafeKey != nil {
                                    envKeyNote
                                } else {
                                    Text("Needs a key").font(.system(size: 12)).foregroundStyle(.orange)
                                }
                            }
                        case .local:
                            SettingRow(title: "On this Mac",
                                       detail: "A model trained on your own history judges the results. Nothing is sent anywhere.") {
                                if let error = localReranker.importError {
                                    Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                                }
                                switch localReranker.state {
                                case .unavailable:
                                    Text("Needs mlx.metallib: build with make").font(.system(size: 12)).foregroundStyle(.orange)
                                case .missing:
                                    chooseCheckpointButton
                                case .importing:
                                    ProgressView().controlSize(.small)
                                    Text("Importing…").font(.system(size: 12)).foregroundStyle(.secondary)
                                case .ready:
                                    Text("Installed").font(.system(size: 12)).foregroundStyle(.secondary)
                                    chooseCheckpointButton
                                case .failed(let message):
                                    Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                                        .lineLimit(1).truncationMode(.tail)
                                    Button("Retry") { Task { await localReranker.retry() } }
                                    chooseCheckpointButton
                                }
                            }
                        }
                        SettingRow(title: "Text generation",
                                   detail: "Writes short text for Varnick's features, such as Hey Varnick's answers.") {
                            Picker("", selection: $settings.textGenerationRunOn) {
                                ForEach(TextRunOn.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 330)
                        }
                        switch settings.textGenerationRunOn {
                        case .claude:
                            ClaudeCodeSettingRow(
                                detail: "Runs your own Claude Code on your Claude subscription, with Claude Haiku: no tools, none of your settings, hooks, plugins, CLAUDE.md or memory, and no transcript saved. With Hey Varnick on, Anthropic gets what you ask out loud and the kind, title, site or folder, date and description of the few results it reads (for a Claude session, its prompts, your paired Macs' too). Each answer counts toward your plan's usage limits.",
                                state: claudeCode)
                            gemmaRow(title: "Fallback on this Mac",
                                     detail: "Writes the text when Claude Code can't: claude missing or logged out, offline, at your plan's limit, or too slow. Gemma 4 E2B, 4-bit, on this Mac; nothing is sent anywhere. One-time \(TextGenerator.downloadSize) download, about 2.5 GB of memory while in use, freed after 10 idle minutes. Optional.")
                        case .server:
                            ServerSettingRow(
                                detail: "With Hey Varnick on, \(ModelServer.name(of: settings.textGenerationServerAddress) ?? "the server below") gets, over your tailnet, what you ask out loud and the kind, title, site or folder, date and description of the few results it reads (for a Claude session, its prompts, your paired Macs' too).",
                                addressPlaceholder: "http://linux-box:8080", address: $settings.textGenerationServerAddress,
                                model: $settings.textGenerationServerModel, server: textGenerationServer)
                        case .local:
                            gemmaRow(title: "On this Mac",
                                     detail: "Gemma 4 E2B, 4-bit. Runs on this Mac; nothing is sent anywhere. One-time \(TextGenerator.downloadSize) download. Uses about 2.5 GB of memory while in use, and frees it after 10 idle minutes.")
                        }
                        SectionLabel(text: "Keys")
                        SettingRow(title: "TypeSafe",
                                   detail: "Used by the relevance filter when it runs on TypeSafe, for searches and for Hey Varnick, which also uses it to choose where to look. Kept in the macOS Keychain.") {
                            if let error = settings.typesafeKeyError {
                                Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                            }
                            if settings.typesafeKeyInKeychain {
                                Button("Remove key") { settings.setTypesafeKey("") }
                            } else {
                                if settings.typesafeKey != nil { envKeyNote }
                                SecureField("TypeSafe API key", text: $typesafeKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 170)
                                    .onSubmit { saveTypesafeKey() }
                                Button("Save") { saveTypesafeKey() }
                                    .disabled(typesafeKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        SettingRow(title: "Model server",
                                   detail: "Sent to a model server that asks for one, whichever role it serves. A headless host's embedding service doesn't.") {
                            if let error = settings.modelServerKeyError {
                                Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                            }
                            if settings.modelServerKeyInKeychain {
                                Text("Key saved").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Remove key") { settings.setModelServerKey("") }
                            } else {
                                SecureField("Model server key", text: $modelServerKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 170)
                                    .onSubmit { saveModelServerKey() }
                                Button("Save") { saveModelServerKey() }
                                    .disabled(modelServerKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        SettingRow(title: "ElevenLabs",
                                   detail: "Speaks Hey Varnick's answers in an ElevenLabs voice, chosen in Settings › Listening. The key needs the Text to Speech and Voices Read permissions. With a key saved, Varnick asks ElevenLabs for your voices (the request carries only the key). Kept in the macOS Keychain.") {
                            if let error = settings.elevenLabsKeyError {
                                Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                            }
                            if settings.elevenLabsKeyInKeychain {
                                Text("Key saved").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Remove key") { settings.setElevenLabsKey("") }
                            } else {
                                SecureField("ElevenLabs API key", text: $elevenLabsKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 170)
                                    .onSubmit { saveElevenLabsKey() }
                                Button("Save") { saveElevenLabsKey() }
                                    .disabled(elevenLabsKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        case .shortcuts:
                        ForEach(groups, id: \.self) { group in
                            SectionLabel(text: group)
                            ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                                ShortcutRow(action: action, settings: settings)
                            }
                        }
                        HStack {
                            Text("Click a shortcut, then press the new keys. esc cancels, ⌫ clears.")
                                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Restore default shortcuts") { settings.resetAllShortcuts() }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        case .experimental:
                        SettingRow(title: "Problems board",
                                   detail: "The Problems tab and work links, for projects that plan work in docs/problems. Experimental.") {
                            Toggle("", isOn: $settings.problemsBoard).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
        }
        .controlSize(.small)
        // Models and Listening show whether Claude Code is found and logged in (a local check, nothing sent), as they appear and when it is chosen.
        .task(id: "\(sectionID) \(settings.textGenerationRunOn.rawValue)") {
            guard settings.textGenerationRunOn == .claude, section == .models || section == .listening else { return }
            await claudeCode.prepareForUse()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                let selected = item == section
                Button { sectionID = item.rawValue } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(selected ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 180)
    }

    /// What is missing before a feature can run, in the words of the link; nil once its model is installed.
    private func modelNeed(ready: Bool, settingUp: Bool) -> String? {
        ready ? nil : settingUp ? "Setting up" : "Needs a model"
    }

    private var embedderNeed: String? {
        switch settings.searchEmbeddingsRunOn {
        case .local: return modelNeed(ready: embedder.isReady, settingUp: embedder.state.isDownloading)
        case .server:
            return serverNeed(address: settings.embeddingServerAddress, state: embeddingServer, fallsBack: embedder.isReady)
        }
    }

    /// What Text generation lacks before it can run: Claude Code found and logged in or this Mac's model installed, this Mac's model
    /// installed, or a server that passed its Check.
    private var textGenerationNeed: String? {
        switch settings.textGenerationRunOn {
        case .claude:
            if claudeCode.loginPassed || textGenerator.isReady { return nil }
            switch claudeCode.status {
            case .notChecked, .checking: return "Setting up"
            default: return "Needs Claude Code"
            }
        case .local: return modelNeed(ready: textGenerator.isReady, settingUp: textGenerator.state.isDownloading)
        case .server: return serverNeed(address: settings.textGenerationServerAddress, state: textGenerationServer, fallsBack: false)
        }
    }

    /// Claude Code failed and this Mac's model answers meanwhile: said beside Hey Varnick, as Search embeddings says it.
    private var textGenerationFallsBack: Bool {
        settings.textGenerationRunOn == .claude && claudeCode.isResting && textGenerator.isReady
    }

    /// This Mac's model: the download and the installed state, as the On this Mac choice and Claude Code's fallback both show them.
    private func gemmaRow(title: String, detail: String) -> some View {
        SettingRow(title: title, detail: detail) {
            switch textGenerator.state {
            case .unavailable:
                Text("Needs mlx.metallib: build with make").font(.system(size: 12)).foregroundStyle(.orange)
            case .missing:
                Button("Download") { Task { await textGenerator.download() } }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            case .ready:
                Text("Installed").font(.system(size: 12)).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
                if textGenerator.failedToLoad {
                    Button("Retry") { Task { await textGenerator.retry() } }
                    Button("Download again") { Task { await textGenerator.download() } }
                } else {
                    Button("Retry") { Task { await textGenerator.download() } }
                }
            }
        }
    }

    /// A role's link while it runs on a server; nil once the server passed. `fallsBack`: this Mac's model answers meanwhile.
    private func serverNeed(address: String, state: ModelServerState, fallsBack: Bool) -> String? {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return "Needs a server" }
        switch state.status {
        case .notChecked: return "Not checked yet"
        case .checking: return "Setting up"
        case .checked(let verdict): return verdict.kind == .passed ? nil : fallsBack ? "Using this Mac's model" : "Needs a server"
        }
    }

    /// Where Search embeddings run, for "Runs on …".
    private var embeddingsPlace: String {
        settings.searchEmbeddingsRunOn == .local ? "this Mac" : ModelServer.name(of: settings.embeddingServerAddress) ?? "the server"
    }

    /// For the judge Settings › Models has chosen.
    private var relevanceNeed: String? {
        switch settings.relevanceFilter {
        case .typesafe: settings.typesafeKey == nil ? "Needs a key" : nil
        case .local: modelNeed(ready: localReranker.isReady, settingUp: localReranker.state == .importing)
        }
    }

    /// Point at the screen can be turned on only with the gate open: only Jev chooses the element.
    private var screenGateOpen: Bool { settings.typesafeGateKey != nil }

    /// The TypeSafe key comes from the environment or `.env`.
    private var envKeyNote: some View {
        Text("Key from .env").font(.system(size: 12)).foregroundStyle(.secondary)
            .help("TYPESAFE_API_KEY from the environment or .env. Save it under Keys to keep it in the Keychain instead.")
    }

    /// A feature that is on but not set up says what's missing and takes you to Models.
    private func modelsLink(_ need: String) -> some View {
        Button("\(need): Settings › Models") { sectionID = SettingsSection.models.rawValue }
            .buttonStyle(.link)
            .font(.system(size: 12))
    }

    /// Imports a checkpoint folder once; Varnick keeps its own copy.
    private var chooseCheckpointButton: some View {
        Button("Choose…") {
            if let path = pickFolders(multiple: false, from: "~").first {
                Task { await localReranker.importCheckpoint(from: URL(fileURLWithPath: path)) }
            }
        }
    }

    private func saveTypesafeKey() {
        guard !typesafeKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settings.setTypesafeKey(typesafeKeyDraft)
        typesafeKeyDraft = ""
    }

    private func saveModelServerKey() {
        guard !modelServerKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settings.setModelServerKey(modelServerKeyDraft)
        modelServerKeyDraft = ""
    }

    private func saveElevenLabsKey() {
        guard !elevenLabsKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settings.setElevenLabsKey(elevenLabsKeyDraft)
        elevenLabsKeyDraft = ""
    }

    private var groups: [String] {
        var seen: [String] = []
        for a in ShortcutAction.allCases where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    private var folderLabel: String {
        let path = settings.claudeDirectory.isEmpty ? LauncherModel.claudeDirectory : settings.claudeDirectory
        let short = (path as NSString).abbreviatingWithTildeInPath
        return settings.claudeDirectory.isEmpty ? "\(short) (default)" : short
    }

    /// Folder picker over the launcher; empty when cancelled.
    private func pickFolders(multiple: Bool, from start: String) -> [String] {
        let panel = NSApp.windows.compactMap { $0 as? LauncherPanel }.first
        panel?.keepOpen = true
        defer {
            panel?.keepOpen = false
            panel?.makeKeyAndOrderFront(nil)
        }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = multiple
        open.level = .modalPanel   // above the floating launcher
        open.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath)
        guard open.runModal() == .OK else { return [] }
        return open.urls.map(\.path)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case claude, apps, search, listening, peers, models, shortcuts, experimental

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .apps: CustomApp.defaultIcon
        case .search: "magnifyingglass"
        case .listening: "waveform"
        case .peers: "desktopcomputer"
        case .models: "cpu"
        case .shortcuts: "keyboard"
        case .experimental: "testtube.2"
        }
    }
}

/// Varnick's Accessibility and Screen Recording, with their Grant buttons: the permissions Point at the screen and Screen access both
/// need. One view for both rows, since the buttons' state (a Grant pressed, Varnick shown in Finder) is the process's, not a row's.
struct ScreenPermissionsView: View {
    /// Opens the Restart Varnick card (`LauncherModel.askRestart`): a Screen Recording grant applies after a restart.
    let askRestart: () -> Void
    /// Whether Varnick has Accessibility, checked while Settings shows it.
    @State private var accessibilityGranted = ScreenReader.isTrusted
    /// Whether Varnick has Screen Recording, for the text read from a picture of the window.
    @State private var screenRecordingGranted = ScreenText.hasAccess
    /// Varnick was shown in Finder by a Grant press in this process (`PermissionGrant.revealed`), for each permission.
    @State private var accessibilityRevealed = PermissionGrant.revealed.contains(.accessibility)
    @State private var screenRevealed = PermissionGrant.revealed.contains(.screenRecording)
    /// The Screen Recording Grant was pressed in this process (`ScreenText.grantAsked`).
    @State private var screenGrantAsked = ScreenText.grantAsked
    /// The widest a hint grows before it wraps.
    private static let hintWidth: CGFloat = 260

    var body: some View {
        // One column, each permission a line of status and buttons at their natural width, and the hints wrapping under it: in a row
        // beside the setting's long description the controls would otherwise be squeezed to "Gr…" and the status to a letter a line.
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text(accessibilityGranted ? "Accessibility granted" : "Needs Accessibility")
                        .font(.system(size: 12))
                        .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
                    if !accessibilityGranted {
                        Button("Grant…") { ScreenReader.askForAccess() }
                    }
                }
                .fixedSize()
                if !accessibilityGranted, accessibilityRevealed {
                    hint(PermissionGrant.revealHint)
                }
            }
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text(screenRecordingGranted ? "Screen Recording granted" : "Needs Screen Recording")
                        .font(.system(size: 12))
                        .foregroundStyle(screenRecordingGranted ? Color.secondary : Color.orange)
                    if !screenRecordingGranted {
                        Button("Grant…") {
                            ScreenText.askForAccess()
                            screenGrantAsked = true
                        }
                        if screenGrantAsked {
                            Button("Restart Varnick") { askRestart() }
                        }
                    }
                }
                .fixedSize()
                if !screenRecordingGranted, screenGrantAsked {
                    if screenRevealed {
                        hint(PermissionGrant.revealHint)
                    }
                    hint("After switching it on, restart Varnick")
                }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = ScreenReader.isTrusted
            accessibilityRevealed = PermissionGrant.revealed.contains(.accessibility)
            screenRecordingGranted = ScreenText.hasAccess
            screenGrantAsked = ScreenText.grantAsked
            screenRevealed = PermissionGrant.revealed.contains(.screenRecording)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.hintWidth, alignment: .trailing)
    }
}

/// Open at login, in the app only: a switch bound to `SMAppService.mainApp` (Login Items). Nothing is saved and nothing registers
/// until the switch is turned on; the status is re-read each second, so an approval in System Settings shows.
struct OpenAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    /// What the last register or unregister threw; cleared by the next try.
    @State private var failure: String?

    private var isOn: Bool { status == .enabled || status == .requiresApproval }

    var body: some View {
        SettingRow(title: "Open at login",
                   detail: "Starts Varnick when you log in to this Mac, through Login Items. Off until you turn it on.") {
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
            } else if status == .requiresApproval {
                Text("Needs approval in Login Items").font(.system(size: 12)).foregroundStyle(.orange)
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else if status == .notFound {
                Text("Login Items can't find this copy of Varnick").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Toggle("", isOn: Binding(get: { isOn }, set: { change(to: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in status = SMAppService.mainApp.status }
    }

    private func change(to on: Bool) {
        failure = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

struct SettingRow<Controls: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) { controls }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var settings: Settings

    var body: some View {
        let recording = settings.recording == action
        HStack(spacing: 8) {
            Text(action.title).font(.system(size: 12.5))
            Spacer()
            if !settings.isDefault(action) {
                Button { settings.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to \(action.defaultCombo.label)")
            }
            Button { settings.recording = recording ? nil : action } label: {
                Group {
                    if recording {
                        Text("Type shortcut…").foregroundStyle(Color.accentColor)
                    } else if let combo = settings.combo(action) {
                        Text(combo.tokens.joined(separator: " "))
                    } else {
                        Text("None").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 110)
                .padding(.vertical, 4)
                .background(recording ? Color.accentColor.opacity(0.15) : Theme.tileFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}
