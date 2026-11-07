import AppKit
import Combine
import Foundation
import VarnickPeer

// The checklist for each headless host under Also between my Macs and hosts in Settings › Claude (option 07 of `sessions-cant-reach-each-other-reliably`), the running
// Varnick's half. A host has no Settings of its own, so this Mac reads its rows (the host's relay decides them with `ChannelChecklist`, from reads made there), shows them
// with their buttons, and sends the user's press to the host: Allow, and Approve, Update and Remove approval through `sudo -n` there. Nothing reaches the host's machine
// policy until a button is pressed. The live test sends a word from a throwaway session here to a throwaway session started on the host, which answers. The host's side is
// `HeadlessMessages.swift` in `varnick-peer`; the Mac's own checklist is `MessagesSetup`.

@MainActor
final class HostMessagesSetup: ObservableObject {
    static let shared = HostMessagesSetup()

    struct State: Equatable {
        var checklist: PeerHostChecklist?
        /// The host answered "Unknown request": its relay predates messages to hosts.
        var older = false
        var reading = false
        /// A button's work under way, as the words shown beside it.
        var working: String?
        /// What the last button did, or why a read failed.
        var outcome: String?
        var test = ChannelChecklist.TestResult.notRun
    }

    /// One line of a host's checklist: its title, what was decided, and the host's action the button sends (nil for Upgrade and Run test, which are not the host's).
    struct Line: Identifiable, Equatable {
        enum Button: Equatable {
            case host(String)
            case upgrade
            case test
        }

        var id: Int
        var title: String
        var row: ChannelChecklist.Row
        var button: Button?
    }

    @Published private(set) var states: [String: State] = [:]

    weak var model: LauncherModel?
    private var tests: [String: Task<Void, Never>] = [:]

    func state(of host: String) -> State { states[host] ?? State() }

    private func update(_ host: String, _ change: (inout State) -> Void) {
        var state = states[host] ?? State()
        change(&state)
        states[host] = state
    }

    // MARK: The rows

    static let upgradeTitle = "Varnick on the host is new enough"

    func lines(for peer: Peer) -> [Line] {
        let state = state(of: peer.id)
        var lines: [Line] = []

        // 1. Varnick there answers the host requests. A host on this protocol that predates them says "Unknown request"; one on another protocol fails the version check.
        let first: ChannelChecklist.Row
        var upgrade = false
        switch PeerManager.shared.status[peer.id] {
        case .mismatch(let theirs)?:
            if theirs < PeerProtocol.version {
                first = .init(.fix, "Older Varnick (protocol \(theirs), this Mac speaks \(PeerProtocol.version)). Upgrade it, then it can take messages.", button: "Upgrade")
                upgrade = true
            } else {
                first = .init(.blocked, "Newer Varnick (protocol \(theirs), this Mac speaks \(PeerProtocol.version)). Update this Mac.")
            }
        case .notAnswering(let why)?:
            first = .init(.blocked, "Not answering: \(why)")
        case .removedThisMac?:
            first = .init(.blocked, "It has taken this Mac out of its list, so nothing reaches it.")
        default:
            if state.older {
                first = .init(.fix, "Varnick on this host predates messages to hosts. Upgrade it, then it can take them.", button: "Upgrade")
                upgrade = true
            } else if state.checklist != nil {
                first = .init(.pass, "Varnick on this host answers the host requests.")
            } else {
                first = .init(.waiting, state.reading ? "Reading the host…" : "Not read yet.")
            }
        }
        lines.append(Line(id: 0, title: Self.upgradeTitle, row: first, button: upgrade ? .upgrade : nil))

        // 2 to 6: the host's own rows.
        for (index, row) in (state.checklist?.rows ?? []).enumerated() {
            lines.append(Line(id: index + 1, title: row.title,
                              row: ChannelChecklist.Row(row.markValue, row.text, button: row.button),
                              button: row.action.map { .host($0) }))
        }
        if state.checklist == nil {
            for (index, title) in HostChecklist.titles.enumerated() {
                lines.append(Line(id: index + 1, title: title, row: .init(.waiting, state.older ? "Checked once Varnick there is upgraded." : "Not read yet.")))
            }
        }

        // 7. The test across.
        let ready = state.checklist?.ready == true
        let test = ChannelChecklist.testRow(state.test, ready: ready)
        lines.append(Line(id: 6, title: "Test", row: test, button: test.action == nil ? nil : .test))
        return lines
    }

