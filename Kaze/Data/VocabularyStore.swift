import Foundation
import Observation

/// A literal find-and-replace applied to every transcript, e.g.
/// "kaze app" → "Kaze".
struct Replacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var find: String
    var replace: String
}

/// Custom words that bias recognition, plus replacements applied afterwards.
@Observable
final class VocabularyStore {
    private(set) var words: [String] = []
    private(set) var replacements: [Replacement] = []

    nonisolated private struct Snapshot: Codable {
        var words: [String]
        var replacements: [Replacement]
    }

    private let url: URL

    init(url: URL = StorageLocations.vocabulary) {
        self.url = url
        if let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            words = snapshot.words
            replacements = snapshot.replacements
        }
    }

    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        words.append(trimmed)
        save()
    }

    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
        save()
    }

    func addReplacement(find: String, replace: String) {
        let find = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !find.isEmpty else { return }
        replacements.removeAll { $0.find.caseInsensitiveCompare(find) == .orderedSame }
        replacements.append(Replacement(find: find, replace: replace))
        save()
    }

    func removeReplacement(_ replacement: Replacement) {
        replacements.removeAll { $0.id == replacement.id }
        save()
    }

    private func save() {
        let snapshot = Snapshot(words: words, replacements: replacements)
        let url = url
        Task.detached(priority: .utility) {
            _ = StorageLocations.ensure(url.deletingLastPathComponent())
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
