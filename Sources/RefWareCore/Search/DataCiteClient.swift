import Foundation

/// DataCite REST API (https://api.datacite.org) — the registry for Zenodo,
/// arXiv (10.48550), figshare, OSF and most dataset/preprint DOIs, which
/// Crossref does not know about.
public struct DataCiteClient: Sendable {
    public var http: HTTPClient
    public var baseURL = URL(string: "https://api.datacite.org")!

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func work(doi: String) async throws -> ResolvedMetadata? {
        guard let doi = DOI.normalize(doi) else { return nil }
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? doi
        let url = URL(string: "\(baseURL.absoluteString)/dois/\(encoded)")!
        let response = try await http.get(url, headers: ["Accept": "application/vnd.api+json", "User-Agent": "RefWare/0.1"])
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw SearchError.http(status: response.status, url: url) }
        do {
            return try JSONDecoder().decode(Envelope.self, from: response.data).data.attributes.metadata(doi: doi)
        } catch {
            throw SearchError.decoding(String(describing: error))
        }
    }

    struct Envelope: Decodable { var data: Item }
    struct Item: Decodable { var attributes: Attributes }

    struct Attributes: Decodable {
        struct Creator: Decodable { var name: String?; var givenName: String?; var familyName: String?; var nameType: String? }
        struct Title: Decodable { var title: String }
        struct Types: Decodable { var resourceTypeGeneral: String? }
        struct Container: Decodable { var title: String?; var volume: String?; var issue: String?; var firstPage: String?; var lastPage: String? }

        var doi: String?
        var url: String?
        var creators: [Creator]?
        var titles: [Title]?
        var publisher: Publisher?
        var publicationYear: Int?
        var types: Types?
        var container: Container?

        /// `publisher` is a string in older records and an object in newer ones.
        enum Publisher: Decodable {
            case name(String)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .name(s); return }
                struct Obj: Decodable { var name: String }
                self = .name(try c.decode(Obj.self).name)
            }
            var name: String { if case .name(let s) = self { return s }; return "" }
        }

        enum CodingKeys: String, CodingKey { case doi, url, creators, titles, publisher, publicationYear, types, container }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            doi = try c.decodeIfPresent(String.self, forKey: .doi)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            creators = try c.decodeIfPresent([Creator].self, forKey: .creators)
            titles = try c.decodeIfPresent([Title].self, forKey: .titles)
            publisher = try? c.decodeIfPresent(Publisher.self, forKey: .publisher)
            // publicationYear is an Int in the JSON:API response but a String in some records.
            if let y = try? c.decodeIfPresent(Int.self, forKey: .publicationYear) {
                publicationYear = y
            } else {
                publicationYear = (try? c.decodeIfPresent(String.self, forKey: .publicationYear)).flatMap { $0.flatMap(Int.init) }
            }
            types = try? c.decodeIfPresent(Types.self, forKey: .types)
            container = try? c.decodeIfPresent(Container.self, forKey: .container)
        }

        func metadata(doi: String) -> ResolvedMetadata? {
            guard let title = titles?.first?.title, !title.isEmpty else { return nil }
            let authors: [Author] = (creators ?? []).compactMap { cr in
                if let family = cr.familyName { return Author(family: family, given: cr.givenName) }
                guard let name = cr.name else { return nil }
                if cr.nameType == "Organizational" { return Author(family: name, isOrganization: true) }
                return WebMetadataReader.parseName(name)
            }
            let type: PublicationType = switch types?.resourceTypeGeneral {
            case "Preprint": .preprint
            case "Report": .report
            case "Book": .book
            case "BookChapter": .bookChapter
            default: .unclassified
            }
            var pages: String?
            if let fp = container?.firstPage { pages = container?.lastPage.map { "\(fp)-\($0)" } ?? fp }
            let isArXiv = doi.hasPrefix("10.48550/")
            var m = ResolvedMetadata(
                authors: authors, year: publicationYear, title: TextCleanup.clean(title),
                publication: container?.title ?? (isArXiv ? "arXiv" : publisher?.name),
                indexing: PublicationIndexing(volume: container?.volume, issue: container?.issue, pages: pages),
                doi: doi, url: url, arxiv: isArXiv ? ArXiv.id(in: doi) : nil,
                publicationType: isArXiv ? .preprint : type, source: .datacite, lookupKey: doi
            )
            m.yearsSeen = publicationYear.map { [$0] } ?? []
            return m
        }
    }
}
