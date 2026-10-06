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

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
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
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    var totalWords: Int { items.reduce(0) { $0 + $1.wordCount } }
    var totalDuration: TimeInterval { items.reduce(0) { $0 + $1.duration } }

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
