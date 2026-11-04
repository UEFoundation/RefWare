import Foundation

/// Imports a citation matrix — the shape research assistants (Gemini, ChatGPT…) produce
/// when asked to source a talk or paper section by section:
///
///     ### Slide 5–6: The ROI Gap
///     * **Claim:** Despite massive investment, enterprise ROI remains elusive …
///     * **Citations:**
///       * **Solow, R. (1987).** *We'd better watch out.* New York Times Book Review.
///         * *Why:* The original formulation of the productivity paradox …
///
/// Each **Claim:** becomes a claim; the works listed under it become its sources, linked
/// to library records where first author, year and title agree. An assistant's notes
/// about what a source *says* — statistics especially — are where invented details
/// hide, so a note stating figures becomes a claim of its own, tied to that one source.
public struct CitationMatrixImporter: Sendable {
    public var file: String

    public init(file: String) {
        self.file = file
    }

    /// A "Claim:" line followed somewhere by a "Citations:"/"Sources:" line.
    public static func looksLikeCitationMatrix(_ text: String) -> Bool {
        text.range(of: #"(?im)^\s*(?:[-*•]\s*)?\**\s*claim\s*:?\**\s*:?"#, options: .regularExpression) != nil
            && text.range(of: #"(?im)^\s*(?:[-*•]\s*)?\**\s*(citations?|sources?|references?|evidence)\s*:?\**\s*:?\s*$"#, options: .regularExpression) != nil
    }

    private static let claimRE = #"(?i)^\s*(?:[-*•]\s*)?\**\s*claim\s*:?\**\s*:?\s*"#
    private static let whyRE = #"(?i)^\s*(?:[-*•]\s*)?[*_]*\s*(why|note|relevance|supports?)\s*:?[*_]*\s*:?\s*"#
    private static let headingRE = #"^\s*#{1,4}\s+"#
    /// "2.8x", "85%", "85%+", "14 minutes", "19 percent"
    private static let statisticRE = #"\d+(?:\.\d+)?\s*(?:%|x\b|×|percent|times\b|-fold)|\$\s?\d"#

    public func claims(from text: String, library: Library, firstID: Int) -> ClaimsListImporter.Result {
        var out = ClaimsListImporter.Result(claims: [], unresolved: [], fragments: [])
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        struct Draft { var label: String; var line: Int; var text: String; var sources: [(source: ClaimSource, cite: String, why: [String])] = [] }
        var drafts: [Draft] = []
        var heading = ""
        var stop = false

        for (i, raw) in lines.enumerated() where !stop {
            let n = i + 1
            if raw.range(of: Self.headingRE, options: .regularExpression) != nil {
                heading = TranscriptImporter.plain(raw.replacingOccurrences(of: Self.headingRE, with: "", options: .regularExpression))
                // The bibliography that often follows is a reference list, not more claims.
                if heading.range(of: #"(?i)\b(references|bibliography|works cited)\b"#, options: .regularExpression) != nil { stop = true }
                continue
            }
            if raw.range(of: Self.claimRE, options: .regularExpression) != nil {
                let body = TranscriptImporter.plain(raw.replacingOccurrences(of: Self.claimRE, with: "", options: .regularExpression))
                if !body.isEmpty { drafts.append(Draft(label: heading.isEmpty ? "Claim \(drafts.count + 1)" : heading, line: n, text: body)) }
                continue
            }
            guard !drafts.isEmpty else { continue }
            if raw.range(of: Self.whyRE, options: .regularExpression) != nil {
                let note = TranscriptImporter.plain(raw.replacingOccurrences(of: Self.whyRE, with: "", options: .regularExpression))
                if !note.isEmpty, !drafts[drafts.count - 1].sources.isEmpty { drafts[drafts.count - 1].sources[drafts[drafts.count - 1].sources.count - 1].why.append(note) }
                continue
            }
            // A cited work: a list item with a year in it ("**Solow, R. (1987).** *Title.* Venue.").
            // (Not `plain`, which would read "Report 2025." as a numbered-list marker.)
            let item = ManuscriptParser.withoutEmphasis(raw)
                .replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard raw.range(of: #"^\s*[-*•]\s"#, options: .regularExpression) != nil,
                  item.range(of: #"\((?:19|20)\d{2}"#, options: .regularExpression) != nil else { continue }
            let entry = ManuscriptParser.parseEntry(item, line: n)
            let cite = Self.shortCite(entry, fallback: item)
            if let ref = Self.resolve(entry, in: library) {
                guard !drafts[drafts.count - 1].sources.contains(where: { $0.source.reference == ref.id }) else { continue }
                drafts[drafts.count - 1].sources.append((ClaimSource(url: ref.doi.map { "https://doi.org/\($0)" } ?? ref.url, title: ref.title, reference: ref.id), cite, []))
            } else {
                drafts[drafts.count - 1].sources.append((ClaimSource(title: item), cite, []))
                let note = "\(cite)\(entry.title.map { " — “\($0)”" } ?? "") not in the library"
                if !out.unresolved.contains(note) { out.unresolved.append(note) }
            }
        }

        for d in drafts {
            let notes = d.sources.filter { !$0.why.isEmpty }.map { "\($0.cite): \($0.why.joined(separator: " "))" }
            var flags: [ClaimFlag] = []
            if d.sources.contains(where: { $0.source.reference == nil && $0.source.title != nil }) { flags.append(.unlinkedTitle) }
            if d.sources.isEmpty { flags.append(.uncitedEvidence) }
            out.claims.append(Claim(id: "C\(firstID + out.claims.count)", text: d.text,
                                    origin: ClaimOrigin(file: file, line: d.line, speaker: nil, label: d.label),
                                    sources: d.sources.map(\.source), flags: flags,
                                    note: notes.isEmpty ? nil : "Assistant's notes on the sources:\n" + notes.map { "- \($0)" }.joined(separator: "\n")))
            // Figures attributed to one source: check them against that source.
            for s in d.sources {
                for w in s.why where w.range(of: Self.statisticRE, options: .regularExpression) != nil {
                    out.claims.append(Claim(id: "C\(firstID + out.claims.count)", text: "\(s.cite): \(w)",
                                            origin: ClaimOrigin(file: file, line: d.line, speaker: nil, label: "\(d.label) — figure attributed to \(s.cite)"),
                                            sources: [s.source], flags: s.source.reference == nil ? [.unlinkedTitle] : []))
                }
            }
        }
        return out
    }

    /// "Stanford HAI" ≈ "Stanford Institute for Human-Centered Artificial Intelligence (HAI)";
    /// "Deloitte" ≈ "Deloitte Global". Every word of the shorter name appears in the longer.
    static func sameOrganization(_ a: String, _ b: String) -> Bool {
        let words = { (s: String) in Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !["the", "of", "and", "for", "inc", "llc", "co"].contains($0) }) }
        let (x, y) = (words(a), words(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.isSubset(of: y) || y.isSubset(of: x)
    }

    /// "Trist & Bamforth (1951)", "Varela et al. (1991)", "Deloitte Global (2025)".
    static func shortCite(_ e: ParsedEntry, fallback: String) -> String {
        let y = e.year.map(String.init) ?? "n.d."
        let names = e.authors.map(\.family)
        switch names.count {
        case 0:
            // "Future Talent / Thomson Reuters (2025/2026). Future of…" → up to the year's closing parenthesis.
            if let r = fallback.range(of: #"^[^()]{1,80}\([^)]{1,20}\)"#, options: .regularExpression) { return String(fallback[r]) }
            return String(fallback.prefix(60))
        case 1: return "\(names[0]) (\(y))"
        case 2: return "\(names[0]) & \(names[1]) (\(y))"
        default: return "\(names[0]) et al. (\(y))"
        }
    }

    /// First author (or organization) and year must agree; where several records do,
    /// the title decides. Never guesses between candidates.
    static func resolve(_ e: ParsedEntry, in library: Library) -> Reference? {
        guard let lead = e.authors.first?.family, let year = e.year else { return nil }
        let byAuthor = library.references.values.filter { r in
            guard r.year == year, let f = r.authors.first else { return false }
            return ManuscriptAuditor.sameName(f.family, lead) || (f.isOrganization && Self.sameOrganization(lead, f.family))
        }
        guard let title = e.title.map(TextCleanup.comparable), !title.isEmpty else { return byAuthor.count == 1 ? byAuthor.first : nil }
        let byTitle = byAuthor.filter { r in
            let t = TextCleanup.comparable(r.title)
            return t == title || t.hasPrefix(title) || title.hasPrefix(t)
        }
        // Same author and year but a different title is a different work (Deloitte publishes many 2025 reports).
        return byTitle.count == 1 ? byTitle.first : nil
    }
}
