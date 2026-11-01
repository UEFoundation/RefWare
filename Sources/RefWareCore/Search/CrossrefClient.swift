import Foundation

/// Crossref REST API client (https://api.crossref.org).
public struct CrossrefClient: Sendable {
    public var http: HTTPClient
    /// Contact address for Crossref's "polite" pool. Strongly recommended.
    public var mailto: String?
    public var baseURL = URL(string: "https://api.crossref.org")!

    public init(http: HTTPClient = URLSessionHTTPClient(), mailto: String? = nil) {
        self.http = http
        self.mailto = mailto
    }

    /// Exact lookup by DOI. Returns `nil` if Crossref has no record (HTTP 404).
    public func work(doi: String) async throws -> ResolvedMetadata? {
        guard let doi = DOI.normalize(doi) else { return nil }
        // DOIs may contain characters that must be percent-encoded in a path segment.
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? doi
        let url = URL(string: "\(baseURL.absoluteString)/works/\(encoded)")!
        let response = try await http.get(withMailto(url), headers: headers)
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw SearchError.http(status: response.status, url: url) }
        do {
            let envelope = try JSONDecoder().decode(Envelope<Work>.self, from: response.data)
            return envelope.message.metadata(lookupKey: doi)
        } catch {
            throw SearchError.decoding(String(describing: error))
        }
    }

    /// Field-qualified search, e.g. `["query.title": "…", "query.author": "…"]`.
    public func search(_ fields: [String: String], rows: Int = 5) async throws -> [ResolvedMetadata] {
        var components = URLComponents(url: baseURL.appendingPathComponent("works"), resolvingAgainstBaseURL: false)!
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "rows", value: String(rows))]
        let url = withMailto(components.url!)
        let response = try await http.get(url, headers: headers)
        guard response.status == 200 else { throw SearchError.http(status: response.status, url: url) }
        do {
            let envelope = try JSONDecoder().decode(Envelope<WorkList>.self, from: response.data)
            let key = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            return envelope.message.items.compactMap { $0.metadata(lookupKey: key) }
        } catch {
            throw SearchError.decoding(String(describing: error))
        }
    }

    private var headers: [String: String] {
        let contact = mailto.map { " (mailto:\($0))" } ?? ""
        return ["User-Agent": "RefWare/0.1\(contact)", "Accept": "application/json"]
    }

    private func withMailto(_ url: URL) -> URL {
        guard let mailto, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "mailto", value: mailto)]
        return c.url ?? url
    }

    // MARK: Wire format

    struct Envelope<T: Decodable>: Decodable { var message: T }
    struct WorkList: Decodable { var items: [Work] }

    struct Work: Decodable {
        struct Person: Decodable { var family: String?; var given: String?; var name: String? }
        struct DateParts: Decodable {
            var dateParts: [[Int?]]?
            enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
            var year: Int? { dateParts?.first?.first ?? nil }
        }

        var DOI: String?
        var URL: String?
        var title: [String]?
        var subtitle: [String]?
        var containerTitle: [String]?
        var shortContainerTitle: [String]?
        var author: [Person]?
        var issued: DateParts?
        var publishedPrint: DateParts?
        var publishedOnline: DateParts?
        var volume: String?
        var issue: String?
        var page: String?
        var articleNumber: String?
        var type: String?

        enum CodingKeys: String, CodingKey {
            case DOI, URL, title, subtitle, author, issued, volume, issue, page, type
            case containerTitle = "container-title"
            case shortContainerTitle = "short-container-title"
            case publishedPrint = "published-print"
            case publishedOnline = "published-online"
            case articleNumber = "article-number"
        }

        func metadata(lookupKey: String) -> ResolvedMetadata? {
            guard var rawTitle = title?.first, !rawTitle.isEmpty else { return nil }
            // Crossref often keeps the subtitle separately; the cited title is "Title: Subtitle".
            if let sub = subtitle?.first, !sub.isEmpty,
               !TextCleanup.comparable(rawTitle).contains(TextCleanup.comparable(sub)) {
                rawTitle += ": " + sub
            }
            let authors: [Author] = (author ?? []).compactMap { p in
                if let family = p.family { return Author(family: TextCleanup.clean(family), given: p.given.map(TextCleanup.clean)) }
                // Some publishers deposit affiliations as unnamed "authors"; those aren't authors.
                if let name = p.name, !Self.looksLikeAffiliation(name) { return Author(family: TextCleanup.clean(name), isOrganization: true) }
                return nil
            }
            var m = ResolvedMetadata(
                authors: authors,
                year: issued?.year ?? publishedPrint?.year ?? publishedOnline?.year,
                title: TextCleanup.clean(rawTitle),
                publication: containerTitle?.first.map(TextCleanup.clean),
                indexing: PublicationIndexing(volume: volume, issue: issue, pages: page, articleNumber: articleNumber),
                doi: DOI,
                url: URL,
                publicationType: Self.publicationType(type),
                source: .crossref,
                lookupKey: lookupKey
            )
            m.yearsSeen = Array(Set([issued?.year, publishedPrint?.year, publishedOnline?.year].compactMap { $0 })).sorted()
            m.publicationAliases = (containerTitle?.dropFirst().map { $0 } ?? []) + (shortContainerTitle ?? [])
            return m
        }

        static func looksLikeAffiliation(_ name: String) -> Bool {
            name.contains(",") || name.range(of: #"\b(University|School|Institute|Laboratory|Department|College|Faculty|Centre|Center|Academy)\b"#,
                                             options: [.regularExpression, .caseInsensitive]) != nil
        }

        /// Only types Crossref states unambiguously are mapped. A Crossref
        /// "journal-article" does not establish peer review, so it stays unclassified.
        static func publicationType(_ type: String?) -> PublicationType {
            switch type {
            case "posted-content": .preprint
            case "book", "monograph", "edited-book": .book
            case "book-chapter": .bookChapter
            case "report": .report
            default: .unclassified
            }
        }
    }
}
