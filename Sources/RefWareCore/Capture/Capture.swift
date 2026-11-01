import CryptoKit
import Foundation

enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Renders a web page to PDF (on macOS: WebKit, the engine Safari uses).
public protocol PageSnapshotter: Sendable {
    /// PDF bytes plus the page's visible text (used to detect bot-check pages).
    func snapshot(_ url: URL) async throws -> (pdf: Data, text: String)
}

/// Unpaywall (https://unpaywall.org): legal open-access copies of DOI'd papers.
public struct UnpaywallClient: Sendable {
    public var http: HTTPClient
    public var email: String

    public init(http: HTTPClient = URLSessionHTTPClient(), email: String) {
        self.http = http
        self.email = email
    }

    public func pdfURL(doi: String) async throws -> URL? {
        guard let doi = DOI.normalize(doi),
              let enc = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let mail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.unpaywall.org/v2/\(enc)?email=\(mail)") else { return nil }
        let r = try await http.get(url, headers: ["User-Agent": "RefWare/0.1"])
        guard r.status == 200 else { return nil }
        struct Body: Decodable {
            struct Loc: Decodable { var url_for_pdf: String? }
            var best_oa_location: Loc?
            var oa_locations: [Loc]?
        }
        let body = try JSONDecoder().decode(Body.self, from: r.data)
        let candidates = [body.best_oa_location?.url_for_pdf] + (body.oa_locations ?? []).map(\.url_for_pdf)
        return candidates.compactMap { $0 }.compactMap(URL.init(string:)).first
    }
}

/// User defaults for one-click capture: which library and project to send to.
public struct RefWareConfig: Codable, Sendable {
    public var library: String?
    public var project: String?
    public var mailto: String?
    /// Initials recorded when you mark a record as checked ("SMH").
    public var reviewer: String?

    public init(library: String? = nil, project: String? = nil, mailto: String? = nil, reviewer: String? = nil) {
        self.library = library
        self.project = project
        self.mailto = mailto
        self.reviewer = reviewer
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RefWare/config.json")
    }

