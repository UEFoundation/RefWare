import Foundation

/// Bibliographic metadata returned by a resolver, before it is assigned an IDI.
public struct ResolvedMetadata: Hashable, Sendable {
    public var authors: [Author]
    public var year: Int?
    public var title: String
    public var publication: String?
    public var indexing: PublicationIndexing
    public var doi: String?
    public var url: String?
    public var arxiv: String?
    public var publicationType: PublicationType
    public var source: Provenance.Source
    public var lookupKey: String
    /// Every year the record carries (issued, print, online). A hand-written
    /// year matching any of these is defensible, not an error.
    public var yearsSeen: [Int] = []
    /// Abbreviated / alternate journal names (Crossref `short-container-title`).
    public var publicationAliases: [String] = []

    public init(
        authors: [Author], year: Int?, title: String, publication: String? = nil,
        indexing: PublicationIndexing = .init(), doi: String? = nil, url: String? = nil, arxiv: String? = nil,
        publicationType: PublicationType = .unclassified, source: Provenance.Source, lookupKey: String
    ) {
        self.authors = authors
        self.year = year
        self.title = title
        self.publication = publication
        self.indexing = indexing
        self.doi = doi.flatMap(DOI.normalize)
        self.url = url
        self.arxiv = arxiv
        self.publicationType = publicationType
        self.source = source
        self.lookupKey = lookupKey
    }

    public func makeReference(id: IDI, verified: Bool, retrieved: Date = Date(), projects: [ProjectTag] = [], fileName: String? = nil) -> Reference {
        Reference(
            id: id, fileName: fileName, authors: authors, year: year, title: title,
            publication: publication, indexing: indexing, doi: doi, url: url, arxiv: arxiv,
            publicationType: publicationType, projects: projects,
            provenance: Provenance(source: source, key: lookupKey, retrieved: retrieved, verified: verified)
        )
    }
}

public enum TextCleanup {
    /// Strips markup (Crossref titles often contain `<i>`, `<sub>`, JATS tags),
    /// decodes common entities, and collapses whitespace.
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = decodeEntities(t)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
    ]

    /// Decodes numeric entities exactly and common named ones; unknown named
    /// entities are left as-is so nothing is silently dropped.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let re = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)
        var out = ""
        var cursor = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let body = Range(m.range(at: 1), in: s) else { continue }
            out += s[cursor..<whole.lowerBound]
            let b = String(s[body])
            var replacement: String?
            if b.hasPrefix("#x") || b.hasPrefix("#X") {
                replacement = UInt32(b.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if b.hasPrefix("#") {
                replacement = UInt32(b.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[b]
            }
            out += replacement ?? String(s[whole])
            cursor = whole.upperBound
        }
        return out + s[cursor...]
    }

    /// Lowercased, punctuation-free form used to compare titles.
    public static func comparable(_ s: String) -> String {
        clean(s).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
