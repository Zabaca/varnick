import Foundation
import VarnickPeer

// Screen access for sessions, the relay half (ADR 0023): `Varnick --mcp --pane <id>` is the MCP server every Claude pane starts, with the screen
// tools when Settings › Claude › Screen access is on and Panel access's (`PanelMCP`, ADR 0031) always. It turns each tool call into one line on the peer
// socket and prints the reply. It never reads or acts: the running Varnick does, in `ScreenAccess` and `PanelAccess`. The request and
// reply types are both halves'.

/// One tool call as it travels on the socket. It has no `op`, which is how the app tells it from a peer's request: the peer relay
/// refuses any line without a known `op` and passes the app only lines that carry one, so no Mac or device can send this.
struct ScreenRequest: Codable {
    /// The version of this request, not of the peer protocol: a server from an older launch is told to restart.
    var screen: Int
    var pane: String
    var tool: String
    var args: ScreenArguments

    static let version = 1
}

/// The six tools, by the names the relay lists and the app answers to.
enum ScreenTool: String {
    case look, point, click, type, drag, window
}

/// The tools' arguments, a union of all six. Points are Accessibility's: the origin at the top left of the main display.
struct ScreenArguments: Codable {
    var app: String?
    /// `look`'s flag or `type`'s characters, whichever the call sent: the tool says which it takes.
    var text: Text?
    /// `look`'s flag for a picture of the window, with `rect` to crop it.
    var picture: Bool?
    /// `look`'s flag for a picture of every display; `display` asks for one and needs no flag.
    var screen: Bool?
    var display: Int?
    /// Set by the relay when `display` was sent and is not a whole number, so the app refuses the call instead of taking every display.
    var displayUnreadable: Bool?
    var id: String?
    var rect: Rect?
    /// Set by the relay when `rect` was sent and could not be read, so the app refuses the call instead of acting as if there were none.
    var rectUnreadable: Bool?
    var note: String?
    var at: Point?
    var keys: [String]?
    var replace: Bool?
    var from: Spot?
    var to: Spot?
    var position: Point?
    var size: Size?

