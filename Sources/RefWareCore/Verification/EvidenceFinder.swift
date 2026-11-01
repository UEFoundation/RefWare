import Foundation

/// A sentence (or two) from a source PDF that may support a claim.
public struct Passage: Identifiable, Hashable, Sendable {
    public var page: Int
    public var line: Int
    /// The passage as it reads in the PDF (line-break hyphenation rejoined).
    public var text: String
    public var score: Double
    /// Numbers from the claim found in this passage ("19", "644").
    public var numbers: [String]
    /// Claim terms found in this passage.
    public var terms: [String]

    public var id: String { "\(page)-\(line)-\(text.prefix(24))" }
}

/// Finds the passages in a source most likely to back a claim, so a person
/// reads three candidates instead of the whole paper. It ranks; it never
/// decides. Numbers in the claim weigh most ("19 percent", "$644 billion",
/// "4.3 hours"), then the claim's content words.
public enum EvidenceFinder {
    public static func passages(for claim: String, in pages: PageLines, limit: Int = 3) -> [Passage] {
        let claimBody = stripCitations(claim)
        let wantNumbers = numbers(in: claimBody)
        let wantTerms = Set(terms(in: claimBody))
        guard !wantTerms.isEmpty || !wantNumbers.isEmpty else { return [] }

        var found: [Passage] = []
        for (p, lines) in pages.enumerated() {
            let pageSentences = sentences(on: lines)
            // Candidates: sentences, plus 1–3-line windows (web pages often have no sentence breaks).
            var windows = pageSentences
            for size in 1...3 {
                for i in lines.indices where i + size <= lines.count {
                    windows.append(contentsOf: sentences(joining: Array(lines[i..<(i + size)]), firstLine: i + 1).filter { $0.text.split(separator: " ").count >= 6 })
                }
            }
            for w in windows where !looksLikeReference(w.text) {
                let words = w.text.split(separator: " ").count
                let have = Set(terms(in: w.text))
                let matchedTerms = wantTerms.intersection(have)
                let haveNumbers = Set(numbers(in: w.text))
                let matchedNumbers = wantNumbers.filter { haveNumbers.contains($0) }
                guard matchedNumbers.count >= 1 && matchedTerms.count >= 1 || matchedTerms.count >= 3 else { continue }
                let coverage = Double(matchedTerms.count) / Double(max(wantTerms.count, 1))
                let density = Double(matchedTerms.count) / sqrt(Double(max(words, 1)))
                // Show whole sentences: expand a line window to the sentence(s) it falls in — unless that
                // balloons it (a headline inside a navigation run-on).
                let expanded = expand(w, lineCount: max(1, lineSpan(w.text, in: lines, from: w.line)), sentences: pageSentences)
                let shown = expanded.flatMap { e in e.text.split(separator: " ").count <= max(60, words * 3) ? e : nil } ?? w
                let shownWords = shown.text.split(separator: " ").count
                var score = 3 * Double(matchedNumbers.count) + 4 * density + 3 * coverage
                if shownWords > 45 { score *= 45 / Double(shownWords) } // run-ons and navigation text read poorly as evidence
                found.append(Passage(page: p + 1, line: shown.line, text: shown.text, score: score, numbers: matchedNumbers, terms: matchedTerms.sorted()))
            }
        }
        // Best first; one candidate per neighbourhood (±2 lines on a page).
        var kept: [Passage] = []
        for c in found.sorted(by: { $0.score > $1.score }) where !kept.contains(where: { $0.page == c.page && abs($0.line - c.line) <= 2 }) {
            kept.append(c)
            if kept.count == limit { break }
        }
        return kept
    }

    // MARK: Text helpers

    struct Sentence { var text: String; var line: Int }

    /// The page sentences overlapping lines [w.line, w.line + lineCount), joined (at most three).
    static func expand(_ w: Sentence, lineCount: Int, sentences: [Sentence]) -> Sentence? {
        let first = w.line, last = w.line + lineCount - 1
        var picked: [Sentence] = []
        for (k, s) in sentences.enumerated() {
            let next = k + 1 < sentences.count ? sentences[k + 1].line : Int.max
            if s.line <= last && next >= first { picked.append(s) }
        }
        guard !picked.isEmpty, picked.count <= 3 else { return nil }
        let text = picked.map(\.text).joined(separator: " ")
        return text.split(separator: " ").count <= 90 ? Sentence(text: text, line: picked[0].line) : nil
    }

    /// How many source lines a window's text spans, starting at `from`.
    static func lineSpan(_ text: String, in lines: [String], from: Int) -> Int {
        var count = 0, length = 0
        for l in lines.dropFirst(from - 1) {
            length += l.trimmingCharacters(in: .whitespaces).count + 1
            count += 1
            if length >= text.count { break }
        }
        return count
    }

