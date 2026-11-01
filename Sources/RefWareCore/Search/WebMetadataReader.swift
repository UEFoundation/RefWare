import Foundation

/// Reads publisher-declared bibliographic metadata (Highwire `citation_*`
/// meta tags, used by Google Scholar) from a web page.
public enum WebMetadataReader {
    public struct PageMetadata: Equatable, Sendable {
        public var doi: String?
        public var metadata: ResolvedMetadata?
        /// `true` when the page declares scholarly `citation_*`/Dublin Core metadata;
        /// `false` when only general page metadata (Open Graph, `<title>`) was available.
        public var scholarly: Bool = false
    }

    public static func read(html: String, url: String) -> PageMetadata {
        let tags = metaTags(in: html)
        func first(_ names: String...) -> String? {
            for n in names { if let v = tags.first(where: { $0.name == n })?.content, !v.isEmpty { return v } }
            return nil
        }

        let doi = first("citation_doi", "dc.identifier", "prism.doi").flatMap(DOI.find)

        guard let title = first("citation_title", "dc.title") else {
            return generalMetadata(tags: tags, html: html, url: url, doi: doi)
        }
        let authors = tags.filter { $0.name == "citation_author" || $0.name == "dc.creator" }
            .map { parseName($0.content) }
        let year = first("citation_publication_date", "citation_date", "citation_online_date", "citation_year", "dc.date")
            .flatMap(yearIn)

        var pages: String?
        if let fp = first("citation_firstpage") {
            pages = first("citation_lastpage").map { "\(fp)-\($0)" } ?? fp
        }

        var metadata = ResolvedMetadata(
            authors: authors,
            year: year,
            title: TextCleanup.clean(title),
            publication: first("citation_journal_title", "citation_conference_title", "citation_publisher", "og:site_name").map(TextCleanup.clean),
            indexing: PublicationIndexing(volume: first("citation_volume"), issue: first("citation_issue"), pages: pages),
            doi: doi,
            url: url,
            source: .webMetadata,
            lookupKey: url
        )
        // arXiv: citation_date is v1, citation_online_date the latest version — both are citable years.
        metadata.yearsSeen = Array(Set(["citation_publication_date", "citation_date", "citation_online_date", "citation_year"]
            .compactMap { n in tags.first { $0.name == n }?.content }.compactMap(yearIn))).sorted()
        return PageMetadata(doi: doi, metadata: metadata, scholarly: true)
    }

    /// Fallback for blogs, vendor pages and videos: Open Graph / `<title>`.
    /// Authors are taken only from an explicit `author` meta tag.
    private static func generalMetadata(tags: [MetaTag], html: String, url: String, doi: String?) -> PageMetadata {
        func first(_ names: String...) -> String? {
            for n in names { if let v = tags.first(where: { $0.name == n })?.content, !v.isEmpty { return v } }
            return nil
        }
        let htmlTitle = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression)
            .map { String(html[$0]).replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression) }
        guard let title = first("og:title", "twitter:title") ?? htmlTitle.map(TextCleanup.clean), !title.isEmpty,
              !isInterstitial(title) else {
            return PageMetadata(doi: doi, metadata: nil)
        }
        let authors = tags.filter { $0.name == "author" && !$0.content.hasPrefix("http") }.map { parseName($0.content) }
        let year = first("article:published_time", "date", "publish_date", "og:updated_time").flatMap(yearIn)
        let metadata = ResolvedMetadata(
            authors: authors, year: year, title: TextCleanup.clean(title),
            publication: first("og:site_name").map(TextCleanup.clean) ?? CanonicalURL.host(url),
            doi: doi, url: url, source: .webPage, lookupKey: url
        )
        return PageMetadata(doi: doi, metadata: metadata, scholarly: false)
    }

    /// Bot checks, consent walls and error pages that return HTTP 200 but say
    /// nothing about the work. Their titles must never become references.
    static func isInterstitial(_ title: String) -> Bool {
        let t = title.lowercased()
        let markers = [
            "verifying your browser", "verify you are human", "just a moment", "attention required", "are you a robot",
            "access denied", "checking your browser", "captcha", "security check", "enable javascript", "page not found",
            "404 not found", "403 forbidden", "robot check", "cloudflare", "before you continue", "sign in", "log in",
        ]
        return markers.contains { t.contains($0) }
    }

    /// Stricter check for a rendered page's *text*: only challenge-page phrases,
    /// since ordinary pages say "Sign in" in their navigation.
    public static func isBotCheck(_ text: String) -> Bool {
        let t = text.prefix(600).lowercased()
        return ["verifying your browser", "verify you are human", "just a moment", "checking your browser", "are you a robot",
                "attention required", "captcha", "access denied", "enable javascript and cookies"].contains { t.contains($0) }
    }

    /// "Not found" pages served with a normal status (soft 404s).
    public static func isNotFoundPage(_ text: String) -> Bool {
        let t = text.prefix(800).lowercased()
        return ["page cannot be found", "page not found", "page could not be found", "this page doesn't exist", "this page does not exist",
                "404 not found", "error 404", "no longer available", "page you requested", "we can't find the page", "we couldn't find"].contains { t.contains($0) }
    }

    /// "Doe, Jane Q." or "Jane Q. Doe" → Author.
    static func parseName(_ raw: String) -> Author {
        let s = TextCleanup.clean(raw)
        if s.range(of: #"\b(Team|Group|Consortium|Collaboration|Lab|Labs|Inc\.?|Ltd\.?|LLC|Foundation|Organization|Organisation|Committee|Council|Institute)\b"#,
                   options: .regularExpression) != nil {
            return Author(family: s, isOrganization: true)
        }
        if let comma = s.firstIndex(of: ",") {
            return Author(family: String(s[..<comma]), given: String(s[s.index(after: comma)...]))
        }
        var words = s.split(separator: " ").map(String.init)
        guard words.count > 1 else { return Author(family: s) }
        let family = words.removeLast()
        return Author(family: family, given: words.joined(separator: " "))
    }

    private static func yearIn(_ s: String) -> Int? {
        guard let r = s.range(of: #"\b(1[5-9]|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    struct MetaTag { var name: String; var content: String }

    static func metaTags(in html: String) -> [MetaTag] {
        let tagRE = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive])
        let attrRE = try! NSRegularExpression(pattern: #"([a-zA-Z:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        var result: [MetaTag] = []
        for m in tagRE.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            var attrs: [String: String] = [:]
            for a in attrRE.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let k = Range(a.range(at: 1), in: tag) else { continue }
                let v = Range(a.range(at: 2), in: tag) ?? Range(a.range(at: 3), in: tag)
                attrs[tag[k].lowercased()] = v.map { TextCleanup.clean(String(tag[$0])) } ?? ""
            }
            if let name = attrs["name"] ?? attrs["property"], let content = attrs["content"] {
                result.append(MetaTag(name: name.lowercased(), content: content))
            }
        }
        return result
    }
}
