import Foundation

/// What search needs of an embedder: this Mac's `Embedder` or a model server's `ServerEmbedder`. Both give L2-normalized
/// 1024-number vectors under the one model key, so they share an archive.
@MainActor
protocol TextEmbedding {
    func embedQuery(_ text: String) async throws -> [Float]
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder: TextEmbedding {}
extension ServerEmbedder: TextEmbedding {}
