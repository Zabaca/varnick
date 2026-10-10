import Foundation

/// Embeds on a model server's `/v1/embeddings` (ADR 0014). It adds the query instruction and normalizes the reply, so
/// the vectors share the archive and its model key with `Embedder`'s.
struct ServerEmbedder {
    let address: String
    var model = Embedder.modelKey

    var target: ModelServerState.Target { .init(address: address, model: model) }

    /// A vector of another size is not this model's: `Check` words it, and a search or a sync treats it as a failure.
    struct WrongSize: LocalizedError, Equatable {
        let count: Int
        var errorDescription: String? { "Wrong size: \(count) numbers, needs \(EmbeddingReferences.dimension)" }
    }

    static let queryTimeout: TimeInterval = 2
    static let batchTimeout: TimeInterval = 30
    static let checkTimeout: TimeInterval = 5

    func embedQuery(_ text: String) async throws -> [Float] {
        try await vectors([Embedder.queryPrefix + text], timeout: Self.queryTimeout)[0]
    }

    /// L2-normalized vectors in input order. Batched shortest first and one request at a time, as `Embedder` does.
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        let order = texts.indices.sorted { texts[$0].count < texts[$1].count }
        var out = [[Float]](repeating: [], count: texts.count)
        for start in stride(from: 0, to: order.count, by: Embedder.batchSize) {
            let batch = Array(order[start ..< min(start + Embedder.batchSize, order.count)])
            for (i, vector) in zip(batch, try await vectors(batch.map { texts[$0] }, timeout: Self.batchTimeout)) { out[i] = vector }
        }
        return out
    }

    private func vectors(_ texts: [String], timeout: TimeInterval) async throws -> [[Float]] {
        let vectors = try await request(texts, timeout: timeout)
        if let wrong = vectors.first(where: { $0.count != EmbeddingReferences.dimension }) { throw WrongSize(count: wrong.count) }
        return vectors
    }

    /// One normalized vector per input, matched by `index` (a missing or repeated one fails the batch), of any size. No
    /// `dimensions` field: Ollama shortens the vector when it gets one.
    func request(_ texts: [String], timeout: TimeInterval) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let data = try await ModelServer.post(["model": model, "input": texts], to: "embeddings", at: address, timeout: timeout)
        struct Reply: Decodable {
            struct Item: Decodable { let index: Int; let embedding: [Float] }
            let data: [Item]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.data.count == texts.count else {
            throw ModelServer.Failure.unreadable
        }
        var out = [[Float]?](repeating: nil, count: texts.count)
        for item in reply.data {
            guard out.indices.contains(item.index), out[item.index] == nil, let unit = Self.normalized(item.embedding) else {
                throw ModelServer.Failure.unreadable
            }
            out[item.index] = unit
        }
        return out.compactMap { $0 }
    }

    /// Nil for an empty, zero or non-finite vector.
    static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    // MARK: The Check

    /// What the Check found. It passes only as `sameModel`.
    enum Check: Equatable {
        /// Every vector has the right size and a cosine of at least `EmbeddingReferences.passingCosine` with its reference.
        case sameModel(cosines: [Double], roundTrip: Duration)
        case anotherModel(cosines: [Double], roundTrip: Duration)
        case wrongSize(Int)
        case notAnswering(String)
        case notOnTailnet

        var passed: Bool { if case .sameModel = self { true } else { false } }

        var lowestCosine: Double? {
            switch self {
            case .sameModel(let cosines, _), .anotherModel(let cosines, _): cosines.min()
            default: nil
            }
        }

        /// Settings' status, and the command line's first line.
        var summary: String {
            switch self {
            case .sameModel: "Same model"
            case .anotherModel: "Another model (similarity \(String(format: "%.2f", lowestCosine ?? 0)))"
            case .wrongSize(let count): "Wrong size: \(count) numbers, needs \(EmbeddingReferences.dimension)"
            case .notAnswering(let reason): "Not answering: \(reason)"
            case .notOnTailnet: "Not on your tailnet"
            }
        }
    }

    /// Sends the three references and compares what comes back with the ones shipped in Varnick, which this Mac's model made.
    func check() async -> Check {
        let references = EmbeddingReferences.all
        let clock = ContinuousClock()
        let started = clock.now
        let vectors: [[Float]]
        do {
            vectors = try await request(references.map { $0.isQuery ? Embedder.queryPrefix + $0.text : $0.text },
                                        timeout: Self.checkTimeout)
        } catch {
            return ModelServer.notAnsweringReason(error).map(Check.notAnswering) ?? .notOnTailnet
        }
        let roundTrip = started.duration(to: clock.now)
        if let wrong = vectors.first(where: { $0.count != EmbeddingReferences.dimension }) { return .wrongSize(wrong.count) }
        let cosines = zip(vectors, references).map { EmbeddingReferences.cosine($0, $1.vector) }
        return (cosines.min() ?? 0) >= EmbeddingReferences.passingCosine
            ? .sameModel(cosines: cosines, roundTrip: roundTrip) : .anotherModel(cosines: cosines, roundTrip: roundTrip)
    }
}
