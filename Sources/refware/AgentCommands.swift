import Foundation
import RefWareCore

/// JSON output for agents: `--json` on read commands prints one parseable document.
func printJSON<T: Encodable>(_ value: T) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    print(String(decoding: try e.encode(value), as: UTF8.self))
}

/// `refware worklist [--json]` — what RefWare Review shows: possible duplicates,
/// placeholders (no author/year), unverified records.
func worklist(_ args: Arguments) throws {
    let library = try Library.load(from: libraryURL(args))
    let dupes = library.likelyDuplicates()
    let placeholders = library.needsReview().filter { $0.authors.isEmpty || $0.year == nil }
    let unverified = library.needsReview().filter { !$0.authors.isEmpty && $0.year != nil }
    let shared = library.sharedPDFs(pdfDirectory: Library.pdfDirectory(forLibraryAt: libraryURL(args)))
    let stale = library.projects.values.flatMap(\.quotes).filter { $0.verified && $0.staleSince != nil }.map(\.tag).sorted()
    let revalidate = library.claimsNeedingRevalidation().map(\.claim.id).sorted()
    if args.flags.contains("json") {
        struct Out: Encodable {
            var duplicates: [[IDI]]; var placeholders: [Reference]; var unverified: [Reference]
            var sharedPDFs: [[IDI]]; var staleQuotes: [String]; var supportedClaimsNeedingRevalidation: [String]
        }
        try printJSON(Out(duplicates: dupes, placeholders: placeholders, unverified: unverified, sharedPDFs: shared, staleQuotes: stale, supportedClaimsNeedingRevalidation: revalidate))
        return
    }
    if !shared.isEmpty {
        print("Records sharing one PDF (\(shared.count)) — each record needs its own document:")
        for g in shared { print("  IDI " + g.map(String.init).joined(separator: ", IDI ")) }
    }
    if !stale.isEmpty { print("Stale quotes (\(stale.count)) — their PDF changed and they weren't found again: \(stale.joined(separator: ", "))") }
    if !revalidate.isEmpty { print("Supported claims without a current quote (\(revalidate.count)): \(revalidate.joined(separator: ", "))") }
    func line(_ r: Reference) -> String { "  IDI \(r.id)  \(CitationFormatter(references: [r]).inline([r]))  \(r.title.prefix(70))\(r.fileName == nil ? "  · no PDF" : "")" }
    print("Possible duplicates (\(dupes.count))")
    for g in dupes { print("  IDI " + g.map(String.init).joined(separator: " = IDI ") + "  \(library[g[0]]?.title.prefix(60) ?? "")") }
    print("Placeholders — no author or year (\(placeholders.count))"); placeholders.forEach { print(line($0)) }
    print("Unverified (\(unverified.count))"); unverified.forEach { print(line($0)) }
    if !dupes.isEmpty || !placeholders.isEmpty {
        print("\nResolve with: refware refresh <IDI>, refware identify <IDI>, refware merge <IDI> --into <IDI>, refware distinct <IDI> <IDI>, refware confirm <IDI>")
    }
}

/// `refware refresh <IDI> [--apply KEY] [--json]` — fresh suggestions from the record's PDF
/// (properties, cover, printed DOI), the registry, and the library.
func refresh(_ args: Arguments) async throws {
    guard let raw = args.positionals.first, let id = Int(raw) else { throw UsageError(description: "refresh needs an IDI") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    guard let ref = library[id] else { throw LibraryError.unknownIDI(id) }
    let pdfDir = Library.pdfDirectory(forLibraryAt: libURL)
    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? RefWareConfig.load().mailto
    let http = URLSessionHTTPClient()
    let cascade = SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http)

    var list: [IdentCandidate] = []
    if let f = ref.fileName {
        let url = pdfDir.appendingPathComponent(f)
        if f.contains("_web-"), let link = ref.url {
            if case .exact(let m, _) = await cascade.run(SearchQuery(url: link)).outcome {
                list.append(IdentCandidate(kind: .registry(m), evidence: "the web page's own metadata (\(CanonicalURL.host(link) ?? link))", strong: false))
            }
        } else if let m = PDFDetails.read(url) { list.append(IdentCandidate(kind: .registry(m), evidence: "read from the PDF itself (document properties and cover)", strong: false)) }
        if let pages = try? PDFText.pages(of: url) { list += await PDFIdentifier(cascade: cascade).identify(pages, library: library, excluding: id) }
    }
    if let doi = ref.doi, let m = try? await cascade.lookup(doi: doi) {
        list.append(IdentCandidate(kind: .registry(m), evidence: "the registry record for DOI \(doi)", strong: true))
    }

    list = uniqueByKey(list)
    if let pick = args.options["apply"] {
        let c = try candidate(pick, in: list, command: "refresh \(id)")
        let before = library[id].map { CitationFormatter(references: [$0]).referenceEntry($0) }
        print(try apply(c, to: id, library: &library, pdfDirectory: pdfDir))
        try library.save(to: libURL)
        let after = library[id].map { CitationFormatter(references: [$0]).referenceEntry($0) }
        History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(id) refreshed (\(c.key)): \(c.evidence)\(before != after ? " — was: \(before ?? "?")" : "")", idis: [id]), forLibraryAt: libURL)
        if case .registry(let m) = c.kind, m.url == nil, let u = library[id]?.url {
            print("  Note: its link still points to \(u) — `refware set \(id) --url …` if the PDF came from elsewhere.")
        }
        return
    }
    if args.flags.contains("json") {
        struct C: Encodable { var number: Int; var key: String; var kind: String; var existing: IDI?; var reference: Reference?; var evidence: String; var confident: Bool; var verifies: Bool }
        try printJSON(list.enumerated().map { i, c -> C in
            switch c.kind {
            case .existing(let e): return C(number: i + 1, key: c.key, kind: "existing", existing: e, reference: library[e], evidence: c.evidence, confident: c.strong, verifies: true)
            case .registry(let m): return C(number: i + 1, key: c.key, kind: c.verifies ? "registry" : "pdf-details", existing: nil, reference: m.makeReference(id: id, verified: c.verifies), evidence: c.evidence, confident: c.strong, verifies: c.verifies)
            }
        })
        return
    }
    print("[IDI \(id)] \(CitationFormatter(references: [ref]).referenceEntry(ref))")
    if list.isEmpty { print("  nothing new found — edit fields with `refware set \(id) …`") }
    for c in list { print("  [\(c.key)] \(describe(c, library))\n       \(c.strong ? "confident" : "suggestion"): \(c.evidence)") }
    if !list.isEmpty { print("\nApply one with: refware refresh \(id) --apply <key>   (e.g. --apply \(list[0].key))") }
}

