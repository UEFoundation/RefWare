import Foundation

/// APA 7–style formatter for inline citations and the reference list.
///
/// Formatting is computed over the *set* of references cited in a document so
/// that same-author/same-year works get stable `a`, `b`, … suffixes in both the
/// inline citation and the reference list.
public struct CitationFormatter: Sendable {
    public enum Markup: Sendable {
        /// No styling — for .txt output.
        case plain
        /// Publication name and volume wrapped in `*…*`.
        case markdown
    }

    public enum AuthorList: Equatable, Sendable {
        /// Up to `n` authors; beyond that, the first `n` then "et al." (UEF house style: 10).
        case upTo(Int)
        /// Every author, however many.
        case all
        /// APA 7: up to 20; with 21+, the first 19, an ellipsis, then the last.
        case apa7

        public static let uef = AuthorList.upTo(10)
    }

    public var markup: Markup
    public var authorList: AuthorList
    private let suffixes: [IDI: String]
    /// Works whose first authors share a surname and year but differ in initials:
    /// APA 7 §8.20 cites them with initials — (J. Zhao et al., 2025), (K. Zhao et al., 2025).
    private let needsInitials: Set<IDI>

    public init(references: [Reference], markup: Markup = .plain, authorList: AuthorList = .uef) {
        self.markup = markup
        self.authorList = authorList
        self.suffixes = Self.disambiguationSuffixes(for: references)
        var initials = Set<IDI>()
        let groups = Dictionary(grouping: references) { "\(Self.inlineAuthors($0).lowercased())|\($0.year.map(String.init) ?? "n.d.")" }
        for group in groups.values where Set(group.compactMap { $0.authors.first?.initials }).count > 1 {
            for r in group where r.authors.first?.isOrganization == false && !(r.authors.first?.initials.isEmpty ?? true) { initials.insert(r.id) }
        }
        self.needsInitials = initials
    }

    /// "Zhao et al." or, when needed, "J. Zhao et al.".
    private func inlineNames(_ ref: Reference) -> String {
        let names = Self.inlineAuthors(ref)
        guard needsInitials.contains(ref.id), let i = ref.authors.first?.initials, !i.isEmpty else { return names }
        return "\(i) \(names)"
    }

    // MARK: Inline

    /// `Smith, 2020` · `Smith & Jones, 2020` · `Smith et al., 2020` (no parentheses).
    public func inlineBody(_ ref: Reference) -> String {
        "\(inlineNames(ref)), \(yearLabel(ref))"
    }

    /// `(Smith, 2020)` or, for several, `(Jones et al., 2019; Smith, 2020)`.
    /// Multiple works are ordered alphabetically, as APA requires.
    public func inline(_ refs: [Reference]) -> String {
        var seen = Set<IDI>()
        let bodies = Self.sorted(refs.filter { seen.insert($0.id).inserted }).map(inlineBody) // [IDI 12, 12] cites once
        return "(\(bodies.joined(separator: "; ")))"
    }

    /// Narrative form: `Smith (2020)`, `Smith and Jones (2020)`, `Smith et al. (2020, p. 4)`.
    public func narrative(_ ref: Reference, locator: String? = nil, possessive: Bool = false) -> String {
        var names = ref.authors.count == 2 ? "\(ref.authors[0].family) and \(ref.authors[1].family)" : Self.inlineAuthors(ref)
        if needsInitials.contains(ref.id), let i = ref.authors.first?.initials, !i.isEmpty { names = "\(i) \(names)" }
        if possessive { names += "’s" }  // APA: Jones’s, not Jones’
        return "\(names) (\(yearLabel(ref))\(locator.map { ", \($0)" } ?? ""))"
    }

    // MARK: Reference list

    /// APA italics: periodicals (volume) and proceedings (pages) italicize the source;
    /// standalone works — preprints, reports, web pages, model cards — italicize the title.
    private func isStandalone(_ ref: Reference) -> Bool {
        ref.indexing.volume == nil && ref.indexing.pages == nil
    }