    static func sentences(joining lines: [String], firstLine: Int) -> [Sentence] {
        let joined = sentences(on: lines)
        guard !joined.isEmpty else { return [] }
        // As a window, keep the lines whole (even without a sentence break).
        var text = ""
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            if text.hasSuffix("-"), l.first?.isLowercase == true { text.removeLast() } else if !text.isEmpty { text += " " }
            text += l
        }
        return [Sentence(text: text, line: firstLine)]
    }

    /// Sentences on one page, each with the line it starts on.
    static func sentences(on lines: [String]) -> [Sentence] {
        var text = "", starts: [(offset: Int, line: Int)] = []
        for (i, raw) in lines.enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            starts.append((text.count, i + 1))
            if text.hasSuffix("-"), l.first?.isLowercase == true {
                text.removeLast() // rejoin "sensi-" + "tive"
            } else if !text.isEmpty {
                text += " "
            }
            text += l
        }
        func lineAt(_ offset: Int) -> Int { starts.last { $0.offset <= offset }?.line ?? 1 }

        var out: [Sentence] = []
        let re = try! NSRegularExpression(pattern: #"(?<!\bet al)(?<!\be\.g)(?<!\bi\.e)(?<!\b\p{Lu})(?<!\bFig)(?<!\bpp?)[.!?]["”’)]?\s+(?=["“(]?\p{Lu})"#)
        var start = text.startIndex
        let ns = NSRange(text.startIndex..., in: text)
        for m in re.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text) else { continue }
            let end = text.index(before: r.upperBound)
            let s = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
            if s.split(separator: " ").count >= 5 { out.append(Sentence(text: s, line: lineAt(text.distance(from: text.startIndex, to: start)))) }
            start = r.upperBound
        }
        let tail = String(text[start...]).trimmingCharacters(in: .whitespaces)
        if tail.split(separator: " ").count >= 5 { out.append(Sentence(text: tail, line: lineAt(text.distance(from: text.startIndex, to: start)))) }
        // Very long "sentences" (tables, run-on extraction) are clipped to keep candidates readable.
        return out.map { s in
            let words = s.text.split(separator: " ")
            return words.count > 70 ? Sentence(text: words.prefix(70).joined(separator: " "), line: s.line) : s
        }
    }

    static func stripCitations(_ s: String) -> String {
        s.replacingOccurrences(of: #"\([^()]*\b(19|20)\d{2}[a-z]?[^()]*\)"#, with: " ", options: .regularExpression)
    }

    /// "19 percent" → "19", "$644 billion" → "644", "4.3" → "4.3", "1,000" → "1000". Years are ignored.
    static func numbers(in raw: String) -> [String] {
        // Figure/table/section numbers and bracketed citation numbers ("[19; 20]") aren't findings.
        let s = raw.replacingOccurrences(of: #"\[\d+(?:\s*[;,–-]\s*\d+)*\]"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"(?i)\b(fig(ure)?s?|tables?|sections?|appendix|eq(uation)?s?|chapters?|pages?|pp?)\.?\s*[A-Z]?\d+(\.\d+)*(\s*(,|and|&|–|-)\s*[A-Z]?\d+(\.\d+)*)*"#,
                                         with: " ", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range, in: s).map { String(s[$0]).replacingOccurrences(of: ",", with: "") }
        }.filter { n in
            guard let v = Double(n) else { return false }
            return !(1900...2100).contains(v) || n.contains(".") // a bare year is a citation, not a finding
        }
    }

    private static let stop: Set<String> = [
        "about", "above", "across", "after", "again", "against", "also", "although", "among", "another", "because", "been", "before",
        "being", "between", "both", "could", "does", "doing", "during", "each", "either", "from", "further", "have", "having", "here",
        "into", "itself", "just", "more", "most", "much", "must", "only", "other", "over", "same", "should", "since", "some", "such",
        "than", "that", "their", "them", "then", "there", "these", "they", "this", "those", "through", "under", "until", "very", "were",
        "what", "when", "where", "which", "while", "with", "within", "without", "would", "your", "show", "shows", "shown", "study",
        "studies", "research", "paper", "found", "find", "finds", "demonstrate", "demonstrates", "estimate", "estimates", "recent",
        "approximately", "roughly", "percent", "around", "nearly",
    ]

    /// Content words, lightly stemmed so "developers" meets "developer" and "completing" meets "complete".
    static func terms(in s: String) -> [String] {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) }
            .map(stem)
    }

    static func stem(_ w: String) -> String {
        for suffix in ["ations", "ation", "ions", "ion", "ingly", "ings", "ing", "ers", "ies", "ied", "ed", "es", "er", "ly", "e", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    /// Bibliography lines match author names and titles; skip them.
    static func looksLikeReference(_ s: String) -> Bool {
        let years = s.range(of: #"\((19|20)\d{2}[a-z]?\)\."#, options: .regularExpression) != nil
        return years && (s.contains("doi") || s.contains("http") || s.range(of: #"\p{Lu}\., "#, options: .regularExpression) != nil)
    }
}
