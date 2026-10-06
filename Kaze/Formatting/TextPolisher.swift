import Foundation

/// Deterministic cleanup applied to every transcript, before and after the
/// optional S1-mini pass.
nonisolated enum TextPolisher {
    /// Removes engine artifacts and normalizes whitespace.
    static func clean(_ text: String) -> String {
        var result = text
        // Whisper emits bracketed annotations for non-speech audio.
        result = result.replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|NOISE|SILENCE|INAUDIBLE)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\((music|noise|silence|inaudible|applause|laughs?)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies user replacements as whole-word, case-insensitive matches.
    static func applyReplacements(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        for replacement in replacements where !replacement.find.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: replacement.find) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: replacement.replace)
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// Whether the formatter's output looks like a real rewrite rather than a
    /// failure mode (blank output for real speech, or runaway generation).
    static func isPlausibleRewrite(_ output: String, of input: String) -> Bool {
        let inputWords = input.split(whereSeparator: \.isWhitespace).count
        let outputWords = output.split(whereSeparator: \.isWhitespace).count
        if outputWords == 0 { return inputWords <= 3 }   // filler-only input legitimately becomes ""
        return outputWords <= inputWords * 2 + 12
    }
}
