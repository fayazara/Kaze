import Foundation
import Observation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    /// What was pasted.
    var text: String
    /// The engine's transcript before formatting, when it differed.
    var rawText: String?
    var model: SpeechModel
    var appName: String?
    var appBundleID: String?
    /// Seconds of audio recorded.
    var duration: TimeInterval
    /// Seconds from releasing the shortcut to the paste.
    var latency: TimeInterval
    /// Why the recording wasn't transcribed, if it wasn't. `text` is empty
    /// and the audio is kept so it can be retried.
    var failure: String?

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The saved audio, if it's still on disk.
    var recordingURL: URL? {
        let url = StorageLocations.recording(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Recent dictations, kept on disk so they survive relaunches and can be
/// re-copied if a paste lands in the wrong place.
@Observable
final class HistoryStore {
    private(set) var items: [HistoryItem] = []
    private let url: URL
    private static let limit = 500

    init(url: URL = StorageLocations.history) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
        }
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.limit {
            items.suffix(from: Self.limit).forEach { Self.deleteRecording($0.id) }
            items.removeLast(items.count - Self.limit)
        }
        save()
    }

    func update(_ item: HistoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        Self.deleteRecording(item.id)
        save()
    }

    func clear() {
        items.forEach { Self.deleteRecording($0.id) }
        items.removeAll()
        save()
    }

    static func deleteRecording(_ id: UUID) {
        try? FileManager.default.removeItem(at: StorageLocations.recording(for: id))
    }

    /// A recording without a history item was cut off by a crash or quit.
    /// List it so it can be retried. Call at launch, before any dictation.
    func recoverInterruptedRecordings(model: SpeechModel) {
        let known = Set(items.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(at: StorageLocations.recordings, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !known.contains(id) else { continue }
            let duration = AudioRecorder.duration(ofRecordingAt: file)
            guard duration >= 1 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            items.append(HistoryItem(id: id, date: date, text: "", model: model, duration: duration, latency: 0, failure: "Interrupted"))
        }
        guard items.count > known.count else { return }
        items.sort { $0.date > $1.date }
        save()
    }

    var totalWords: Int { items.reduce(0) { $0 + $1.wordCount } }
    var totalDuration: TimeInterval { items.reduce(0) { $0 + ($1.failure == nil ? $1.duration : 0) } }

    private func save() {
        let items = items
        let url = url
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            _ = StorageLocations.ensure(url.deletingLastPathComponent())
            if let data = try? encoder.encode(items) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
