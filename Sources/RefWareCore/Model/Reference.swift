import Foundation

/// Internal Database Index — the stable integer key behind `[IDI #]` tags.
public typealias IDI = Int

public enum PublicationType: String, Codable, CaseIterable, Sendable {
    case peerReviewed = "peer-reviewed"
    case preprint
    case popularPress = "popular-press"
    case industryMagazine = "industry-magazine"
    case whitePaper = "white-paper"
    case developerDocumentation = "developer-documentation"
    case book
    case bookChapter = "book-chapter"
    case report
    case other
    /// Default when no source states the type. RefWare never guesses peer-review status.
    case unclassified
}

/// Vol. / Issue / Pages etc.
public struct PublicationIndexing: Codable, Hashable, Sendable {
    public var volume: String?
    public var issue: String?
    public var pages: String?
    /// Article number for journals that use e-locators instead of page ranges.
    public var articleNumber: String?

    public init(volume: String? = nil, issue: String? = nil, pages: String? = nil, articleNumber: String? = nil) {
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.articleNumber = articleNumber
    }

    public var isEmpty: Bool { volume == nil && issue == nil && pages == nil && articleNumber == nil }
}

/// One UEF project's internal tag on a paper. A paper may carry several.
public struct ProjectTag: Codable, Hashable, Sendable {
    /// `UEF-XXXX`
    public var project: String
    /// Internal short name.
    public var handle: String?
    /// Sub-projects within the project this work belongs to ("Section 1.3", "Talk deck").
    public var subprojects: [String]

    public init(project: String, handle: String? = nil, subprojects: [String] = []) {
        self.project = project
        self.handle = handle
        self.subprojects = subprojects
    }

    private enum CodingKeys: String, CodingKey { case project, handle, subprojects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(String.self, forKey: .project)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        subprojects = try c.decodeIfPresent([String].self, forKey: .subprojects) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(project, forKey: .project)
        try c.encodeIfPresent(handle, forKey: .handle)
        if !subprojects.isEmpty { try c.encode(subprojects, forKey: .subprojects) }
    }
}

/// Where a reference's bibliographic metadata came from. Kept so every field
/// in the library can be traced back to an authoritative source.
public struct Provenance: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case crossref
        case datacite
        /// Scholarly `citation_*` metadata declared by the page.
        case webMetadata = "web-metadata"
        /// Only general page metadata (Open Graph / `<title>`): blogs, vendor pages, video.
        case webPage = "web-page"
        /// Read from a publisher/archive cover sheet inside the PDF (e.g. JSTOR).
        case pdfCover = "pdf-cover"
        case manual
    }

    public var source: Source
    /// The lookup key that produced the record (DOI, URL, query…).
    public var key: String
    public var retrieved: Date
    /// `true` only after an exact-key match (DOI/URL) or explicit human confirmation.
    public var verified: Bool
    /// Who confirmed the metadata by hand (for sources no registry covers), and when.
    public var confirmedBy: String?
    public var confirmedOn: Date?

    public init(source: Source, key: String, retrieved: Date, verified: Bool, confirmedBy: String? = nil, confirmedOn: Date? = nil) {
        self.source = source
        self.key = key
        self.retrieved = retrieved
        self.verified = verified
        self.confirmedBy = confirmedBy
        self.confirmedOn = confirmedOn
    }
}

public struct Reference: Codable, Hashable, Sendable, Identifiable {
    public var id: IDI
    /// `[IDI #] = FILE_NAME.pdf` — path relative to the library's PDF folder.
    public var fileName: String?

    public var authors: [Author]
    /// `nil` renders as "n.d."
    public var year: Int?
    public var title: String
    /// Name of journal or platform.
    public var publication: String?
    public var indexing: PublicationIndexing
    /// Bare DOI (`10.xxxx/yyyy`) in its registered case — rendered as `https://doi.org/…`.
    public var doi: String?
    /// Web address, used in the reference list only when no DOI is available.
    public var url: String?
    /// Version-less arXiv identifier, when the work has an arXiv record.
    public var arxiv: String?
    public var publicationType: PublicationType

    public var projects: [ProjectTag]
    public var provenance: Provenance?
    /// When the record entered the library (set automatically on add).
    public var added: Date?
    /// SHA-256 of the attached PDF (identifies the exact document quotes were checked against).
    public var pdfSHA256: String?

    /// Import date: `added`, or for older records the date their metadata was retrieved.
    public var importDate: Date? { added ?? provenance?.retrieved }

    public init(
        id: IDI,
        fileName: String? = nil,
        authors: [Author],
        year: Int?,
        title: String,
        publication: String? = nil,
        indexing: PublicationIndexing = .init(),
        doi: String? = nil,
        url: String? = nil,
        arxiv: String? = nil,
        publicationType: PublicationType = .unclassified,
        projects: [ProjectTag] = [],
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.authors = authors
        self.year = year
        self.title = title
        self.publication = publication
        self.indexing = indexing
        self.doi = doi.flatMap(DOI.normalize)
        self.url = url
        self.arxiv = arxiv
        self.publicationType = publicationType
        self.projects = projects
        self.provenance = provenance
    }
}

public enum DOI {
    /// Strips resolver prefixes and `doi:` labels. Case is preserved for display;
    /// compare DOIs with `DOI.same` (they are case-insensitive).
    /// Returns `nil` if the string does not look like a DOI.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("10."), s.contains("/") else { return nil }
        return s
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        guard let x = normalize(a), let y = normalize(b) else { return false }
        return x.caseInsensitiveCompare(y) == .orderedSame
    }

    /// Finds the first DOI embedded anywhere in a string (e.g. a publisher URL).
    public static func find(in text: String) -> String? {
        guard let range = text.range(of: #"10\.\d{4,9}/[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        var doi = String(text[range])
        while let last = doi.last, ".,;)".contains(last) { doi.removeLast() }
        return normalize(doi)
    }
}
