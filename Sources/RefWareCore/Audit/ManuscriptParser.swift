import Foundation

/// A hand-written reference-list entry, parsed field by field.
public struct ParsedEntry: Equatable, Sendable {
    public var line: Int
    public var raw: String
    public var authors: [Author]
    /// The entry abbreviates its author list ("et al." or ". . .").
    public var truncatedAuthors: Bool
    public var year: Int?
    public var yearSuffix: String?
    public var title: String?
    public var publication: String?
    public var indexing: PublicationIndexing
    public var doi: String?
    public var url: String?
    /// Formatting problems in the entry as written (independent of any registry).
    public var lint: [String] = []
}

/// An in-text citation as written: `(Smith & Jones, 2020)`, `Lee et al. (2021)`.
public struct InTextCitation: Equatable, Sendable {
    public var line: Int
    /// The citation item as written (one item of a parenthetical group).
    public var raw: String
    /// Family names as written, in order (without "et al.").
    public var names: [String]
    public var etAl: Bool
    public var year: Int?
    public var yearSuffix: String?
    public var locator: String?
    public var narrative: Bool
}

public struct ParsedManuscript: Sendable {
    public var entries: [ParsedEntry]
    public var citations: [InTextCitation]
    /// Line of the reference-list heading, if one was found.
    public var referenceHeadingLine: Int?
}

public enum ManuscriptParser {
    static let headingRE = try! NSRegularExpression(
        pattern: #"^\s*(?:#+\s*)?(?:\d+\.?\s*)?(references|reference list|bibliography|works cited|literature cited)\s*:?\s*$"#,
        options: [.caseInsensitive])
    static let endOfReferencesRE = try! NSRegularExpression(
        pattern: #"^\s*(?:#+\s*)?(?:\d+\.?\s*)?(appendix|appendices|acknowledg|credits|notes|endnotes|footnotes|supplementary|author contributions|attribution|about the author|figures|tables)\b"#,
        options: [.caseInsensitive])

    public static func parse(_ text: String) -> ParsedManuscript {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        // The last "References" heading wins (a table of contents may mention it earlier).
        let heading = lines.indices.last { matches(headingRE, lines[$0]) }
        var bodyLines = Array(lines.enumerated())
        var refLines: [(Int, String)] = []
        if let h = heading {
            let end = lines.indices.first { $0 > h && matches(endOfReferencesRE, lines[$0]) } ?? lines.count
            bodyLines = Array(lines.enumerated()).filter { $0.offset < h || $0.offset >= end }
            refLines = (h + 1 ..< end).map { ($0 + 1, lines[$0]) }
        }
        return ParsedManuscript(
            entries: entries(from: refLines),
            citations: bodyLines.flatMap { citations(in: $0.element, line: $0.offset + 1) },
            referenceHeadingLine: heading.map { $0 + 1 }
        )
    }

    // MARK: Reference entries

