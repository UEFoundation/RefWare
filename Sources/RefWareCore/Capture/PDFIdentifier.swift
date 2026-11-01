import Foundation

/// A proposed identity for a PDF, with the evidence behind it.
public struct IdentCandidate: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// A record already in the library.
        case existing(IDI)
        /// A registry record not yet in the library.
        case registry(ResolvedMetadata)
    }

    public var kind: Kind
    public var evidence: String
    /// Strong = an exact key or exact title found *in the PDF's own text*.
    public var strong: Bool

    public init(kind: Kind, evidence: String, strong: Bool) {
        self.kind = kind
        self.evidence = evidence
        self.strong = strong
    }

    /// A stable key for applying this suggestion (`--apply <key>`), unlike its list number,
    /// which can shift between runs: `idi:12`, `doi:10.1/x`, `arxiv:2401.01234`, or
    /// `details:<hash>` for details read from a PDF or web page.
    public var key: String {
        switch kind {
        case .existing(let id): return "idi:\(id)"
        case .registry(let m):
            if verifies, let d = m.doi { return "doi:\(d.lowercased())" }
            if verifies, let a = m.arxiv { return "arxiv:\(a.lowercased())" }
            let fingerprint = [m.title, m.year.map(String.init) ?? "", m.authors.map(\.family).joined(separator: ";"), m.doi ?? ""]
                .joined(separator: "|").lowercased()
            return "details:" + SHA256Hex.of(Data(fingerprint.utf8)).prefix(10)
        }
    }

    /// Registry records (Crossref, DataCite, arXiv) verify; cover sheets and web pages don't.
    public var verifies: Bool {
        switch kind {
        case .existing: true
        case .registry(let m): [.crossref, .datacite, .webMetadata].contains(m.source)
        }
    }

    public var id: String {
        switch kind {
        case .existing(let i): "existing-\(i)"
        case .registry(let m): "registry-\(m.doi ?? m.title)"
        }
    }
}

/// Works out what paper a PDF is from its own first pages — for PDFs that carry
/// no usable metadata (most direct PDF links).
public struct PDFIdentifier: Sendable {
    public var cascade: SearchCascade

    public init(cascade: SearchCascade) {
        self.cascade = cascade
    }

