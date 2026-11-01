import Foundation

extension ManuscriptAudit {
    /// Every body sentence carrying an in-text citation becomes a claim whose
    /// sources are the reference entries those citations matched (with their
    /// IDIs when imported). Citations that matched nothing stay as unresolved
    /// sources so they surface in the claims report.
    public func claims(from text: String, file: String, firstID: Int = 1) -> [Claim] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let refRange: Range<Int>? = referenceHeadingLine.map { h in
            let end = entries.map(\.entry.line).max() ?? h
            return h ..< end + 1
        }
        var claims: [Claim] = []
        for (i, paragraph) in lines.enumerated() {
            let number = i + 1
            if let r = refRange, r.contains(number) { continue }
            guard !ManuscriptParser.citations(in: paragraph, line: number).isEmpty else { continue }

            for sentence in Self.sentences(paragraph) {
                let cites = ManuscriptParser.citations(in: sentence, line: number)
                guard !cites.isEmpty else { continue }
                var sources: [ClaimSource] = []
                for c in cites {
                    if let e = entries.first(where: { $0.citedBy.contains { $0.line == number && $0.raw == c.raw && $0.year == c.year } }) {
                        guard !sources.contains(where: { $0.title == e.entry.title && $0.reference == e.importedAs }) else { continue }
                        let link = e.entry.doi.map { "https://doi.org/\($0)" } ?? e.entry.url
                        sources.append(ClaimSource(url: link, title: e.entry.title, reference: e.importedAs))
                    } else {
                        sources.append(ClaimSource(title: "\(c.raw) — no matching reference entry"))
                    }
                }
                claims.append(Claim(id: "C\(firstID + claims.count)", text: sentence,
                                    origin: ClaimOrigin(file: file, line: number, speaker: nil), sources: sources))
            }
        }
        return claims
    }

    /// Words whose trailing period doesn't end a sentence.
    private static let abbreviations: Set<String> = ["al", "e.g", "eg", "i.e", "ie", "vs", "cf", "dr", "mr", "mrs", "ms", "prof", "fig", "figs",
                                                     "eq", "eqs", "no", "nos", "vol", "vols", "pp", "p", "ch", "chap", "sec", "st", "approx", "ed", "eds",
                                                     "tab", "ref", "refs", "suppl", "jr", "sr", "inc", "ltd", "co", "corp", "dept", "univ"]
    /// Words after which a number's period is still mid-sentence ("Fig. 2. shows").
    private static let numbered: Set<String> = ["fig", "figs", "figure", "table", "eq", "section", "sec", "ch", "chapter", "no", "vol", "p", "pp"]

    /// Sentence split that doesn't break inside parentheses (citations), after abbreviations
    /// ("et al.", "e.g.", "cf.", "Dr.", "Fig. 2."), or after initials.
    static func sentences(_ paragraph: String) -> [String] {
        let chars = Array(paragraph)
        var out: [String] = []
        var start = 0, depth = 0, i = 0
        func word(endingAt end: Int) -> (String, Int) {
            var s = end
            while s > 0, !chars[s - 1].isWhitespace, chars[s - 1] != "(" { s -= 1 }
            return (String(chars[s..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'’[(")), s)
        }
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" { depth += 1 } else if (c == ")" || c == "]") && depth > 0 { depth -= 1 }
            if depth == 0, c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, "\"”’)".contains(chars[j]) { j += 1 }
                var k = j
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                let nextStarts = k > j && k < chars.count && (chars[k].isUppercase || "\"“(".contains(chars[k]))
                var breaks = nextStarts
                if breaks, c == "." {
                    let (w, ws) = word(endingAt: i)
                    let lw = w.lowercased()
                    if abbreviations.contains(lw) || (w.count == 1 && w.first!.isUppercase) {
                        breaks = false
                    } else if w.allSatisfy(\.isNumber), ws > 0 {
                        let (prev, _) = word(endingAt: ws - 1)
                        if numbered.contains(prev.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) { breaks = false }
                    }
                }
                if breaks {
                    out.append(String(chars[start..<j]).trimmingCharacters(in: .whitespaces))
                    start = k
                    i = k
                    continue
                }
            }
            i += 1
        }
        out.append(String(chars[start...]).trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }
}
