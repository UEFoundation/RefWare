import Foundation

public enum EvidenceError: Error, CustomStringConvertible, Equatable {
    case unknownProject(String)
    case unknownClaim(String)
    case noPDF(IDI)
    case quoteNotFound(IDI, matchedWords: Int, totalWords: Int, nearest: String?)
    case quoteTooShort
    case referenceNotLinkedToClaim(IDI, claim: String)
    case statusNeedsQuote(String)
    case notAPDF(String)

    public var description: String {
        switch self {
        case .unknownProject(let p): "project \(p) has no claims — run `claims import` first"
        case .unknownClaim(let c): "no claim \(c) in this project"
        case .noPDF(let id): "IDI \(id) has no PDF attached — use `pdf fetch` or `pdf attach`"
        case .quoteNotFound(let id, let matched, let total, let nearest):
            "quote not found in IDI \(id)'s PDF" + (matched >= 3
                ? " — the first \(matched) of \(total) words match at \(nearest ?? "?"), then the text diverges"
                : " — not even the opening words occur")
        case .quoteTooShort: "quote is too short to verify (needs ≥ \(QuoteVerifier.minimumLength) letters/digits)"
        case .referenceNotLinkedToClaim(let id, let claim):
            "IDI \(id) is not among \(claim)'s sources — link it with `claims link` first if it really is the source"
        case .statusNeedsQuote(let claim): "\(claim) can't be marked supported without at least one current verified quote from its sources (stale quotes — from a replaced PDF — don't count until re-verified)"
        case .notAPDF(let what): "\(what) is not a PDF"
        }
    }
}

extension Library {
    /// Where PDFs live relative to the library file.
    public static func pdfDirectory(forLibraryAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("PDFs", isDirectory: true)
    }

