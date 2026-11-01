import Foundation

/// A tag found in a manuscript.
///
/// Accepted forms (case-insensitive, `#` and `-` optional):
///
///     [IDI 12]              → (Smith, 2020)
///     [IDI #12]             → (Smith, 2020)
///     [IDI 12, 7]           → (Jones et al., 2019; Smith, 2020)
///     [IDI 12; IDI 7]       → same as above
///     [IDI 12, p. 4]        → (Smith, 2020, p. 4)
///     [IDI 12, pp. 4-6]     → (Smith, 2020, pp. 4–6)
///     [IDI 12-Q1]           → (Smith, 2020, p. 4) — page taken from verified quote Q1
///     [IDI 12, narrative]   → Smith et al. (2020)
///     [IDI 12, narrative, p. 4] → Smith et al. (2020, p. 4)
///     [IDI 12, possessive]  → Smith et al.’s (2020)
///     [IDI # - ALLREF]      → alphabetized reference list of everything cited
public enum RefTag: Equatable, Sendable {
    case cite([IDI], locator: String?)
    case narrative(IDI, locator: String?)
    /// Narrative, possessive: `Smith’s (2020)`.
    case possessive(IDI, locator: String?)
    /// A verified quote: `IDI 12-Q1`.
    case quote(IDI, label: String)
    case allReferences

    public var ids: [IDI] {
        switch self {
        case .cite(let ids, _): ids
        case .narrative(let id, _), .possessive(let id, _), .quote(let id, _): [id]
        case .allReferences: []
        }
    }

    /// `IDI 12-Q1` for quote tags.
    public var quoteTag: String? {
        if case .quote(let id, let label) = self { return "IDI \(id)-\(label)" }
        return nil
    }
}

public struct TagOccurrence: Equatable, Sendable {
    public var tag: RefTag
    /// Range of the full `[…]` text in the source.
    public var range: Range<String.Index>
    /// 1-based line number in the source, for error reporting.
    public var line: Int
    public var source: String
}

public struct MalformedTag: Equatable, Sendable {
    public var source: String
    public var line: Int
}

public enum TagParser {
    // Anything that opens with "[IDI" is treated as a tag; if its contents
    // don't parse, it is reported rather than silently left in the text.
    private static let tagPattern = try! NSRegularExpression(pattern: #"\[\s*IDI\b[^\[\]\n]*\]"#, options: [.caseInsensitive])
    private static let allRefPattern = try! NSRegularExpression(pattern: #"^\s*#?\s*-?\s*ALLREF\s*$"#, options: [.caseInsensitive])
    private static let quotePattern = try! NSRegularExpression(pattern: #"^\s*#?\s*-?\s*(\d+)\s*-\s*Q(\d+)\s*$"#, options: [.caseInsensitive])
    private static let idPattern = try! NSRegularExpression(pattern: #"^\s*(?:IDI)?\s*#?\s*-?\s*(\d+)\s*$"#, options: [.caseInsensitive])
    private static let locatorPattern = try! NSRegularExpression(pattern: #"^\s*(pp?\.|para\.|ch\.|sec\.|fig\.|table)\s*(\S.*?)\s*$"#, options: [.caseInsensitive])

    private static let commentPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(-->|$)"#)

    public static func scan(_ text: String) -> (tags: [TagOccurrence], malformed: [MalformedTag]) {
        var tags: [TagOccurrence] = []
        var malformed: [MalformedTag] = []
        let ns = NSRange(text.startIndex..., in: text)
        var lineCounter = LineCounter(text)
        // Tags inside HTML comments (<!-- … -->) are notes to self, not citations.
        let comments = commentPattern.matches(in: text, range: ns).compactMap { Range($0.range, in: text) }

        for match in tagPattern.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text) else { continue }
            if comments.contains(where: { $0.contains(range.lowerBound) }) { continue }
            let source = String(text[range])
            let line = lineCounter.line(at: range.lowerBound)
            if let tag = parse(source) {
                tags.append(TagOccurrence(tag: tag, range: range, line: line, source: source))
            } else {
                malformed.append(MalformedTag(source: source, line: line))
            }
        }
        return (tags, malformed)
    }

    /// Parses one `[IDI …]` tag. Returns `nil` if malformed.
    public static func parse(_ source: String) -> RefTag? {
        var inner = source.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("["), inner.hasSuffix("]") else { return nil }
        inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard inner.uppercased().hasPrefix("IDI") else { return nil }
        let body = String(inner.dropFirst(3))

        if matches(allRefPattern, body) { return .allReferences }
        if let q = capture(quotePattern, body), let id = IDI(q[0]), let n = Int(q[1]) { return .quote(id, label: "Q\(n)") }

        var ids: [IDI] = []
        var locator: String?
        var narrative = false, possessive = false
        for piece in body.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let p = String(piece)
            let word = p.trimmingCharacters(in: .whitespaces).lowercased()
            if word == "narrative" || word == "possessive" {
                guard !narrative, locator == nil else { return nil }
                narrative = true
                possessive = word == "possessive"
            } else if let id = capture(idPattern, p).flatMap({ IDI($0[0]) }) {
                guard !narrative else { return nil } // "narrative" comes after the ID
                guard locator == nil else { return nil } // locator must come last
                ids.append(id)
            } else if let loc = capture(locatorPattern, p) {
                guard locator == nil else { return nil }
                locator = normalizeLocator(label: loc[0], value: loc[1])
            } else {
                return nil
            }
        }
        guard !ids.isEmpty else { return nil }
        // A page locator — or narrative form — is only meaningful for a single work.
        if (locator != nil || narrative) && ids.count > 1 { return nil }
        if possessive { return .possessive(ids[0], locator: locator) }
        return narrative ? .narrative(ids[0], locator: locator) : .cite(ids, locator: locator)
    }

    private static func normalizeLocator(label: String, value: String) -> String {
        let l = label.lowercased()
        let v = value.replacingOccurrences(of: #"\s*-+\s*"#, with: "–", options: .regularExpression)
        return l == "table" ? "Table \(v)" : "\(l) \(v)"
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func capture(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
}

/// Incremental line lookup for ascending positions.
struct LineCounter {
    private let text: String
    private var position: String.Index
    private var line = 1

    init(_ text: String) {
        self.text = text
        self.position = text.startIndex
    }

    mutating func line(at index: String.Index) -> Int {
        while position < index {
            if text[position] == "\n" { line += 1 }
            position = text.index(after: position)
        }
        return line
    }
}
