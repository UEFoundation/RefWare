import Foundation

public struct DocxCitationResult: Sendable {
    public var data: Data
    /// IDIs cited, in order of first appearance.
    public var cited: [IDI]
    public var citationsReplaced: Int
    public var referenceListEntries: Int
    /// Cited references whose metadata isn't registry-verified.
    public var unverified: [IDI]
    /// IDI-Q tags cited.
    public var quoteTags: [String] = []
}

/// Expands `[IDI …]` tags inside a .docx. Only the touched `<w:t>` runs and the
/// ALLREF paragraph change; every other part of the package is copied unchanged.
public struct DocxCiter: Sendable {
    public var processor: DocumentProcessor
    /// APA 0.5″ hanging indent on generated reference paragraphs (unless the
    /// ALLREF paragraph's style already sets an indent).
    public var hangingIndent: Bool

    public static let textParts = ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"]

    public init(library: Library, requireVerified: Bool = false, hangingIndent: Bool = true) {
        processor = DocumentProcessor(library: library, markup: .markdown, requireVerified: requireVerified)
        self.hangingIndent = hangingIndent
    }

    public func process(_ docx: Data) throws -> DocxCitationResult {
        var zip = try ZipArchive(data: docx)
        var parts: [(name: String, doc: WordXML)] = []
        for name in Self.textParts {
            guard let data = try zip.data(name) else { continue }
            parts.append((name, WordXML(String(decoding: data, as: UTF8.self))))
        }
        guard parts.contains(where: { $0.name == "word/document.xml" }) else { throw ZipError.corrupt("no word/document.xml") }

        // Pass 1: find and validate every tag. "line" = paragraph number in its part.
        struct Found { var part: Int; var paragraph: Int; var occurrence: TagOccurrence; var text: String }
        var found: [Found] = []
        var malformed: [(line: Int, source: String)] = []
        for (pi, part) in parts.enumerated() {
            for (i, p) in part.doc.paragraphs.enumerated() {
                let text = p.text
                guard text.contains("[") else { continue }
                let (tags, bad) = TagParser.scan(text)
                found += tags.map { Found(part: pi, paragraph: i, occurrence: $0, text: text) }
                malformed += bad.map { (i + 1, $0.source + (part.name == "word/document.xml" ? "" : " in \(part.name)")) }
            }
        }
        let cited = try processor.validate(found.map { ($0.occurrence.tag, $0.paragraph + 1, $0.occurrence.source) }, malformed: malformed)
        let refs = cited.compactMap { processor.library[$0] }
        let formatter = CitationFormatter(references: refs, markup: .markdown)

        // Pass 2: edits.
        var replaced = 0
        for (pi, part) in parts.enumerated() {
            var edits: [WordXML.TextEdit] = []
            var paragraphsOut: [Int: String] = [:]
            for f in found where f.part == pi {
                if f.occurrence.tag == .allReferences {
                    let pPr = part.doc.paragraphProperties(f.paragraph)
                    let rPr = part.doc.firstRunProperties(f.paragraph)
                    let entries = CitationFormatter.sorted(refs).map { formatter.referenceEntry($0) }
                    paragraphsOut[f.paragraph] = entries
                        .map { WordXML.paragraph(markdown: $0, pPr: pPr, rPr: rPr, hangingIndent: hangingIndent) }
                        .joined()
                } else {
                    let lower = f.text.distance(from: f.text.startIndex, to: f.occurrence.range.lowerBound)
                    let upper = f.text.distance(from: f.text.startIndex, to: f.occurrence.range.upperBound)
                    edits.append(.init(paragraph: f.paragraph, range: lower..<upper, replacement: processor.render(f.occurrence.tag, formatter: formatter)))
                    replaced += 1
                }
            }
            guard !edits.isEmpty || !paragraphsOut.isEmpty else { continue }
            try zip.set(part.name, Data(part.doc.applying(edits, replacingParagraphs: paragraphsOut).utf8))
        }

        let hasList = found.contains { $0.occurrence.tag == .allReferences }
        return DocxCitationResult(
            data: zip.serialized(), cited: cited, citationsReplaced: replaced,
            referenceListEntries: hasList ? refs.count : 0,
            unverified: refs.filter { $0.provenance?.verified != true }.map(\.id),
            quoteTags: DocumentProcessor.uniqueQuoteTags(found.map(\.occurrence.tag), library: processor.library)
        )
    }
}
