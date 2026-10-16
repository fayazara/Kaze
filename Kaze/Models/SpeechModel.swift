import Foundation

/// Every speech-to-text model Kaze can run. All run fully on-device.
nonisolated enum SpeechModel: String, CaseIterable, Identifiable, Codable {
    case apple
    case parakeetV2
    case parakeetV3
    case phonon2
    case whisperBase
    case whisperSmallEnglish
    case whisperLargeTurbo

    var id: String { rawValue }

    enum Family: String {
        case apple, parakeet, phonon, whisper

        var vendor: String {
            switch self {
            case .apple: "Apple"
            case .parakeet: "NVIDIA"
            case .phonon: "Fermion Research"
            case .whisper: "OpenAI"
            }
        }

        var runtime: String {
            switch self {
            case .apple: "SpeechAnalyzer · Built into macOS"
            case .parakeet: "Core ML · Neural Engine"
            case .phonon: "Core ML · Neural Engine"
            case .whisper: "Core ML · Neural Engine"
            }
        }
    }

    var family: Family {
        switch self {
        case .apple: .apple
        case .parakeetV2, .parakeetV3: .parakeet
        case .phonon2: .phonon
        case .whisperBase, .whisperSmallEnglish, .whisperLargeTurbo: .whisper
        }
    }

    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeetV2: "Parakeet v2"
        case .parakeetV3: "Parakeet v3"
        case .phonon2: "Phonon-2"
        case .whisperBase: "Whisper Base"
        case .whisperSmallEnglish: "Whisper Small"
        case .whisperLargeTurbo: "Whisper Large v3 Turbo"
        }
    }

    var summary: String {
        switch self {
        case .apple: "Built into macOS. Shows your words live as you speak. Nothing to download."
        case .parakeetV2: "The fastest, most accurate model for English. Transcribes a minute of audio in under a second."
        case .parakeetV3: "Parakeet's multilingual build, covering 25 European languages."
        case .phonon2: "A compact Parakeet for English, a third of the download with near-identical accuracy."
        case .whisperBase: "A small, quick Whisper model covering 99 languages."
        case .whisperSmallEnglish: "Whisper tuned for English. Good accuracy, modest size."
        case .whisperLargeTurbo: "Whisper's most accurate model for 99 languages."
        }
    }

    var languages: String {
        switch self {
        case .apple: "~30 languages"
        case .parakeetV2, .phonon2, .whisperSmallEnglish: "English"
        case .parakeetV3: "25 languages"
        case .whisperBase, .whisperLargeTurbo: "99 languages"
        }
    }

    /// Approximate download size; `nil` when nothing needs downloading.
    var downloadSize: String? {
        switch self {
        case .apple: nil
        case .parakeetV2, .parakeetV3: "480 MB"
        case .phonon2: "345 MB"
        case .whisperBase: "145 MB"
        case .whisperSmallEnglish: "220 MB"
        case .whisperLargeTurbo: "630 MB"
        }
    }

    /// 1...5 for the comparison meters in Settings.
    var speedRating: Int {
        switch self {
        case .apple: 4
        case .parakeetV2, .parakeetV3, .phonon2: 5
        case .whisperBase: 4
        case .whisperSmallEnglish: 3
        case .whisperLargeTurbo: 2
        }
    }

    var accuracyRating: Int {
        switch self {
        case .apple: 4
        case .parakeetV2: 5
        case .parakeetV3: 4
        case .phonon2: 5
        case .whisperBase: 2
        case .whisperSmallEnglish: 3
        case .whisperLargeTurbo: 4
        }
    }

    /// Whether this model can show text while you are still speaking.
    var streamsLiveText: Bool { self == .apple }

    var requiresDownload: Bool { family != .apple }

    /// WhisperKit folder suffix in `argmaxinc/whisperkit-coreml`.
    var whisperVariant: String? {
        switch self {
        case .whisperBase: "base"
        case .whisperSmallEnglish: "small.en_217MB"
        case .whisperLargeTurbo: "large-v3-v20240930_turbo_632MB"
        default: nil
        }
    }

    /// Whether the model is English-only (used to hide the language picker).
    var isEnglishOnly: Bool {
        self == .parakeetV2 || self == .phonon2 || self == .whisperSmallEnglish
    }

    static let pickerOrder: [SpeechModel] = [.apple, .parakeetV2, .parakeetV3, .phonon2, .whisperSmallEnglish, .whisperBase, .whisperLargeTurbo]
}

/// Phonon-2's Core ML package from `FermionResearch/Phonon-2-CoreML`.
nonisolated enum PhononModel {
    static let repo = "FermionResearch/Phonon-2-CoreML"
    /// Pinned to a commit; the package must match the Swift runner's version.
    static let revision = "1143812fd4236522232a8c33e3115f0577e3cd7d"
    static let folder = "Phonon-2"
    static let package = "Phonon-2.mlpackage"
    /// The encoder windows in the package, in seconds.
    static let encoderWindows: [Double] = [5, 10, 15, 35]
    static let files = [
        "manifest.json",
        "decoder.bin",
        "Phonon-2.mlpackage/Manifest.json",
        "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "LICENSE-WEIGHTS-CC-BY-4.0.txt",
        "NOTICE",
    ]
}

/// The post-processing language model. Its name and capitalization are
/// required by its license: "S1-mini" by "Superwhisper".
nonisolated enum FormatterModel {
    static let name = "S1-mini"
    static let author = "Superwhisper"
    static let repo = "superwhisper/s1-mini"
    /// Pinned to a commit so the weights and prompt format can't change
    /// underneath the app (the repo has no release tags).
    static let revision = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"
    static let files = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt",
        "model.safetensors",
        "LICENSE",
        "NOTICE",
    ]
    static let downloadSize = "1.5 GB"
}

/// Where Kaze stores the models it downloads itself.
nonisolated enum StorageLocations {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kaze", isDirectory: true)
    }

    static var whisperModels: URL { root.appendingPathComponent("Whisper", isDirectory: true) }
    static var phononModels: URL { root.appendingPathComponent("Phonon", isDirectory: true) }
    static var formatterModel: URL { root.appendingPathComponent("S1-mini", isDirectory: true) }
    static var history: URL { root.appendingPathComponent("history.json") }
    static var vocabulary: URL { root.appendingPathComponent("vocabulary.json") }

    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension FileManager {
    /// Total allocated size of a directory tree, in bytes.
    nonisolated func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
