import CryptoKit
import Foundation

/// What a Mac's Phone page server is given and what `tailscale serve` says about its port (ADR 0011). Every decision
/// here touches no process; `PhonePageRunner` runs the server, `PhonePagePublisher` publishes it, `PhonePageServer` shows it.
enum PhonePage {
    /// The HTTPS port the page is published on: the one the server's Host and Origin checks expect.
    static let publishedPort = 8444
    /// The port of 127.0.0.1 the server listens on where Tailscale can't serve a socket.
    static let loopbackPort = 18444
    /// The server's zmx session. It is never a pane's name, so neither the launch sweep nor `tabs` sees it.
    static let sessionName = "varnick-phone-page"
    /// The labels the session is made with: the server's files, where they are, and how it listens. A session with other values
    /// than the ones wanted now is ended and started again.
    private static let digestKey = "varnick-page", modeKey = "varnick-page-mode", placeKey = "varnick-page-place", pushKey = "varnick-page-push"

    // MARK: How the server listens

    enum Mode: String, Equatable {
        case socket, loopback
    }

    /// Why the server listens on 127.0.0.1, where any program on the Mac can reach it.
    enum LoopbackReason: Equatable {
        /// The CLI's `serve --help` doesn't mention `unix:` (the Homebrew Tailscale CLI, 1.92.2).
        case cliLacksSockets
        /// The Tailscale app's CLI: its serve answers 502 for every socket (the option's Spike › Results), whatever `--help` says.
        case appCLI
        /// No CLI, or one that didn't answer.
        case cliUnknown
        /// The running server was started on loopback and this CLI can serve a socket now: that changes at the next start.
        case socketPossibleNow
        /// Serve refused a socket to Varnick's user, who isn't root (`refusesSocket`), and the Tailscale that did is still the one here.
        case socketRefused
    }

    /// A socket only where the local CLI can serve one and hasn't refused it (`refused`: `Refusal.stands`). Anything not
    /// known to work is loopback, which works everywhere.
    static func chooseMode(cli: String?, help: String?, refused: Bool = false) -> (mode: Mode, reason: LoopbackReason?) {
        guard let cli, let help else { return (.loopback, .cliUnknown) }
        if cli.hasPrefix("/Applications/Tailscale.app/") { return (.loopback, .appCLI) }
        guard help.contains("unix:") else { return (.loopback, .cliLacksSockets) }
        return refused ? (.loopback, .socketRefused) : (.socket, nil)
    }

    /// Whether `tailscale serve` said it won't serve a path or a socket to this user: tailscaled lets only root, or an
    /// operator whose `sudo --list tailscale` it can run, do that (ADR 0011's note). Anything else that fails is not this.
    static func refusesSocket(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("to serve a path or unix socket") || lower.contains("must be root")
    }

    /// What a remembered refusal comes to against the Tailscale version now. It is kept with the version that gave it, so a
    /// newer one gets one more try (`over`). Where no version was known then (`recordedVersion` nil) the first one that
    /// answers is adopted, not compared; and a CLI that doesn't answer now changes nothing.
    enum Refusal: Equatable {
        case none, standing, over
        case adopt(String)

        var stands: Bool {
            switch self {
            case .standing, .adopt: true
            case .none, .over: false
            }
        }
    }

    static func refusal(remembered: Bool, recordedVersion: String?, version: String?) -> Refusal {
        guard remembered else { return .none }
        guard let version else { return .standing }
        guard let recordedVersion else { return .adopt(version) }
        return recordedVersion == version ? .standing : .over
    }

    /// `~/Library/Application Support/Varnick/phone`: owner-only, since Bun binds the socket before it can be chmodded.
    static func folder(in support: URL) -> URL { support.appendingPathComponent("phone", isDirectory: true) }
    static func socketPath(in support: URL) -> String { folder(in: support).appendingPathComponent("page.sock").path }
    static func logURL(in support: URL) -> URL { folder(in: support).appendingPathComponent("server.log") }

    /// What `tailscale serve` is given to reach the server.
    static func target(_ mode: Mode, socketPath: String) -> String {
        mode == .socket ? "unix:\(socketPath)" : "http://127.0.0.1:\(loopbackPort)"
    }

    /// A unix socket path over 103 bytes fails to bind with no useful error.
    static let socketPathLimit = 103

    // MARK: The server's files

    /// The server's folder: `PhonePage` next to the binary, which `make build` copies there as it does zmx.
    static func serverFolder(installedIn install: URL?) -> URL? {
        guard let folder = install?.appendingPathComponent("PhonePage", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("server.ts").path) else { return nil }
        return folder
    }

