import Foundation

/// A claim made in a source conversation or draft, with the sources it was
/// attributed to and the verified quotes that back it.
public struct Claim: Codable, Hashable, Sendable, Identifiable {
    /// `C1`, `C2`, …
    public var id: String
    public var text: String
    public var origin: ClaimOrigin?
    public var sources: [ClaimSource]
    /// Quote tags (`IDI 2-Q1`) recorded with `quote add`.
    public var quotes: [String]
    public var flags: [ClaimFlag]
    public var status: ClaimStatus
    public var note: String?
    /// Sub-project this claim belongs to, if any.
    public var subproject: String?
    /// Who last set the status, and when (a person's initials or an agent's name).
    public var reviewedBy: String?
    public var reviewedOn: Date?
    /// Attributed review events (judgments, flags, comments) — see `reviews`.
    var reviewLog: [ReviewEvent]?

    public init(id: String, text: String, origin: ClaimOrigin? = nil, sources: [ClaimSource] = [], quotes: [String] = [],
                flags: [ClaimFlag] = [], status: ClaimStatus = .unreviewed, note: String? = nil) {
        self.id = id
        self.text = text
        self.origin = origin
        self.sources = sources
        self.quotes = quotes
        self.flags = flags
        self.status = status
        self.note = note
    }

    /// Linked IDIs in source order, without duplicates (a link and a named title often resolve to the same work).
    public var references: [IDI] {
        var seen = Set<IDI>()
        return sources.compactMap(\.reference).filter { seen.insert($0).inserted }
    }
}

public struct ClaimOrigin: Codable, Hashable, Sendable {
    public var file: String
    /// 1-based line in the source file.
    public var line: Int
    public var speaker: String?
    /// The claim's label in the imported list ("C5"), when it had one.
    public var label: String?

    public init(file: String, line: Int, speaker: String? = nil, label: String? = nil) {
        self.file = file
        self.line = line
        self.speaker = speaker
        self.label = label
    }
}

/// One source a claim was attributed to: a footnote URL, an inline link, or a
/// title named without a link. `reference` is set once it resolves to an IDI.
public struct ClaimSource: Codable, Hashable, Sendable {
    /// Footnote number in the original turn (`[3]`), if any.
    public var marker: Int?
    public var url: String?
    public var title: String?
    public var reference: IDI?

    public init(marker: Int? = nil, url: String? = nil, title: String? = nil, reference: IDI? = nil) {
        self.marker = marker
        self.url = url
        self.title = title
        self.reference = reference
    }
}

/// Warnings raised mechanically at import. They never change status by themselves.
public enum ClaimFlag: String, Codable, Hashable, Sendable {
    /// A work is named (title + year) but no link was given.
    case unlinkedTitle = "unlinked-title"
    /// The claim contains text presented as a verbatim quotation from a source.
    case containsQuotation = "contains-quotation"
    /// "Research shows…"-style language with no citation attached.
    case uncitedEvidence = "uncited-evidence"
    /// The claim text looks cut off (starts or ends mid-sentence) — check the manuscript.
    case fragment
}

/// Editorial status. Only a person sets these (via `claims set`).
public enum ClaimStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed
    /// A verified quote from a linked source supports the claim. Requires ≥ 1 quote.
    case supported
    /// The source is real but the claim goes beyond what it says.
    case overstated
    /// The source is real but does not support the claim.
    case unsupported
    /// The attributed source could not be located.
    case sourceNotFound = "source-not-found"
    /// Supported only by the author's own material.
    case selfCitation = "self-citation"
    /// Removed from the manuscript.
    case dropped
}