    public func identify(_ pages: PageLines, library: Library, excluding: IDI? = nil) async -> [IdentCandidate] {
        let subject = excluding.flatMap { library[$0] }
        let page1 = (pages.first ?? []).joined(separator: " ")
        let firstPages = pages.prefix(2).flatMap { $0 }.joined(separator: " ")
        // Titles sit near the top; matching only there avoids hits from a reference list.
        let head = TextCleanup.comparable(String(page1.prefix(2500)))
        var out: [IdentCandidate] = []

        func titleInHead(_ title: String) -> Bool {
            let t = TextCleanup.comparable(title)
            // ≥ 4 words: a bare journal name ("American Economic Review") on the page is not a title match.
            return t.split(separator: " ").count >= 4 && head.contains(t)
        }
        func add(_ c: IdentCandidate) {
            if let i = out.firstIndex(where: { $0.id == c.id }) {
                if c.strong && !out[i].strong { out[i] = c }
            } else {
                out.append(c)
            }
        }
        func addRecord(_ m: ResolvedMetadata, evidence: String, strong: Bool) {
            let existing = m.doi.flatMap(library.reference(forDOI:)) ?? m.arxiv.flatMap(library.reference(forArXiv:))
            if let e = existing, e.id != excluding {
                add(IdentCandidate(kind: .existing(e.id), evidence: evidence, strong: strong))
            } else if existing == nil {
                add(IdentCandidate(kind: .registry(m), evidence: evidence, strong: strong))
            }
        }

        // 1. Records already in the library whose title is on page 1.
        for ref in library.references.values.sorted(by: { $0.id < $1.id }) where ref.id != excluding && titleInHead(ref.title) {
            // Same title isn't proof: a record with its own, different year or DOI may be another work
            // (Anthropic's 2023 post and 2026 document are both "Claude's Constitution").
            var conflicts: [String] = []
            if let a = subject?.year, let b = ref.year, a != b { conflicts.append("years differ (\(a) vs \(b))") }
            if let a = subject?.doi, let b = ref.doi, !DOI.same(a, b) { conflicts.append("DOIs differ") }
            let evidence = "its title appears on page 1" + (conflicts.isEmpty ? "" : " — but \(conflicts.joined(separator: ", ")); may be a different work or version")
            add(IdentCandidate(kind: .existing(ref.id), evidence: evidence, strong: !ref.authors.isEmpty && conflicts.isEmpty))
        }

        // 2. DOIs printed in the first pages — trusted only if that record's title is also on page 1.
        for doi in Self.dois(in: firstPages).prefix(4) {
            if let m = try? await cascade.lookup(doi: doi), titleInHead(m.title) {
                addRecord(m, evidence: "DOI \(doi) is printed in the PDF", strong: true)
            }
        }

        // 3. arXiv stamp ("arXiv:2412.14093v2").
        if let r = firstPages.range(of: #"arXiv:\s*\d{4}\.\d{4,5}"#, options: .regularExpression),
           let id = ArXiv.id(in: String(firstPages[r]).replacingOccurrences(of: " ", with: "")),
           case .exact(let m, _) = await cascade.run(SearchQuery(url: ArXiv.absURL(id).absoluteString)).outcome, titleInHead(m.title) {
            addRecord(m, evidence: "arXiv:\(id) is stamped on the PDF", strong: true)
        }

        // 4. Registry search — suggestions, never automatic. First the opening text as a whole,
        //    then each early line that reads like a title (cover sheets, e.g. JSTOR's, bury the
        //    title in boilerplate that throws off a whole-text search).
        if !out.contains(where: \.strong) {
            var queries: [[String: String]] = []
            let opening = String(page1.prefix(300))
            if opening.split(separator: " ").count >= 5 { queries.append(["query.bibliographic": opening]) }
            let lines = (pages.first ?? []).prefix(8).filter { l in
                let words = l.split(separator: " ")
                return words.count >= 3 && words.count <= 25 && !l.contains("http") && l.rangeOfCharacter(from: .letters) != nil
            }
            queries += lines.prefix(3).map { ["query.title": $0] }
            for q in queries {
                guard let found = try? await cascade.crossref.search(q, rows: 5) else { continue }
                // A search hit counts only if its title AND first author are both on page 1.
                for m in found where titleInHead(m.title) {
                    guard let a = m.authors.first, head.contains(TextCleanup.comparable(a.family)) else { continue }
                    addRecord(m, evidence: "Crossref match: title and first author appear on page 1", strong: false)
                }
                if out.contains(where: { if case .registry = $0.kind { return true }; return false }) { break }
            }
        }
        // 5. No registry record at all (older articles never got DOIs): the archive's own cover sheet.
        if !out.contains(where: { if case .registry = $0.kind { return true }; return false }), let m = JSTORCover.parse(pages.first ?? []) {
            if let e = library.references(titled: m.title).first(where: { $0.id != excluding }) {
                add(IdentCandidate(kind: .existing(e.id), evidence: "the JSTOR cover sheet names this title", strong: false))
            } else {
                add(IdentCandidate(kind: .registry(m), evidence: "read from the JSTOR cover sheet in the PDF (no DOI was ever registered)", strong: false))
            }
        }
        return out.sorted { $0.strong && !$1.strong }
    }

    /// The single candidate safe to apply without asking, if there is exactly one.
    public static func confident(_ candidates: [IdentCandidate]) -> IdentCandidate? {
        let strong = candidates.filter(\.strong)
        return strong.count == 1 ? strong[0] : nil
    }

    static func dois(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"10\.\d{4,9}/[^\s"'<>]+"#)
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let d = DOI.normalize(String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]"))) else { continue }
            if seen.insert(d.lowercased()).inserted { out.append(d) }
        }
        return out
    }
}