    /// A digest of every file in the folder: the first 16 hex digits of the SHA-256 of one line per file, in path
    /// order, `<SHA-256 of the file>  <path>` (what `shasum -a 256` prints, without a leading `./`). So it changes
    /// when any file's content, name or presence does, and by nothing else. Nil when the folder can't be read.
    static func digest(of folder: URL) -> String? {
        let fm = FileManager.default
        // Paths relative to the folder, from the walk itself: a prefix cut from absolute ones goes wrong where the folder
        // is under /tmp, which `resolvingSymlinksInPath` spells without /private and a walk spells with it.
        guard let walk = fm.enumerator(atPath: folder.path) else { return nil }
        var paths: [String] = []
        for case let path as String in walk {
            guard (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(path).path))?[.type] as? FileAttributeType == .typeRegular,
                  (path as NSString).lastPathComponent != ".DS_Store" else { continue }
            paths.append(path)
        }
        var manifest = ""
        for path in paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { return nil }
            manifest += "\(hex(SHA256.hash(data: data)))  \(path)\n"
        }
        return String(hex(SHA256.hash(data: Data(manifest.utf8))).prefix(16))
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// The labels the session is created with. `place` names the folder holding `PhonePage/` (its last component): a
    /// session without it, or in another folder, isn't current, so one started from the build folder is replaced. `push` is the
    /// fingerprint of the push key the server was given (`PhonePagePush.noKey` for none): a different key restarts the server, and the
    /// fingerprint says nothing of the key.
    static func labels(digest: String, mode: Mode, place: String, push: String) -> String {
        "\(digestKey)=\(digest) \(modeKey)=\(mode.rawValue) \(placeKey)=\(place) \(pushKey)=\(push)"
    }

    /// The `place` label of a server run from `folder` (`serverFolder`).
    static func place(of folder: URL) -> String { folder.deletingLastPathComponent().lastPathComponent }

    /// The folder name a running session was started from, from its labels.
    static func place(inLabels line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("\(placeKey)=") }.map { String($0.dropFirst(placeKey.count + 1)) }
    }

    /// The mode a running session was started in, from its labels: where `tailscale serve` has to point, whatever the CLI can do now.
    static func mode(inLabels line: String) -> Mode? {
        line.split(whereSeparator: \.isWhitespace)
            .compactMap { $0.hasPrefix("\(modeKey)=") ? Mode(rawValue: String($0.dropFirst(modeKey.count + 1))) : nil }.first
    }

    /// The push key fingerprint a running session was started with (`PhonePagePush.noKey` for none), from its labels.
    static func push(inLabels line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("\(pushKey)=") }.map { String($0.dropFirst(pushKey.count + 1)) }
    }

    /// Where the key is handed to the server: a file in the server's owner-only folder, written just before the start, read and deleted by the
    /// server as its first act.
    static func pushKeyHandoff(in phoneFolder: URL) -> URL { phoneFolder.appendingPathComponent("push-key-handoff", isDirectory: false) }

    /// Whether a running session's labels (`zmx get`) are the ones this start would give it.
    static func isCurrent(labels line: String, digest: String, mode: Mode, place: String, push: String) -> Bool {
        let words = Set(line.split(whereSeparator: \.isWhitespace).map(String.init))
        return words.contains("\(digestKey)=\(digest)") && words.contains("\(modeKey)=\(mode.rawValue)") && words.contains("\(placeKey)=\(place)")
            && words.contains("\(pushKey)=\(push)")
    }

    /// The first of Bun's usual homes that is executable, found the way `Tailscale.executable` finds the CLI: there is
    /// no login shell here, so oh-my-zsh never puts it on a PATH.
    static func bunExecutable(home: String = NSHomeDirectory()) -> String? {
        ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: What the server is given

    /// The server's environment, and nothing else of Varnick's. `VARNICK_ZMX_DIR` goes along only when Varnick has it
    /// (a check's throwaway folder), so the relay the server runs looks in the same zmx folder. The push key itself is never in the
    /// environment, where `ps eww` shows it: `pushKeyFile` names an owner-only file the server reads at its start and deletes
    /// (`PhonePage.pushKeyHandoff`); without it the server sends no push.
    static func environment(mode: Mode, socketPath: String, relay: String, devices: String, tailscale: String?,
                            home: String, zmxDirectory: String?, proxyFolder: String, proxyStatus: String, proxyTabs: String,
                            pushFolder: String, panesFolder: String, presenceFolder: String, pushKeyFile: String?) -> [String] {
        var environment = [mode == .socket ? "VARNICK_PAGE_SOCKET=\(socketPath)" : "VARNICK_PAGE_LOOPBACK=\(loopbackPort)",
                           "VARNICK_PAGE_PORT=\(publishedPort)", "VARNICK_RELAY=\(relay)", "VARNICK_DEVICES=\(devices)",
                           "VARNICK_PROXY_FOLDER=\(proxyFolder)", "VARNICK_PROXY_STATUS=\(proxyStatus)", "VARNICK_PROXY_TABS=\(proxyTabs)",
                           "VARNICK_PUSH_FOLDER=\(pushFolder)", "VARNICK_PANES_FOLDER=\(panesFolder)", "VARNICK_PRESENCE_FOLDER=\(presenceFolder)"]
        if let pushKeyFile { environment.append("VARNICK_PUSH_KEY_FILE=\(pushKeyFile)") }
        if let tailscale { environment.append("VARNICK_TAILSCALE=\(tailscale)") }
        environment += ["HOME=\(home)", "PATH=/usr/bin:/bin", "LANG=en_US.UTF-8"]
        if let zmxDirectory { environment.append("VARNICK_ZMX_DIR=\(zmxDirectory)") }
        return environment
    }

    /// The shell that starts Bun in the session: its output goes to the log, emptied here at each start, since zmx ends
    /// the session with the command and there would be nothing to read afterwards. `$1` is Bun, `$2` the server, `$3` the log.
    static let startScript = #"exec "$1" "$2" >"$3" 2>&1"#

    /// The last lines of the server's log, for a server that exited.
    static func logTail(_ text: String, lines: Int = 4) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: What Tailscale says

    /// What `tailscale serve status --json` and `funnel status` say about the published port.
    enum ServeState: Equatable {
        /// 8444 points at the server and Funnel is off.
        case published
        case notPublished
        /// 8444 points at what Varnick last published, and that isn't this server's address now (the mode changed): where.
        case ownOther(String)
        /// 8444 points somewhere that isn't this page: where. It is the user's and is left alone (ADR 0011).
        case elsewhere(String)
        /// Funnel is on for 8444: the page is open to the internet.
        case funnelOn
        /// Tailscale didn't answer, or answered something unreadable.
        case unreadable(String)
    }

    /// `https://<MagicDNS name>:8444/`, which the user opens on the device.
    static func address(dnsName: String) -> String { "https://\(dnsName):\(publishedPort)/" }

    /// Where port 8444 points, from `serve status --json`: `Web["<name>:8444"].Handlers["/"].Proxy`. Nil when nothing
    /// is published there. Anything that isn't a proxy is described, since it isn't the server either.
    static func published(statusJSON text: String, dnsName: String, port: Int = publishedPort) -> Result<String?, ServeReadError> {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .failure(ServeReadError("Tailscale's serve status wasn't readable"))
        }
        let key = "\(dnsName):\(port)".lowercased()
        let web = json["Web"] as? [String: Any] ?? [:]
        if let entry = web.first(where: { $0.key.lowercased() == key })?.value as? [String: Any] {
            let handlers = entry["Handlers"] as? [String: Any] ?? [:]
            // Paths beside "/" are somebody's own: turning "/" off or on would leave them half there.
            let others = handlers.keys.filter { $0 != "/" }.sorted()
            if !others.isEmpty { return .success("other paths too (\(others.joined(separator: ", ")))") }
            guard let root = handlers["/"] as? [String: Any] else { return .success("a page that isn't at /") }
            if let proxy = root["Proxy"] as? String { return .success(proxy) }
            return .success(root["Path"] != nil ? "a folder" : "a fixed text")
        }
        let forwards = (json["TCP"] as? [String: Any])?["\(port)"] as? [String: Any]
        if let forward = forwards?["TCPForward"] as? String { return .success("TCP \(forward)") }
        if forwards != nil { return .success("something that isn't the server") }
        return .success(nil)
    }

    struct ServeReadError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// Whether Funnel is on for 8444, from the serve config's `AllowFunnel` and `funnel status`'s lines
    /// (`https://<name>:8444 (Funnel on)`, against `(tailnet only)`).
    static func funnelIsOn(statusJSON: String?, funnelStatus: String?, dnsName: String, port: Int = publishedPort) -> Bool {
        let key = "\(dnsName):\(port)".lowercased()
        if let statusJSON, let json = (try? JSONSerialization.jsonObject(with: Data(statusJSON.utf8))) as? [String: Any],
           let allowed = json["AllowFunnel"] as? [String: Any], allowed.contains(where: { $0.key.lowercased() == key && ($0.value as? Bool) == true }) {
            return true
        }
        let prefix = "https://\(key) "
        return (funnelStatus ?? "").split(whereSeparator: \.isNewline).contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix(prefix) && lower.contains("(funnel on)")
        }
    }

    /// The state from where 8444 points (nil: nowhere) and whether Funnel is on, which comes first. Only `target` and
    /// `lastPublished` (what Varnick itself last published) are this page's; anything else is the user's.
    static func serveState(points: String?, funnelOn: Bool, target: String, lastPublished: String? = nil) -> ServeState {
        if funnelOn { return .funnelOn }
        guard let points else { return .notPublished }
        if sameTarget(points, target) { return .published }
        if let lastPublished, sameTarget(points, lastPublished) { return .ownOther(points) }
        return .elsewhere(points)
    }

    // MARK: Publishing

    /// What Varnick does with the port when the setting is on and the server runs.
    enum PublishAction: Equatable {
        case publish
        case keep
        case refuse(PublishRefusal)
    }

    enum PublishRefusal: Equatable {
        /// 8444 is somebody's own mount: where it points.
        case conflict(String)
        case funnelOn
        case unreadable(String)
    }

    static func publishAction(_ state: ServeState) -> PublishAction {
        switch state {
        case .notPublished, .ownOther: .publish
        case .published: .keep
        case .elsewhere(let place): .refuse(.conflict(place))
        case .funnelOn: .refuse(.funnelOn)
        case .unreadable(let message): .refuse(.unreadable(message))
        }
    }

    /// Whether turning the setting off takes the mount down: only where it points at this page (ADR 0011).
    static func shouldUnpublish(_ state: ServeState) -> Bool {
        switch state {
        case .published, .ownOther: true
        case .notPublished, .elsewhere, .funnelOn, .unreadable: false
        }
    }

    /// The arguments that publish the port to the target and take it down: the one mount `https:<port>`, never funnel's.
    static func publishArguments(target: String, port: Int = publishedPort) -> [String] { ["serve", "--bg", "--https=\(port)", target] }
    static func unpublishArguments(port: Int = publishedPort) -> [String] { ["serve", "--https=\(port)", "off"] }

    /// Whether serve's `Proxy` is the target this server needs: the same socket path, or the same loopback port
    /// whether it says `127.0.0.1` or `localhost` and with or without a final slash.
    static func sameTarget(_ proxy: String, _ target: String) -> Bool {
        func normal(_ text: String) -> String {
            var text = text.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("/"), !text.hasSuffix("://") { text.removeLast() }
            return text.hasPrefix("unix:") ? text : text.lowercased().replacingOccurrences(of: "//localhost:", with: "//127.0.0.1:")
        }
        return normal(proxy) == normal(target)
    }

    /// The command Varnick ran to publish, for Settings to show: the CLI as `tailscale` where it is that, else by its path.
    static func serveCommand(cli: String?, target: String) -> String {
        ([cliName(cli)] + publishArguments(target: target).map(shellQuoted)).joined(separator: " ")
    }

    /// The command that turns Funnel off for 8444, which Varnick never runs.
    static func funnelOffCommand(cli: String?) -> String { "\(cliName(cli)) funnel --https=\(publishedPort) off" }

    private static func cliName(_ cli: String?) -> String {
        guard let cli, URL(fileURLWithPath: cli).lastPathComponent != "tailscale" else { return "tailscale" }
        return shellQuoted(cli)
    }

    /// One shell word: as it is when it has nothing special, else in single quotes.
    static func shellQuoted(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_@%+=:,./-".unicodeScalars.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the loopback line says: information, not a fault, but any program on this Mac can reach the page there.
    static func loopbackNote(_ reason: LoopbackReason, version: String?) -> String {
        let reach = "Any program on this Mac can reach it."
        switch reason {
        case .cliLacksSockets: return "Listening on loopback (Tailscale \(version ?? "here") can't serve a socket; a newer one can). \(reach)"
        case .appCLI: return "Listening on loopback (the Tailscale app can't serve a socket). \(reach)"
        case .cliUnknown: return "Listening on loopback (Tailscale didn't say whether it can serve a socket). \(reach)"
        case .socketPossibleNow: return "Listening on loopback (this Tailscale can serve a socket now: restart Varnick to use one). \(reach)"
        case .socketRefused:
            return "Listening on loopback (Tailscale refused to serve a socket without root). \(reach) \"\(socketButton)\" tries one again, and asks for your password if it has to."
        }
    }

    /// The Settings button for a refused socket, which the note for `.socketRefused` points to.
    static let socketButton = "Use a socket"

    /// An AppleScript that runs `executable` with `arguments` as root, behind the system's password prompt. Every word is
    /// AppleScript's `quoted form of`, since the socket's folder has a space in its name.
    static func administratorScript(executable: String, arguments: [String]) -> String {
        func word(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "(quoted form of \"\(escaped)\")"
        }
        return "do shell script (" + ([executable] + arguments).map(word).joined(separator: " & \" \" & ") + ") with administrator privileges"
    }

    /// Why an administrator run failed, from osascript's complaint: that the prompt was cancelled, else its first line.
    static func administratorFailure(_ error: String) -> String {
        if error.contains("(-128)") || error.lowercased().contains("user canceled") { return "the password prompt was cancelled" }
        let line = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return String((line ?? "it didn't say why").prefix(200))
    }
}
