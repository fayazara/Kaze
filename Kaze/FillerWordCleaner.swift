import Foundation

/// Removes filler words (uh, um, er, hmm, ah, etc.) from transcribed text
/// using word-boundary-aware regex to avoid false positives.
enum FillerWordCleaner {

    // MARK: - Public

    /// Clean filler words from transcribed text.
    ///
    /// The approach:
    /// 1. Remove whole filler words matched at word boundaries (case-insensitive).
    /// 2. Clean up punctuation artifacts left behind (orphaned commas, double periods, etc.).
    /// 3. Collapse multiple spaces and trim.
    static func clean(_ text: String) -> String {
        var result = text

        // Step 1: Remove filler words at word boundaries.
        // We match fillers that may be followed by a comma (e.g. "Um, I think") and
        // consume the comma + optional space so the sentence reads naturally.
        //
        // Pattern explanation:
        //   \b          – word boundary before the filler
        //   (filler)    – one of the filler patterns
        //   \b          – word boundary after the filler
        //   [,;]?\s*    – optional trailing comma/semicolon and whitespace
        for pattern in fillerPatterns {
            let regex = "\\b\(pattern)\\b[,;]?\\s*"
            result = result.replacingOccurrences(
                of: regex,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Step 2: Fix punctuation artifacts.
        // "I, , think" → "I, think"  (doubled commas)
        result = result.replacingOccurrences(
            of: ",\\s*,",
            with: ",",
            options: .regularExpression
        )
        // "I.. think" → "I. think" (doubled periods)
        result = result.replacingOccurrences(
            of: "\\.\\s*\\.",
            with: ".",
            options: .regularExpression
        )
        // Sentence starting with a comma: ", I think" → "I think"
        result = result.replacingOccurrences(
            of: "^\\s*[,;]\\s*",
            with: "",
            options: .regularExpression
        )
        // Comma/semicolon right before a period: ",." → "."
        result = result.replacingOccurrences(
            of: "[,;]\\s*\\.",
            with: ".",
            options: .regularExpression
        )

        // Step 3: Collapse whitespace and trim.
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 4: Re-capitalise first letter if it got lowered by removal.
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Private

    /// Regex patterns for common English filler words.
    /// Each pattern uses character repetition to catch elongated forms
    /// (e.g. "uhhh", "ummm") that ASR models sometimes produce.
    private static let fillerPatterns: [String] = [
        "u+h+",          // uh, uhh, uhhh, uuhhh …
        "u+m+",          // um, umm, ummm …
        "e+r+m+",        // erm, errm, errrm …
        "h+m+",          // hm, hmm, hmmm …
        "a+h+",          // ah, ahh, ahhh …
        "m+h+m+",        // mhm, mhmm …
        "h+u+h+",        // huh, huhh …
    ]
}