    struct Rect: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        /// Numbers or numbers as text, as a model sends them.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let x = ScreenArguments.number(values, .x), let y = ScreenArguments.number(values, .y),
                  let width = ScreenArguments.number(values, .width), let height = ScreenArguments.number(values, .height) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a rectangle"))
            }
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }

        private enum CodingKeys: String, CodingKey { case x, y, width, height }
    }

    struct Point: Codable {
        var x: Double
        var y: Double

        var point: CGPoint { CGPoint(x: x, y: y) }
    }

    struct Size: Codable {
        var width: Double
        var height: Double

        var size: CGSize { CGSize(width: width, height: height) }
    }

    /// A boolean or a string as sent, kept as it came: `look` reads `"true"` as the flag, `type` types a string and refuses a flag.
    /// A number is its digits as a string.
    enum Text: Codable {
        case flag(Bool)
        case words(String)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let words = try? value.decode(String.self) {
                self = .words(words)
            } else if let number = try? value.decode(Double.self) {
                self = .words(number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number))
            } else {
                throw DecodingError.typeMismatch(Text.self, .init(codingPath: decoder.codingPath, debugDescription: "Not a flag or text"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .flag(let flag): try value.encode(flag)
            case .words(let words): try value.encode(words)
            }
        }
    }

    /// One end of a drag: an id from `look`, sent as a string or as `{id}`, or a point `{x, y}`.
    struct Spot: Codable {
        var id: String?
        var point: Point?

        init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                id = word
                return
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try? values.decodeIfPresent(String.self, forKey: .id)
            if let x = ScreenArguments.number(values, .x), let y = ScreenArguments.number(values, .y) { point = Point(x: x, y: y) }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(id, forKey: .id)
            try values.encodeIfPresent(point?.x, forKey: .x)
            try values.encodeIfPresent(point?.y, forKey: .y)
        }

        private enum CodingKeys: String, CodingKey { case id, x, y }
    }

    init() {}

    /// Lenient about what a model sends: a number or a boolean as text, a missing or null argument.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        app = try? values.decodeIfPresent(String.self, forKey: .app)
        id = try? values.decodeIfPresent(String.self, forKey: .id)
        note = try? values.decodeIfPresent(String.self, forKey: .note)
        if values.contains(.rect), (try? values.decodeNil(forKey: .rect)) != true {
            // The rectangle as an object, or as JSON text.
            if let found = try? values.decode(Rect.self, forKey: .rect) {
                rect = found
            } else if let text = try? values.decode(String.self, forKey: .rect), let found = try? JSONDecoder().decode(Rect.self, from: Data(text.utf8)) {
                rect = found
            } else {
                rectUnreadable = true
            }
        }
        at = try? values.decodeIfPresent(Point.self, forKey: .at)
        text = try? values.decodeIfPresent(Text.self, forKey: .text)
        if let list = try? values.decodeIfPresent([String].self, forKey: .keys) {
            keys = list
        } else if let one = try? values.decodeIfPresent(String.self, forKey: .keys) {
            keys = one.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        replace = Self.flag(values, .replace)
        picture = Self.flag(values, .picture)
        screen = Self.flag(values, .screen)
        if values.contains(.display), (try? values.decodeNil(forKey: .display)) != true {
            if let number = Self.number(values, .display), number.rounded() == number, abs(number) < 1e6 {
                display = Int(number)
            } else {
                displayUnreadable = true
            }
        }
        from = try? values.decodeIfPresent(Spot.self, forKey: .from)
        to = try? values.decodeIfPresent(Spot.self, forKey: .to)
        position = try? values.decodeIfPresent(Point.self, forKey: .position)
        size = try? values.decodeIfPresent(Size.self, forKey: .size)
        // The relay's verdicts, which travel in the request line: the arguments they were judged from are not in it.
        if Self.flag(values, .rectUnreadable) == true { rectUnreadable = true }
        if Self.flag(values, .displayUnreadable) == true { displayUnreadable = true }
    }

    /// `look`'s `text` flag (read the window's text from a picture): `true`, or `"true"` as a model sends it.
    var asksForText: Bool {
        switch text {
        case .flag(let flag)?: flag
        case .words(let word)?: word.lowercased() == "true"
        case nil: false
        }
    }

    /// A boolean or `"true"`, nil when absent or neither.
    private static func flag<Key>(_ values: KeyedDecodingContainer<Key>, _ key: Key) -> Bool? {
        if let flag = try? values.decodeIfPresent(Bool.self, forKey: key) { return flag }
        return (try? values.decodeIfPresent(String.self, forKey: key)).map { $0.lowercased() == "true" }
    }

    /// A number or a number as text, for the points a model sends.
    fileprivate static func number<Key>(_ values: KeyedDecodingContainer<Key>, _ key: Key) -> Double? {
        if let number = try? values.decodeIfPresent(Double.self, forKey: key) { return number }
        return (try? values.decodeIfPresent(String.self, forKey: key)).flatMap { Double($0) }
    }

    private enum CodingKeys: String, CodingKey { case app, text, picture, screen, display, displayUnreadable, id, rect, rectUnreadable, note, at, keys, replace, from, to, position, size }
}

/// The reply line: the call's text, whether it was a refusal or a failure, and for a `look` that asked for them, a picture of the
/// window or one per display. An older Varnick sends no pictures and an older server ignores them, so the request's version is unchanged.
struct ScreenReply: Codable {
    var text: String
    var isError: Bool
    var image: Image?
    /// A screen look's pictures, in the order its text names them.
    var images: [Image]?

    /// A picture as MCP carries it: base64 data and its mime type.
    struct Image: Codable {
        var data: String
        var mimeType: String
    }
}

/// The server: newline-delimited JSON-RPC on standard input and output, the stdio transport of MCP. No library: the protocol
/// subset is `initialize`, `tools/list`, `tools/call` and `ping`, and the tools are fixed here.
enum ScreenMCP {
    /// How long a call waits for the running Varnick. A click takes over a second on its own; the longest `type` waits for its turn
    /// and then takes a few seconds.
    static let callTimeout: TimeInterval = 15

    // MARK: The command line

