import Foundation

/// Pulls candidate claims out of a chat transcript.
///
/// Expected shape (as exported from a browser chat):
///
///     **Me**: question…
///     **Assistant**: answer with markers [1, 2]
///     [1] [https://arxiv.org](https://arxiv.org/html/2504.06969v1)
///
/// Everything here is mechanical. A line (or list item with its indented
/// sub-items) becomes a candidate claim when it
///   • carries footnote markers or inline links,
///   • names a work by title, or
///   • uses "research shows"-style language without any citation.
/// Footnote numbers are resolved within their own turn, since chat assistants
/// restart numbering each turn. A person reviews the result; nothing here
/// decides whether a claim is true.
public struct TranscriptImporter: Sendable {
    public var file: String
    /// Speakers whose turns are scanned. `nil` = everyone except whoever speaks first.
    public var speakers: Set<String>?

    public init(file: String, speakers: Set<String>? = nil) {
        self.file = file
        self.speakers = speakers
    }

    struct Turn {
        var speaker: String
        var lines: [(number: Int, text: String)]
    }

    struct Unit {
        var line: Int
        var parts: [String]
        var text: String { parts.joined(separator: " ") }
    }

    public func claims(from transcript: String, firstID: Int = 1) -> [Claim] {
        let turns = Self.turns(in: transcript)
        let scanned = speakers ?? Set(turns.map(\.speaker)).subtracting([turns.first?.speaker].compactMap { $0 })
        var claims: [Claim] = []
        for turn in turns where scanned.contains(turn.speaker) {
            let (footnotes, body) = Self.footnotes(in: turn.lines)
            for unit in Self.units(in: body) {
                guard let claim = makeClaim(unit, footnotes: footnotes, speaker: turn.speaker, id: "C\(firstID + claims.count)") else { continue }
                claims.append(claim)
            }
        }
        return claims
    }

    // MARK: Structure

    static func turns(in text: String) -> [Turn] {
        let speakerRE = try! NSRegularExpression(pattern: #"^\*\*([^*]+?)\*\*\s*:\s?(.*)$"#)
        var turns: [Turn] = []
        for (i, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let ns = NSRange(raw.startIndex..., in: raw)
            if let m = speakerRE.firstMatch(in: raw, range: ns),
               let s = Range(m.range(at: 1), in: raw), let rest = Range(m.range(at: 2), in: raw) {
                turns.append(Turn(speaker: String(raw[s]).trimmingCharacters(in: .whitespaces), lines: [(i + 1, String(raw[rest]))]))
            } else if !turns.isEmpty {
                turns[turns.count - 1].lines.append((i + 1, raw))
            }
        }
        return turns
    }

    private static let footnoteRE = try! NSRegularExpression(
        pattern: #"^\s*\[(\d+)\]\s*(?:\[[^\]]*\]\((https?://[^)\s]+)\)|(https?://\S+))\s*$"#)

    static func footnotes(in lines: [(number: Int, text: String)]) -> ([Int: String], [(number: Int, text: String)]) {
        var map: [Int: String] = [:]
        var body: [(Int, String)] = []
        for line in lines {
            let ns = NSRange(line.text.startIndex..., in: line.text)
            if let m = footnoteRE.firstMatch(in: line.text, range: ns),
               let n = Range(m.range(at: 1), in: line.text).flatMap({ Int(line.text[$0]) }),
               let u = Range(m.range(at: 2), in: line.text) ?? Range(m.range(at: 3), in: line.text) {
                map[n] = String(line.text[u])
            } else {
                body.append(line)
            }
        }
        return (map, body)
    }

    static func units(in lines: [(number: Int, text: String)]) -> [Unit] {
        var units: [Unit] = []
        var inFence = false
        var current: Unit?
        var mergeNext = false // previous unit ended with ":" — a quotation that follows belongs to it

        func flush() {
            if let c = current { units.append(c) }
            current = nil
        }

        for (number, raw) in lines {
            let text = raw.replacingOccurrences(of: "\u{2800}", with: "") // braille blank used as a spacer
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); flush(); continue }
            if inFence { continue }
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil {
                flush()
                mergeNext = false
                continue
            }
            let indented = text.first == " " || text.first == "\t"
            if current != nil && (indented || (mergeNext && startsWithQuotation(trimmed))) {
                current!.parts.append(trimmed)
            } else {
                flush()
                current = Unit(line: number, parts: [trimmed])
            }
            mergeNext = trimmed.hasSuffix(":")
        }
        flush()
        return units
    }

    /// `> *"…`, `2. *"…`, `“…` — a quotation once list/markdown prefixes are removed.
    static func startsWithQuotation(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: #"^(\d+\.|[*>•-])?\s*[*_]*"#, with: "", options: .regularExpression)
        return stripped.first.map { "\"\u{201C}".contains($0) } ?? false
    }

