import Foundation

/// Reads the cover sheet JSTOR prepends to its PDFs. For older articles that
/// never received a DOI, it is the most authoritative metadata available.
///
/// Two layouts are handled:
///   older:  Title / Author / "Journal, Vol. 75, No. 2, … (May, 1985), pp. 332-337." / Stable URL: …
///   newer:  Title / "Author(s): … Source: Journal, Vol. 99, No. 394 (Mar., 1989), pp. 116-131 Published by: … Stable URL: …"
public enum JSTORCover {
    public static func parse(_ page1: [String]) -> ResolvedMetadata? {
        let joined = page1.joined(separator: " ")
        guard joined.range(of: "jstor", options: .caseInsensitive) != nil, joined.contains("Stable URL") else { return nil }
        let stable = joined.range(of: #"https?://(www\.)?jstor\.org/stable/\d+"#, options: .regularExpression).map { String(joined[$0]) }

        var title: String?, authorText: String?, source: String?
        if let m = joined.range(of: #"Author\(s\):\s*(.+?)\s*Source:\s*(.+?)\s*(Published by|Stable URL)"#, options: .regularExpression) {
            let block = String(joined[m])
            title = String(joined[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
            authorText = block.components(separatedBy: "Author(s):").last?.components(separatedBy: "Source:").first
            source = block.components(separatedBy: "Source:").last?.replacingOccurrences(of: #"\s*(Published by|Stable URL).*$"#, with: "", options: .regularExpression)
        } else {
            // Older layout: lines before "Stable URL", minus logo noise.
            guard let stop = page1.firstIndex(where: { $0.hasPrefix("Stable URL") }) else { return nil }
            let lines = page1[..<stop].filter { l in l.count > 4 && !l.contains("•") && l.range(of: #"^J?STOR"#, options: .regularExpression) == nil }
            guard let s = lines.firstIndex(where: { $0.contains("Vol.") || $0.range(of: #"\(\w*\.?,?\s*(1[6-9]|20)\d{2}\)"#, options: .regularExpression) != nil }),
                  s >= 2 else { return nil }
            let end = lines[s...].firstIndex { $0.contains("pp.") } ?? s
            source = lines[s...end].joined(separator: " ")
            authorText = lines[s - 1]
            title = lines[..<(s - 1)].joined(separator: " ")
        }
        guard let t = title?.trimmingCharacters(in: .whitespaces), t.split(separator: " ").count >= 2, let src = source else { return nil }

        let authors = (authorText ?? "")
            .replacingOccurrences(of: #"\s+and\s+"#, with: ", ", options: .regularExpression)
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
            .map(WebMetadataReader.parseName)
        func grab(_ pattern: String) -> String? {
            guard let r = src.range(of: pattern, options: .regularExpression) else { return nil }
            return String(src[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        }
        let journal = src.components(separatedBy: ", Vol.").first?.trimmingCharacters(in: .whitespaces)
        var year: Int?
        if let r = src.range(of: #"\((?:[A-Za-z]+\.?,?\s*)?((1[6-9]|20)\d{2})\)"#, options: .regularExpression) {
            let paren = String(src[r])
            year = paren.range(of: #"(1[6-9]|20)\d{2}"#, options: .regularExpression).flatMap { Int(paren[$0]) }
        }

        var m = ResolvedMetadata(
            authors: authors, year: year, title: TextCleanup.clean(t), publication: journal,
            indexing: PublicationIndexing(volume: grab(#"Vol\.\s*\d+"#), issue: grab(#"No\.\s*\d+"#), pages: grab(#"pp\.\s*\d+\s*[-–]\s*\d+"#)),
            url: stable, source: .pdfCover, lookupKey: stable ?? t)
        m.yearsSeen = year.map { [$0] } ?? []
        return m
    }
}
