import Foundation

/// Clean Up without a language model: fillers, stutters, self-corrections,
/// spoken commands, numbered lists, email layout and register, all by rule.
/// Runs in well under a millisecond and nothing leaves the Mac.
///
/// Expects a transcript the speech engine has already punctuated and
/// capitalized, which every Kaze engine does. English only.
nonisolated enum RuleCleanUp {
    static func clean(_ transcript: String, style: FormatStyle, allowLists: Bool, context: FormatContext) -> String {
        var text = transcript.replacingOccurrences(of: "’", with: "'")
        text = spokenBreaks(text)
        text = scratchThat(text)
        text = removeHesitations(text)
        text = spokenAddresses(text)
        text = currencies(spokenNumbers(text))
        text = applyCorrections(text)
        text = removeDiscourseFillers(text)
        text = removeStutters(text)
        text = tidy(text)
        // In editors and terminals, only take out what was never meant.
        guard context != .code, !text.isEmpty else { return text }

        text = applyRegister(text, style)
        var greeting: String?
        var signOff: String?
        if context == .email { (greeting, text, signOff) = splitEmail(text) }
        if allowLists, let list = numberedList(text) { text = list }
        text = sentenceCase(text, style)
        return tidy([greeting, text, signOff].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    // MARK: - Spoken commands

    /// "new line" and "new paragraph", with whatever punctuation the engine put after them.
    static func spokenBreaks(_ text: String) -> String {
        text.replacingPattern(#"[ \t]*\bnew paragraph\b[,.;:!]?[ \t]*"#, with: "\n\n")
            .replacingPattern(#"[ \t]*\bnew line\b[,.;:!]?[ \t]*"#, with: "\n")
    }

    /// "scratch that" drops the sentence it ends, or the one before it when
    /// it's said on its own.
    static func scratchThat(_ text: String) -> String {
        var text = text
        let command = Regex.make(#"\b(?:scratch|strike|delete) that\b[.,!]?\s*"#)
        while let match = command.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) {
            var before = text[..<range.lowerBound]
            while let last = before.last, last == " " || last == "," { before.removeLast() }
            if let last = before.last, ".!?".contains(last) { before.removeLast() }
            let start = before.lastIndex { ".!?\n".contains($0) }.map { before.index(after: $0) } ?? text.startIndex
            text = String(text[..<start]) + (start == text.startIndex ? "" : " ") + text[range.upperBound...]
        }
        return text
    }

    // MARK: - Fillers

    /// um, uh, erm and friends, with the commas around them. "uh-oh" and "hmm" stay.
    static func removeHesitations(_ text: String) -> String {
        text.replacingPattern(#",?\s*(?<![\p{L}'-])(?:u+m+|u+h+m*|e+r+m+|e+r+|e+h+m*)(?![\p{L}'-]),?"#, with: " ")
    }

    /// "you know", "I mean" and "like" when they're set off by commas, which
    /// is how engines punctuate them as asides.
    static func removeDiscourseFillers(_ text: String) -> String {
        text.replacingPattern(#"\b(and|but|or|so)\s*,\s*(?:you know|like)\s*,\s*"#, with: "$1 ")
            .replacingPattern(#",\s*(?:you know|like)\s*,"#, with: ",")
            .replacingPattern(#"(^|[.!?\n]\s*)(?:you know|I mean|like),\s*"#, with: "$1")
            .replacingPattern(#",\s*I mean,\s*"#, with: ", ")
    }

    /// Words said twice by accident: "the the", "I, I think".
    static func removeStutters(_ text: String) -> String {
        let doubled = text.replacingPattern(#"(?<![\p{L}'])(\p{L}+)(?:\s+\1)+(?![\p{L}'])"#) { groups in
            intentionalRepeats.contains(groups[1]!.lowercased()) ? nil : groups[1]
        }
        return doubled.replacingPattern(#"(?<![\p{L}'])(I|a|an|the|we|my|our|and|but)\s*,\s+\1(?![\p{L}'])"#, with: "$1")
    }

    private static let intentionalRepeats: Set<String> = [
        "had", "that", "very", "really", "so", "no", "yes", "yeah", "bye", "ha", "haha", "ho", "la", "ok", "okay",
        "go", "knock", "tick", "tock", "blah", "more", "again", "over", "round", "by", "out", "far", "long", "now",
        "well", "please", "wait", "hey", "oh", "ah", "wow", "yay", "ooh", "aw", "hip", "ding", "chop", "boo", "night",
    ]

    // MARK: - Addresses

    private static let topLevelDomains = "com|org|net|io|co|ai|app|dev|edu|gov|me|us|uk|in|de|fr|ca|au|info|biz|xyz|tech|so|sh|gg|tv|ly|to|it|es|nl|jp|ch|se|fi|nz|eu|ie|be|at|sg|ae|br|mx"

    /// "emily dot smith at google dot com" → "emily.smith@google.com", and
    /// "kaze dot app" → "kaze.app". A domain has to end in a real top-level
    /// domain, so "meet at home" is never an address.
    static func spokenAddresses(_ text: String) -> String {
        let word = #"[\p{L}\d][\p{L}\d_-]*"#
        let dot = #"(?:\s+dot\s+|\.(?=[\p{L}\d]))"#
        let domain = "(\(word)(?:\(dot)\(word))*\(dot)(?:\(topLevelDomains)))(?![\\p{L}\\d])"
        let local = #"([\p{L}\d][\p{L}\d]*(?:(?:\s+(?:dot|underscore|dash|hyphen)\s+|[._-])[\p{L}\d]+)*)"#
        let withEmails = text.replacingPattern(#"(?<![\p{L}\d@.])"# + local + #"\s+(?:at the rate(?: of)?|at)\s+"# + domain) { groups in
            spokenAddress(groups[1]!) + "@" + spokenAddress(groups[2]!)
        }
        // Spoken domains on their own; at least one "dot" must be spoken, so
        // an engine's "google.com" is left as it is.
        return withEmails.replacingPattern(#"(?<![\p{L}\d@.])((?:www\s+dot\s+)?\#(word)(?:\s+dot\s+\#(word))*\s+dot\s+(?:\#(topLevelDomains)))(?![\p{L}\d])"#) { groups in
            spokenAddress(groups[1]!)
        }
    }

    private static func spokenAddress(_ spoken: String) -> String {
        spoken.lowercased()
            .replacingPattern(#"\s+dot\s+"#, with: ".")
            .replacingPattern(#"\s+underscore\s+"#, with: "_")
            .replacingPattern(#"\s+(?:dash|hyphen)\s+"#, with: "-")
    }

    // MARK: - Numbers

    private enum NumberWord {
        case unit(Int), teen(Int), tens(Int), hundred, scale(Int)
    }

    private static let numberWordValues: [String: NumberWord] = {
        var words: [String: NumberWord] = ["hundred": .hundred, "thousand": .scale(1_000), "million": .scale(1_000_000), "billion": .scale(1_000_000_000)]
        for (i, w) in ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"].enumerated() { words[w] = .unit(i) }
        for (i, w) in ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"].enumerated() { words[w] = .teen(10 + i) }
        for (i, w) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() { words[w] = .tens(20 + 10 * i) }
        return words
    }()

    private static let numberWordPattern = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)"
    /// Words after a number that make it a quantity, so even "three" becomes "3".
    private static let unitWords: Set<String> = ["dollar", "dollars", "cent", "cents", "euro", "euros", "rupee", "rupees", "yen", "percent", "am", "pm", "a.m.", "p.m.", "o'clock"]
    private static let timeLeads: Set<String> = ["at", "by", "until", "till", "from", "around", "before", "after", "to", "about"]
    private static let yearLeads = Set(["in", "since", "from", "until", "by", "of", "year", "circa"]).union(months.split(separator: "|").map(String.init))

    /// Spelled-out numbers become digits: "twelve hundred" → "1,200",
    /// "ten thirty" after "at" → "10:30", "twenty twenty six" after "in" →
    /// "2026", "three point five" → "3.5". Below ten stays a word unless a
    /// unit follows ("three dollars"), as style guides do.
    static func spokenNumbers(_ text: String) -> String {
        let w = numberWordPattern
        let run = Regex.make(#"(?<![\p{L}\d'])(?:a\s+(?=(?:hundred|thousand|million|billion)\b))?\#(w)\b(?:(?:\s+|-)(?:and\s+(?=\#(w)\b))?(?:\#(w)\b|point(?=\s+\#(w)\b)))*"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in run.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let spoken = ns.substring(with: match.range)
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: match.range.location + match.range.length)
            let previous = before.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            var next = after.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;!?")) } ?? ""
            if next.hasSuffix("."), next != "a.m.", next != "p.m." { next.removeLast() }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += digits(for: spoken, previous: previous, next: next) ?? spoken
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    private static func digits(for spoken: String, previous: String, next: String) -> String? {
        let words = spoken.lowercased().split { $0 == " " || $0 == "-" || $0.isNewline }.map(String.init).filter { $0 != "and" }
        let isQuantity = unitWords.contains(next) || next.hasPrefix("%")

        if let point = words.firstIndex(of: "point") {
            // "three point five" → "3.5", "one point five million" → "1.5 million"
            var fraction = Array(words[(point + 1)...])
            var scale = ""
            if let last = fraction.last, case .scale = numberWordValues[last] { scale = " " + last; fraction.removeLast() }
            let decimals = fraction.compactMap { word -> String? in
                if case .unit(let d) = numberWordValues[word] { return String(d) }
                return nil
            }
            guard decimals.count == fraction.count, !decimals.isEmpty,
                  let whole = numbers(in: Array(words[..<point])), whole.count == 1 else { return nil }
            return "\(whole[0].value).\(decimals.joined())\(scale)"
        }

        guard let parsed = numbers(in: words) else { return nil }
        if parsed.count == 2 {
            let (a, b) = (parsed[0], parsed[1])
            // "ten thirty" at a time-ish position → "10:30".
            if (1...12).contains(a.value), (10...59).contains(b.value), !b.hasScale,
               timeLeads.contains(previous) || ["am", "pm", "a.m.", "p.m."].contains(next) {
                return "\(a.value):\(b.value)"
            }
            // "nineteen ninety", "twenty twenty six" → a year; other centuries need "in" before them.
            if (10...99).contains(a.value), (10...99).contains(b.value), !a.hasScale, !b.hasScale,
               a.value == 19 || a.value == 20 || yearLeads.contains(previous) {
                return String(a.value * 100 + b.value)
            }
            return nil
        }
        guard parsed.count == 1 else { return nil }
        let number = parsed[0]
        guard number.value >= 10 || isQuantity || words.count > 1 else { return nil }
        // "a hundred people" reads fine; "a hundred dollars" becomes "$100".
        if words.first == "a", !isQuantity { return nil }
        // "five million" reads better than "5,000,000".
        if let last = words.last, case .scale(let scale) = numberWordValues[last], scale >= 1_000_000, number.value % scale == 0 {
            return "\(number.value / scale) \(last)"
        }
        if (1900...2099).contains(number.value), yearLeads.contains(previous) { return String(number.value) }
        return grouped(number.value)
    }

    /// Splits a run of number words into the numbers it says, or `nil` when
    /// the words don't form numbers ("hundred hundred").
    private static func numbers(in words: [String]) -> [(value: Int, hasScale: Bool)]? {
        var result: [(value: Int, hasScale: Bool)] = []
        var total = 0, current = 0, hasScale = false
        var last: NumberWord?
        var started = false

        func close() {
            if started { result.append((total + current, hasScale)) }
            total = 0; current = 0; hasScale = false; last = nil; started = false
        }

        for word in words {
            if word == "a" { current = 1; started = true; continue }
            guard let kind = numberWordValues[word] else { return nil }
            // Whether `kind` can continue the number so far.
            let continues: Bool = switch (last, kind) {
            case (nil, _): true
            case (.tens, .unit): true
            case (.unit, .hundred), (.teen, .hundred), (.tens, .hundred): true
            case (.hundred, .unit), (.hundred, .teen), (.hundred, .tens): true
            case (.scale, .unit), (.scale, .teen), (.scale, .tens): true
            case (_, .scale): last.map { if case .scale = $0 { false } else { true } } ?? true
            default: false
            }
            if !continues { close() }
            started = true
            switch kind {
            case .unit(let v), .teen(let v), .tens(let v):
                current += v
            case .hundred:
                current = max(current, 1) * 100
                hasScale = true
            case .scale(let scale):
                total += max(current, 1) * scale
                current = 0
                hasScale = true
            }
            last = kind
        }
        close()
        return result.isEmpty ? nil : result
    }

    private static func grouped(_ value: Int) -> String {
        guard value >= 1000 else { return String(value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1,200 dollars" → "$1,200", "5 dollars and 50 cents" → "$5.50",
    /// "20 percent" → "20%".
    static func currencies(_ text: String) -> String {
        text.replacingPattern(#"(?<![\p{L}\d$€₹¥.,])(\d[\d,]*(?:\.\d+)?)(\s+(?:million|billion|trillion))?\s+(dollars?|euros?|rupees?|yen)(?:\s+and\s+(\d{1,2})\s+cents?)?(?![\p{L}])"#) { groups in
            let symbol = switch groups[3]!.lowercased().prefix(2) {
            case "do": "$"
            case "eu": "€"
            case "ru": "₹"
            default: "¥"
            }
            var amount = groups[1]!
            if !amount.contains(","), !amount.contains("."), let value = Int(amount) { amount = grouped(value) }
            let cents = groups[4].map { "." + ($0.count == 1 ? "0" + $0 : $0) } ?? ""
            return symbol + amount + cents + (groups[2] ?? "")
        }
        .replacingPattern(#"(\d)\s*percent\b"#, with: "$1%")
    }

    // MARK: - Self-corrections

    private static let days = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight|yesterday"
    private static let months = "january|february|march|april|may|june|july|august|september|october|november|december"
    private static let numberWords = "zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred"
    private static let numeral = #"[$€₹¥]?\d+(?:[.:,]\d+)*(?:\s?(?:am|pm|a\.m\.|p\.m\.|%))?"#

    /// "Friday, no wait, Thursday" → "Thursday". Only when both sides are the
    /// same kind of thing (a day, a month, a number or time), which is what
    /// makes a correction certain without understanding the sentence.
    static func applyCorrections(_ text: String) -> String {
        let token = "(\(days)|\(months)|\(numberWords)|\(numeral))"
        let marker = #"(?:no,? wait|wait,? no|no,? sorry|sorry|no,? actually|actually,? no|actually|I mean|or rather|rather|make that|no)"#
        let pattern = #"(?<![\p{L}\d$])"# + token + #"[,.]?\s+"# + marker + #"[,.]?\s+"# + token + #"(?![\p{L}\d])"#
            // The comma that closed the spoken aside: "twelve, actually fifteen, chairs".
            + #"(,(?=\s+(?!(?:and|but|or|so|then)\b)\p{Ll}))?"#
        var text = text
        while true {
            let corrected = text.replacingPattern(pattern) { groups in
                guard let said = groups[1], let meant = groups[2],
                      said.lowercased() != meant.lowercased(),
                      category(of: said) == category(of: meant) else { return nil }
                return meant
            }
            if corrected == text { return text }
            text = corrected
        }
    }

    private static func category(of token: String) -> Int {
        let word = token.lowercased()
        if days.split(separator: "|").contains(Substring(word)) { return 0 }
        if months.split(separator: "|").contains(Substring(word)) { return 1 }
        return 2
    }

    // MARK: - Register

    static func applyRegister(_ text: String, _ style: FormatStyle) -> String {
        switch style {
        case .formal:
            expandContractions(expandSlang(text, formal: true))
        case .semiFormal:
            expandSlang(text, formal: false)
        case .semiCasual:
            text
        case .casual:
            // Texting style: "im", "dont", "i".
            text.replacingPattern(#"(?<=\p{L})'(?=\p{L})"#, with: "")
                .replacingPattern(#"\bI(m|ve|ll|d)?\b"#, with: "i$1", caseInsensitive: false)
        }
    }

    private static let slang: [(String, String)] = [
        ("gonna", "going to"), ("wanna", "want to"), ("gotta", "have to"), ("kinda", "kind of"),
        ("sorta", "sort of"), ("lemme", "let me"), ("gimme", "give me"), ("dunno", "don't know"),
        ("'cause", "because"), ("cuz", "because"), ("outta", "out of"), ("lotta", "lot of"),
    ]
    private static let formalSlang: [(String, String)] = [("yeah", "yes"), ("yep", "yes"), ("yup", "yes"), ("nope", "no")]

    static func expandSlang(_ text: String, formal: Bool) -> String {
        (slang + (formal ? formalSlang : [])).reduce(text) { text, pair in
            text.replacingPattern(#"(?<![\p{L}'])"# + NSRegularExpression.escapedPattern(for: pair.0) + #"(?![\p{L}'])"#) { groups in
                matchCase(of: groups[0]!, pair.1)
            }
        }
    }

    static func expandContractions(_ text: String) -> String {
        var text = text
        for (word, expansion) in [("can't", "cannot"), ("won't", "will not"), ("shan't", "shall not"), ("let's", "let us"), ("I'm", "I am")] {
            text = text.replacingPattern(#"(?<![\p{L}'])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}'])"#) { groups in
                matchCase(of: groups[0]!, expansion)
            }
        }
        return text
            // "it's been" is "it has been"; "I'd been" is "I had been".
            .replacingPattern(#"\b(it|he|she|that|there|what|who|where)'s (been|got)\b"#, with: "$1 has $2")
            .replacingPattern(#"\b(I|you|we|they|he|she)'d (been|better)\b"#, with: "$1 had $2")
            .replacingPattern(#"\b(it|he|she|that|there|what|who|where|here|how)'s\b"#, with: "$1 is")
            .replacingPattern(#"\b(\p{L}+)n't\b"#, with: "$1 not")
            .replacingPattern(#"\b(\p{L}+)'re\b"#, with: "$1 are")
            .replacingPattern(#"\b(\p{L}+)'ve\b"#, with: "$1 have")
            .replacingPattern(#"\b(\p{L}+)'ll\b"#, with: "$1 will")
            .replacingPattern(#"\b(\p{L}+)'d\b"#, with: "$1 would")
    }

    /// `replacement`, capitalized like `original`.
    private static func matchCase(of original: String, _ replacement: String) -> String {
        guard let first = original.first(where: \.isLetter), first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    // MARK: - Lists

    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// "First, … Second, … And finally, …" or "number one … number two …"
    /// becomes a numbered list. Needs at least two markers in order, each at
    /// the start of a clause, so "the first time" never starts a list.
    static func numberedList(_ text: String) -> String? {
        let marker = Regex.make(#"(?<![\p{L}\d'])((?:and|then|and then)\s+)?(?:(first)(?: of all)?|(second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)|(first|second|third|fourth|fifth)ly|number\s+(one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})|(finally|lastly))\b(,|:)?\s*"#)
        let ns = text as NSString
        var items: [Range<String.Index>] = []
        var expected = 1
        for match in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i)).lowercased()
            }
            let joined = group(1) != nil
            let before = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            let spokenNumber = group(5)
            let atClauseStart = before.isEmpty || ".!?,;:\n".contains(before.last!) || joined || spokenNumber != nil
                || before.range(of: #"(?i)\b(?:ok|okay|so|well|alright|right|now)$"#, options: .regularExpression) != nil
            let hasComma = group(7) != nil
            // A bare "second" mid-sentence is just a word; a list marker is
            // set off by a comma, joined with "and"/"then", or "number two".
            guard atClauseStart, hasComma || joined || spokenNumber != nil || group(4) != nil else { continue }

            let value: Int?
            if group(6) != nil {
                value = expected >= 3 ? expected : nil
            } else if let word = group(2) ?? group(3) ?? group(4) ?? spokenNumber {
                value = ordinals[word] ?? Int(word)
            } else {
                value = nil
            }
            guard let value, let range = Range(match.range, in: text) else { continue }
            if value == expected {
                items.append(range)
                expected += 1
            } else if !items.isEmpty {
                break
            }
        }
        guard items.count >= 2 else { return nil }

        var intro = text[..<items[0].lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        // "Ok" or "So" before the list isn't an intro.
        if intro.range(of: #"(?i)^(?:(?:ok|okay|so|well|alright|right|now)[,.]?\s*)+$"#, options: .regularExpression) != nil { intro = "" }
        if let last = intro.last, !".!?:".contains(last) {
            intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: ",;")) + ":"
        }
        var lines: [String] = []
        var rest = ""
        for (index, range) in items.enumerated() {
            let end = index + 1 < items.count ? items[index + 1].lowerBound : text.endIndex
            var item = text[range.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if index == items.count - 1, let split = item.range(of: #"[.!?]\s+(?=\S)"#, options: .regularExpression) {
                // Whatever follows the last item's sentence isn't part of it.
                rest = String(item[split.upperBound...])
                item = String(item[..<split.upperBound]).trimmingCharacters(in: .whitespaces)
            }
            item = item.replacingPattern(#"[\s,;]+(?:and|then|and then)?[\s,;]*$"#, with: "")
            if item.filter({ ".!?".contains($0) }).count == 1, item.hasSuffix(".") { item.removeLast() }
            guard !item.isEmpty else { return nil }
            lines.append("\(index + 1). \(item)")
        }
        var output = lines.joined(separator: "\n")
        if !intro.isEmpty { output = intro + "\n" + output }
        if !rest.isEmpty { output += "\n\n" + rest }
        return output
    }

    // MARK: - Email

    /// Splits off a greeting ("Hi Sam,") and a sign-off ("Thanks,\nPriya") so
    /// each gets its own paragraph.
    static func splitEmail(_ text: String) -> (greeting: String?, body: String, signOff: String?) {
        var body = text
        var greeting: String?
        var signOff: String?
        let greetingPattern = Regex.make(#"^((?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b[^.!?,\n]{0,40}?)[,.!:]\s+"#)
        if let match = greetingPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let whole = Range(match.range, in: body), let name = Range(match.range(at: 1), in: body),
           whole.upperBound < body.endIndex {
            greeting = body[name] + ","
            body = String(body[whole.upperBound...])
        }
        let signOffPattern = Regex.make(
            #"(?:(?<=[.!?])\s+|\n+)((?i:thanks(?: again| so much| a lot)?|thank you(?: so much)?|cheers|best(?: regards| wishes)?|kind regards|warm regards|regards|sincerely|talk soon|speak soon))[,.!]?(?:\s+(\p{Lu}[\p{L}'-]*(?:\s+\p{Lu}[\p{L}'-]*)?))?[.!]?\s*$"#,
            caseInsensitive: false
        )
        if let match = signOffPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let whole = Range(match.range, in: body), let phrase = Range(match.range(at: 1), in: body),
           whole.lowerBound > body.startIndex {
            let words = matchCase(of: "A", String(body[phrase]))
            let name = Range(match.range(at: 2), in: body).map { "\n" + body[$0] } ?? ""
            signOff = words + "," + name
            body = String(body[..<whole.lowerBound])
        }
        return (greeting, body, signOff)
    }

    // MARK: - Sentence case

    static func sentenceCase(_ text: String, _ style: FormatStyle) -> String {
        switch style {
        case .formal, .semiFormal:
            let capitalized = text
                .replacingPattern(#"(^|\n|[.!?]\s+)(\d+\.\s+)?(\p{Ll})(?![^\s]*(?:@|\.\p{L}))"#, caseInsensitive: false) { groups in
                    (groups[1] ?? "") + (groups[2] ?? "") + groups[3]!.uppercased()
                }
                .replacingPattern(#"(?<![\p{L}'])i(?=(?:'[\p{L}]+)?(?![\p{L}]))"#, with: "I", caseInsensitive: false)
            // Every paragraph that isn't a list ends in punctuation.
            return capitalized.components(separatedBy: "\n\n").map { paragraph in
                guard let lastLine = paragraph.split(separator: "\n").last,
                      lastLine.range(of: #"^\d+\.\s"#, options: .regularExpression) == nil,
                      let last = paragraph.last, last.isLetter || last.isNumber || last == ")" || last == "\"" else { return paragraph }
                return paragraph + "."
            }.joined(separator: "\n\n")
        case .semiCasual, .casual:
            var relaxed = text.replacingPattern(#"(^|\n|[.!?]\s+)(\d+\.\s+)?(\p{Lu}[\p{Ll}']*)(?![\p{L}])"#, caseInsensitive: false) { groups in
                let word = groups[3]!
                guard commonStarters.contains(word.lowercased()) else { return nil }
                return (groups[1] ?? "") + (groups[2] ?? "") + word.lowercased()
            }
            if relaxed.hasSuffix("."), !relaxed.hasSuffix("..") { relaxed.removeLast() }
            return relaxed
        }
    }

    /// Words safe to lowercase at the start of a sentence (never a name).
    private static let commonStarters: Set<String> = [
        "the", "a", "an", "and", "but", "so", "or", "if", "when", "then", "there", "there's", "theres", "it", "it's", "its",
        "this", "that", "that's", "thats", "these", "those", "we", "we're", "were", "we'll", "well", "we've", "you", "you're",
        "youre", "your", "he", "she", "they", "they're", "theyre", "my", "our", "just", "also", "anyway", "hey", "hi", "hello",
        "ok", "okay", "yeah", "yes", "yep", "no", "nope", "not", "maybe", "can", "could", "should", "would", "will", "what",
        "what's", "whats", "why", "how", "where", "who", "let's", "lets", "do", "does", "did", "don't", "dont", "is", "are",
        "was", "be", "have", "has", "had", "going", "gonna", "got", "sounds", "see", "thanks", "thank", "sorry", "please",
        "hope", "actually", "honestly", "basically", "still", "now", "today", "tomorrow", "tonight", "let", "need", "want",
        "wanna", "gotta", "hmm", "oh", "ah", "wow", "lol", "cool", "nice", "great", "sure", "all", "some", "one", "here",
        "here's", "heres", "after", "before", "because", "since", "until", "about", "for", "to", "in", "on", "at", "with",
        "first", "second", "next", "last", "finally", "every", "each", "any", "nothing", "something", "everything", "kinda",
        "really", "very", "even", "only", "never", "always", "probably", "definitely", "totally", "good", "bad", "same",
    ]

    // MARK: - Tidying

    static func tidy(_ text: String) -> String {
        text.replacingPattern(#"[ \t]+"#, with: " ")
            .replacingPattern(#" +([,.!?;:])"#, with: "$1")
            .replacingPattern(#",(?:\s*,)+"#, with: ",")
            .replacingPattern(#",\s*([.!?])"#, with: "$1")
            .replacingPattern(#"([.!?])\s*,"#, with: "$1")
            .replacingPattern(#"(^|\n)[ \t]*[,;:.!?]+[ \t]*"#, with: "$1")
            .replacingPattern(#"[ \t]*\n[ \t]*"#, with: "\n")
            .replacingPattern(#"\n{3,}"#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Regex helpers

private nonisolated enum Regex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    /// Compiled once per pattern; compiling is most of the cost of a clean.
    static func make(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        lock.lock()
        defer { lock.unlock() }
        if let regex = cache[key] { return regex }
        // Patterns are literals in this file; a bad one is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        cache[key] = regex
        return regex
    }
}

private extension String {
    nonisolated func replacingPattern(_ pattern: String, with template: String, caseInsensitive: Bool = true) -> String {
        Regex.make(pattern, caseInsensitive: caseInsensitive)
            .stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    /// Replaces each match with `transform(groups)`; `nil` keeps the match as it was.
    /// Unmatched groups are `nil`.
    nonisolated func replacingPattern(_ pattern: String, caseInsensitive: Bool = true, _ transform: ([String?]) -> String?) -> String {
        let regex = Regex.make(pattern, caseInsensitive: caseInsensitive)
        let ns = self as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { i -> String? in
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(groups) ?? groups[0]!
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }
}