    /// The sets of tools a server lists, as its arguments name them.
    struct Sets: OptionSet {
        let rawValue: Int
        static let screen = Sets(rawValue: 1)
        static let panel = Sets(rawValue: 2)
        /// `notify` (option 04 of `phone-page-is-only-a-browser-tab`): in every Claude pane, whatever Screen access says.
        static let notify = Sets(rawValue: 4)
        /// The automation tools (option 01 of `prompts-cant-run-on-a-schedule`, slice 3): in every Claude pane started while Automations is on, a run's
        /// excepted, and behind no switch of their own.
        static let automations = Sets(rawValue: 8)
        /// The task tools (option 01 of `work-cant-be-saved-or-chained`, slice 2a): in every Claude pane started while Tasks is on, a run's excepted.
        static let tasks = Sets(rawValue: 16)
        /// `task_result`, a Claude step's answer: answered by this server alone, and listed only while the pane's folder holds the step's schema.
        static let taskResult = Sets(rawValue: 32)
        /// `search` (option 09 of `listening-never-answers`): History, Bookmarks and Claude sessions, listed for the voice session alone.
        static let voiceSearch = Sets(rawValue: 64)
        /// `pane_open` and `pane_close` (option 01 of `panes-open-only-by-hand-at-a-mac`): in every Claude pane, a run's and the voice session's
        /// excepted, behind no switch. Their calls travel as Panel access's requests.
        static let panes = Sets(rawValue: 128)

        static let screenArgument = "--screen"
        static let panelArgument = "--panel"
        static let automationsArgument = "--automations"
        static let tasksArgument = "--tasks"
        static let voiceSearchArgument = "--search"
        static let panesArgument = "--panes"

        /// With none named, the screen tools alone: a session started before Panel access keeps the tools it had.
        init(arguments: [String]) {
            var found: Sets = []
            if arguments.contains(Self.screenArgument) { found.insert(.screen) }
            if arguments.contains(Self.panelArgument) { found.insert(.panel) }
            if arguments.contains(Self.automationsArgument) { found.insert(.automations) }
            if arguments.contains(Self.tasksArgument) { found.insert(.tasks) }
            if arguments.contains(TaskResultTool.argument) { found.insert(.taskResult) }
            if arguments.contains(NotifyTool.argument) { found.insert(.notify) }
            if arguments.contains(Self.voiceSearchArgument) { found.insert(.voiceSearch) }
            if arguments.contains(Self.panesArgument) { found.insert(.panes) }
            self = found.isEmpty ? .screen : found
        }

        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// The JSON `--mcp-config` takes for a pane: one stdio server, `varnick`, that is this binary through the peer link, with the pane
    /// id as an argument so nothing depends on claude passing its environment on, and an argument for each set of tools that pane gets.
    /// `--notify` is always there, and the callers name `--panel` and `--panes` for every pane but a run's (and the voice session's `--panes`); Screen
    /// access is the one set a switch still decides.
    static func configuration(pane: UUID, screen: Bool, panel: Bool, automations: Bool, tasks: Bool = false, taskResult: Bool = false,
                              voiceSearch: Bool = false, panes: Bool = false) -> String {
        MCPServer.configuration(command: PeerLink.mcpCommand,
                                 arguments: ["--mcp", "--pane", pane.uuidString.lowercased()]
                                    + (screen ? [Sets.screenArgument] : []) + (panel ? [Sets.panelArgument] : [])
                                    + (automations ? [Sets.automationsArgument] : []) + (tasks ? [Sets.tasksArgument] : [])
                                    + [NotifyTool.argument] + (taskResult ? [TaskResultTool.argument] : []) + (voiceSearch ? [Sets.voiceSearchArgument] : [])
                                    + (panes ? [Sets.panesArgument] : []))
    }

    // MARK: The tools

    private static let clickLead = Int(ScreenAccess.clickLead.components.seconds)

    private static func tool(_ name: ScreenTool, _ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name.rawValue, "description": description, "inputSchema": schema]
    }

    private static let rectSchema: [String: Any] = [
        "type": "object", "description": "A rectangle in screen points, the origin at the top left of the main display.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
        "required": ["x", "y", "width", "height"],
    ]