    // MARK: Reading

    private func testWord(_ host: String) -> String {
        switch state(of: host).test {
        case .passed: "passed"
        case .failed: HostChecklist.testFailed
        case .notRun, .running: "notRun"
        }
    }

    /// Reads the host's rows, from its saved read when that is under a minute old unless `fresh` (Check again). A host that answers "Unknown request" is an older relay.
    func refresh(_ host: String, fresh: Bool = false) {
        guard states[host]?.reading != true, states[host]?.working == nil else { return }
        update(host) { $0.reading = true }
        Task {
            let result = await PeerManager.shared.hostChecklist(PeerHostCheckAsk(fresh: fresh ? true : nil, test: testWord(host)), on: host)
            update(host) { state in
                state.reading = false
                switch result {
                case .success(let list):
                    state.checklist = list
                    state.older = false
                case .failure(let refusal):
                    if PeerManager.unknownRequest(refusal) {
                        state.older = true
                        state.checklist = nil
                    } else {
                        state.outcome = "The host's checklist couldn't be read: \(refusal.message)"
                    }
                }
            }
        }
    }

    // MARK: The buttons

    /// Allow, Approve, Update or Remove approval, sent to the host behind the user's press. The host runs the fixed command through `sudo -n`; when its sudo wants a password
    /// nothing is changed, and a terminal opens on the host with the command typed in.
    func perform(_ action: String, on host: String) {
        guard states[host]?.working == nil, states[host]?.reading != true else { return }
        update(host) {
            $0.outcome = nil
            $0.working = action == HostChecklist.remove ? "Removing Varnick's approval on the host" : action == HostChecklist.allow ? "Changing Claude Code's settings on the host" : "Asking the host to approve Varnick"
        }
        Task {
            let result = await PeerManager.shared.hostChecklist(PeerHostCheckAsk(action: action, fresh: true, test: testWord(host)), on: host)
            update(host) { state in
                state.working = nil
                switch result {
                case .success(let list):
                    state.checklist = list
                    state.outcome = list.outcome
                case .failure(let refusal):
                    if PeerManager.unknownRequest(refusal) { state.older = true; state.checklist = nil }
                    state.outcome = "Nothing was changed: \(refusal.message)"
                }
            }
            if case .success(let list) = result, list.passwordRequired == true, let command = list.terminalCommand { openTerminal(on: host, typing: command) }
            await PeerManager.shared.refresh(host)
            HostMessageCollector.shared.refresh()
        }
    }

    /// The host's sudo wants a password, which never passes through Varnick: a terminal tab opens on the host with the command typed in, for the user to enter it there.
    /// The row reads the host again when the tab closes.
    private func openTerminal(on host: String, typing command: String) {
        guard let model else { return }
        let id = UUID()
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = PeerStart(id: id.uuidString.lowercased(), prompt: "", kind: .terminal)
        Task {
            switch await PeerManager.shared.send(request, to: host, timeout: 40) {
            case .failure(let refusal):
                update(host) { $0.outcome = "A terminal couldn't be opened on the host (\(refusal.message)). Run this there yourself: \(command)" }
            case .success(let reply):
                var record = SessionRecord(id: id, prompt: "", title: "", directory: reply.folder ?? "", startedAt: Date(), lastUsed: Date())
                record.shell = true
                record.host = host
                let session = model.makeSession(record, resuming: false, query: "")
                let tab = model.addTab(PaneNode(session: session), id: reply.tab.flatMap(UUID.init(uuidString:)), show: true)
                tab.inControl = true
                update(host) { $0.outcome = "The host's sudo asks for a password, so nothing was changed. A terminal on the host is open with the command typed in: enter the host account's password there." }
                // Typed once the shell is up: the session has started with no card or notice over it, and the shell has had a moment to print its prompt.
                let deadline = ContinuousClock.now + .seconds(30)
                while ContinuousClock.now < deadline, !(session.started && session.away == nil) { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(2))
                session.view.send(txt: command + "\r")
                // The row reads the host again when the tab closes.
                while model.tabs.contains(where: { $0 === tab }) { try? await Task.sleep(for: .seconds(2)) }
                refresh(host, fresh: true)
            }
        }
    }

