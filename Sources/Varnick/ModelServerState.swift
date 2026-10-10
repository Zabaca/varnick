import Combine
import SwiftUI

/// Where a role's model runs (Settings › Models): in this process, or on a model server on the tailnet (ADR 0014).
enum ModelRunOn: String, CaseIterable, Identifiable {
    case local, server

    var id: String { rawValue }
    var title: String { self == .local ? "On this Mac" : "Server" }
}

/// A role's choice in effect: where it runs, and for Server which address and model.
typealias ServerChoice = (runOn: ModelRunOn, address: String, model: String)

/// What a Check found, as Settings shows it. Both roles word their checks the same way.
struct ServerVerdict: Equatable {
    enum Kind: Equatable {
        case passed
        /// Answers, but not as this role needs (another model, the wrong size): not to be used until the address or model
        /// changes or Check is pressed.
        case wrongServer
        /// No answer, or an address off the tailnet: asked again after a minute.
        case notAnswering
    }
    let kind: Kind
    let text: String
    var help: String?
}

/// Where a role's model answered: this Mac's, the server's, or this Mac's because the server isn't answering.
enum ModelPlace: Equatable { case thisMac, server, fallback }

/// One role's model server as the app knows it: the last Check for the address and model in effect, and when it passed or
/// didn't answer. In memory only, so each launch checks again, and nothing is sent until something asks.
@MainActor
final class ModelServerState: ObservableObject {
    struct Target: Equatable {
        let address: String
        let model: String
    }
    enum Status: Equatable { case notChecked, checking, checked(ServerVerdict) }

    /// A Check for an address and model; a change of either makes it stale.
    private struct Record {
        let target: Target
        var status: Status
        var passedAt: Date?
        var notAnsweringAt: Date?
    }

    /// Not asked again within this long of not answering, except by a press of Check.
    static let retryAfter: TimeInterval = 60

    private let target: @MainActor () -> Target
    private let run: (Target) async -> ServerVerdict
    @Published private var record: Record?
    private var task: Task<Void, Never>?

    init(target: @escaping @MainActor () -> Target, run: @escaping (Target) async -> ServerVerdict) {
        self.target = target
        self.run = run
    }

    private var current: Record? { record.flatMap { $0.target == target() ? $0 : nil } }

    var status: Status { current?.status ?? .notChecked }
    /// When the last Check passed, for the address and model in Settings now.
    var passedAt: Date? { current?.passedAt }
    /// The last Check passed.
    var isPassing: Bool { passedAt != nil }
    /// A server that answered as another model, or the wrong size.
    var isBlocked: Bool {
        if case .checked(let verdict) = status { verdict.kind == .wrongServer } else { false }
    }
    /// Not to be asked again yet.
    var isResting: Bool {
        current?.notAnsweringAt.map { Date().timeIntervalSince($0) < Self.retryAfter } ?? false
    }

    /// Whether the server passed a Check within `age` seconds, asking first (and waiting for the answer) when it didn't and
    /// isn't blocked or resting. A Check already under way is waited for, not repeated.
    func passes(within age: TimeInterval) async -> Bool {
        if let passedAt, Date().timeIntervalSince(passedAt) < age { return true }
        guard !isBlocked, !isResting else { return false }
        if status != .checking { check() }
        await task?.value
        return passedAt.map { Date().timeIntervalSince($0) < age } ?? false
    }

    /// A request to `requested` failed. Dropped when the address or model has changed since; a wrong size blocks the
    /// server like a failed Check, and any other failure rests it for a minute.
    func failed(_ error: Error, for requested: Target) {
        guard requested == target() else { return }
        let wrongServer = error is ServerEmbedder.WrongSize
        let failure = (error as? ModelServer.Failure) ?? .unreadable
        let text = (error as? ServerEmbedder.WrongSize)?.errorDescription
            ?? failure.errorDescription!
        record = Record(target: requested, status: .checked(ServerVerdict(kind: wrongServer ? .wrongServer : .notAnswering, text: text)),
                        notAnsweringAt: wrongServer ? nil : Date())
    }