    public func referenceEntry(_ ref: Reference) -> String {
        var parts: [String] = []
        let title = isStandalone(ref) ? italicTitle(ref.title) : Self.terminated(ref.title)

        if ref.authors.isEmpty {
            // APA: with no author, the title moves into the author position.
            parts.append(title)
            parts.append("(\(yearLabel(ref))).")
        } else {
            parts.append(Self.terminated(Self.referenceAuthors(ref.authors, list: authorList)))
            parts.append("(\(yearLabel(ref))).")
            parts.append(title)
        }

        if let source = sourceElement(ref) { parts.append(source) }

        if let doi = ref.doi {
            parts.append("https://doi.org/\(doi)")
        } else if let url = ref.url {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    /// The full alphabetized reference list, one entry per line.
    /// One entry per line; in Markdown, a blank line between entries so each renders as its own paragraph.
    public func referenceList(_ refs: [Reference]) -> String {
        var seen = Set<IDI>()
        return Self.sorted(refs.filter { seen.insert($0.id).inserted }).map(referenceEntry).joined(separator: markup == .markdown ? "\n\n" : "\n")
    }

    // MARK: Pieces

    func yearLabel(_ ref: Reference) -> String {
        let suffix = suffixes[ref.id] ?? ""
        guard let year = ref.year else { return suffix.isEmpty ? "n.d." : "n.d.-\(suffix)" }
        return "\(year)\(suffix)"
    }

    /// Italic title with its terminal period outside the italics: `*Title*.` (`*Title?*` keeps its own mark).
    private func italicTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard markup == .markdown else { return Self.terminated(t) }
        if let last = t.last, "?!".contains(last) { return "*\(t)*" }
        let bare = t.hasSuffix(".") ? String(t.dropLast()) : t
        return "*\(bare)*."
    }

    /// `Publication, Vol(Issue), Pages.`
    private func sourceElement(_ ref: Reference) -> String? {
        guard let publication = ref.publication, !publication.isEmpty else { return nil }
        if isStandalone(ref) {
            let p = publication.trimmingCharacters(in: .whitespaces)
            return p.hasSuffix(".") ? p : p + "."
        }
        var s = italic(publication)
        var ix = ref.indexing
        // Registries sometimes zero-pad ("06(01), 01–26"); print 6(1), 1–26.
        let unpad = { (v: String) in v.replacingOccurrences(of: #"(?<![\d.])0+(\d)"#, with: "$1", options: .regularExpression) }
        ix.volume = ix.volume.map(unpad); ix.issue = ix.issue.map(unpad); ix.pages = ix.pages.map(unpad)
        if let volume = ix.volume {
            s += ", " + italic(volume)
            if let issue = ix.issue { s += "(\(issue))" }
        } else if let issue = ix.issue {
            s += ", (\(issue))"
        }
        if let pages = ix.pages {
            s += ", " + pages.replacingOccurrences(of: "-", with: "–")
        } else if let article = ix.articleNumber {
            s += ", Article \(article)"
        }
        return s + "."
    }

    private func italic(_ s: String) -> String {
        markup == .markdown ? "*\(s)*" : s
    }

    static func inlineAuthors(_ ref: Reference) -> String {
        let a = ref.authors
        switch a.count {
        case 0: return shortTitle(ref.title)
        case 1: return a[0].family
        case 2: return "\(a[0].family) & \(a[1].family)"
        default: return "\(a[0].family) et al."
        }
    }

    static func referenceAuthors(_ authors: [Author], list: AuthorList = .uef) -> String {
        let forms = authors.map(\.referenceForm)
        if case .upTo(let n) = list, forms.count > n {
            return forms.prefix(n).joined(separator: ", ") + ", et al."
        }
        switch forms.count {
        case 1: return forms[0]
        // The comma before "&" follows initials ("Smith, J., & Lee, K."), not a group name.
        case 2: return authors[0].isOrganization ? "\(forms[0]) & \(forms[1])" : "\(forms[0]), & \(forms[1])"
        case 21... where list == .apa7: return forms.prefix(19).joined(separator: ", ") + ", . . . " + forms.last!
        default: return forms.dropLast().joined(separator: ", ") + ", & " + forms.last!
        }
    }

    /// For author-less works APA cites the first few words of the title.
    private static func shortTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        let short = words.prefix(4).joined(separator: " ")
        return words.count > 4 ? "\u{201C}\(short)…\u{201D}" : "\u{201C}\(short)\u{201D}"
    }

    /// Adds a terminal period unless the text already ends in punctuation.
    private static func terminated(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".?!".contains(last) ? t : t + "."
    }

    // MARK: Ordering & disambiguation

    /// Alphabetical: first author family, initials, subsequent authors, then year, then title.
    public static func sorted(_ refs: [Reference]) -> [Reference] {
        refs.sorted { lhs, rhs in
            let l = sortKey(lhs), r = sortKey(rhs)
            for (a, b) in zip(l, r) {
                // No POSIX locale: with it, "MIT NANDA" sorted before "Meincke" (uppercase first).
                let c = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
                if c != .orderedSame { return c == .orderedAscending }
            }
            if l.count != r.count { return l.count < r.count }
            return lhs.id < rhs.id
        }
    }

    private static func sortKey(_ ref: Reference) -> [String] {
        let names = ref.authors.isEmpty
            ? [strippingArticle(ref.title)]
            : ref.authors.flatMap { [$0.family, $0.initials] }
        // Year is zero-padded so it compares correctly as text; n.d. sorts first per APA.
        let year = ref.year.map { String(format: "%05d", $0) } ?? "00000"
        return names + ["\u{0}", year, strippingArticle(ref.title)]
    }

    private static func strippingArticle(_ title: String) -> String {
        for article in ["A ", "An ", "The "] where title.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    /// Any two works whose inline citations would read identically get
    /// a/b/c suffixes, ordered by title.
    static func disambiguationSuffixes(for refs: [Reference]) -> [IDI: String] {
        // Same inline text *and* same first author (initials included): J. Zhao and K. Zhao
        // are different authors, which APA resolves with initials in the text, not a/b.
        let groups = Dictionary(grouping: refs) { ref in
            "\(inlineAuthors(ref).lowercased())|\(ref.authors.first?.initials ?? "")|\(ref.year.map(String.init) ?? "n.d.")"
        }
        var result: [IDI: String] = [:]
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted {
                let c = strippingArticle($0.title).localizedCaseInsensitiveCompare(strippingArticle($1.title))
                return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
            }
            for (i, ref) in ordered.enumerated() {
                result[ref.id] = suffixLetters(i)
            }
        }
        return result
    }

    /// 0 → a, 25 → z, 26 → aa …
    private static func suffixLetters(_ n: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var n = n, s = ""
        repeat {
            s = String(letters[n % 26]) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }
}
