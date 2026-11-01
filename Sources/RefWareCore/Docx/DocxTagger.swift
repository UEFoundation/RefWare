import Foundation

/// Converts a manuscript with hand-typed citations into a tagged one:
/// `(Smith & Jones, 2020)` → `[IDI 4]`, `Lee et al. (2021)` → `[IDI 9, narrative]`,
/// and the reference section → `[IDI # - ALLREF]`.
///
/// Conservative by design: a citation is converted only when every item in it
/// matches exactly one reference entry by first author (or organization acronym)
/// and year, and that entry is in the library. Anything else is left exactly as
/// typed and reported. The reference section is replaced only when every entry
/// in it is in the library.
public struct DocxTagger: Sendable {
    public struct Skipped: Sendable {
        public var paragraph: Int
        public var text: String
        public var reason: String
    }

    public struct Report: Sendable {
        public var converted = 0
        public var skipped: [Skipped] = []
        public var referenceEntries = 0
        public var referenceListReplaced = false
        public var unmappedEntries: [String] = []
    }

    /// Normalized entry text → IDI (see `key(forEntry:)`).
    public var entryIDs: [String: IDI]

    public init(entryIDs: [String: IDI]) {
        self.entryIDs = entryIDs
    }

    /// Entries are matched between the audit and the .docx by their text, since
    /// paragraph numbering differs between the two readers.
    public static func key(forEntry raw: String) -> String { TextCleanup.comparable(raw) }

    public func tag(_ docx: Data) throws -> (data: Data, report: Report) {
        var zip = try ZipArchive(data: docx)
        guard let data = try zip.data("word/document.xml") else { throw ZipError.corrupt("no word/document.xml") }
        let doc = WordXML(String(decoding: data, as: UTF8.self))
        let texts = doc.paragraphs.map(\.text)
        var report = Report()

        // Reference section: last "References" heading up to the next back-matter heading.
        guard let heading = texts.indices.last(where: { ManuscriptParser.matches(ManuscriptParser.headingRE, texts[$0]) }) else {
            throw ZipError.corrupt("no References heading found")
        }
        let end = texts.indices.first { $0 > heading && ManuscriptParser.matches(ManuscriptParser.endOfReferencesRE, texts[$0]) } ?? texts.count
        let entries = ManuscriptParser.entries(from: ((heading + 1)..<end).map { ($0 + 1, texts[$0]) })
        report.referenceEntries = entries.count
        let ids: [IDI?] = entries.map { entryIDs[Self.key(forEntry: $0.raw)] }
        report.unmappedEntries = Swift.zip(entries, ids).filter { $0.1 == nil }.map { $0.0.raw }

        // Citations in the body (everything outside the reference section).
        var edits: [WordXML.TextEdit] = []
        for (i, text) in texts.enumerated() where i <= heading || i >= end {
            for span in ManuscriptParser.citationSpans(in: text, line: i + 1) {
                let original = String(text[span.range])
                switch resolve(span, entries: entries, ids: ids) {
                case .success(let tag):
                    let lower = text.distance(from: text.startIndex, to: span.range.lowerBound)
                    let upper = text.distance(from: text.startIndex, to: span.range.upperBound)
                    edits.append(.init(paragraph: i, range: lower..<upper, replacement: tag))
                    report.converted += 1
                case .failure(let reason):
                    report.skipped.append(Skipped(paragraph: i + 1, text: original, reason: reason.message))
                }
            }
        }

        // Reference section → one ALLREF paragraph, only if every entry is in the library.
        var replaced: [Int: String] = [:]
        if report.unmappedEntries.isEmpty, let first = entries.first.map({ $0.line - 1 }) {
            let pPr = doc.paragraphProperties(first), rPr = doc.firstRunProperties(first)
            replaced[first] = WordXML.paragraph(markdown: "[IDI # - ALLREF]", pPr: pPr, rPr: rPr, hangingIndent: false)
            for p in (heading + 1)..<end where p != first {
                // Keep a paragraph that carries a section break; just empty it.
                let el = doc.xml[doc.paragraphs[p].element]
                replaced[p] = el.contains("<w:sectPr") ? String(el).replacingOccurrences(of: #"<w:r(?=[\s>]).*?</w:r>"#, with: "", options: .regularExpression) : ""
            }
            report.referenceListReplaced = true
        }

        try zip.set("word/document.xml", Data(doc.applying(edits, replacingParagraphs: replaced).utf8))
        return (zip.serialized(), report)
    }

    struct Unresolved: Error { var message: String }

    func resolve(_ span: ManuscriptParser.CitationSpan, entries: [ParsedEntry], ids: [IDI?]) -> Result<String, Unresolved> {
        var resolved: [IDI] = []
        for c in span.citations {
            guard let first = c.names.first else { return .failure(.init(message: "no author")) }
            let matches = entries.indices.filter { i in
                let lead = entries[i].authors.first
                let nameOK = lead.map { ManuscriptAuditor.sameName($0.family, first) || ($0.isOrganization && ManuscriptAuditor.isAcronym(first, of: $0.family)) } ?? false
                return nameOK && entries[i].year == c.year && (c.yearSuffix == nil || entries[i].yearSuffix == c.yearSuffix)
            }
            guard !matches.isEmpty else {
                return .failure(.init(message: "\(c.raw): no entry by \(first) in \(c.year.map(String.init) ?? "n.d.")"))
            }
            guard matches.count == 1 else { return .failure(.init(message: "\(c.raw): ambiguous (\(matches.count) entries)")) }
            guard let id = ids[matches[0]] else { return .failure(.init(message: "\(c.raw): its entry isn't in the library")) }
            if !resolved.contains(id) { resolved.append(id) }
        }
        let locators = span.citations.compactMap(\.locator)
        if span.narrative {
            // "Smith’s (2020) model" keeps its possessive.
            let possessive = span.citations.first.map { $0.raw.range(of: #"['’]s\s*\("#, options: .regularExpression) != nil } ?? false
            return .success("[IDI \(resolved[0]), \(possessive ? "possessive" : "narrative")\(locators.first.map { ", \($0)" } ?? "")]")
        }
        if !locators.isEmpty {
            guard resolved.count == 1 else { return .failure(.init(message: "page locator inside a multi-work citation — tag by hand")) }
            return .success("[IDI \(resolved[0]), \(locators[0])]")
        }
        return .success("[IDI \(resolved.map(String.init).joined(separator: ", "))]")
    }
}