    /// Like `pdfFileName(for:)`, but keeps a web snapshot's `_web-YYYY-MM-DD` marker from `old`,
    /// so a renamed snapshot is still recognisably a snapshot (its file date isn't a publication year).
    public static func pdfFileName(for ref: Reference, keepingSnapshotFrom old: String?) -> String {
        let base = pdfFileName(for: ref)
        guard let old, let r = old.range(of: #"_web-\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return base }
        return base.replacingOccurrences(of: ".pdf", with: "\(old[r]).pdf")
    }

    /// `IDI-0002_Haller_2025.pdf`
    public static func pdfFileName(for ref: Reference) -> String {
        let author = ref.authors.first?.family ?? "Anon"
        let safe = author.folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return String(format: "IDI-%04d_%@_%@.pdf", ref.id, safe.isEmpty ? "Anon" : safe, ref.year.map(String.init) ?? "nd")
    }

    /// Verifies `text` against the reference's PDF and records it as the next
    /// `Q#` for that reference. If `claim` is given, the reference must be one
    /// of that claim's sources and the quote tag is attached to it.
    @discardableResult
    public mutating func addQuote(project: String, reference rawID: IDI, text: String, claim claimID: String?,
                                  pdfPages: PageLines, pdfSHA256: String? = nil) throws -> QuoteRecord {
        guard var index = projects[project] else { throw EvidenceError.unknownProject(project) }
        let id = canonical(rawID) // a retired number files the quote under its survivor
        guard self[id] != nil else { throw LibraryError.unknownIDI(rawID) }
        var claimIndex: Int?
        if let claimID {
            guard let c = index.claimIndex(claimID) else { throw EvidenceError.unknownClaim(claimID) }
            guard index.claims[c].references.contains(id) else { throw EvidenceError.referenceNotLinkedToClaim(id, claim: index.claims[c].id) }
            claimIndex = c
        }

        let match: QuoteMatch
        switch QuoteVerifier.locate(text, in: pdfPages) {
        case .found(let m): match = m
        case .tooShort: throw EvidenceError.quoteTooShort
        case .notFound(let matched, let total, let nearest):
            throw EvidenceError.quoteNotFound(id, matchedWords: matched, totalWords: total, nearest: nearest.map { "p. \($0.page), line \($0.line)" })
        }

        let normalized = QuoteVerifier.normalize(text)
        let pdfText = match.matchedText.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : match.matchedText
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var record: QuoteRecord
        if let i = index.quotes.firstIndex(where: { $0.reference == id && QuoteVerifier.normalize($0.text) == normalized }) {
            // Same passage: refresh its verification against this PDF (clears staleness).
            index.quotes[i].page = match.page; index.quotes[i].line = match.line
            index.quotes[i].pdfSHA256 = pdfSHA256 ?? index.quotes[i].pdfSHA256
            index.quotes[i].normalization = QuoteVerifier.normalizationVersion
            index.quotes[i].staleSince = nil; index.quotes[i].verified = true
            index.quotes[i].verifiedOn = now
            record = index.quotes[i]
        } else {
            record = QuoteRecord(label: index.nextQuoteLabel(for: id), reference: id, text: pdfText, page: match.page, line: match.line, verified: true)
            // The label must not collide with a tag a merge has redirected.
            while quoteAliases[record.tag] != nil { record.label = "Q\((Int(record.label.dropFirst()) ?? 0) + 1)" }
            record.submitted = submitted == pdfText ? nil : submitted
            record.pdfSHA256 = pdfSHA256
            record.normalization = QuoteVerifier.normalizationVersion
            record.verifiedOn = now
            index.quotes.append(record)
        }
        index.addReference(id)
        if let c = claimIndex, !index.claims[c].quotes.contains(record.tag) {
            index.claims[c].quotes.append(record.tag)
        }
        projects[project] = index
        return record
    }

    /// Sets a claim's editorial status. `supported` requires a verified quote
    /// from one of the claim's own sources.
    public mutating func setClaimStatus(project: String, claim claimID: String, status: ClaimStatus, note: String?, by reviewer: String? = nil) throws {
        guard var index = projects[project] else { throw EvidenceError.unknownProject(project) }
        guard let c = index.claimIndex(claimID) else { throw EvidenceError.unknownClaim(claimID) }
        if status == .supported { try checkSupportable(project: project, claim: claimID) }
        index.claims[c].status = status
        if let note { index.claims[c].note = note.isEmpty ? nil : note }
        index.claims[c].reviewedBy = reviewer ?? HistoryEvent.defaultActor
        index.claims[c].reviewedOn = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        projects[project] = index
    }

    /// "Supported" needs a current verified quote from one of the claim's own sources.
    public func checkSupportable(project: String, claim claimID: String) throws {
        guard let index = projects[project] else { throw EvidenceError.unknownProject(project) }
        guard let c = index.claimIndex(claimID) else { throw EvidenceError.unknownClaim(claimID) }
        let refs = Set(index.claims[c].references)
        let backed = index.claims[c].quotes.compactMap(index.quote(tag:)).contains { $0.isCurrent && refs.contains($0.reference) }
        guard backed else { throw EvidenceError.statusNeedsQuote(index.claims[c].id) }
    }
}

/// Downloads PDFs for references that have a freely available copy (arXiv).
public struct PDFFetcher: Sendable {
    public var http: HTTPClient
    /// When set, DOI'd papers without an arXiv copy are looked up on Unpaywall.
    public var unpaywall: UnpaywallClient?

    public init(http: HTTPClient = URLSessionHTTPClient(), unpaywall: UnpaywallClient? = nil) {
        self.http = http
        self.unpaywall = unpaywall
    }

    /// Returns the downloaded bytes after checking they really are a PDF.
    public func fetch(_ ref: Reference) async throws -> Data? {
        guard let arxiv = ref.arxiv else {
            guard let doi = ref.doi, let up = unpaywall, let url = try await up.pdfURL(doi: doi) else { return nil }
            let r = try await http.get(url, headers: ["User-Agent": "Mozilla/5.0 (Macintosh) RefWare/0.1"])
            return r.status == 200 && r.data.starts(with: Data("%PDF".utf8)) ? r.data : nil
        }
        let url = ArXiv.pdfURL(arxiv)
        let response = try await http.get(url, headers: ["User-Agent": "RefWare/0.1"])
        guard response.status == 200 else { throw SearchError.http(status: response.status, url: url) }
        guard response.data.starts(with: Data("%PDF".utf8)) else { throw EvidenceError.notAPDF(url.absoluteString) }
        return response.data
    }
}

import CryptoKit

extension Library {
    /// SHA-256 of a file, hex.
    public static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public struct RecheckResult: Sendable, Equatable {
        public var unchanged: [String] = []
        public var reverified: [String] = []
        public var stale: [String] = []
        /// Supported claims left without a current quote — their support needs revalidating.
        public var supportNeedsRecheck: [String] = []
        public init() {}
    }

