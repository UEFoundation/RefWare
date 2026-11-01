import Foundation
import RefWareCore

/// `refware identify <IDI> [--apply KEY]` — what is this PDF? Suggest (or apply) a match.
func identify(_ args: Arguments) async throws {
    guard let raw = args.positionals.first, let id = Int(raw) else { throw UsageError(description: "identify needs an IDI") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    guard let ref = library[id] else { throw LibraryError.unknownIDI(id) }
    guard let file = ref.fileName else { throw EvidenceError.noPDF(id) }
    let pdfDir = Library.pdfDirectory(forLibraryAt: libURL)
    let pages = try PDFText.pages(of: pdfDir.appendingPathComponent(file))
    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? RefWareConfig.load().mailto
    let http = URLSessionHTTPClient()
    let candidates = uniqueByKey(await PDFIdentifier(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http))
        .identify(pages, library: library, excluding: ref.id))

    guard let pick = args.options["apply"] else {
        print("[IDI \(ref.id)] \(ref.title)  (\(file))")
        if candidates.isEmpty { print("  no matches found — set its fields with `refware set`, or attach the PDF to the right record with `refware merge`") }
        for c in candidates { print("  [\(c.key)] \(describe(c, library))\n       \(c.strong ? "confident" : "suggestion"): \(c.evidence)") }
        if !candidates.isEmpty { print("\nApply one with: refware identify \(ref.id) --apply <key>   (e.g. --apply \(candidates[0].key))") }
        return
    }
    let c = try candidate(pick, in: candidates, command: "identify \(ref.id)")
    let before = CitationFormatter(references: [ref]).referenceEntry(ref)
    print(try apply(c, to: ref.id, library: &library, pdfDirectory: pdfDir))
    try library.save(to: libURL)
    History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(ref.id) identified (\(c.key)): \(c.evidence) — was: \(before)", idis: [ref.id]), forLibraryAt: libURL)
}

func uniqueByKey(_ list: [IdentCandidate]) -> [IdentCandidate] {
    var seen = Set<String>()
    return list.filter { seen.insert($0.key).inserted }
}

/// The suggestion with this key. List numbers aren't accepted: suggestions come partly from
/// the network, so "2" can mean a different record on the next run.
func candidate(_ key: String, in list: [IdentCandidate], command: String) throws -> IdentCandidate {
    if let c = list.first(where: { $0.key == key.lowercased() || $0.key == key }) { return c }
    let keys = list.map(\.key).joined(separator: ", ")
    if Int(key) != nil {
        throw UsageError(description: "--apply takes a suggestion's key, not its number (numbers can shift between runs). Current keys: \(keys.isEmpty ? "none" : keys)")
    }
    throw UsageError(description: "no current suggestion has the key \(key) — run `refware \(command)` again to see the current ones\(keys.isEmpty ? "" : ": \(keys)")")
}

/// `refware merge <from> --into <to>`
func merge(_ args: Arguments) throws {
    guard let raw = args.positionals.first, let from = Int(raw), let intoRaw = args.options["into"], let into = Int(intoRaw) else {
        throw UsageError(description: "usage: refware merge <IDI> --into <IDI>")
    }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    let take = args.flags.contains("take-details")
    let r = try library.merge(from, into: into, pdfDirectory: Library.pdfDirectory(forLibraryAt: libURL),
                              preferIncomingPDF: args.flags.contains("prefer-incoming-pdf") || take, takeIncomingDetails: take)
    try library.save(to: libURL)
    History.record(HistoryEvent(kind: .merge, title: "IDI \(r.retired) → IDI \(r.survivor)", idis: [r.survivor, r.retired]), forLibraryAt: libURL)
    print(mergeSummary(r))
}

func describe(_ c: IdentCandidate, _ library: Library) -> String {
    switch c.kind {
    case .existing(let id):
        guard let r = library[id] else { return "IDI \(id)" }
        return "merge into existing [IDI \(id)] \(CitationFormatter(references: [r]).inline([r])) — \(r.title)"
    case .registry(let m):
        let r = m.makeReference(id: 0, verified: true)
        let what = c.verifies ? "use registry record" : "use details read from the PDF"
        return "\(what): \(CitationFormatter(references: [r]).referenceEntry(r))"
    }
}

func apply(_ c: IdentCandidate, to id: IDI, library: inout Library, pdfDirectory: URL) throws -> String {
    switch c.kind {
    case .existing(let target):
        return mergeSummary(try library.merge(id, into: target, pdfDirectory: pdfDirectory))
    case .registry(let m):
        let old = library[id]
        try library.adopt(m, for: id, verified: c.verifies, pdfDirectory: pdfDirectory)
        let r = library[id]!
        var s = "IDI \(id) is now \(CitationFormatter(references: [r]).inline([r])) — \(r.title) (\(c.verifies ? "verified" : "unverified — details read from the PDF; check and `refware confirm \(id)`"))"
        // Author, year and title all different: this is another work, not a correction.
        if let old, old.authors.first?.family.lowercased() != r.authors.first?.family.lowercased(), old.year != r.year,
           TextCleanup.comparable(old.title) != TextCleanup.comparable(r.title) {
            s += "\n  ⚠︎ This looks like a different work, not a correction (was \(CitationFormatter(references: [old]).inline([old])) — \(old.title))."
            let citing = library.claimsCiting(id)
            if !citing.isEmpty {
                s += "\n    Claims citing IDI \(id) now point at the new work — check them: \(citing.map { "\($0.claim.id)" }.joined(separator: ", "))."
            }
            s += "\n    If the PDF was simply on the wrong record, undo with `refware set \(id) …` and add the PDF's work as its own record."
        }
        return s
    }
}