    public static func load() -> RefWareConfig {
        (try? JSONDecoder().decode(RefWareConfig.self, from: Data(contentsOf: fileURL))) ?? RefWareConfig()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

public struct CaptureResult: Sendable {
    public enum DocumentSource: String, Sendable {
        case pdfLink = "the linked PDF"
        case arXiv = "arXiv"
        case openAccess = "an open-access copy (Unpaywall)"
        case webSnapshot = "a snapshot of the web page"
        case alreadyAttached = "the PDF already in the library"
    }

    public var reference: Reference
    public var isNew: Bool
    public var document: DocumentSource?
    /// Why no document was saved, if none was.
    public var documentNote: String?
    public var linkedClaim: String?
    /// How a metadata-less PDF was identified ("its title appears on page 1"), if it was.
    public var matchEvidence: String?
    /// True when RefWare couldn't identify the work confidently — the review window should open.
    public var needsReview = false
    /// Suggestions for the review window.
    public var candidates: [IdentCandidate] = []
}

public enum CaptureError: Error, CustomStringConvertible {
    case noMetadata(String)
    case blockedPage(String)
    case deadLink(String)

    public var description: String {
        switch self {
        case .noMetadata(let url): "couldn't identify the work at \(url) (no DOI, arXiv ID, or page metadata)"
        case .blockedPage(let url): "\(url) served a bot check instead of the page — open it in your browser and use File ▸ Export as PDF, then `refware pdf attach`"
        case .deadLink(let url): "\(url) is a dead link (the page isn't there any more) — find its current address, `refware set <IDI> --url …`, and capture again"
        }
    }
}

/// Sends one URL — a paper's page, a PDF link, a DOI, a blog post — into the
/// library: metadata via the search cascade, the document as a PDF, and an
/// optional link to the claim it supports.
public struct Capture: Sendable {
    public var cascade: SearchCascade
    public var http: HTTPClient
    public var snapshotter: PageSnapshotter?
    public var unpaywall: UnpaywallClient?

    public init(cascade: SearchCascade, http: HTTPClient, snapshotter: PageSnapshotter?, unpaywall: UnpaywallClient?) {
        self.cascade = cascade
        self.http = http
        self.snapshotter = snapshotter
        self.unpaywall = unpaywall
    }

    public func run(_ raw: String, project: String, claim: String?, library: inout Library, pdfDirectory: URL,
                    replacePDF: Bool = false, now: Date = Date()) async throws -> CaptureResult {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CaptureError.noMetadata(raw) }

        // 1. Fetch once: a PDF link is the document itself.
        var linkedPDF: Data?
        if ArXiv.id(in: raw) == nil, DOI.find(in: raw) == nil || raw.lowercased().hasSuffix(".pdf") {
            if let r = try? await http.get(url, headers: ["User-Agent": "Mozilla/5.0 (Macintosh) RefWare/0.1", "Accept": "application/pdf,text/html"]),
               r.status == 200, r.data.starts(with: Data("%PDF".utf8)) {
                linkedPDF = r.data
            }
        }

        // 2. Metadata: existing entry, else the cascade, else (for a bare PDF) identify it from its own text.
        var isNew = false
        var ref: Reference
        var evidence: String?
        var review = false
        var candidates: [IdentCandidate] = []
        if let existing = library.reference(forURL: raw) ?? DOI.find(in: raw).flatMap(library.reference(forDOI:)) {
            ref = existing
        } else {
            let result = await cascade.run(SearchQuery(doi: DOI.find(in: raw), url: raw))
            if case .exact(let m, _) = result.outcome,
               let existing = m.doi.flatMap(library.reference(forDOI:)) ?? m.arxiv.flatMap(library.reference(forArXiv:)) {
                ref = existing
            } else if case .exact(let m, _) = result.outcome {
                let scholarly = m.source == .crossref || m.source == .datacite || m.source == .webMetadata
                ref = m.makeReference(id: library.nextIDI, verified: scholarly, retrieved: now, projects: [ProjectTag(project: project)])
                try library.add(ref)
                isNew = true
            } else if let pdf = linkedPDF {
                let pages = (try? PDFText.pages(of: pdf)) ?? []
                candidates = await PDFIdentifier(cascade: cascade).identify(pages, library: library)
                switch PDFIdentifier.confident(candidates)?.kind {
                case .existing(let id)?:
                    ref = library[id]!
                    evidence = candidates.first { $0.strong }?.evidence
                case .registry(let m)?:
                    ref = m.makeReference(id: library.nextIDI, verified: true, retrieved: now, projects: [ProjectTag(project: project)])
                    try library.add(ref)
                    isNew = true
                    evidence = candidates.first { $0.strong }?.evidence
                case nil:
                    // Not identifiable with confidence: keep it as a clearly-marked placeholder for review.
                    let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                    ref = Reference(id: library.nextIDI, authors: [], year: nil, title: name, url: raw,
                                    projects: [ProjectTag(project: project)],
                                    provenance: Provenance(source: .manual, key: raw, retrieved: now, verified: false))
                    try library.add(ref)
                    isNew = true
                    review = true
                }
            } else {
                throw CaptureError.noMetadata(raw)
            }
        }
        if !ref.projects.contains(where: { $0.project == project }) {
            ref.projects.append(ProjectTag(project: project))
        }

        // 3. The document.
        var source: CaptureResult.DocumentSource?
        var note: String?
        if ref.fileName != nil && !replacePDF {
            source = .alreadyAttached
            if ref.authors.isEmpty || ref.year == nil { review = true } // a placeholder that already has its PDF
        } else {
            var pdf: Data?
            if let d = linkedPDF {
                pdf = d; source = .pdfLink
            } else if let id = ref.arxiv, let r = try? await http.get(ArXiv.pdfURL(id), headers: ["User-Agent": "RefWare/0.1"]),
                      r.status == 200, r.data.starts(with: Data("%PDF".utf8)) {
                pdf = r.data; source = .arXiv
            } else if let doi = ref.doi, let up = unpaywall, let pdfURL = try? await up.pdfURL(doi: doi),
                      let r = try? await http.get(pdfURL, headers: ["User-Agent": "Mozilla/5.0 (Macintosh) RefWare/0.1"]),
                      r.status == 200, r.data.starts(with: Data("%PDF".utf8)) {
                pdf = r.data; source = .openAccess
            } else if ref.doi == nil || ref.provenance?.source == .webPage, let snap = snapshotter {
                // Web copy (press releases, blogs, docs): the page as rendered, dated.
                let shot: (pdf: Data, text: String)
                do {
                    shot = try await snap.snapshot(url)
                } catch {
                    // Snapshotters report HTTP errors in their own error type; anything mentioning 4xx/5xx is a dead link.
                    if String(describing: error).range(of: #"HTTP (4|5)\d\d"#, options: .regularExpression) != nil { throw CaptureError.deadLink(raw) }
                    throw error
                }
                if WebMetadataReader.isNotFoundPage(shot.text) { throw CaptureError.deadLink(raw) }
                if WebMetadataReader.isBotCheck(shot.text) || shot.text.count < 200 {
                    throw CaptureError.blockedPage(raw)
                }
                pdf = shot.pdf; source = .webSnapshot
            } else if ref.doi != nil {
                note = "no free PDF found — download it through your library access, then `refware pdf attach \(ref.id) <file.pdf>`"
            }
            if let data = pdf {
                let sha = SHA256Hex.of(data)
                if let other = library.owner(ofPDFWithSHA: sha, excluding: ref.id, pdfDirectory: pdfDirectory) {
                    note = "this exact PDF is already IDI \(other)'s — not attached twice (merge the records if they're the same work)"
                    pdf = nil
                }
            }
            if let pdf {
                try FileManager.default.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
                var name = Library.pdfFileName(for: ref)
                if source == .webSnapshot {
                    let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
                    name = name.replacingOccurrences(of: ".pdf", with: "_web-\(day).pdf")
                }
                try pdf.write(to: pdfDirectory.appendingPathComponent(name), options: .atomic)
                ref.fileName = name
                ref.pdfSHA256 = SHA256Hex.of(pdf)
            }
        }
        try library.update(ref)
        if source != nil && source != .alreadyAttached { library.revalidateQuotes(of: ref.id, pdfDirectory: pdfDirectory) }

        // 4. Project + claim links.
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        index.addReference(ref.id)
        var linked: String?
        if let claim, let c = index.claimIndex(claim) {
            if !index.claims[c].references.contains(ref.id) {
                if let s = index.claims[c].sources.firstIndex(where: { $0.reference == nil }) {
                    index.claims[c].sources[s].reference = ref.id
                } else {
                    index.claims[c].sources.append(ClaimSource(url: raw, reference: ref.id))
                }
            }
            linked = index.claims[c].id
        }
        library.projects[project] = index
        if review && candidates.isEmpty, let file = ref.fileName,
           let pages = try? PDFText.pages(of: pdfDirectory.appendingPathComponent(file)) {
            candidates = await PDFIdentifier(cascade: cascade).identify(pages, library: library, excluding: ref.id)
        }
        return CaptureResult(reference: ref, isNew: isNew, document: source, documentNote: note, linkedClaim: linked,
                             matchEvidence: evidence, needsReview: review, candidates: candidates)
    }
}
