import Foundation

public struct Discrepancy: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, minor }
    public var field: String
    public var yours: String
    public var source: String
    public var severity: Severity
    public var note: String?
}

public struct EntryAudit: Sendable {
    public enum Match: Equatable, Sendable {
        /// Found by the DOI (or arXiv ID) written in the entry.
        case doi
        /// No DOI in the entry; found by exact title + first author. Needs confirming.
        case title
        /// No DOI; checked against the metadata the linked web page declares.
        case webPage
        /// The entry's DOI is not registered with Crossref or DataCite.
        case doiNotRegistered
        /// The entry's link doesn't load (404, 410…).
        case deadLink(Int)
        /// The link loads (e.g. a PDF report) but declares no metadata to compare.
        case linkOnly
        case notFound
    }

    public var entry: ParsedEntry
    public var match: Match
    public var record: ResolvedMetadata?
    public var discrepancies: [Discrepancy]
    /// In-text citations that point at this entry.
    public var citedBy: [InTextCitation]
    public var importedAs: IDI?

    public var errors: [Discrepancy] { discrepancies.filter { $0.severity == .error } }
    public var isClean: Bool { match == .doi && errors.isEmpty }
    public var isFound: Bool { record != nil && match != .title }
}

public struct CitationIssue: Equatable, Sendable {
    public var citation: InTextCitation
    public var problem: String
}

public struct ManuscriptAudit: Sendable {
    public var entries: [EntryAudit]
    public var citationIssues: [CitationIssue]
    public var referenceHeadingLine: Int?
    public var citationCount: Int
    /// Problems found while importing (e.g. a DOI that belongs to a different work).
    public var importWarnings: [String] = []
}

/// Checks a manuscript's hand-written references against the registries and
/// its in-text citations against its reference list.
public struct ManuscriptAuditor: Sendable {
    public var cascade: SearchCascade

    public init(cascade: SearchCascade) {
        self.cascade = cascade
    }

