import Foundation

/// Imports anything that lists works: a bibliography, a reading list, or an annotated list
/// where each item names a source and says something about it.
///
///     1. Greshake et al. (2023), "Not what you've signed up for: …", arXiv:2302.12173. The
///        foundational paper on indirect injection: …
///     - Ashby, W. R. (1956). An introduction to cybernetics. Chapman & Hall.
///
/// References come first: each item is rewritten as a standard reference line and checked by
/// the audit (DOI, arXiv, exact title + first author, linked web page). What an item *says*
/// about its source becomes a claim linked to that source, for a person to verify.
public enum ReferenceListImporter {
    public struct Item: Sendable, Equatable {
        /// 1-based line in the file.
        public var line: Int
        /// The item as written (Markdown emphasis removed).
        public var text: String
        /// A standard reference line built from the item, for the audit.
        public var reference: String
        /// What the item says about the work, beyond naming it.
        public var annotation: String?
        /// Short label for messages ("Greshake et al. (2023)").
        public var label: String
    }

    public struct Result: Sendable {
        public var added: [IDI] = []
        public var reused: [IDI] = []
        public var unverified: [IDI] = []
        public var claims: [Claim] = []
        /// Items whose reference couldn't be added (e.g. no usable title).
        public var skipped: [String] = []
        /// Identifiers that point to a different work, and similar problems.
        public var warnings: [String] = []
    }

    // MARK: Finding items

    private static let bullet = #"^\s*(?:\d+[.)]|[-*•+])\s+"#
    private static let arXivRE = #"(?i)arxiv(?:\.org/(?:abs|pdf)/|:\s*)(\d{4}\.\d{4,5})(?:v\d+)?"#
    private static let urlRE = #"https?://[^\s)>\]]+"#
    /// A bare web address in prose: "genai.owasp.org", "simonwillison.net/tags/prompt-injection".
    private static let bareURLRE = #"\b(?:[a-z0-9-]+\.)+(?:org|com|net|edu|gov|io|ai|dev|info|int|ac\.uk|co\.uk)(?:/[^\s,;)\]]*[^\s,;.)\]])?"#