    private static let pointSchema: [String: Any] = [
        "type": "object", "description": "A point in screen points, the origin at the top left of the main display.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"],
    ]

    private static func spotSchema(_ description: String) -> [String: Any] {
        ["description": description, "anyOf": [["type": "string"], pointSchema]]
    }

    static let tools: [[String: Any]] = [
        tool(.look, "Lists the controls of a window on the user's Mac: the window's id (w1), its title and frame, and each control with an id "
             + "(e1, e2…), its name, kind and frame. Where the window lists nothing, or Chrome hides its page, it adds the short lines of text "
             + "read from a picture of the window (t1, t2…). A last line says which control has focus, by its id or its kind: \"Focus: e7\", "
             + "\"Focus: a text field that isn't listed\", \"Focus: a password field\" or \"Focus: none\". Ids are what point, click, type, "
             + "drag and window take, and are replaced by the next look. Frames are in screen points, the origin at the top left of the "
             + "main display. Nothing a person typed into a field is listed. With `picture` it also returns an image of the window "
             + "(at most about \(ScreenPicture.longSide) pixels on the long side), and the text says which part of the screen it shows. The "
             + "image shows everything on the window, typed text included, and goes to Anthropic with this session: ask for it only when the "
             + "listing is not enough. Password fields Varnick can see are painted black; one it cannot see (a Chrome page's, a remote "
             + "desktop's) is not. With `screen` it returns an image of every display instead, or with `display` of one: the text lists "
             + "the displays by number with their frames, and says each image's area in screen points and its pixels per point, so a "
             + "place in an image maps back to a point for click and point. It lists no controls unless `app` is also named, and leaves "
             + "the last look's ids as they were. Nothing is blacked out: it shows everything on every display, Varnick's own window and "
             + "other sessions included, typed text and password fields included, and goes to Anthropic with this session. Ask for it "
             + "only when one window's listing and picture are not enough.",
             properties: [
                "app": ["type": "string", "description": "The app to look at, by name. Omit for the app the user is working in."],
                "text": ["type": "boolean", "description": "Also read the window's text from a picture of it, even when its controls are listed."],
                "picture": ["type": "boolean", "description": "Also return an image of the window. Needs Screen Recording."],
                "screen": ["type": "boolean", "description": "Return an image of every display instead of the window's. Needs Screen Recording."],
                "display": ["type": "integer", "description": "Return an image of this display only, by the number in the text's Displays list (1 is the main display). Needs no `screen`."],
                "rect": ["type": "object", "description": "With `picture`, `screen` or `display`: only this area, in screen points, the origin at the top left of the main display. A display it does not reach is left out.",
                         "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
                         "required": ["x", "y", "width", "height"]],
             ]),
        tool(.point, "Draws the user's attention to a control or a rectangle with an arrow and a sign that shows this session's name and "
             + "the note. It stays \(Int(ArrowOverlay.lingers)) seconds, or until the next point or click. It changes nothing on the screen.",
             properties: [
                "id": ["type": "string", "description": "A control or line of text from the last look, such as e3 or t2."],
                "rect": rectSchema,
                "note": ["type": "string", "description": "What the sign says, a short sentence (cut to \(ScreenAccess.signNote) characters)."],
             ], required: ["note"]),
        tool(.click, "Clicks for the user, after showing the arrow on the target for \(clickLead) second\(clickLead == 1 ? "" : "s"). It then brings the target's app "
             + "and window forward, and refuses if the app does not come forward or Varnick's own panel is over the point (ask the user "
             + "to move or hide it). With an id it presses the control, or clicks its centre when it cannot be pressed or is in a web "
             + "page (the centre is read again after the app comes forward, so look again after a scroll); with a point it left-clicks "
             + "there. Nothing asks first. It reports what it did, not that it worked: look again to see.",
             properties: [
                "id": ["type": "string", "description": "A control or line of text from the last look."],
                "at": pointSchema,
             ]),
        tool(.type, "Types for the user, after showing the arrow on the target for \(clickLead) second\(clickLead == 1 ? "" : "s"). It brings the app "
             + "forward, and with an id from the last look puts the focus on that control first (a control in a web page is clicked); without "
             + "an id it types where the app already has the focus. It types `text`, then presses `keys` in order, as key events the app takes "
             + "for the user's. Nothing asks first, and one action runs at a time across all sessions, so a call may wait for another's turn "
             + "and holds the next for up to about \(ScreenKeys.longestTyping) seconds. A field's contents are never read: look will not show "
             + "what was typed, and `replace` selects everything in the field first, so the field ends up holding only the text. Nothing is "
             + "typed or pressed while a password field has focus: ask the user. `text` is at most \(ScreenKeys.maxCharacters) characters, "
             + "with no line break or tab: those are keys (Return, shift+Return in a chat box, Tab). `keys` is at most \(ScreenKeys.maxKeys) "
             + "combos, each modifiers (cmd, ctrl, opt, shift) and one key joined by +, such as cmd+l, shift+Tab, Return or Escape; the key "
             + "is a name (Return, Tab, Escape, Delete, ForwardDelete, Space, Up, Down, Left, Right, Home, End, PageUp, PageDown, F1 to F12) "
             + "or one character. A combo needed before the text, such as cmd+l before an address, is a call of its own. Varnick's own "
             + "shortcuts, log out, lock screen and Force Quit are refused. It reports what it did, not that it worked: look again to see.",
             properties: [
                "id": ["type": "string", "description": "A control or line of text from the last look, such as e3 or t2. Not a window (w1)."],
                "app": ["type": "string", "description": "With no id: the app to type into, by name. Omit for the app the user is working in."],
                "text": ["type": "string", "description": "What to type, at most \(ScreenKeys.maxCharacters) characters, no line breaks or tabs."],
                "keys": ["type": "array", "items": ["type": "string"], "description": "Key combos to press after the text, in order: [\"cmd+a\", \"Return\"]."],
                "replace": ["type": "boolean", "description": "Select everything in the field first, so it holds only the text."],
             ]),
        tool(.drag, "Drags for the user, after showing the arrow on the start for \(clickLead) second\(clickLead == 1 ? "" : "s"). It brings the start's app "
             + "forward, then presses the left mouse button at the start, drags in a straight line and lets go at the end. Each end is a "
             + "control from the last look or a point; a point or control under Varnick's own windows is refused, and so is one that another "
             + "window covers once the app is forward. The pointer stays at the end. Nothing asks first, and one action runs at a time across "
             + "all sessions. It reports what it did, not that it worked: look again to see.",
             properties: [
                "from": spotSchema("The start: a control or line of text from the last look (e3, t2), or a point."),
                "to": spotSchema("The end: a control or line of text from the last look, or a point."),
             ], required: ["from", "to"]),
        tool(.window, "Moves or resizes a window for the user, after showing the arrow on it for \(clickLead) second\(clickLead == 1 ? "" : "s"). It uses "
             + "Accessibility: no pointer moves and no app comes forward. The window is the id from the last look (w1) or the focused window of "
             + "an app named by `app`. Give `position` (where the top left goes), `size`, or both. A window in full screen or minimized, "
             + "one that cannot be moved or resized, and a frame whose title bar would be off every display are refused. The app may limit "
             + "a size, so it reports the frame read back. Nothing asks first, and one action runs at a time across all sessions. Controls "
             + "listed by the last look move with the window: look again.",
             properties: [
                "id": ["type": "string", "description": "A window from the last look, such as w1."],
                "app": ["type": "string", "description": "With no id: the app whose focused window to change, by name."],
                "position": pointSchema,
                "size": ["type": "object", "description": "The window's new size in screen points.",
                         "properties": ["width": ["type": "number"], "height": ["type": "number"]], "required": ["width", "height"]],
             ]),
    ]

    // MARK: The server

    /// The tools `tools/list` gives for the sets: the screen tools, then Panel access's, the automation tools, the task tools, then `notify`,
    /// `task_result` (which is listed only while the pane's folder holds a step's schema), the voice session's `search` and the pane tools.
    static func tools(for sets: Sets, pane: UUID? = nil) -> [[String: Any]] {
        var listed: [[String: Any]] = []
        if sets.contains(.screen) { listed += tools }
        if sets.contains(.panel) { listed += PanelMCP.tools }
        if sets.contains(.automations) { listed += AutomationMCP.tools }
        if sets.contains(.tasks) { listed += TaskMCP.tools }
        if sets.contains(.notify) { listed.append(NotifyTool.tool) }
        if sets.contains(.taskResult), let pane { listed += TaskResultTool.tools(in: TaskResultTool.folder(for: pane)) }
        if sets.contains(.voiceSearch) { listed += VoiceSearchMCP.tools }
        if sets.contains(.panes) { listed += PaneMCP.tools }
        return listed
    }

    /// Runs until standard input ends; the exit status is 0.
    static func run(pane: String, sets: Sets) -> Int32 {
        MCPServer.run { answer($0, pane: pane, sets: sets) }
    }

    /// The reply to one JSON-RPC message; nil for a notification, which is never answered, and for what can't be answered. The JSON-RPC is
    /// `MCPServer`'s, which the headless relay's `--mcp` shares.
    static func answer(_ line: String, pane: String, sets: Sets = .screen, ask: (String) -> ScreenReply = ScreenMCP.ask) -> [String: Any]? {
        let paneID = UUID(uuidString: pane)
        return MCPServer.answer(line, tools: tools(for: sets, pane: paneID)) { name, arguments in
            let reply: ScreenReply
            if ScreenTool(rawValue: name) != nil, sets.contains(.screen) {
                let decoded = arguments.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONDecoder().decode(ScreenArguments.self, from: $0) } ?? ScreenArguments()
                reply = ask(requestLine(pane: pane, tool: name, arguments: decoded))
            } else if (sets.contains(.panel) && PanelMCP.names.contains(name)) || (sets.contains(.panes) && PaneMCP.names.contains(name)) {
                // The pane tools travel as Panel access's request.
                reply = ask(PanelMCP.requestLine(pane: pane, tool: name, arguments: PanelMCP.arguments(from: arguments)))
            } else if sets.contains(.automations), AutomationMCP.names.contains(name) {
                reply = ask(AutomationMCP.requestLine(pane: pane, tool: name, arguments: PanelMCP.arguments(from: arguments)))
            } else if sets.contains(.tasks), TaskMCP.names.contains(name) {
                reply = ask(TaskMCP.requestLine(pane: pane, tool: name, arguments: arguments))
            } else if sets.contains(.voiceSearch), VoiceSearchMCP.names.contains(name) {
                reply = ask(VoiceSearchMCP.requestLine(pane: pane, tool: name, arguments: arguments))
            } else if sets.contains(.notify), name == NotifyTool.name {
                // Answered here: the hook records the call, and nothing is sent to the app.
                return NotifyTool.call(arguments)
            } else if sets.contains(.taskResult), name == TaskResultTool.name, let paneID {
                // Answered here too, against the schema file the host wrote into the pane's folder: nothing is sent to the app.
                return TaskResultTool.call(arguments, in: TaskResultTool.folder(for: paneID))
            } else {
                return nil
            }
            var content: [[String: Any]] = [["type": "text", "text": reply.text]]
            for image in (reply.image.map { [$0] } ?? []) + (reply.images ?? []) {
                content.append(["type": "image", "data": image.data, "mimeType": image.mimeType])
            }
            return MCPResult(content: content, isError: reply.isError)
        }
    }

    static func requestLine(pane: String, tool: String, arguments: ScreenArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = ScreenRequest(screen: ScreenRequest.version, pane: pane, tool: tool, args: arguments)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// One request line to the running Varnick and its reply. With no socket, or nothing listening, the result is that Varnick isn't
    /// running.
    static func ask(_ line: String) -> ScreenReply {
        guard let answer = PeerSocket.request(line, timeout: callTimeout) else {
            return PeerSocket.isAnswering()
                ? ScreenReply(text: "Varnick didn't answer within \(Int(callTimeout)) seconds. Check what happened before calling again.", isError: true)
                : ScreenReply(text: "Varnick isn't running", isError: true)
        }
        return PeerJSON.decode(ScreenReply.self, from: answer) ?? ScreenReply(text: "Varnick's answer wasn't readable", isError: true)
    }
}