    public func audit(_ text: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ManuscriptAudit {
        let parsed = ManuscriptParser.parse(text)
        var audits: [EntryAudit] = []
        for (i, entry) in parsed.entries.enumerated() {
            progress?(i + 1, parsed.entries.count)
            audits.append(await auditEntry(entry))
        }
        let issues = Self.crossCheck(parsed.citations, against: &audits)
        return ManuscriptAudit(entries: audits, citationIssues: issues, referenceHeadingLine: parsed.referenceHeadingLine,
                               citationCount: parsed.citations.count)
    }

    func auditEntry(_ entry: ParsedEntry) async -> EntryAudit {
        var audit = EntryAudit(entry: entry, match: .notFound, record: nil, discrepancies: [], citedBy: [], importedAs: nil)
        do {
            if let doi = entry.doi {
                if let m = try await cascade.lookup(doi: doi) {
                    audit.match = .doi
                    audit.record = m
                } else {
                    audit.match = .doiNotRegistered
                }
            } else if let url = entry.url, let acl = Self.aclAnthologyDOI(url), let m = try await cascade.lookup(doi: acl) {
                audit.match = .doi
                audit.record = m
                audit.discrepancies.append(Discrepancy(field: "DOI", yours: "—", source: "https://doi.org/\(acl)", severity: .minor,
                                                       note: "ACL Anthology papers have DOIs — use it instead of the PDF link"))
            } else if let url = entry.url, ArXiv.id(in: url) != nil,
                      case .exact(let m, _) = await cascade.run(SearchQuery(url: url)).outcome {
                audit.match = .doi
                audit.record = m
            }
        } catch {
            audit.discrepancies.append(Discrepancy(field: "lookup", yours: "", source: "", severity: .minor, note: "DOI lookup failed: \(error)"))
        }
        do {
            if audit.record == nil, let title = entry.title, title.count > 10 {
                var fields = ["query.title": title]
                if let first = entry.authors.first { fields["query.author"] = first.family }
                let target = TextCleanup.comparable(title)
                let candidates = try await cascade.crossref.search(fields, rows: 10)
                let sameWork = candidates.filter { c in
                    TextCleanup.comparable(c.title) == target
                        && (entry.authors.first.map { a in c.authors.first.map { Self.sameName($0.family, a.family) } ?? false } ?? true)
                }
                // Same title and author but a different year is often a later re-deposit
                // or a junk copy, not the work cited — report it, never match on it.
                if let hit = sameWork.first(where: { c in entry.year.map { c.year == $0 || c.yearsSeen.contains($0) } ?? true }) {
                    if audit.match != .doiNotRegistered { audit.match = .title }
                    audit.record = hit
                } else if !sameWork.isEmpty {
                    let others = sameWork.map { "\($0.year.map(String.init) ?? "n.d.")\($0.doi.map { " doi:\($0)" } ?? "")" }
                    audit.discrepancies.append(Discrepancy(field: "lookup", yours: entry.year.map(String.init) ?? "n.d.", source: others.joined(separator: "; "),
                        severity: .minor, note: "only records with the same title in other years were found — likely re-deposits; not matched"))
                }
            }
        } catch {
            audit.discrepancies.append(Discrepancy(field: "lookup", yours: "", source: "", severity: .minor, note: "title search failed: \(error)"))
        }
        do {
            // Last resort for web sources: the page's own declared metadata.
            if audit.record == nil, audit.match == .notFound, let url = entry.url, URL(string: url) != nil {
                let response = try await cascade.http.get(URL(string: url)!, headers: ["User-Agent": "Mozilla/5.0 (Macintosh) RefWare/0.1", "Accept": "text/html,application/pdf"])
                if [404, 410].contains(response.status) {
                    audit.match = .deadLink(response.status)
                } else if response.status != 200 {
                    audit.discrepancies.append(Discrepancy(field: "lookup", yours: "", source: "HTTP \(response.status)", severity: .minor,
                        note: "the page refused the check (HTTP \(response.status)) — often bot protection; open the link yourself"))
                } else if response.status == 200, response.data.starts(with: Data("%PDF".utf8)) {
                    audit.match = .linkOnly
                } else if response.status == 200 {
                    let page = WebMetadataReader.read(html: String(decoding: response.data, as: UTF8.self), url: url)
                    if let doi = page.doi, let m = try await cascade.lookup(doi: doi) {
                        audit.match = .doi
                        audit.record = m
                    } else if var m = page.metadata {
                        // A page can't vouch for authors it doesn't name, or a year it doesn't state.
                        if m.authors.isEmpty { m.authors = entry.authors }
                        if m.year == nil { m.year = entry.year }
                        m.indexing = PublicationIndexing()
                        m.publication = nil
                        m.yearsSeen = []
                        audit.match = .webPage
                        audit.record = m
                    }
                }
            }
        } catch {
            audit.discrepancies.append(Discrepancy(field: "lookup", yours: "", source: "", severity: .minor, note: "web page check failed: \(error)"))
        }
        if let record = audit.record { audit.discrepancies += Self.compare(entry, record) }
        audit.discrepancies += entry.lint.map { Discrepancy(field: "format", yours: "", source: "", severity: .minor, note: $0) }
        return audit
    }

    // MARK: Field comparison

    /// The entry names a published venue but its link/DOI is the arXiv preprint.
    static func isVersionMismatch(_ e: ParsedEntry, _ r: ResolvedMetadata) -> Bool {
        guard r.arxiv != nil, r.publication == "arXiv", let venue = e.publication else { return false }
        return !TextCleanup.comparable(venue).contains("arxiv")
    }

    static func compare(_ e: ParsedEntry, _ r: ResolvedMetadata) -> [Discrepancy] {
        var d: [Discrepancy] = []
        let versionMismatch = isVersionMismatch(e, r)
        if versionMismatch {
            d.append(Discrepancy(field: "version", yours: e.publication ?? "", source: "arXiv preprint", severity: .minor,
                                 note: "your entry names \(e.publication ?? "a venue") but links the arXiv preprint — cite the published version with its DOI, or cite the preprint as arXiv"))
        }
        let web = r.source == .webPage || r.source == .webMetadata && r.doi == nil && r.arxiv == nil
        let yoursAuthors = e.authors.map(\.referenceForm).joined(separator: "; ")
        let sourceAuthors = r.authors.map(\.referenceForm).joined(separator: "; ")

        // Authors: count, order, family names, initials.
        // House style: more than 10 authors → first 10, then "et al." That's correct, not an omission.
        let houseLimit = 10
        let houseTruncationOK = e.truncatedAuthors && r.authors.count > houseLimit && e.authors.count == houseLimit
        if r.authors.count > houseLimit && !e.truncatedAuthors && e.authors.count == r.authors.count {
            d.append(Discrepancy(field: "authors", yours: "all \(r.authors.count)", source: "\(r.authors.count)", severity: .minor,
                                 note: "house style: list the first \(houseLimit), then et al."))
        } else if e.authors.count != r.authors.count && !houseTruncationOK {
            let missing = r.authors.filter { a in !e.authors.contains { Self.sameName($0.family, a.family) } }.map(\.referenceForm)
            let wanted = min(r.authors.count, houseLimit)
            let note = e.truncatedAuthors
                ? "et al. after \(e.authors.count) — house style names \(r.authors.count > houseLimit ? "the first \(houseLimit)" : "all \(r.authors.count)")"
                : (r.authors.count > houseLimit && e.authors.count < wanted ? "name the first \(houseLimit), then et al." : (missing.isEmpty ? nil : "missing: \(missing.prefix(10).joined(separator: "; "))\(missing.count > 10 ? "; … (\(missing.count) in all)" : "")"))
            d.append(Discrepancy(field: "authors", yours: "\(e.authors.count): \(yoursAuthors)", source: "\(r.authors.count): \(sourceAuthors)", severity: .error, note: note))
        }
        for (i, (mine, theirs)) in zip(e.authors, r.authors).enumerated() {
            if !Self.sameName(mine.family, theirs.family) {
                let elsewhere = r.authors.firstIndex { Self.sameName($0.family, mine.family) }
                d.append(Discrepancy(field: "author \(i + 1)", yours: mine.referenceForm, source: theirs.referenceForm, severity: .error,
                                     note: elsewhere.map { "\(mine.family) is author \($0 + 1) in the source — order differs" }))
            } else if !mine.isOrganization && !theirs.isOrganization && theirs.given != nil {
                let a = Self.initialLetters(mine.initials), b = Self.initialLetters(theirs.initials)
                if a != b {
                    let severity: Discrepancy.Severity = a.first == b.first ? .minor : .error
                    d.append(Discrepancy(field: "author \(i + 1) initials", yours: mine.referenceForm, source: theirs.referenceForm, severity: severity))
                }
            }
        }

        if let y = e.year, let ry = r.year, y != ry {
            if versionMismatch {
                d.append(Discrepancy(field: "year", yours: String(y), source: String(ry), severity: .minor, note: "preprint year; the published version may differ"))
            } else if r.yearsSeen.contains(y) {
                d.append(Discrepancy(field: "year", yours: String(y), source: String(ry), severity: .minor,
                                     note: "\(y) is also in the record (print vs. online date); APA uses the version you read"))
            } else {
                d.append(Discrepancy(field: "year", yours: String(y), source: r.yearsSeen.map(String.init).joined(separator: " / ").nilIfEmpty ?? String(ry), severity: .error))
            }
        } else if e.year == nil, let ry = r.year {
            d.append(Discrepancy(field: "year", yours: "n.d.", source: String(ry), severity: .error))
        }

        if let t = e.title {
            let a = TextCleanup.comparable(t), b = TextCleanup.comparable(r.title)
            if a != b {
                let sim = Self.similarity(a, b)
                if b.contains(a) {
                    d.append(Discrepancy(field: "title", yours: t, source: r.title, severity: .minor,
                                         note: b.hasPrefix(a) ? "source title continues (subtitle or label missing)" : "source title has extra text around yours"))
                } else if a.contains(b) {
                    d.append(Discrepancy(field: "title", yours: t, source: r.title, severity: .minor, note: "your title has extra text"))
                } else {
                    d.append(Discrepancy(field: "title", yours: t, source: r.title, severity: sim >= 0.85 || web ? .minor : .error,
                                         note: web ? "web page title differs — confirm the title the source itself uses" : sim >= 0.85 ? "small wording/punctuation difference" : nil))
                }
            }
        }

        if let p = r.publication, !p.isEmpty, !versionMismatch {
            if let mine = e.publication {
                let names = ([p] + r.publicationAliases).map(TextCleanup.comparable)
                let a = TextCleanup.comparable(mine)
                if !names.contains(a) {
                    let partial = names.contains { $0.contains(a) || a.contains($0) } || Self.venueTokensCovered(mine, by: [p] + r.publicationAliases)
                    d.append(Discrepancy(field: "journal", yours: mine, source: p, severity: partial ? .minor : .error))
                }
            } else if r.source == .crossref {
                d.append(Discrepancy(field: "journal", yours: "—", source: p, severity: .error, note: "missing from your entry"))
            }
        }

        let ix = r.indexing
        func check(_ field: String, _ mine: String?, _ theirs: String?) {
            guard let theirs, !theirs.isEmpty else { return }
            guard let mine else {
                d.append(Discrepancy(field: field, yours: "—", source: theirs, severity: .minor, note: "missing from your entry"))
                return
            }
            if Self.normalizeLocator(mine) != Self.normalizeLocator(theirs) {
                d.append(Discrepancy(field: field, yours: mine, source: theirs, severity: .error))
            }
        }
        check("volume", e.indexing.volume, ix.volume)
        check("issue", e.indexing.issue, ix.issue)
        if e.indexing.articleNumber != nil || (ix.pages == nil && ix.articleNumber != nil) {
            check("article number", e.indexing.articleNumber, ix.articleNumber)
        } else {
            check("pages", e.indexing.pages, ix.pages)
        }
        if e.doi == nil, let doi = r.doi {
            d.append(Discrepancy(field: "DOI", yours: "—", source: "https://doi.org/\(doi)", severity: .minor, note: "add it — DOIs make the entry checkable"))
        }
        return d
    }

    // MARK: In-text ↔ reference list

    static func crossCheck(_ citations: [InTextCitation], against audits: inout [EntryAudit]) -> [CitationIssue] {
        var issues: [CitationIssue] = []
        for c in citations {
            guard let first = c.names.first else { continue }
            let candidates = audits.indices.filter { i in
                audits[i].entry.authors.first.map { sameName($0.family, first) || ($0.isOrganization && isAcronym(first, of: $0.family)) } ?? false
            }
            let exact = candidates.filter { audits[$0].entry.year == c.year && (c.yearSuffix == nil || audits[$0].entry.yearSuffix == c.yearSuffix) }
            if exact.count > 1, c.yearSuffix == nil {
                issues.append(CitationIssue(citation: c, problem: "ambiguous — \(exact.count) entries by \(first) in \(c.year.map(String.init) ?? "n.d."); add a/b suffixes"))
            }
            guard let i = exact.first else {
                if let other = candidates.first {
                    let y = audits[other].entry.year.map(String.init) ?? "n.d."
                    issues.append(CitationIssue(citation: c, problem: "no \(first) \(c.year.map(String.init) ?? "n.d.") in the reference list — did you mean \(first) (\(y))?"))
                } else if let i = audits.indices.first(where: { i in
                    audits[i].entry.year == c.year
                        && ((audits[i].record?.authors ?? audits[i].entry.authors).dropFirst().contains { sameName($0.family, first) }
                            || audits[i].entry.authors.dropFirst().contains { sameName($0.family, first) })
                }) {
                    let lead = audits[i].entry.authors.first?.family ?? "?"
                    // A hint only: a co-author match is not a citation of that work, so nothing is linked to it.
                    issues.append(CitationIssue(citation: c, problem: "no \(first) \(c.year.map(String.init) ?? "n.d.") entry — a \(first) is a co-author of \(lead) (\(c.year.map(String.init) ?? "n.d.")); if that's the work, cite \(lead); otherwise the reference is missing"))
                } else {
                    issues.append(CitationIssue(citation: c, problem: "no matching entry in the reference list"))
                }
                continue
            }
            audits[i].citedBy.append(c)

            // Citation form: 1 → Smith; 2 → Smith & Jones; 3+ → Smith et al.
            // Judged against the source's author list when it's known, since that's the true count.
            let authors = audits[i].record?.authors ?? audits[i].entry.authors
            let n = authors.count
            if n >= 3 && !c.etAl {
                issues.append(CitationIssue(citation: c, problem: "\(n) authors — cite as \(authors[0].family) et al."))
            } else if n == 2 && c.etAl {
                issues.append(CitationIssue(citation: c, problem: "2 authors — cite both: \(authors[0].family) & \(authors[1].family)"))
            } else if n == 2 && !c.etAl && c.names.count < 2 {
                issues.append(CitationIssue(citation: c, problem: "2 authors — cite both: \(authors[0].family) & \(authors[1].family)"))
            } else if n == 2, c.names.count >= 2, !sameName(c.names[1], authors[1].family) {
                issues.append(CitationIssue(citation: c, problem: "second author is \(authors[1].family), not \(c.names[1])"))
            } else if n == 1 && (c.etAl || c.names.count > 1) {
                issues.append(CitationIssue(citation: c, problem: "single-author work — cite as \(authors[0].family)"))
            }
            if let first = c.names.first, let org = audits[i].entry.authors.first, org.isOrganization, isAcronym(first, of: org.family) {
                issues.append(CitationIssue(citation: c, problem: "abbreviation of \(org.family) — APA: write “\(org.family) [\(first)], \(c.year.map(String.init) ?? "n.d.")” at first use"))
            }
            if audits[i].match == .doi, let record = audits[i].record, !isVersionMismatch(audits[i].entry, record),
               let ry = record.year, let cy = c.year, cy != ry, !record.yearsSeen.contains(cy) {
                issues.append(CitationIssue(citation: c, problem: "source year is \(ry)"))
            }
        }
        return issues
    }

    // MARK: Helpers

    /// aclanthology.org/2024.acl-long.73(.pdf) → 10.18653/v1/2024.acl-long.73
    static func aclAnthologyDOI(_ url: String) -> String? {
        guard CanonicalURL.host(url) == "aclanthology.org",
              let r = url.range(of: #"(\d{4}\.[a-z0-9-]+\.\d+|[A-Z]\d{2}-\d{4})"#, options: .regularExpression) else { return nil }
        return "10.18653/v1/\(url[r])"
    }

    /// "Proceedings of CHI 2026" vs. "Proceedings of the 2026 CHI Conference on Human Factors…": every
    /// significant word of the short form appears in (or abbreviates part of) the full name.
    static func venueTokensCovered(_ short: String, by names: [String]) -> Bool {
        let skip: Set<String> = ["of", "the", "and", "on", "in", "for", "proceedings", "conference", "annual", "meeting", "journal", "international"]
        let mine = short.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !skip.contains($0.lowercased()) && Int($0) == nil }
        guard !mine.isEmpty else { return false }
        return names.contains { name in
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let lower = Set(words.map { $0.lowercased() })
            let caps = words.filter { $0.first?.isUppercase == true && !skip.contains($0.lowercased()) }
            return mine.allSatisfy { tok in
                lower.contains(tok.lowercased()) || (tok == tok.uppercased() && tok.count >= 2 && (0..<caps.count).contains { i in
                    caps[i...].prefix(tok.count).compactMap(\.first).map(String.init).joined() == tok
                })
            }
        }
    }

    /// "WHO" ↔ "World Health Organization"
    static func isAcronym(_ short: String, of name: String) -> Bool {
        guard short.count >= 2, short == short.uppercased(), short.allSatisfy(\.isLetter) else { return false }
        let skip: Set<String> = ["of", "the", "and", "for", "&", "on", "in"]
        let initials = name.split(separator: " ").filter { !skip.contains($0.lowercased()) }.compactMap(\.first).map(String.init).joined()
        return initials.uppercased() == short
    }

    public static func sameName(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter) }
        return fold(a) == fold(b)
    }

    static func initialLetters(_ s: String) -> String { s.filter(\.isLetter).uppercased() }

    static func normalizeLocator(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[\s‐-―–—-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"^0+(\d)"#, with: "$1", options: .regularExpression)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
