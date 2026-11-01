import Foundation

public struct ProcessingIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case unknownIDI(IDI)
        case malformedTag
        case unverifiedReference(IDI)
        case unknownQuote(String)
        case deletedIDI(IDI, String)
    }

    public var kind: Kind
    public var line: Int
    public var source: String

    public var description: String {
        switch kind {
        case .unknownIDI(let id): "line \(line): \(source) — IDI \(id) is not in the library"
        case .malformedTag: "line \(line): \(source) — malformed tag"
        case .unverifiedReference(let id): "line \(line): \(source) — IDI \(id) metadata has not been verified"
        case .deletedIDI(let id, let why): "line \(line): \(source) — IDI \(id) was deleted (\(why)); cite another source or remove the citation"
        case .unknownQuote(let tag): "line \(line): \(source) — \(tag) is not a recorded quote (record it with `refware quote add`)"
        }
    }
}

public struct ProcessingError: Error, CustomStringConvertible {
    public var issues: [ProcessingIssue]
    public var description: String {
        "document not processed (\(issues.count) issue\(issues.count == 1 ? "" : "s")):\n"
            + issues.map { "  " + $0.description }.joined(separator: "\n")
    }
}

public struct ProcessedDocument: Sendable {
    public var text: String
    /// IDIs cited, in order of first appearance.
    public var cited: [IDI]
    /// IDI-Q tags cited.
    public var quoteTags: [String] = []
}

/// Replaces `[IDI …]` tags in a manuscript with formatted citations.
///
/// Processing is all-or-nothing: if any tag is malformed or refers to an IDI
/// that isn't in the library, nothing is substituted and every problem is
/// reported. A citation is never emitted for a reference RefWare can't vouch for.
public struct DocumentProcessor: Sendable {
    public var library: Library
    public var markup: CitationFormatter.Markup
    /// When `true`, references whose provenance isn't verified are rejected.
    public var requireVerified: Bool

    public init(library: Library, markup: CitationFormatter.Markup = .plain, requireVerified: Bool = false) {
        self.library = library
        self.markup = markup
        self.requireVerified = requireVerified
    }

    public func process(_ text: String) throws(ProcessingError) -> ProcessedDocument {
        let (tags, malformed) = TagParser.scan(text)
        let cited = try validate(tags.map { ($0.tag, $0.line, $0.source) },
                                 malformed: malformed.map { ($0.line, $0.source) })

        let refs = cited.compactMap { library[$0] }
        let formatter = CitationFormatter(references: refs, markup: markup)
        let referenceList = formatter.referenceList(refs)

        var output = ""
        var cursor = text.startIndex
        for occurrence in tags {
            output += text[cursor..<occurrence.range.lowerBound]
            output += occurrence.tag == .allReferences ? referenceList : render(occurrence.tag, formatter: formatter)
            cursor = occurrence.range.upperBound
        }
        output += text[cursor...]
        return ProcessedDocument(text: output, cited: cited, quoteTags: Self.uniqueQuoteTags(tags.map(\.tag), library: library))
    }

    /// Checks every tag against the library. Returns cited IDIs in order of first
    /// appearance, or throws with every problem found (nothing is partially processed).
    public func validate(_ tags: [(tag: RefTag, line: Int, source: String)], malformed: [(line: Int, source: String)]) throws(ProcessingError) -> [IDI] {
        var issues = malformed.map { ProcessingIssue(kind: .malformedTag, line: $0.line, source: $0.source) }
        var cited: [IDI] = []
        var seen = Set<IDI>()
        for t in tags {
            if let qt = t.tag.quoteTag, quote(qt) == nil {
                issues.append(.init(kind: .unknownQuote(qt), line: t.line, source: t.source))
            }
            for id in t.tag.ids {
                guard let ref = library[id] else {
                    if let d = library.deleted[id] {
                        let why = "\(d.citation), \(d.on.formatted(date: .abbreviated, time: .omitted))\(d.reason.map { " — \($0)" } ?? "")"
                        issues.append(.init(kind: .deletedIDI(id, why), line: t.line, source: t.source))
                        continue
                    }
                    issues.append(.init(kind: .unknownIDI(id), line: t.line, source: t.source))
                    continue
                }
                if requireVerified && ref.provenance?.verified != true {
                    issues.append(.init(kind: .unverifiedReference(id), line: t.line, source: t.source))
                }
                // Canonical: a merged-away number and its survivor are one work (one entry, no stray "b").
                let canonical = library.canonical(id)
                if seen.insert(canonical).inserted { cited.append(canonical) }
            }
        }
        if !issues.isEmpty {
            throw ProcessingError(issues: issues.sorted { $0.line < $1.line })
        }
        return cited
    }

    /// Inline text for a citation tag (not `.allReferences`).
    public func render(_ tag: RefTag, formatter: CitationFormatter) -> String {
        switch tag {
        case .cite(let ids, let locator):
            let group = ids.compactMap { library[$0] }
            if let locator, let only = group.first { return "(\(formatter.inlineBody(only)), \(locator))" }
            return formatter.inline(group)
        case .narrative(let id, let locator):
            return library[id].map { formatter.narrative($0, locator: locator) } ?? ""
        case .possessive(let id, let locator):
            return library[id].map { formatter.narrative($0, locator: locator, possessive: true) } ?? ""
        case .quote(let id, _):
            guard let ref = library[id] else { return "" }
            let page = tag.quoteTag.flatMap(quote)?.page
            return "(\(formatter.inlineBody(ref))\(page.map { ", p. \($0)" } ?? ""))"
        case .allReferences:
            return ""
        }
    }

    /// A recorded quote by tag, from any project. Tags follow merges: `IDI 57-Q1`
    /// still finds the quote after 57 is merged into 37 and it becomes `IDI 37-Q2`.
    public func quote(_ tag: String) -> QuoteRecord? {
        let resolved = library.canonicalQuoteTag(tag)
        for index in library.projects.values {
            if let q = index.quote(tag: resolved) { return q }
        }
        return nil
    }

    public static func uniqueQuoteTags(_ tags: [RefTag], library: Library) -> [String] {
        var seen = Set<String>()
        return tags.compactMap(\.quoteTag).filter { seen.insert($0).inserted }
    }
}
