import Foundation
import RefWareCore
import RefWareMac

/// `refware capture <url>` — metadata + PDF (or web snapshot) into the library.
func capture(_ args: Arguments) async throws {
    if args.flags.contains("missing") { try await captureMissing(args); return }
    guard let raw = args.positionals.first else { throw UsageError(description: "capture needs a URL (page, PDF link, or DOI), or --missing") }
    let project = try requireProject(args)
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    let config = RefWareConfig.load()
    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? config.mailto

    let http = URLSessionHTTPClient()
    let capture = Capture(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http), http: http,
                          snapshotter: WebSnapshotter(), unpaywall: mailto.map { UnpaywallClient(http: http, email: $0) })
    let result = try await capture.run(raw, project: project, claim: args.options["claim"], library: &library,
                                       pdfDirectory: Library.pdfDirectory(forLibraryAt: libURL), replacePDF: args.flags.contains("replace"))
    try library.save(to: libURL)
    History.recordCapture(result, url: raw, project: project, libraryURL: libURL)
    print(captureSummary(result))
}

func captureSummary(_ r: CaptureResult) -> String {
    let ref = r.reference
    var lines = ["\(r.isNew ? "Added" : "Updated") [IDI \(ref.id)] \(CitationFormatter(references: [ref]).inline([ref])) — \(ref.title)"]
    if let p = ref.provenance { lines.append("  metadata: \(p.source.rawValue)\(p.verified ? " (verified)" : " (unverified — check by hand)")") }
    if let d = r.document { lines.append("  document: \(d.rawValue)\(ref.fileName.map { " → PDFs/\($0)" } ?? "")") }
    if let n = r.documentNote { lines.append("  document: \(n)") }
    if let c = r.linkedClaim { lines.append("  linked to claim \(c)") }
    if let e = r.matchEvidence { lines.append("  identified: \(e)") }
    if r.needsReview { lines.append("  needs a decision — run `refware review` (or `refware identify \(ref.id)`)") }
    return lines.joined(separator: "\n")
}

/// `refware config` — defaults for one-click capture.
func configure(_ args: Arguments) throws {
    var config = RefWareConfig.load()
    if let lib = args.options["library"] { config.library = URL(fileURLWithPath: (lib as NSString).expandingTildeInPath).standardizedFileURL.path }
    if let p = args.options["project"] { config.project = p }
    if let m = args.options["mailto"] { config.mailto = m }
    if let r = args.options["reviewer"] { config.reviewer = r }
    if !args.options.isEmpty { try config.save() }
    print("library:  \(config.library ?? "(unset)")\nproject:  \(config.project ?? "(unset)")\nmailto:   \(config.mailto ?? "(unset)")\nreviewer: \(config.reviewer ?? "(unset — the app uses your Mac account's initials)")\n(\(RefWareConfig.fileURL.path))")
}

/// `refware capture --missing` — every record with a link (or DOI) but no PDF gets one:
/// the PDF itself, an open-access copy, or a dated snapshot of the page.
func captureMissing(_ args: Arguments) async throws {
    let project = try requireProject(args)
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? RefWareConfig.load().mailto
    let http = URLSessionHTTPClient()
    let capture = Capture(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http), http: http,
                          snapshotter: WebSnapshotter(), unpaywall: mailto.map { UnpaywallClient(http: http, email: $0) })
    let todo = library.references.values.filter { $0.fileName == nil && ($0.url != nil || $0.doi != nil) }.sorted { $0.id < $1.id }
    print("\(todo.count) record(s) without a PDF.")
    for ref in todo {
        let link = ref.url ?? "https://doi.org/\(ref.doi!)"
        do {
            let r = try await capture.run(link, project: project, claim: nil, library: &library, pdfDirectory: Library.pdfDirectory(forLibraryAt: libURL))
            try library.save(to: libURL)
            History.recordCapture(r, url: link, project: project, libraryURL: libURL)
            let got = r.reference.fileName.map { "→ PDFs/\($0)" } ?? (r.documentNote ?? "no document")
            print("  IDI \(ref.id): \(r.document?.rawValue ?? "—") \(got)")
        } catch {
            print("  IDI \(ref.id): couldn't capture — \(error)")
        }
    }
}
