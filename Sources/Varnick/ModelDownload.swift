import Foundation

/// A model's files from Hugging Face at a pinned revision, shared by the embedder and text generation.
struct ModelSource {
    let repo: String
    let revision: String
    /// Weights last: the download's progress follows that file.
    let files: [String]
    /// Byte counts to check before the folder is moved into place, so a cut-short file never looks installed.
    var sizes: [String: Int] = [:]
}

enum ModelDownload {
    struct Incomplete: LocalizedError {
        let file: String
        var errorDescription: String? { "\(file) downloaded incomplete" }
    }

    /// Downloads into a `.partial` sibling, moved over `directory` only once every size matches, so a failure
    /// leaves what was installed alone. `progress` follows the weights, from any thread.
    static func run(_ source: ModelSource, into directory: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        let partial = directory.appendingPathExtension("partial")
        do {
            try? fileManager.removeItem(at: partial)
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            for file in source.files {
                let url = URL(string: "https://huggingface.co/\(source.repo)/resolve/\(source.revision)/\(file)")!
                let isWeights = file == source.files.last
                let destination = partial.appending(path: file)
                try await fetch(url, to: destination) { if isWeights { progress($0) } }
                if let size = source.sizes[file] {
                    let written = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                    guard written == size else { throw Incomplete(file: file) }
                }
            }
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.replaceItemAt(directory, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: directory)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func fetch(_ url: URL, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let error { return done.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return done.resume(throwing: URLError(.badServerResponse))
                }
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }
}