func mergeSummary(_ r: MergeResult) -> String {
    var s = "Merged IDI \(r.retired) into IDI \(r.survivor). IDI \(r.retired) is retired; tags using it now point to \(r.survivor)."
    if let p = r.pdfNote { s += "\n  \(p)" }
    for (old, new) in r.retaggedQuotes.sorted(by: { $0.key < $1.key }) { s += "\n  quote \(old) → \(new)" }
    return s
}

/// `refware confirm <IDI>…` — you've checked author, year and title against the source itself.
func confirm(_ args: Arguments) throws {
    let ids = args.positionals.compactMap { Int($0) }
    guard !ids.isEmpty else { throw UsageError(description: "confirm needs one or more IDIs") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    // Who checked the record against the source — not necessarily who is running the command.
    let who = args.options["checked-by"] ?? HistoryEvent.defaultActor ?? personInitials()
    for id in ids {
        try library.confirm(id, by: who)
        let r = library[id]!
        print("IDI \(id) \(CitationFormatter(references: [r]).inline([r])) — checked by \(who)")
    }
    try library.save(to: libURL)
    for id in ids { History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(id) checked by \(who)", idis: [id]), forLibraryAt: libURL) }
}

/// The person at this Mac: the configured reviewer's initials, or initials from the account name.
func personInitials() -> String {
    RefWareConfig.load().reviewer ?? NSFullUserName().split(separator: " ").compactMap(\.first).map(String.init).joined()
}

/// Who is reviewing claims from this command line (see `Reviewer.current`).
func currentReviewer() -> Reviewer { Reviewer.current(fallbackHuman: personInitials()) }

/// `refware distinct <IDI> <IDI>…` — same title, different works; stop flagging them.
func distinct(_ args: Arguments) throws {
    let ids = args.positionals.compactMap { Int($0) }
    guard ids.count >= 2 else { throw UsageError(description: "distinct needs two or more IDIs") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    library.markDistinct(ids)
    try library.save(to: libURL)
    History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(ids.map(String.init).joined(separator: ", ")) marked as different works", idis: ids), forLibraryAt: libURL)
    print("Noted: IDI \(ids.map(String.init).joined(separator: ", ")) are different works.")
}

/// `refware unconfirm <IDI>…` — remove a hand check.
func unconfirm(_ args: Arguments) throws {
    let ids = args.positionals.compactMap { Int($0) }
    guard !ids.isEmpty else { throw UsageError(description: "unconfirm needs one or more IDIs") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    for id in ids { try library.unconfirm(id) }
    try library.save(to: libURL)
    for id in ids { History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(id) check removed", idis: [id]), forLibraryAt: libURL) }
    print("Check removed from IDI \(ids.map(String.init).joined(separator: ", ")).")
}

/// `refware delete <IDI> [--reason "…"] [--drop-claims]` — remove a record; its number is retired.
func delete(_ args: Arguments) throws {
    guard let raw = args.positionals.first, let id = Int(raw) else { throw UsageError(description: "usage: refware delete <IDI> [--reason \"…\"] [--drop-claims]") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    guard let ref = library[id], ref.id == id else { throw LibraryError.unknownIDI(id) }
    let citing = library.claimsCiting(id)
    let res = try library.delete(id, reason: args.options["reason"], by: HistoryEvent.defaultActor,
                                 dropClaims: args.flags.contains("drop-claims"), pdfDirectory: Library.pdfDirectory(forLibraryAt: libURL))
    try library.save(to: libURL)
    var summary = "IDI \(id) deleted\(args.options["reason"].map { " (\($0))" } ?? "")"
    if !res.droppedClaims.isEmpty { summary += "; dropped \(res.droppedClaims.joined(separator: ", "))" }
    History.record(HistoryEvent(kind: .recordDeleted, title: summary, idis: [id]), forLibraryAt: libURL)
    print(summary + ".")
    if let p = res.parkedPDF { print("  PDF moved to \(p)") }
    let kept = citing.filter { !res.droppedClaims.contains($0.claim.id) }.map(\.claim.id)
    if !kept.isEmpty { print("  These claims lost this source and need another (or --drop-claims): \(kept.joined(separator: ", "))") }
    if !res.removedQuotes.isEmpty { print("  Removed quotes: \(res.removedQuotes.joined(separator: ", "))") }
}
