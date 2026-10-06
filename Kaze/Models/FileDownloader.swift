import Foundation

/// Downloads a set of files into a directory with accurate, byte-weighted
/// progress. Files land in a staging folder and are moved into place only
/// when everything succeeded, so a cancelled download never looks installed.
nonisolated enum FileDownloader {
    struct Item: Sendable {
        let url: URL
        let fileName: String
    }

    static func download(_ items: [Item], to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let sizes = try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, try await contentLength(of: item.url)) }
            }
            var sizes = [Int64](repeating: 0, count: items.count)
            for try await (index, size) in group { sizes[index] = size }
            return sizes
        }
        let total = max(sizes.reduce(0, +), 1)
        var completed: Int64 = 0

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let base = completed
            let file = try await downloadOne(item.url) { written in
                progress(Double(base + written) / Double(total))
            }
            try fm.moveItem(at: file, to: staging.appendingPathComponent(item.fileName))
            completed += sizes[index]
            progress(Double(completed) / Double(total))
        }

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
    }

    private static func contentLength(of url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        return max(response.expectedContentLength, 0)
    }

    private static func downloadOne(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(onProgress: @escaping @Sendable (Int64) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            // The temporary file is deleted when this method returns.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                continuation?.resume(returning: kept)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }
}
