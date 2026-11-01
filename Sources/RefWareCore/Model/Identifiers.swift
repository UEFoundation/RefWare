import Foundation

public enum ArXiv {
    private static let hosts = ["arxiv.org", "export.arxiv.org", "alphaxiv.org", "ui.adsabs.harvard.edu"]
    private static let newStyle = #"(\d{4}\.\d{4,5})(?:v\d+)?"#
    private static let oldStyle = #"([a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?"#

    /// Extracts a version-less arXiv identifier from an arXiv/alphaXiv/ADS URL,
    /// an `arXiv:` label, or an arXiv DOI (`10.48550/arXiv.…`). Returns `nil`
    /// for anything else — a bare number elsewhere is never treated as an arXiv ID.
    public static func id(in text: String) -> String? {
        let lower = text.lowercased()
        let host = URL(string: text)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        let onArXivHost = host.map { h in hosts.contains { h == $0 || h.hasSuffix("." + $0) } } ?? false
        guard onArXivHost || lower.contains("arxiv:") || lower.contains("10.48550/arxiv.") else { return nil }
        for pattern in [newStyle, oldStyle] {
            if let r = text.range(of: pattern, options: .regularExpression),
               let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: String(text[r]), range: NSRange(location: 0, length: text[r].utf16.count)),
               let idRange = Range(m.range(at: 1), in: String(text[r])) {
                return String(String(text[r])[idRange])
            }
        }
        return nil
    }

    public static func absURL(_ id: String) -> URL { URL(string: "https://arxiv.org/abs/\(id)")! }
    public static func pdfURL(_ id: String) -> URL { URL(string: "https://arxiv.org/pdf/\(id)")! }
}

public enum CanonicalURL {
    /// Comparable form of a URL: arXiv links collapse to `arxiv:<id>`; others
    /// drop scheme, `www.`, fragment, and trailing slash.
    public static func key(_ raw: String) -> String {
        if let id = ArXiv.id(in: raw) { return "arxiv:\(id)" }
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)), let host = c.host else {
            return raw.lowercased()
        }
        c.fragment = nil
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = c.percentEncodedQuery.map { "?\($0)" } ?? ""
        return host.lowercased().replacingOccurrences(of: "www.", with: "") + path + query
    }

    public static func host(_ raw: String) -> String? {
        URL(string: raw)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }
}