    // MARK: Claim detection

    private static let markerRE = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\](?!\()"#)
    private static let linkRE = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
    private static let italicRE = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?![*\s])([^*\n]+?)(?<!\s)\*(?!\*)(\s*\(([^()*]*?)\))?"#)
    private static let quotationRE = try! NSRegularExpression(pattern: #"["\u201C][^"\u201D]{40,}["\u201D]"#)
    private static let attributionRE = try! NSRegularExpression(
        pattern: #"\b(notes?|states?|writes?|wrote|argues?|according to|quotes?|quoted|says|said)\b"#, options: [.caseInsensitive])
    private static let evidenceRE = try! NSRegularExpression(
        pattern: #"\b(research|studies|study|empirical|evidence|researchers|literature)\b[^.]{0,80}?\b(shows?|showed|shown|demonstrat\w*|proves?|proved|proven|finds?|found|validates?|confirms?)\b"#,
        options: [.caseInsensitive])

    func makeClaim(_ unit: Unit, footnotes: [Int: String], speaker: String, id: String) -> Claim? {
        let text = unit.text
        var sources: [ClaimSource] = []
        var seenKeys = Set<String>()

        func addSource(_ s: ClaimSource) {
            let key = s.url.map(CanonicalURL.key) ?? "marker:\(s.marker ?? -1)"
            if seenKeys.insert(key).inserted { sources.append(s) }
        }

        for m in Self.matches(Self.markerRE, text) {
            for n in m[1].split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                addSource(ClaimSource(marker: n, url: footnotes[n]))
            }
        }
        for m in Self.matches(Self.linkRE, text) {
            let label = Self.strippingYear(TextCleanup.clean(m[1]))
            addSource(ClaimSource(url: m[2], title: Self.looksLikeTitle(label) ? label : nil))
        }

        var titles: [String] = []
        for m in Self.matches(Self.italicRE, text) {
            let phrase = m[1].trimmingCharacters(in: CharacterSet(charactersIn: "~ "))
            let hasYear = m.count > 3 && m[3].range(of: #"(19|20)\d{2}"#, options: .regularExpression) != nil
            if (hasYear && phrase.split(separator: " ").count >= 3 && !phrase.contains(" et al")) || Self.looksLikeTitle(phrase) {
                titles.append(Self.strippingYear(TextCleanup.clean(phrase)))
            }
        }
        let linkedTitles = Set(sources.compactMap(\.title).map(TextCleanup.comparable))
        for t in titles where !linkedTitles.contains(TextCleanup.comparable(t)) {
            sources.append(ClaimSource(title: t))
        }

        var flags: [ClaimFlag] = []
        let hasLink = sources.contains { $0.url != nil }
        if !titles.isEmpty && !hasLink { flags.append(.unlinkedTitle) }
        if Self.has(Self.quotationRE, text) && Self.has(Self.attributionRE, text) { flags.append(.containsQuotation) }
        if sources.isEmpty && Self.has(Self.evidenceRE, text) { flags.append(.uncitedEvidence) }

        guard !sources.isEmpty || !flags.isEmpty else { return nil }
        return Claim(id: id, text: Self.plain(text), origin: ClaimOrigin(file: file, line: unit.line, speaker: speaker),
                     sources: sources, flags: flags)
    }

    /// Title Case heuristic: ≥ 4 words, most significant words capitalized,
    /// not a quotation or a label.
    static func looksLikeTitle(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, !"\"\u{201C}'".contains(first), !t.hasSuffix(":"), !t.hasPrefix("http") else { return false }
        let words = t.split(separator: " ")
        guard words.count >= 4 else { return false }
        let small: Set<String> = ["a", "an", "the", "of", "for", "to", "in", "on", "and", "or", "with", "as", "at", "by", "from", "is", "vs", "via"]
        let significant = words.filter { !small.contains($0.lowercased()) }
        guard !significant.isEmpty else { return false }
        let capitalized = significant.filter { $0.first?.isUppercase == true || $0.first?.isNumber == true }
        return Double(capitalized.count) / Double(significant.count) >= 0.75
    }

    /// "Title (Haller et al., 2025)" → "Title"
    static func strippingYear(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\([^()]*(19|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
    }

    /// Claim text without markdown, footnote markers or list bullets.
    static func plain(_ s: String) -> String {
        var t = s
        t = markerRE.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        t = linkRE.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        for token in ["==", "**", "~"] { t = t.replacingOccurrences(of: token, with: "") }
        t = t.replacingOccurrences(of: #"(?<!\w)\*|\*(?!\w)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|\s)(\d+\.|[*•>-])\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([.,;:])"#, with: "$1", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [[String]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
    }
}