/// `refware recent [--hours 24] [--json]` — what happened lately (captures, quotes, builds, merges…).
func recent(_ args: Arguments) throws {
    let libURL = libraryURL(args)
    let hours = Double(args.options["hours"] ?? "24") ?? 24
    let cutoff = Date().addingTimeInterval(-hours * 3600)
    let events = History.load(forLibraryAt: libURL).events.filter { $0.date > cutoff }.sorted { $0.date > $1.date }
    if args.flags.contains("json") { try printJSON(events); return }
    if events.isEmpty { print("Nothing in the last \(Int(hours)) h.") }
    for e in events {
        print("\(e.date.formatted(date: .abbreviated, time: .shortened))  \(e.kind.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(e.title)\(e.idis.isEmpty ? "" : "  [IDI \(e.idis.map(String.init).joined(separator: ", "))]")\(e.actor.map { "  — \($0)" } ?? "")")
    }
}

/// `refware recheck [<IDI>… | --all] [--json]` — re-verify recorded quotes against each record's current
/// PDF (fingerprint + text). Quotes that no longer appear are marked stale (kept on record).
func recheck(_ args: Arguments) throws {
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    let dir = Library.pdfDirectory(forLibraryAt: libURL)
    let quoted = Set(library.projects.values.flatMap(\.quotes).map(\.reference))
    let ids = args.flags.contains("all") || args.positionals.isEmpty ? quoted.sorted() : args.positionals.compactMap { Int($0) }
    var total = Library.RecheckResult()
    for id in ids {
        let r = library.revalidateQuotes(of: id, pdfDirectory: dir)
        total.unchanged += r.unchanged; total.reverified += r.reverified; total.stale += r.stale; total.supportNeedsRecheck += r.supportNeedsRecheck
    }
    try library.save(to: libURL)
    let stale = total.stale.sorted(), recheckClaims = Array(Set(total.supportNeedsRecheck)).sorted()
    if !total.reverified.isEmpty || !stale.isEmpty {
        History.record(HistoryEvent(kind: .quoteVerified, title: "Recheck: \(total.reverified.count) re-verified, \(stale.count) stale", quoteTags: total.reverified + stale), forLibraryAt: libURL)
    }
    if args.flags.contains("json") {
        struct Out: Encodable { var unchanged: [String]; var reverified: [String]; var stale: [String]; var supportedClaimsNeedingRevalidation: [String] }
        try printJSON(Out(unchanged: total.unchanged.sorted(), reverified: total.reverified.sorted(), stale: stale, supportedClaimsNeedingRevalidation: recheckClaims))
        return
    }
    print("Quotes: \(total.unchanged.count) unchanged, \(total.reverified.count) re-verified against the current PDF, \(stale.count) stale.")
    if !stale.isEmpty { print("  Stale (no longer in the record's PDF — re-record from the right PDF, or drop): \(stale.joined(separator: ", "))") }
    if !recheckClaims.isEmpty { print("  Supported claims now without a current quote (judgment needs revalidating): \(recheckClaims.joined(separator: ", "))") }
}
