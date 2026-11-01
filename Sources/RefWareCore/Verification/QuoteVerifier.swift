import Foundation

/// Text of a document as pages of lines (1-based page/line numbers are
/// positions in these arrays + 1).
public typealias PageLines = [[String]]

public struct QuoteMatch: Equatable, Sendable {
    public var page: Int
    public var line: Int
    public var endPage: Int
    public var endLine: Int
    /// How many times the quote occurs; > 1 means the location is ambiguous.
    public var occurrences: Int
    /// The matched passage as the PDF has it (line breaks joined, hyphenation repaired).
    public var matchedText: String = ""
}

public enum QuoteResult: Equatable, Sendable {
    case found(QuoteMatch)
    /// Not found. If the opening words do occur, reports how many matched and
    /// where, so a slightly altered quote can be corrected against the source.
    case notFound(matchedWords: Int, totalWords: Int, nearest: (page: Int, line: Int)?)
    case tooShort

    public static func == (a: QuoteResult, b: QuoteResult) -> Bool {
        switch (a, b) {
        case (.found(let x), .found(let y)):
            x.page == y.page && x.line == y.line && x.endPage == y.endPage && x.endLine == y.endLine && x.occurrences == y.occurrences
        case (.tooShort, .tooShort): true
        case (.notFound(let w1, let t1, let n1), .notFound(let w2, let t2, let n2)):
            w1 == w2 && t1 == t2 && n1?.page == n2?.page && n1?.line == n2?.line
        default: false
        }
    }
}

/// Checks that a quote appears word-for-word in a source text.
///
/// Forgiven (PDF extraction artifacts): case, whitespace and line breaks,
/// hyphenation at line ends, ligatures, curly vs straight quotes, punctuation
/// between words. **Not** forgiven (they change meaning): decimal points and
/// thousands separators between digits ("4.3" ≠ "43", "1,000" ≠ "1000"),
/// signs and ranges before digits ("−19%" ≠ "19%", "45–67"), and the symbols
/// % < > = ≤ ≥ ± — "p < .05" ≠ "p > .05".
public enum QuoteVerifier {
    /// Version of the normalization rules, recorded with each verification.
    public static let normalizationVersion = 2
    /// Quotes shorter than this many significant characters are rejected as too easy to match by chance.
    public static let minimumLength = 20

    private static let significant: Set<Character> = ["%", "<", ">", "=", "≤", "≥", "±", "×", "≠"]
    private static let dashes: Set<Character> = ["-", "−", "–", "—", "‐", "‑"]

    struct Stream {
        var chars: [Character] = []
        /// For each kept character: page, line (1-based) and offset within that line's text.
        var positions: [(page: Int, line: Int, offset: Int)] = []
    }