    /// The fallback rule (where-it-breaks, Search store); nil: nothing may answer now.
    func place(_ runOn: ModelRunOn, hasAddress: Bool, thisMacReady: Bool, interactive: Bool) -> ModelPlace? {
        guard runOn == .server else { return thisMacReady ? .thisMac : nil }
        if hasAddress, interactive ? (!isBlocked && !isResting) : isPassing { return .server }
        return interactive && thisMacReady ? .fallback : nil
    }

    /// Sent when the user asks for a Check (Check pressed, or the address or model submitted), after it has started.
    let userChecked = PassthroughSubject<Void, Never>()

    func userCheck() {
        check()
        userChecked.send()
    }

    /// Asks the server now, whatever it said last. Nothing without an address.
    func check() {
        let target = target()
        guard !target.address.isEmpty else { return }
        task?.cancel()
        record = Record(target: target, status: .checking)
        task = Task { [run] in
            let verdict = await run(target)
            guard !Task.isCancelled else { return }
            record = Record(target: target, status: .checked(verdict),
                            passedAt: verdict.kind == .passed ? Date() : nil,
                            notAnsweringAt: verdict.kind == .notAnswering ? Date() : nil)
        }
    }
}

extension ModelServerState {
    /// Search embeddings' server: the address and model in effect (Settings, or VARNICK_EMBEDDINGS), checked against the references.
    static func forEmbeddings() -> ModelServerState {
        ModelServerState(
            target: { .init(address: Settings.shared.activeEmbeddings.address, model: Settings.shared.activeEmbeddings.model) },
            run: { target in await ServerEmbedder(address: target.address, model: target.model).check().verdict })
    }
}

extension ModelServerState {
    /// Text generation's server: the address and model in effect (Settings, or VARNICK_TEXT_GENERATION), asked for a word.
    static func forTextGeneration() -> ModelServerState {
        ModelServerState(
            target: { .init(address: Settings.shared.activeTextGeneration.address, model: Settings.shared.activeTextGeneration.model) },
            run: { target in await ServerGenerator(address: target.address, model: target.model).check().verdict })
    }
}

extension ServerGenerator.Check {
    var verdict: ServerVerdict {
        switch self {
        case .answers(_, let model):
            ServerVerdict(kind: .passed, text: summary, help: model.map { "The reply names the model \($0)" } ?? "The reply names no model")
        case .notAnswering, .notOnTailnet: ServerVerdict(kind: .notAnswering, text: summary)
        }
    }
}

extension ServerEmbedder.Check {
    var verdict: ServerVerdict {
        switch self {
        case .sameModel(let cosines, let roundTrip):
            ServerVerdict(kind: .passed, text: summary,
                          help: String(format: "Lowest similarity %.4f, round trip %.0f ms", cosines.min() ?? 0, roundTrip.seconds * 1000))
        case .anotherModel, .wrongSize: ServerVerdict(kind: .wrongServer, text: summary)
        case .notAnswering, .notOnTailnet: ServerVerdict(kind: .notAnswering, text: summary)
        }
    }
}

/// The Server choice's row: the address, the model, Check and the status, the same for both roles.
struct ServerSettingRow: View {
    let detail: String
    let addressPlaceholder: String
    @Binding var address: String
    @Binding var model: String
    @ObservedObject var server: ModelServerState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server").font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(addressPlaceholder, text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { server.userCheck() }
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 190)
                    .onSubmit { server.userCheck() }
                Button("Check") { server.userCheck() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || server.status == .checking)
            }
            status
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var status: some View {
        switch server.status {
        case .notChecked:
            Text("Not checked yet").font(.system(size: 12)).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .checked(let verdict):
            Text(verdict.text).font(.system(size: 12))
                .foregroundStyle(verdict.kind == .passed ? Color.secondary : Color.orange)
                .help(verdict.help ?? "")
        }
    }
}
