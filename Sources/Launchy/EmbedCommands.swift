import Foundation

/// `Launchy --embed-reference` and `Launchy --embed-check <address> [model]`. They build only what they need (never
/// `AppDelegate` or `LauncherModel`, which restore sessions), write no UserDefaults and send nothing but the three references.
@MainActor
enum EmbedCommands {
    /// Prints the three reference vectors from this Mac's model as `name=base64`, and each one's cosine to the shipped
    /// reference when there is one. Needs the model installed; downloads nothing.
    static func reference() async -> Int32 {
        guard MLXRuntime.hasMetalLibrary else {
            print("mlx.metallib isn't next to the binary: build with make build")
            return 1
        }
        let embedder = Embedder()
        guard embedder.isReady else {
            print("Search embeddings aren't installed: \(embedder.state)")
            return 1
        }
        do {
            var cosines: [String] = []
            for reference in EmbeddingReferences.all {
                let vector = reference.isQuery
                    ? try await embedder.embedQuery(reference.text) : try await embedder.embedDocuments([reference.text])[0]
                print("\(reference.name)=\(EmbeddingReferences.Reference.encode(vector))")
                let shipped = reference.vector
                if shipped.count == vector.count {
                    cosines.append("\(reference.name) \(String(format: "%.7f", EmbeddingReferences.cosine(vector, shipped)))")
                }
            }
            if !cosines.isEmpty { print("cosine to shipped: " + cosines.joined(separator: ", ")) }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Runs the Check against a server and prints what it found. Exits 0 on a pass.
    static func check(_ arguments: [String]) async -> Int32 {
        guard let address = arguments.first, !address.hasPrefix("--") else {
            print("usage: Launchy --embed-check <address> [model]")
            return 2
        }
        let model = arguments.dropFirst().first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? Embedder.modelKey
        let outcome = await ServerEmbedder(address: address, model: model).check()
        print(outcome.summary)
        switch outcome {
        case .sameModel(let cosines, let roundTrip), .anotherModel(let cosines, let roundTrip):
            print("size \(EmbeddingReferences.dimension)")
            for (reference, cosine) in zip(EmbeddingReferences.all, cosines) {
                print("cosine \(reference.name) \(String(format: "%.6f", cosine))")
            }
            print("round trip \(String(format: "%.3f", roundTrip.seconds)) s")
        case .wrongSize(let count):
            print("size \(count)")
        case .notAnswering, .notOnTailnet:
            break
        }
        return outcome.passed ? 0 : 1
    }
}
