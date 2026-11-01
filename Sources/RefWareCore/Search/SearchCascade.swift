import Foundation

/// What is known about a paper, e.g. from a transcript.
public struct SearchQuery: Sendable {
    public var doi: String?
    public var url: String?
    public var title: String?
    /// The identified claim the paper is cited for.
    public var claim: String?
    /// Publication outlet (journal, platform).
    public var outlet: String?
    public var author: String?

    public init(doi: String? = nil, url: String? = nil, title: String? = nil, claim: String? = nil, outlet: String? = nil, author: String? = nil) {
        self.doi = doi
        self.url = url
        self.title = title
        self.claim = claim
        self.outlet = outlet
        self.author = author
    }
}

/// The spec's search order: DOI → URL → Title → Identified claim → Publication outlet → Author.
public enum SearchStep: String, CaseIterable, Sendable {
    case doi, url, title, claim, outlet, author
}

public enum SearchOutcome: Sendable {
    /// Retrieved by an exact key (DOI, or a URL that declares its own metadata).
    /// Safe to store as verified.
    case exact(ResolvedMetadata, step: SearchStep)
    /// Fuzzy matches. A human must pick one before it enters the library.
    case candidates([ResolvedMetadata], step: SearchStep)
    case notFound
}

public struct SearchLogEntry: Sendable, CustomStringConvertible {
    public var step: SearchStep
    public var note: String
    public var description: String { "\(step.rawValue): \(note)" }
}

public struct SearchResult: Sendable {
    public var outcome: SearchOutcome
    public var log: [SearchLogEntry]
}

/// Runs the lookup cascade, stopping at the first step that yields anything.
/// Steps whose input is missing are skipped. Network errors on one step are
/// logged and the cascade continues to the next.
public struct SearchCascade: Sendable {
    public var crossref: CrossrefClient
    public var datacite: DataCiteClient
    public var http: HTTPClient
    public var candidateLimit: Int

    public init(crossref: CrossrefClient, http: HTTPClient = URLSessionHTTPClient(), candidateLimit: Int = 5) {
        self.crossref = crossref
        self.datacite = DataCiteClient(http: http)
        self.http = http
        self.candidateLimit = candidateLimit
    }

    /// Exact DOI lookup: Crossref first, then DataCite (Zenodo, arXiv, figshare…).
    public func lookup(doi: String) async throws -> ResolvedMetadata? {
        if let m = try await crossref.work(doi: doi) { return m }
        return try await datacite.work(doi: doi)
    }

    public func run(_ query: SearchQuery) async -> SearchResult {
        var log: [SearchLogEntry] = []
        for step in SearchStep.allCases {
            do {
                guard let outcome = try await attempt(step, query, &log) else { continue }
                return SearchResult(outcome: outcome, log: log)
            } catch {
                log.append(.init(step: step, note: "error — \(error)"))
            }
        }
        return SearchResult(outcome: .notFound, log: log)
    }

    private func attempt(_ step: SearchStep, _ q: SearchQuery, _ log: inout [SearchLogEntry]) async throws -> SearchOutcome? {
        switch step {
        case .doi:
            guard let raw = q.doi else { return nil }
            guard let doi = DOI.normalize(raw) else {
                log.append(.init(step: step, note: "\"\(raw)\" is not a DOI"))
                return nil
            }
            if let m = try await lookup(doi: doi) {
                log.append(.init(step: step, note: "\(m.source == .crossref ? "Crossref" : "DataCite") record for \(doi)"))
                return .exact(m, step: step)
            }
            log.append(.init(step: step, note: "no Crossref or DataCite record for \(doi)"))
            return nil

        case .url:
            guard let raw = q.url, var url = URL(string: raw) else { return nil }
            // arXiv HTML/PDF/mirror links all carry the same paper; the abstract
            // page is the one that declares citation metadata.
            let arxiv = ArXiv.id(in: raw)
            if let arxiv { url = ArXiv.absURL(arxiv) }
            func tagged(_ m: ResolvedMetadata) -> ResolvedMetadata {
                guard let arxiv else { return m }
                var m = m
                m.arxiv = arxiv
                if m.source != .crossref {
                    m.url = url.absoluteString
                    if m.publicationType == .unclassified { m.publicationType = .preprint }
                    // arXiv registers a DOI for every paper; APA cites the preprint as "arXiv. https://doi.org/10.48550/arXiv.…".
                    m.publication = "arXiv"
                    if m.doi == nil { m.doi = "10.48550/arXiv.\(arxiv)" }
                }
                return m
            }

            if arxiv == nil, let doi = DOI.find(in: raw), let m = try await lookup(doi: doi) {
                log.append(.init(step: step, note: "DOI \(doi) embedded in URL"))
                return .exact(m, step: step)
            }
            let response = try await http.get(url, headers: ["User-Agent": "RefWare/0.1", "Accept": "text/html"])
            guard response.status == 200 else { throw SearchError.http(status: response.status, url: url) }
            let html = String(decoding: response.data, as: UTF8.self)
            let page = WebMetadataReader.read(html: html, url: url.absoluteString)
            if let doi = page.doi, let m = try await lookup(doi: doi) {
                log.append(.init(step: step, note: "page declares DOI \(doi)"))
                return .exact(tagged(m), step: step)
            }
            if let m = page.metadata {
                log.append(.init(step: step, note: page.scholarly ? "page declares citation metadata" : "page declares only general web metadata"))
                return .exact(tagged(m), step: step)
            }
            log.append(.init(step: step, note: "page has no citation metadata"))
            return nil

        case .title:
            guard let title = q.title else { return nil }
            var fields = ["query.title": title]
            if let author = q.author { fields["query.author"] = author }
            return try await candidates(step, fields, rankingBy: title, &log)

        case .claim:
            guard let claim = q.claim else { return nil }
            return try await candidates(step, ["query.bibliographic": claim], rankingBy: nil, &log)

        case .outlet:
            guard let outlet = q.outlet else { return nil }
            var fields = ["query.container-title": outlet]
            if let author = q.author { fields["query.author"] = author }
            if let claim = q.claim { fields["query.bibliographic"] = claim }
            guard fields.count > 1 else {
                log.append(.init(step: step, note: "outlet alone is too broad; needs an author or claim"))
                return nil
            }
            return try await candidates(step, fields, rankingBy: nil, &log)

        case .author:
            guard let author = q.author else { return nil }
            return try await candidates(step, ["query.author": author], rankingBy: nil, &log)
        }
    }

    private func candidates(_ step: SearchStep, _ fields: [String: String], rankingBy title: String?, _ log: inout [SearchLogEntry]) async throws -> SearchOutcome? {
        var found = try await crossref.search(fields, rows: candidateLimit)
        log.append(.init(step: step, note: "\(found.count) candidate\(found.count == 1 ? "" : "s")"))
        guard !found.isEmpty else { return nil }
        // Float exact title matches to the top; otherwise keep Crossref's relevance order.
        if let title {
            let target = TextCleanup.comparable(title)
            let exact = found.filter { TextCleanup.comparable($0.title) == target }
            found = exact + found.filter { TextCleanup.comparable($0.title) != target }
        }
        return .candidates(found, step: step)
    }
}
