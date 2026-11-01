import Foundation

/// Imports a claims list — the shape drafting collaborators (and RefWare's own
/// export) produce:
///
///     ## C5
///     > Developers took 19 percent longer … (Becker et al., 2025).
///
///     - In-text citation(s): (Becker et al., 2025)
///
/// Each claim's citations are linked to library records by first author (or
/// organization) and year, so claims arrive connected to their PDFs.
public struct ClaimsListImporter: Sendable {
    public struct Result: Sendable {
        public var claims: [Claim]
        /// "C5: Zhang, 2025 — no matching record" etc.
        public var unresolved: [String]
        /// Original labels whose text looks cut off.
        public var fragments: [String]
    }

    public var file: String

    public init(file: String) {
        self.file = file
    }

    /// True when the text looks like a claims list rather than a chat transcript.
    public static func looksLikeClaimsList(_ text: String) -> Bool {
        text.range(of: #"(?m)^#{2,3}\s*C\d+\s*$"#, options: .regularExpression) != nil
    }

    public func claims(from text: String, library: Library, firstID: Int) -> Result {
        var out = Result(claims: [], unresolved: [], fragments: [])
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [(label: String, line: Int, body: [String])] = []
        for (i, l) in lines.enumerated() {
            if let r = l.range(of: #"^#{2,3}\s*(C\d+)\s*$"#, options: .regularExpression) {
                blocks.append((String(l[r]).trimmingCharacters(in: CharacterSet(charactersIn: "# ")), i + 1, []))
            } else if l.hasPrefix("## ") || l.hasPrefix("# ") {
                // A non-claim heading ends the current block.
                if !blocks.isEmpty, !blocks[blocks.count - 1].body.isEmpty { blocks.append(("", i + 1, [])) }
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].body.append(l)
            }
        }

        for b in blocks where !b.label.isEmpty {
            let quoted = b.body.filter { $0.hasPrefix(">") }
                .map { $0.drop(while: { $0 == ">" || $0 == " " }) }.joined(separator: " ")
            let sentence = TranscriptImporter.plain(String(quoted)).replacingOccurrences(of: "\\$", with: "$")
            guard !sentence.isEmpty else { continue }
            let citeLine = b.body.first { $0.range(of: #"(?i)in-?text citations?"#, options: .regularExpression) != nil } ?? ""

            // Citations from the sentence and the citations line, de-duplicated.
            var cites: [InTextCitation] = []
            for c in ManuscriptParser.citations(in: sentence, line: b.line) + ManuscriptParser.citations(in: citeLine, line: b.line)
            where !cites.contains(where: { $0.names == c.names && $0.year == c.year }) {
                cites.append(c)
            }

            var sources: [ClaimSource] = []
            for c in cites {
                if let ref = Self.resolve(c, in: library) {
                    if !sources.contains(where: { $0.reference == ref.id }) { sources.append(ClaimSource(url: ref.doi.map { "https://doi.org/\($0)" } ?? ref.url, title: ref.title, reference: ref.id)) }
                } else {
                    let hint = Self.hint(c, in: library)
                    sources.append(ClaimSource(title: "\(c.raw) — \(hint)"))
                    out.unresolved.append("\(b.label): \(c.raw) — \(hint)")
                }
            }

            var flags: [ClaimFlag] = []
            let words = sentence.split(separator: " ").count
            let startsBroken = sentence.first.map { $0.isLowercase || ")].,;".contains($0) } ?? true
                || sentence.range(of: #"^\p{Lu}[\p{L}'’-]*( et al\.)?,? (19|20)\d{2}\)"#, options: .regularExpression) != nil
            let endsBroken = !(sentence.last.map { ".?!”\")".contains($0) } ?? false)
            if words < 5 || startsBroken || endsBroken {
                flags.append(.fragment)
                out.fragments.append(b.label)
            }
            if sources.isEmpty && cites.isEmpty && words >= 5 { flags.append(.uncitedEvidence) }

            out.claims.append(Claim(id: "C\(firstID + out.claims.count)", text: sentence,
                                    origin: ClaimOrigin(file: file, line: b.line, speaker: nil, label: b.label),
                                    sources: sources, flags: flags))
        }
        return out
    }

    /// First author (or organization, incl. acronym) + year, exactly.
    static func resolve(_ c: InTextCitation, in library: Library) -> Reference? {
        guard let first = c.names.first else { return nil }
        let matches = library.references.values.filter { r in
            guard let lead = r.authors.first, r.year == c.year else { return false }
            return ManuscriptAuditor.sameName(lead.family, first)
                || (lead.isOrganization && (ManuscriptAuditor.isAcronym(first, of: lead.family)
                    || lead.family.lowercased().hasPrefix(first.lowercased())))
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Why a citation didn't resolve, in plain words.
    static func hint(_ c: InTextCitation, in library: Library) -> String {
        guard let first = c.names.first else { return "no author" }
        let byAuthor = library.references.values.filter { $0.authors.first.map { ManuscriptAuditor.sameName($0.family, first) } ?? false }
        if let other = byAuthor.first, byAuthor.count == 1 {
            return "no \(first) \(c.year.map(String.init) ?? "n.d.") in the library — IDI \(other.id) is \(first) (\(other.year.map(String.init) ?? "n.d."))"
        }
        if byAuthor.count > 1, c.year != nil, byAuthor.filter({ $0.year == c.year }).count > 1 { return "ambiguous — several \(first) \(c.year!) records" }
        if let co = library.references.values.first(where: { r in r.year == c.year && r.authors.dropFirst().contains { ManuscriptAuditor.sameName($0.family, first) } }) {
            return "no record led by \(first); a \(first) is a co-author of IDI \(co.id) (\(co.authors.first?.family ?? "?"), \(co.year.map(String.init) ?? "n.d."))"
        }
        return "no matching record in the library"
    }
}