    static func entries(from lines: [(Int, String)]) -> [ParsedEntry] {
        // Group wrapped lines: an entry starts with a capitalized name (or quote/title)
        // and continuation lines don't.
        var groups: [(Int, String)] = []
        for (n, raw) in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
            guard !t.isEmpty else { continue }
            // Subheadings inside the list ("Core Reasoning and Prompting"): short, no year, no link.
            if t.split(separator: " ").count <= 8, t.range(of: #"\((19|20)\d{2}|n\.\s?d\.|https?://|10\.\d{4}"#, options: .regularExpression) == nil,
               !t.hasSuffix(".") || t.split(separator: " ").count <= 4 {
                continue
            }
            // A new entry starts with "Surname, I." — or with any capital once the
            // previous entry looks finished (ends in a period, DOI or URL).
            let namesFirst = t.range(of: #"^\p{Lu}[\p{L}'’ -]*,\s*\p{Lu}\."#, options: .regularExpression) != nil
            let previousDone = groups.last.map { g in
                g.1.hasSuffix(".") || g.1.range(of: #"(doi\.org/|https?://)\S+$"#, options: .regularExpression) != nil
            } ?? true
            // Lowercase-led names ("xAI.", "van Dijk") still start an entry when a year follows.
            let startsEntry = namesFirst || (previousDone && (t.range(of: #"^[\p{Lu}"“\[]"#, options: .regularExpression) != nil
                || t.range(of: #"^\S{1,40}?\.?\s*\((19|20)\d{2}"#, options: .regularExpression) != nil))
            if startsEntry || groups.isEmpty {
                groups.append((n, t))
            } else {
                groups[groups.count - 1].1 += " " + t
            }
        }
        return groups.map { parseEntry($0.1, line: $0.0) }
    }

    private static let yearRE = try! NSRegularExpression(pattern: #"\(\s*(?:((?:19|20)\d{2})([a-z])?|(n\.\s?d\.)(?:-([a-z]))?)(?:,[^)]*)?\s*\)\.?"#)
    private static let sourceRE = try! NSRegularExpression(
        pattern: #"^(.+?),\s*(\d+[A-Za-z]?)\s*(?:\(([^)]+)\))?\s*(?:,\s*((?:[A-Za-z]?\d+\s*[-‐-―]+\s*[A-Za-z]?\d+)|(?:Article\s+[\w.-]+)|(?:[A-Za-z]?\d+)))?\s*\.?\s*$"#)

    public static func parseEntry(_ raw: String, line: Int) -> ParsedEntry {
        var entry = ParsedEntry(line: line, raw: raw, authors: [], truncatedAuthors: false, year: nil, yearSuffix: nil,
                                title: nil, publication: nil, indexing: .init(), doi: nil, url: nil)

        // DOI / URL come off the end first.
        var text = raw
        if let r = text.range(of: #"(https?://(dx\.)?doi\.org/|doi:\s*)\S+"#, options: [.regularExpression, .caseInsensitive]) {
            entry.doi = DOI.find(in: String(text[r]))
            text.removeSubrange(r)
        } else if let doi = DOI.find(in: text) {
            entry.doi = doi
            if let r = text.range(of: #"10\.\d{4,9}/\S+"#, options: .regularExpression) { text.removeSubrange(r) }
        }
        if let r = text.range(of: #"(Retrieved from\s+|Available at:?\s+)?https?://\S+"#, options: [.regularExpression, .caseInsensitive]) {
            entry.url = String(text[r]).replacingOccurrences(of: #"^(Retrieved from|Available at:?)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
            text.removeSubrange(r)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        let ns = NSRange(text.startIndex..., in: text)
        guard let y = yearRE.firstMatch(in: text, range: ns), let yr = Range(y.range, in: text) else {
            entry.title = text
            return entry
        }
        if let r = Range(y.range(at: 1), in: text) { entry.year = Int(text[r]) }
        if let r = Range(y.range(at: 2), in: text) ?? Range(y.range(at: 4), in: text) { entry.yearSuffix = String(text[r]) }

        let authorPart = String(text[..<yr.lowerBound])
        let scan = scanAuthors(authorPart)
        entry.authors = scan.authors
        entry.truncatedAuthors = scan.truncated
        entry.lint += scan.lint

        var rest = String(text[yr.upperBound...]).trimmingCharacters(in: .whitespaces)
        // "Authors. Title. (Year). Venue." — the title came before the year.
        if let early = scan.remainder {
            entry.lint.append("year placed after the title — APA order is Author, A. (Year). Title.")
            entry.title = early
            let venue = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            parseSource(venue, into: &entry)
            lintRaw(raw, into: &entry)
            return entry
        }
        rest = rest.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression) // [Preprint], [Blog post]
        // Title runs to the first sentence end that isn't an initial or abbreviation.
        if let end = rest.range(of: #"(?<!\b\p{Lu})(?<!\bvs)(?<!\bet al)[.?!](\s|$)"#, options: .regularExpression) {
            var title = String(rest[..<end.lowerBound])
            let terminator = rest[end.lowerBound]
            if terminator != "." { title.append(terminator) }
            entry.title = title.trimmingCharacters(in: .whitespaces)
            rest = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            entry.title = rest.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            rest = ""
        }

        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        parseSource(rest, into: &entry)
        lintRaw(raw, into: &entry)
        return entry
    }

    private static let colonLocatorRE = try! NSRegularExpression(pattern: #"^(.+?)[,\s]+(\d+)\s*:\s*([A-Za-z]?\d+(?:\s*[-‐-―]+\s*\d+)?)\.?$"#)

    static func parseSource(_ raw: String, into entry: inout ParsedEntry) {
        guard !raw.isEmpty else { return }
        // "Vol. 17, Issue 4, Article 85" / "Volume 4, Issue 2: 238-248" → "17(4), Article 85" / "4(2), 238-248"
        var rest = raw.replacingOccurrences(of: #"\bVol(?:ume)?\.?\s*(\d+)\s*,?\s*(?:Issue|No\.?|Number)\s*(\w+)\s*[:,]?\s*"#,
                                            with: "$1($2), ", options: [.regularExpression, .caseInsensitive])
        rest = rest.replacingOccurrences(of: #"\bVol(?:ume)?\.?\s*(\d+)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        let rns = NSRange(rest.startIndex..., in: rest)
        if let m = sourceRE.firstMatch(in: rest, range: rns) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: rest).map { String(rest[$0]).trimmingCharacters(in: .whitespaces) } }
            entry.publication = g(1)
            entry.indexing.volume = g(2)
            entry.indexing.issue = g(3)
            if let p = g(4) {
                if p.lowercased().hasPrefix("article") {
                    entry.indexing.articleNumber = String(p.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else {
                    entry.indexing.pages = p.replacingOccurrences(of: #"\s*[-‐-―]+\s*"#, with: "-", options: .regularExpression)
                }
            }
        } else if let m = colonLocatorRE.firstMatch(in: rest, range: rns) {
            // "Front. Comput. Sci. 6:1521066" — volume:article (or volume:pages)
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: rest).map { String(rest[$0]) } }
            entry.publication = g(1)
            entry.indexing.volume = g(2)
            if let loc = g(3) {
                if loc.contains(where: { "-‐-―".contains($0) }) {
                    entry.indexing.pages = loc.replacingOccurrences(of: #"\s*[-‐-―]+\s*"#, with: "-", options: .regularExpression)
                } else {
                    entry.indexing.articleNumber = loc
                }
            }
        } else {
            entry.publication = rest
        }
    }

    /// Mechanical formatting checks on the entry as typed.
    static func lintRaw(_ raw: String, into entry: inout ParsedEntry) {
        if raw.range(of: #"\.\s+\.(?!\s*\.)"#, options: .regularExpression) != nil || raw.contains("..") && !raw.contains("...") {
            entry.lint.append("doubled punctuation (\". .\")")
        }
        if raw.range(of: #"(doi\.org/|https?://)\S+\.$"#, options: .regularExpression) != nil {
            entry.lint.append("period after the DOI/URL — APA ends the entry at the link")
        }
        if raw.range(of: #"[\p{Ll}]\s+[\p{Ll}]{1,2}[\p{Lu}]{2,}"#, options: .regularExpression) != nil
            || raw.range(of: #"\b\p{Ll}+\p{Lu}{2,}\p{Ll}+"#, options: .regularExpression) != nil {
            entry.lint.append("possible typo (stray capitals inside a word)")
        }
    }

    struct AuthorScan {
        var authors: [Author] = []
        var truncated = false
        /// Text left after the author list when the title precedes the year.
        var remainder: String?
        var lint: [String] = []
    }

    private static let personRE = try! NSRegularExpression(
        pattern: #"^\s*(?:,\s*)?(?:(?:&|and)\s+)?(\p{Lu}[\p{L}'’-]*(?:\s+(?:van|von|de|der|den|del|da|di|le|la|du|dos|\p{Lu}[\p{L}'’-]*))*)(\.)?\s*,\s*((?:\p{Lu}\.?(?:\s?-\s?\p{Lu}\.?)?\s?){1,4})(?=[,.&\s]|$)"#)

    /// Reads "Family, I. I., Family, I., & Family, I." from the start of `s`.
    /// Anything that isn't a person list is treated as an organization name.
    static func scanAuthors(_ s: String) -> AuthorScan {
        var scan = AuthorScan()
        var t = s.trimmingCharacters(in: .whitespaces)
        var rest = t
        var separators: [String] = []
        while let m = personRE.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let whole = Range(m.range, in: rest), let fam = Range(m.range(at: 1), in: rest), let ini = Range(m.range(at: 3), in: rest) {
            if Range(m.range(at: 2), in: rest) != nil { scan.lint.append("stray period after \"\(rest[fam])\" (\"\(rest[fam]).,\")") }
            separators.append(String(rest[..<fam.lowerBound]))
            scan.authors.append(Author(family: String(rest[fam]), given: String(rest[ini]).trimmingCharacters(in: .whitespaces)))
            rest = String(rest[whole.upperBound...])
            if let etal = rest.range(of: #"^\s*,?\s*(et al\.?|\.\s?\.\s?\.|…)"#, options: .regularExpression) {
                scan.truncated = true
                rest = String(rest[etal.upperBound...])
                break
            }
        }

        guard !scan.authors.isEmpty else {
            // Organization(s): "World Economic Forum & BCG."
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            for marker in ["et al.", "et al"] where t.contains(marker) {
                scan.truncated = true
                t = t.replacingOccurrences(of: marker, with: "")
            }
            scan.authors = t.components(separatedBy: " & ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,.")) }
                .filter { !$0.isEmpty }.map { Author(family: $0, isOrganization: true) }
            return scan
        }

        // Separators: later authors should follow ", " and the last one "& ".
        for (i, sep) in separators.enumerated() where i > 0 {
            if !sep.contains(",") && !sep.contains("&") { scan.lint.append("missing comma before \"\(scan.authors[i].family)\"") }
        }
        if scan.authors.count >= 2, !scan.truncated, let last = separators.last, !last.contains("&"), !last.lowercased().contains("and") {
            scan.lint.append("missing \"&\" before the final author")
        }

        let leftover = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        if leftover.split(separator: " ").count >= 2 {
            scan.remainder = leftover
        }
        return scan
    }

    static func isInitials(_ s: String) -> Bool {
        s.range(of: #"^(\p{Lu}\.?(\s?-\s?\p{Lu}\.?)?\s?)+$"#, options: .regularExpression) != nil
    }

    // MARK: In-text citations

    private static let groupRE = try! NSRegularExpression(pattern: #"\(([^()]*?\b(?:(?:19|20)\d{2}[a-z]?|n\.\s?d\.)[^()]*)\)"#)
    private static let itemRE = try! NSRegularExpression(
        pattern: #"^(?:(?:e\.g\.|i\.e\.|see(?: also)?|cf\.|for example|as reviewed in)[,\s]+)?(.+?),?\s+((?:(?:19|20)\d{2}[a-z]?|n\.\s?d\.)(?:\s*,\s*(?:19|20)\d{2}[a-z]?)*)(?:\s*,\s*(.+))?$"#,
        options: [.caseInsensitive])
    private static let narrativeRE = try! NSRegularExpression(
        pattern: #"(\p{Lu}[\p{L}'’-]+(?:\s+(?:and|&)\s+\p{Lu}[\p{L}'’-]+|\s+et al\.?)?)(?:['’]s)?\s+\(((?:19|20)\d{2}[a-z]?|n\.\s?d\.)(?:,\s*([^)]*))?\)"#)

    /// Capitalized words that precede years without being authors: "In (2020)", "(Since 2019)".
    private static let notNames: Set<String> = ["In", "By", "Since", "From", "During", "Until", "Before", "After", "The", "See",
                                                "Table", "Figure", "Fig", "Fig.", "Version", "Released", "Updated", "Accessed", "Spring", "Summer", "Fall", "Winter",
                                                "January", "February", "March", "April", "May", "June", "July", "August", "September",
                                                "October", "November", "December", "Q1", "Q2", "Q3", "Q4"]

    public static func citations(in line: String, line number: Int) -> [InTextCitation] {
        citationSpans(in: line, line: number).flatMap(\.citations)
    }

    /// A citation as it sits in the text: one parenthetical group (all its
    /// items) or one narrative citation, with its exact range.
    public struct CitationSpan: Sendable {
        public var range: Range<String.Index>
        public var citations: [InTextCitation]
        public var narrative: Bool
    }

    public static func citationSpans(in line: String, line number: Int) -> [CitationSpan] {
        var spans: [CitationSpan] = []
        let ns = NSRange(line.startIndex..., in: line)

        for g in groupRE.matches(in: line, range: ns) {
            guard let inner = Range(g.range(at: 1), in: line), let whole = Range(g.range, in: line) else { continue }
            var found: [InTextCitation] = []
            for item in line[inner].split(separator: ";") {
                let it = item.trimmingCharacters(in: .whitespaces)
                guard let m = itemRE.firstMatch(in: it, range: NSRange(it.startIndex..., in: it)),
                      let nr = Range(m.range(at: 1), in: it), let yr = Range(m.range(at: 2), in: it) else { continue }
                let namesPart = String(it[nr])
                guard namesPart.range(of: #"^\p{Lu}"#, options: .regularExpression) != nil, !notNames.contains(namesPart),
                      namesPart.range(of: #"[=<>%]|\b(p|n|N|r|t|F)\s*[=<>]"#, options: .regularExpression) == nil else { continue }
                let locator = Range(m.range(at: 3), in: it).map { String(it[$0]) }
                for y in it[yr].split(separator: ",") {
                    found.append(makeCitation(names: namesPart, year: String(y).trimmingCharacters(in: .whitespaces),
                                              locator: locator, raw: it, line: number, narrative: false))
                }
            }
            if !found.isEmpty { spans.append(CitationSpan(range: whole, citations: found, narrative: false)) }
        }

        for m in narrativeRE.matches(in: line, range: ns) {
            guard let whole = Range(m.range, in: line), !spans.contains(where: { $0.range.overlaps(whole) }),
                  let nr = Range(m.range(at: 1), in: line), let yr = Range(m.range(at: 2), in: line) else { continue }
            let names = String(line[nr])
            guard !notNames.contains(names) else { continue }
            let c = makeCitation(names: names, year: String(line[yr]), locator: Range(m.range(at: 3), in: line).map { String(line[$0]) },
                                 raw: String(line[whole]), line: number, narrative: true)
            spans.append(CitationSpan(range: whole, citations: [c], narrative: true))
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func makeCitation(names: String, year: String, locator: String?, raw: String, line: Int, narrative: Bool) -> InTextCitation {
        var n = names.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"['’]s$"#, with: "", options: .regularExpression)
        let etAl = n.range(of: #"\bet al\.?"#, options: .regularExpression) != nil
        n = n.replacingOccurrences(of: #",?\s*\bet al\.?"#, with: "", options: .regularExpression)
        let list = n.replacingOccurrences(of: #"\s*,?\s*(&|\band\b)\s*"#, with: ",", options: .regularExpression)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var y = year.trimmingCharacters(in: .whitespaces)
        var suffix: String?
        if let last = y.last, last.isLetter, y.count == 5 { suffix = String(last); y.removeLast() }
        if y.lowercased().hasPrefix("n.") {
            if let r = y.range(of: #"-([a-z])$"#, options: .regularExpression) { suffix = String(y[r].dropFirst()) }
        }
        return InTextCitation(line: line, raw: raw, names: list, etAl: etAl, year: Int(y), yearSuffix: suffix,
                              locator: locator?.trimmingCharacters(in: .whitespaces), narrative: narrative)
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