    public static func locate(_ quote: String, in pages: PageLines) -> QuoteResult {
        let needle = normalize(quote)
        guard needle.count >= minimumLength else { return .tooShort }
        let stream = streamOf(pages)
        let haystack = stream.chars

        let hits = occurrences(of: needle, in: haystack)
        if let first = hits.first {
            let start = stream.positions[first], end = stream.positions[first + needle.count - 1]
            return .found(QuoteMatch(page: start.page, line: start.line, endPage: end.page, endLine: end.line,
                                     occurrences: hits.count, matchedText: text(in: pages, from: start, to: end)))
        }

        // Longest run of opening words that does occur, to point at the divergence.
        let words = quote.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        var lo = 0, hi = words.count, best: Int?
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let prefix = Array(words.prefix(mid).joined())
            if let at = occurrences(of: prefix, in: haystack, limit: 1).first {
                lo = mid
                best = at
            } else {
                hi = mid - 1
            }
        }
        let nearest = (lo >= 3 ? best : nil).map { stream.positions[$0] }
        return .notFound(matchedWords: lo, totalWords: words.count, nearest: nearest.map { ($0.page, $0.line) })
    }

    /// Normalized form of a single string (a quote, or one word of it).
    static func normalize(_ s: String) -> [Character] {
        var out = Stream()
        let chars = Array(fold(s))
        for i in chars.indices { keep(chars, i, page: 0, line: 0, offset: i, into: &out) }
        return out.chars
    }

    private static func fold(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping // ﬁ → fi, full-width → ASCII
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Decides whether `chars[i]` is significant, looking at its neighbours (ignoring spaces for "next").
    private static func keep(_ chars: [Character], _ i: Int, page: Int, line: Int, offset: Int, into out: inout Stream) {
        let c = chars[i]
        func next() -> Character? { var j = i + 1; while j < chars.count, chars[j] == " " { j += 1 }; return j < chars.count ? chars[j] : nil }
        func nextRaw() -> Character? { i + 1 < chars.count ? chars[i + 1] : nil }
        func prevRaw() -> Character? { i > 0 ? chars[i - 1] : nil }
        var kept: Character?
        if c.isLetter || c.isNumber {
            kept = c
        } else if significant.contains(c) {
            kept = c
        } else if c == "." || c == "," {
            // Decimal point / thousands separator: only directly between digits (".05" keeps its point too).
            let nextIsDigit = nextRaw()?.isNumber == true
            if c == "." && nextIsDigit && prevRaw()?.isNumber != false { kept = "." }
            else if c == "," && nextIsDigit && prevRaw()?.isNumber == true { kept = "," }
        } else if dashes.contains(c) {
            // A sign or numeric range ("−19%", "45–67", "COVID-19"); word hyphens are dropped.
            if next()?.isNumber == true { kept = "-" }
        }
        if let k = kept {
            out.chars.append(k)
            out.positions.append((page, line, offset))
        }
    }

    /// The whole document as one normalized stream. Lines are joined with a space, so a
    /// hyphen ending one line looks ahead to the first character of the next.
    static func streamOf(_ pages: PageLines) -> Stream {
        var flat: [Character] = []
        var where_: [(page: Int, line: Int, offset: Int)] = []
        for (p, lines) in pages.enumerated() {
            for (l, line) in lines.enumerated() {
                // Fold character by character so positions stay those of the original text
                // (a ligature like "ﬁ" folds to two letters that both point at it).
                for (o, ch) in Array(line).enumerated() {
                    for f in fold(String(ch)) {
                        flat.append(f)
                        where_.append((p + 1, l + 1, o))
                    }
                }
                flat.append(" ")
                where_.append((p + 1, l + 1, -1))
            }
        }
        var out = Stream()
        for i in flat.indices where where_[i].offset >= 0 || flat[i] != " " {
            keep(flat, i, page: where_[i].page, line: where_[i].line, offset: where_[i].offset, into: &out)
        }
        return out
    }

    /// The source's own text between two stream positions, lines joined, line-end hyphenation repaired.
    static func text(in pages: PageLines, from start: (page: Int, line: Int, offset: Int), to end: (page: Int, line: Int, offset: Int)) -> String {
        var pieces: [String] = []
        var p = start.page, l = start.line
        while true {
            guard p - 1 < pages.count, l - 1 < pages[p - 1].count else { break }
            let chars = Array(pages[p - 1][l - 1])
            let from = (p == start.page && l == start.line) ? min(max(start.offset, 0), chars.count) : 0
            let to = (p == end.page && l == end.line) ? min(end.offset + 1, chars.count) : chars.count
            if from < to { pieces.append(String(chars[from..<to])) }
            if p == end.page && l == end.line { break }
            l += 1
            if l > pages[p - 1].count { p += 1; l = 1 }
            if p > pages.count { break }
        }
        var joined = ""
        for piece in pieces {
            if joined.hasSuffix("-"), piece.first?.isLowercase == true { joined.removeLast() } else if !joined.isEmpty { joined += " " }
            joined += piece
        }
        return joined.trimmingCharacters(in: .whitespaces)
    }

    private static func occurrences(of needle: [Character], in haystack: [Character], limit: Int = .max) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var hits: [Int] = []
        let first = needle[0]
        var i = 0
        while i <= haystack.count - needle.count {
            if haystack[i] == first && haystack[i..<(i + needle.count)].elementsEqual(needle) {
                hits.append(i)
                if hits.count >= limit { break }
            }
            i += 1
        }
        return hits
    }
}