    // MARK: The test

    func runTest(on host: String) {
        guard tests[host] == nil, let model, state(of: host).checklist?.ready == true else { return }
        update(host) { $0.test = .running("Starting a session on the host…"); $0.outcome = nil }
        tests[host] = Task { [weak self] in
            guard let self else { return }
            let result = await self.test(host: host, model: model)
            MessagesSetup.shared.finishTest()
            self.update(host) { $0.test = result }
            self.tests[host] = nil
            // The host keeps the last result with its read: its next session starts with the channel unless the test failed.
            self.refresh(host, fresh: true)
        }
    }

    private func setStep(_ host: String, _ text: String) {
        update(host) { $0.test = .running(text) }
    }

    /// A throwaway session started on the host, out of sight of every board, and a throwaway session here that sends it a word and is answered. Both end at the end.
    private func test(host: String, model: LauncherModel) async -> ChannelChecklist.TestResult {
        let setup = MessagesSetup.shared
        let folder = HomeFolder.madeAndTrusted()
        if let note = ClaudeTrust.note(for: folder) { return .failed("Claude Code hasn't trusted Home on this Mac yet: \(note)") }
        let limit = MessagesSetup.stepLimit
        // The host's last hello says whether it is ready, which is what lets this Mac collect from it.
        await PeerManager.shared.refresh(host)

        let receiver = UUID()
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = PeerStart(id: receiver.uuidString.lowercased(), prompt: "", skipPermissions: false, messageTest: true)
        switch await PeerManager.shared.send(request, to: host, timeout: 40) {
        case .failure(let refusal): return .failed("The host couldn't start the receiving session: \(refusal.message)")
        case .success: break
        }
        defer { Task { _ = await PeerManager.shared.end(session: receiver, on: host, onlyIfControlled: false) } }

        setStep(host, "Waiting for the host's session to start its channel…")
        var up = false
        let started = ContinuousClock.now + .seconds(limit)
        while ContinuousClock.now < started, !up, !Task.isCancelled {
            if case .success(let list) = await PeerManager.shared.hostChecklist(PeerHostCheckAsk(test: "notRun"), on: host), list.receiving?.contains(receiver.uuidString.lowercased()) == true {
                up = true
            } else {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard up else { return .failed(ChannelChecklist.notStarted(after: limit)) }

        // The sender is given the receiver's id in its own table before it starts, and the route to the host that holds it.
        let word = "lantern\(Int.random(in: 1000...9999))"
        PanelAccess.shared.remoteSenders[receiver] = host
        let firstID = UUID()
        let target = PanelAccess.shared.id(for: receiver, caller: firstID)
        let message = "Varnick channel check \(word). Answer by calling send with to set to the from of this message and text set to ack-\(word). Do nothing else."
        let first = setup.checkPane(id: firstID, prompt: "Varnick is checking that messages between its sessions work. Call the send tool once, with to set to \(target) and text set to \"\(message)\". Then reply with the single word: sent.",
                                    folder: folder, model: model)
        first.start()
        setStep(host, "Waiting for the first session to send…")
        guard await setup.waitUntil(limit, { setup.hostSent[firstID] != nil }) else { return .failed(ChannelChecklist.notSent(after: limit)) }
        guard let sent = setup.hostSent[firstID] else { return .failed(ChannelChecklist.notSent(after: limit)) }

        setStep(host, "Waiting for the host's session to answer…")
        guard await setup.waitUntil(limit, { setup.watchedTo[firstID] != nil }) else {
            return .failed(sent.started ? ChannelChecklist.notAnswered(after: limit) : ChannelChecklist.notArrived(after: limit))
        }
        let answeredAt = setup.watchedTo[firstID] ?? Date()
        return .passed(arrived: sent.at.timeIntervalSince(sent.sentAt), answered: answeredAt.timeIntervalSince(sent.sentAt))
    }
}
