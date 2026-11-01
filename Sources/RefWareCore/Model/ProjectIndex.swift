import Foundation

/// A verified quote excerpt: `Q1: line #` in the spec.
public struct QuoteRecord: Codable, Hashable, Sendable {
    /// `Q1`, `Q2`, … numbered per reference within a project.
    public var label: String
    public var reference: IDI
    public var text: String
    /// Page in the source PDF (1-based), once verified.
    public var page: Int?
    /// Line on that page (1-based), once verified.
    public var line: Int?
    public var verified: Bool
    /// What was submitted, when it differed from the PDF's own wording (which is `text`).
    public var submitted: String?
    /// SHA-256 of the PDF this quote was verified against.
    public var pdfSHA256: String?
    /// Normalization rules version used (see `QuoteVerifier.normalizationVersion`).
    public var normalization: Int?
    public var verifiedOn: Date?
    /// Set when the record's PDF changed and the quote could no longer be found in it.
    /// A stale quote stays on record but can't support a claim until re-verified.
    public var staleSince: Date?

    /// Verified against the record's current PDF.
    public var isCurrent: Bool { verified && staleSince == nil }

    public init(label: String, reference: IDI, text: String, page: Int? = nil, line: Int? = nil, verified: Bool = false) {
        self.label = label
        self.reference = reference
        self.text = text
        self.page = page
        self.line = line
        self.verified = verified
    }

    /// `IDI 2-Q1`
    public var tag: String { "IDI \(reference)-\(label)" }
}

/// Per-project citation index: which references a UEF project cites, the
/// quotes it uses, and the claims those quotes back.
public struct ProjectCitationIndex: Codable, Hashable, Sendable {
    /// `UEF-XXXX`
    public var project: String
    public var references: [IDI]
    public var quotes: [QuoteRecord]
    public var claims: [Claim]
    /// The author's own domains (e.g. `my-lab.example`); sources there are flagged as self-citation.
    public var selfDomains: [String]
    /// Declared sub-projects ("Section 1.3", "Talk deck").
    public var subprojects: [String] = []
    /// Review policy: may an AI's judgment set a claim's status? Off by default — an AI's
    /// judgments are kept as proposals for a person to accept.
    public var aiMayFinalize: Bool?

    public init(project: String, references: [IDI] = [], quotes: [QuoteRecord] = [], claims: [Claim] = [], selfDomains: [String] = []) {
        self.project = project
        self.references = references
        self.quotes = quotes
        self.claims = claims
        self.selfDomains = selfDomains
    }

    private enum CodingKeys: String, CodingKey { case project, references, quotes, claims, selfDomains, subprojects, aiMayFinalize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(String.self, forKey: .project)
        references = try c.decodeIfPresent([IDI].self, forKey: .references) ?? []
        quotes = try c.decodeIfPresent([QuoteRecord].self, forKey: .quotes) ?? []
        claims = try c.decodeIfPresent([Claim].self, forKey: .claims) ?? []
        selfDomains = try c.decodeIfPresent([String].self, forKey: .selfDomains) ?? []
        subprojects = try c.decodeIfPresent([String].self, forKey: .subprojects) ?? []
        aiMayFinalize = try c.decodeIfPresent(Bool.self, forKey: .aiMayFinalize)
    }

    public mutating func addReference(_ id: IDI) {
        if !references.contains(id) { references.append(id) }
    }

    public func quote(tag: String) -> QuoteRecord? {
        quotes.first { $0.tag == tag }
    }

    public func nextQuoteLabel(for reference: IDI) -> String {
        "Q\(quotes.filter { $0.reference == reference }.count + 1)"
    }

    public func claimIndex(_ id: String) -> Int? {
        claims.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Adds imported claims, skipping any whose text (normalized) is already a claim here —
    /// a revised list, or the same sentence from another draft. New claims are numbered on
    /// from the last one. Returns what was added and what was already present (new → existing ID).
    @discardableResult
    public mutating func addClaims(_ incoming: [Claim]) -> (added: [Claim], existing: [(text: String, id: String)]) {
        var known = Dictionary(claims.map { (TextCleanup.comparable($0.text), $0.id) }, uniquingKeysWith: { a, _ in a })
        var added: [Claim] = [], existing: [(String, String)] = []
        var n = Int(nextClaimID.dropFirst()) ?? 1
        for var c in incoming {
            let key = TextCleanup.comparable(c.text)
            if let id = known[key] { existing.append((c.text, id)); continue }
            c.id = "C\(n)"; n += 1
            known[key] = c.id
            claims.append(c)
            added.append(c)
        }
        return (added, existing)
    }

    public var nextClaimID: String {
        let n = claims.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        return "C\(n + 1)"
    }

    public func isSelfSource(_ url: String) -> Bool {
        guard let host = CanonicalURL.host(url) else { return false }
        return selfDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