    /// Re-checks a record's quotes against its current PDF. Quotes verified against the same
    /// bytes are left alone; others are searched for again — found ones move to their new
    /// page/line, missing ones are marked stale (kept, not deleted).
    @discardableResult
    public mutating func revalidateQuotes(of rawID: IDI, pdfDirectory dir: URL, now: Date = Date()) -> RecheckResult {
        let id = canonical(rawID)
        var result = RecheckResult()
        guard var ref = references[id] else { return result }
        let file = ref.fileName.map { dir.appendingPathComponent($0) }
        let sha = file.flatMap(Library.sha256(of:))
        if ref.pdfSHA256 != sha { ref.pdfSHA256 = sha; references[id] = ref }
        var pages: PageLines?
        func loadPages() -> PageLines? {
            if pages == nil, let f = file { pages = try? PDFText.pages(of: f) }
            return pages
        }
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        for key in projects.keys {
            var index = projects[key]!
            for q in index.quotes.indices where index.quotes[q].reference == id && index.quotes[q].verified {
                let tag = index.quotes[q].tag
                if let sha, index.quotes[q].pdfSHA256 == sha, index.quotes[q].normalization == QuoteVerifier.normalizationVersion,
                   index.quotes[q].staleSince == nil {
                    result.unchanged.append(tag); continue
                }
                if let p = loadPages(), case .found(let m) = QuoteVerifier.locate(index.quotes[q].text, in: p) {
                    index.quotes[q].page = m.page; index.quotes[q].line = m.line
                    index.quotes[q].pdfSHA256 = sha
                    index.quotes[q].normalization = QuoteVerifier.normalizationVersion
                    index.quotes[q].staleSince = nil
                    result.reverified.append(tag)
                } else if index.quotes[q].staleSince == nil {
                    index.quotes[q].staleSince = stamp
                    result.stale.append(tag)
                } else {
                    result.stale.append(tag)
                }
            }
            for c in index.claims where c.status == .supported && c.references.contains(id) {
                let current = c.quotes.compactMap(index.quote(tag:)).contains { $0.isCurrent && c.references.contains($0.reference) }
                if !current { result.supportNeedsRecheck.append(c.id) }
            }
            projects[key] = index
        }
        return result
    }

    /// Supported claims whose quotes are all stale (any project).
    public func claimsNeedingRevalidation() -> [(project: String, claim: Claim)] {
        projects.flatMap { name, index in
            index.claims.filter { c in
                c.status == .supported && !c.quotes.compactMap(index.quote(tag:)).contains { $0.isCurrent && c.references.contains($0.reference) }
            }.map { (name, $0) }
        }
    }

    /// Records whose attached PDFs are byte-identical (they share one document).
    public func sharedPDFs(pdfDirectory dir: URL) -> [[IDI]] {
        var bySHA: [String: [IDI]] = [:]
        for r in references.values where r.fileName != nil {
            guard let sha = r.pdfSHA256 ?? r.fileName.flatMap({ Library.sha256(of: dir.appendingPathComponent($0)) }) else { continue }
            bySHA[sha, default: []].append(r.id)
        }
        return bySHA.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// The record (other than `id`) already holding a file with these bytes, if any.
    public func owner(ofPDFWithSHA sha: String, excluding id: IDI, pdfDirectory dir: URL) -> IDI? {
        references.values.first { r in
            r.id != id && r.fileName != nil && (r.pdfSHA256 ?? r.fileName.flatMap { Library.sha256(of: dir.appendingPathComponent($0)) }) == sha
        }?.id
    }
}