    /// Items that name a work, in file order.
    public static func items(in text: String) -> [Item] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [(line: Int, lines: [String])] = []
        let hasList = lines.contains { $0.range(of: bullet, options: .regularExpression) != nil }
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if !hasList { blocks.append((i + 2, [])) }; continue }
            if t.hasPrefix("#") || t.hasPrefix("---") || t.hasPrefix("|") { blocks.append((i + 2, [])); continue }
            let startsItem = raw.range(of: bullet, options: .regularExpression) != nil
            // Without a list, one reference per line when lines look like reference entries.
            let entryLine = !hasList && looksLikeReferenceLine(t)
            if startsItem || entryLine || blocks.isEmpty || blocks[blocks.count - 1].lines.isEmpty {
                blocks.append((i + 1, [raw.replacingOccurrences(of: bullet, with: "", options: .regularExpression)]))
            } else {
                blocks[blocks.count - 1].lines.append(t)
            }
        }
        return blocks.filter { !$0.lines.isEmpty }.compactMap { item(from: $0.lines, line: $0.line) }
    }

    /// True when the file lists at least one identifiable work.
    public static func looksLikeReferenceList(_ text: String) -> Bool { !items(in: text).isEmpty }

    /// "Surname, I." / "Org. (2025)." / "Name (2020)." — the shape of a reference-list entry.
    static func looksLikeReferenceLine(_ t: String) -> Bool {
        let s = ManuscriptParser.withoutEmphasis(t)
        return s.range(of: #"^\p{Lu}[\p{L}'’ -]*,\s*\p{Lu}\."#, options: .regularExpression) != nil
            || s.range(of: #"^[^()]{1,160}\(\s*(?:19|20)\d{2}[a-z]?(?:,[^)]*)?\)\s*\."#, options: .regularExpression) != nil
    }

    static func item(from lines: [String], line: Int) -> Item? {
        let first = clean(lines[0])
        let rest = lines.dropFirst().map(clean).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let whole = rest.isEmpty ? first : first + " " + rest

        // A formal entry: the first line is the reference; later lines are the annotation.
        if looksLikeReferenceLine(first) {
            let parsed = ManuscriptParser.parseEntry(first, line: line)
            guard parsed.year != nil, parsed.title != nil else { return nil }
            return Item(line: line, text: whole, reference: withIdentifiers(first, from: first),
                        annotation: rest.isEmpty ? nil : rest, label: shortLabel(parsed, fallback: first))
        }

        // Prose: the first sentence names the work; the rest says something about it.
        let sentences = ManuscriptAudit.sentences(whole)
        guard let lead = sentences.first else { return nil }
        let ids = identifiers(in: whole)
        let quoted = whole.firstMatch(of: /["“]([^"”]{8,300})["”]/).map { String($0.1) }
        let year = lead.firstMatch(of: /\((?:[A-Z][a-z]+\.?\s+)?((?:19|20)\d{2})/).flatMap { Int($0.1) }
            ?? whole.firstMatch(of: /\((?:[A-Z][a-z]+\s+)?((?:19|20)\d{2})/).flatMap { Int($0.1) }
        // Something has to identify a work: an identifier, or a year with a title.
        guard ids.doi != nil || ids.arXiv != nil || (year != nil && (quoted != nil || hasTitleSegment(lead))) || ids.url != nil else { return nil }

        let (authors, title) = authorsAndTitle(lead: lead, quoted: quoted)
        guard let title, !title.isEmpty else { return nil }
        var ref = authors.isEmpty ? "\(title). (\(year.map(String.init) ?? "n.d.")). " : "\(authors) (\(year.map(String.init) ?? "n.d.")). \(title). "
        if let doi = ids.doi { ref += "https://doi.org/\(doi)" }
        else if let a = ids.arXiv { ref += "https://doi.org/10.48550/arXiv.\(a)" }   // every arXiv paper has this DataCite DOI
        else if let u = ids.url, quoted == nil || u.contains(where: { _ in false }) { ref += u }
        let annotation = sentences.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Item(line: line, text: whole, reference: ref.trimmingCharacters(in: .whitespaces),
                    annotation: annotation.isEmpty ? nil : annotation,
                    label: "\(authors.isEmpty ? title.prefix(50) + "" : authors) (\(year.map(String.init) ?? "n.d."))")
    }

    // MARK: Parts of an item

    static func clean(_ s: String) -> String {
        ManuscriptParser.withoutEmphasis(s)
            .replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: "$1 $2", options: .regularExpression)  // [text](url)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func identifiers(in s: String) -> (doi: String?, arXiv: String?, url: String?) {
        let doi = DOI.find(in: s)
        let arXiv = s.firstMatch(of: try! Regex(arXivRE)).flatMap { $0.output[1].substring.map(String.init) }
        var url = s.firstMatch(of: try! Regex(urlRE)).map { String($0.output[0].substring ?? "") }
        if url == nil, let m = s.firstMatch(of: try! Regex(bareURLRE)), let bare = m.output[0].substring {
            url = "https://" + bare
        }
        return (doi, arXiv, url?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
    }

    /// Adds a DOI for an arXiv ID written in a formal entry that has no DOI of its own.
    static func withIdentifiers(_ entry: String, from s: String) -> String {
        let ids = identifiers(in: s)
        if ids.doi == nil, let a = ids.arXiv { return entry + " https://doi.org/10.48550/arXiv.\(a)" }
        return entry
    }

    /// A lead like "NIST AI 100-2 (2025 edition), Adversarial Machine Learning: …".
    static func hasTitleSegment(_ lead: String) -> Bool {
        lead.range(of: #"\),\s+\p{Lu}[^.]{8,}"#, options: .regularExpression) != nil
            || lead.range(of: #"^\p{Lu}[^,(]{8,}"#, options: .regularExpression) != nil
    }

    /// Authors as an entry would write them, and the work's title, from a prose lead.
    static func authorsAndTitle(lead: String, quoted: String?) -> (String, String?) {
        var authors = ""
        // "Greshake et al. (2023)", "Smith and Jones (2020)", "Smith & Jones (2020)"
        if let m = lead.firstMatch(of: /^(\p{Lu}[\p{L}'’-]+(?:\s+(?:et al\.|and \p{Lu}[\p{L}'’-]+|& \p{Lu}[\p{L}'’-]+))?)\s*\(/) {
            authors = String(m.1)
        // "Simon Willison's writing"
        } else if let m = lead.firstMatch(of: /^(\p{Lu}\p{Ll}+(?:\s+\p{Lu}\.)?\s+\p{Lu}[\p{L}'’-]+)['’]s\b/) {
            let parts = m.1.split(separator: " ")
            authors = "\(parts.last!), \(parts.dropLast().map { "\($0.prefix(1))." }.joined(separator: " "))"
        // "OWASP Top 10 …", "NIST AI 100-2 …": an organization's acronym
        } else if let m = lead.firstMatch(of: /^(\p{Lu}{2,}[A-Za-z]*)\b/) {
            authors = String(m.1)
        }
        if let quoted { return (authors, quoted.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))) }
        // "(2025 edition), Title of the Work." — the title follows the parenthesis.
        if let m = lead.firstMatch(of: /\),\s+(\p{Lu}[^.]{8,})\.?/) {
            var t = String(m.1)
            if let cut = t.range(of: #"\s+(?:at|in|from)\s+(?:[a-z0-9-]+\.)+[a-z]{2,}.*$"#, options: .regularExpression) { t.removeSubrange(cut) }
            // "entry LLM01: Prompt Injection" names a section, not the work.
            if t.range(of: #"^(?i)(entry|section|chapter)\b"#, options: .regularExpression) == nil { return (authors, t) }
        }
        // Otherwise the lead up to its first parenthesis or comma is the title.
        let head = lead.components(separatedBy: CharacterSet(charactersIn: "(,")).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = head.replacingOccurrences(of: #"['’]s writing$"#, with: "", options: .regularExpression)
        return (authors, title.count >= 6 ? title.trimmingCharacters(in: CharacterSet(charactersIn: " .")) : nil)
    }

    static func shortLabel(_ e: ParsedEntry, fallback: String) -> String {
        let y = e.year.map(String.init) ?? "n.d."
        switch e.authors.count {
        case 0: return String(fallback.prefix(60))
        case 1: return "\(e.authors[0].family) (\(y))"
        case 2: return "\(e.authors[0].family) & \(e.authors[1].family) (\(y))"
        default: return "\(e.authors[0].family) et al. (\(y))"
        }
    }

    // MARK: Checking and adding

    /// The items as a reference list the audit can check, one entry per item, in order.
    public static func auditText(for items: [Item]) -> String {
        "References\n" + items.map(\.reference).joined(separator: "\n")
    }

    /// Adds the audited references (verified where a registry or page confirms them, otherwise
    /// as written and unverified) and turns annotations into claims linked to their works.
    public static func apply(_ items: [Item], audit: ManuscriptAudit, file: String, library: inout Library,
                             project: String, subproject: String?, firstClaimID: Int) -> Result {
        var out = Result()
        var audit = audit
        let (added, reused) = audit.importVerified(into: &library, project: project, includeUnverified: true, subproject: subproject)
        out.added = added
        out.reused = reused
        out.unverified = added.filter { library[$0]?.provenance?.verified != true }
        out.warnings = audit.importWarnings
        // The audit text has the heading on line 1, so item k is on line k + 2.
        for (k, item) in items.enumerated() {
            let entry = audit.entries.first { $0.entry.line == k + 2 }
            guard let id = entry?.importedAs, let ref = library[id] else {
                out.skipped.append(item.label)
                continue
            }
            guard let note = item.annotation, note.split(separator: " ").count >= 4 else { continue }
            let label = item.label
            out.claims.append(Claim(id: "C\(firstClaimID + out.claims.count)", text: note,
                                    origin: ClaimOrigin(file: file, line: item.line, speaker: nil, label: label),
                                    sources: [ClaimSource(url: ref.doi.map { "https://doi.org/\($0)" } ?? ref.url, title: ref.title, reference: id)],
                                    note: "What the list said about \(label). Check it against the source before relying on it."))
        }
        return out
    }
}
