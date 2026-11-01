import Foundation
import RefWareCore

func claims(_ args: Arguments) async throws {
    var rest = args
    guard !rest.positionals.isEmpty else { throw UsageError(description: "claims needs a subcommand (import, resolve, list, show, link, set, add, export)") }
    let sub = rest.positionals.removeFirst()
    let project = try requireProject(rest)
    let url = libraryURL(rest)
    var library = try Library.load(from: url)

    switch sub {
    case "import":
        guard let path = rest.positionals.first else { throw UsageError(description: "claims import needs a transcript file") }
        let file = URL(fileURLWithPath: path).lastPathComponent
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let next = Int(index.nextClaimID.dropFirst()) ?? 1
        var found: [Claim]
        var notes: [String] = []
        if ClaimsListImporter.looksLikeClaimsList(content) {
            let r = ClaimsListImporter(file: file).claims(from: content, library: library, firstID: next)
            found = r.claims
            notes += r.unresolved.map { "  unresolved \($0)" }
            if !r.fragments.isEmpty { notes.append("  looks cut off (check against the manuscript): \(r.fragments.joined(separator: ", "))") }
        } else {
            let speakers = rest.options["speaker"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            found = TranscriptImporter(file: file, speakers: speakers).claims(from: content, firstID: next)
        }
        guard !found.isEmpty else {
            throw UsageError(description: "no claims found in \(file). RefWare imports chat transcripts (**Me**: / **Assistant**: turns with footnoted sources) and claims lists (## C1 headings, the claim as a > quote, then its in-text citations).")
        }
        if let s = rest.options["subproject"] { for i in found.indices { found[i].subproject = s } }
        let (added, existing) = index.addClaims(found)
        if !existing.isEmpty {
            notes.append("  \(existing.count) already in \(project) (same text) — not added again: \(existing.map(\.id).joined(separator: ", "))")
        }
        found = added
        for id in found.flatMap(\.references) { index.addReference(id) }
        if let domains = rest.options["self-domain"] {
            for d in domains.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !index.selfDomains.contains(d) {
                index.selfDomains.append(d)
            }
        }
        library.projects[project] = index
        try library.save(to: url)
        let archived = History.archive(try Data(contentsOf: URL(fileURLWithPath: path)), named: file, project: project, forLibraryAt: url)
        History.record(HistoryEvent(kind: .transcriptImport, project: project, title: "\(file) — \(found.count) claims",
                                    archived: archived, source: path), forLibraryAt: url)
        for n in notes { print(n) }
        let flagged = found.filter { !$0.flags.isEmpty }.count
        print("Imported \(found.count) claims from \(file) (\(flagged) flagged). " + (ClaimsListImporter.looksLikeClaimsList(content) ? "Next: open RefWare ▸ Actions ▸ Verify claims, or `refware claims evidence <C#>`." : "Next: refware claims resolve --project \(project)"))

    case "resolve":
        let mailto = rest.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"]
        let http = URLSessionHTTPClient()
        let resolver = ClaimResolver(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http))
        let report = await resolver.resolve(project: project, in: &library)
        try library.save(to: url)
        print("Linked \(report.linked) source(s); added \(report.added.count) new reference(s).")
        for id in report.added { if let ref = library[id] { print("  + [IDI \(id)] \(CitationFormatter(references: [ref]).inline([ref]))  \(ref.title)") } }
        if !report.unresolved.isEmpty {
            print("\nUnresolved (\(report.unresolved.count)):")
            for u in report.unresolved { print("  - \(u.source)\n      \(u.reason)") }
        }
        for (title, candidates) in report.titleCandidates where !candidates.isEmpty {
            print("\nCrossref candidates for \u{201C}\(title)\u{201D} — NOT linked; confirm before using:")
            for m in candidates {
                let who = m.authors.first?.family ?? "?"
                print("    \(m.title) — \(who) \(m.year.map(String.init) ?? "n.d.")\(m.doi.map { "  doi:\($0)" } ?? "")")
            }
        }

    case "list":
        let index = try projectIndex(library, project)
        let filter = try rest.options["status"].map(claimStatus)
        if rest.flags.contains("json") { try printJSON(index.claims.filter { filter == nil || $0.status == filter }); return }
        for c in index.claims where filter == nil || c.status == filter {
            let refs = c.references.map { "IDI \($0)" }
            let unresolved = c.sources.filter { $0.reference == nil }.count
            var tail = refs.isEmpty ? "" : " [\(refs.joined(separator: ", "))]"
            if unresolved > 0 { tail += " +\(unresolved) unresolved" }
            if !c.quotes.isEmpty { tail += " {\(c.quotes.joined(separator: ", "))}" }
            let flags = c.flags.isEmpty ? "" : " ⚠︎" + c.flags.map(\.rawValue).joined(separator: ",")
            print("\(c.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(c.status.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(String(c.text.prefix(70)))…\(tail)\(flags)")
        }

    case "show":
        let index = try projectIndex(library, project)
        guard let id = rest.positionals.first, let i = index.claimIndex(id) else { throw UsageError(description: "claims show needs a claim ID") }
        let c = index.claims[i]
        let report = ClaimsReport(library: library, project: project)
        let refs = c.references.compactMap { library[$0] }
        print(report.entry(c, index: index, formatter: CitationFormatter(references: refs)).joined(separator: "\n"))
        print("- **Status:** \(c.status.rawValue)")

    case "link":
        guard rest.positionals.count == 2, let idi = Int(rest.positionals[1]) else {
            throw UsageError(description: "usage: claims link <claim> <IDI> [--for \"<citation or title as the claim gives it>\"] --project P")
        }
        guard library[idi] != nil else { throw LibraryError.unknownIDI(idi) }
        let target = library.canonical(idi)
        var index = try projectIndex(library, project)
        guard let i = index.claimIndex(rest.positionals[0]) else { throw EvidenceError.unknownClaim(rest.positionals[0]) }
        var replaced: String?
        if !index.claims[i].references.contains(target) {
            let open = index.claims[i].sources.indices.filter { index.claims[i].sources[$0].reference == nil }
            // Which unresolved source this resolves: the one named by --for, else the only one.
            var slot: Int?
            if let hint = rest.options["for"] {
                let h = hint.lowercased()
                slot = open.first { j in
                    let s = index.claims[i].sources[j]
                    return [s.title, s.url].compactMap { $0?.lowercased() }.contains { $0.contains(h) || h.contains($0) }
                }
                guard slot != nil else {
                    throw UsageError(description: "no unresolved source of \(index.claims[i].id) matches “\(hint)”. Unresolved: "
                        + open.map { index.claims[i].sources[$0].title ?? index.claims[i].sources[$0].url ?? "?" }.joined(separator: " · "))
                }
            } else if open.count == 1 {
                slot = open[0]
            } else if open.count > 1 {
                throw UsageError(description: "\(index.claims[i].id) has \(open.count) unresolved sources — say which with --for \"…\": "
                    + open.map { "“\(index.claims[i].sources[$0].title ?? index.claims[i].sources[$0].url ?? "?")”" }.joined(separator: ", "))
            }
            if let s = slot {
                replaced = index.claims[i].sources[s].title ?? index.claims[i].sources[s].url
                index.claims[i].sources[s].reference = target
                // The hint described what the claim *named*; the record is now the authority.
                index.claims[i].sources[s].title = nil
            } else {
                index.claims[i].sources.append(ClaimSource(reference: target))
            }
        }
        index.addReference(target)
        library.projects[project] = index
        try library.save(to: url)
        History.record(HistoryEvent(kind: .claimEdited, project: project, title: "\(index.claims[i].id) linked to IDI \(target)\(replaced.map { " (was “\($0.prefix(60))”)" } ?? "")", idis: [target]), forLibraryAt: url)
        print("Linked \(index.claims[i].id) → IDI \(target)\(replaced.map { " (resolves “\($0)”)" } ?? "")")

    case "set":
        guard let id = rest.positionals.first else { throw UsageError(description: "claims set needs a claim ID") }
        if let s = rest.options["subproject"] {
            var index = try projectIndex(library, project)
            guard let i = index.claimIndex(id) else { throw EvidenceError.unknownClaim(id) }
            index.claims[i].subproject = s
            if !index.subprojects.contains(s) { index.subprojects.append(s) }
            library.projects[project] = index
            if rest.options["status"] == nil { try library.save(to: url); print("\(id) → sub-project “\(s)”"); return }
        }
        guard let raw = rest.options["status"] else { throw UsageError(description: "--status is required: \(ClaimStatus.allCases.map(\.rawValue).joined(separator: ", "))") }
        let reviewer = currentReviewer()
        let outcome = try library.judge(project: project, claim: id, status: try claimStatus(raw), by: reviewer,
                                        reasons: reasonList(rest), rationale: rest.options["note"], note: rest.options["note"])
        try library.save(to: url)
        let c = library.projects[project]?.claims.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        let proposed = outcome == .proposed
        History.record(HistoryEvent(kind: .claimReviewed, project: project, title: "\(c?.id ?? id) → \(raw)\(proposed ? " (proposed)" : "")\(rest.options["note"].map { " — \($0.prefix(80))" } ?? "")",
                                    idis: c?.references ?? [], quoteTags: c?.quotes ?? []), forLibraryAt: url)
        if proposed {
            print("\(c?.id ?? id) → \(raw), recorded as a proposal by \(reviewer.name); the status stays \(c?.status.rawValue ?? "?") until a person accepts it (`refware claims accept \(c?.id ?? id)`).")
        } else {
            print("\(c?.id ?? id) → \(raw)")
        }

    case "accept", "reject":
        guard let id = rest.positionals.first else { throw UsageError(description: "claims \(sub) needs a claim ID") }
        let reviewer = currentReviewer()
        let message: String
        if sub == "accept" {
            let status = try library.acceptProposal(project: project, claim: id, by: reviewer, note: rest.options["note"])
            message = "\(id) → \(status.rawValue) (proposal accepted by \(reviewer.name))"
        } else {
            let n = try library.rejectProposals(project: project, claim: id, by: reviewer, note: rest.options["note"])
            message = "\(id): \(n) proposal(s) declined by \(reviewer.name); status unchanged"
        }
        try library.save(to: url)
        let c = library.projects[project]?.claims.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        History.record(HistoryEvent(kind: .claimReviewed, project: project, title: message, idis: c?.references ?? [], quoteTags: c?.quotes ?? []), forLibraryAt: url)
        print(message)

    case "flag", "comment", "resolve-flag":
        guard let id = rest.positionals.first else { throw UsageError(description: "claims \(sub) needs a claim ID") }
        let reviewer = currentReviewer()
        let text = rest.options["note"] ?? rest.options["text"]
        let message: String
        switch sub {
        case "flag":
            guard text != nil || !reasonList(rest).isEmpty else { throw UsageError(description: "say what's in question: claims flag \(id) --reason overclaim --note \"…\"") }
            try library.flag(project: project, claim: id, by: reviewer, reasons: reasonList(rest), rationale: text)
            message = "\(id) questioned by \(reviewer.name)\((text ?? reasonList(rest).joined(separator: ", ")).isEmpty ? "" : " — \((text ?? reasonList(rest).joined(separator: ", ")).prefix(80))")"
        case "comment":
            guard let text else { throw UsageError(description: "claims comment \(id) --text \"…\"") }
            try library.comment(project: project, claim: id, by: reviewer, text: text)
            message = "\(id) comment by \(reviewer.name): \(text.prefix(80))"
        default:
            let n = try library.resolveFlags(project: project, claim: id, by: reviewer, note: text)
            message = "\(id): \(n) flag(s) resolved by \(reviewer.name)\(text.map { " — \($0.prefix(80))" } ?? "")"
        }
        try library.save(to: url)
        let c = library.projects[project]?.claims.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        History.record(HistoryEvent(kind: .claimEdited, project: project, title: message, idis: c?.references ?? []), forLibraryAt: url)
        print(message)

    case "history":
        let index = try projectIndex(library, project)
        guard let id = rest.positionals.first, let i = index.claimIndex(id) else { throw UsageError(description: "claims history needs a claim ID") }
        let c = index.claims[i]
        if rest.flags.contains("json") {
            struct Out: Encodable { var claim: String; var status: ClaimStatus; var questioned: Bool; var pendingProposals: Int; var reviews: [ReviewEvent] }
            try printJSON(Out(claim: c.id, status: c.status, questioned: c.isQuestioned, pendingProposals: c.pendingProposals.count, reviews: c.reviews))
            return
        }
        print("\(c.id)  \(c.status.rawValue)\(c.isQuestioned ? "  ⚑ questioned" : "")\(c.pendingProposals.isEmpty ? "" : "  · \(c.pendingProposals.count) proposal(s) pending")")
        if c.reviews.isEmpty { print("  no review events yet\(c.reviewedBy.map { " (status last set by \($0))" } ?? "")") }
        for e in c.reviews {
            let what: String
            switch e.kind {
            case .judgment: what = "\(e.state == .proposed ? "proposed" : "judged") \(e.status?.rawValue ?? "?")\(e.state == .superseded ? " (superseded)" : "")"
            case .flag: what = "flagged\(e.state == .resolved ? " (resolved)" : "")"
            case .comment: what = "comment"
            case .resolution: what = "resolved a flag"
            }
            let who = "\(e.reviewer)\(e.reviewerType == .ai ? " [AI\(e.model.map { ", \($0)" } ?? "")]" : "")"
            var line = "  \(e.date.formatted(date: .abbreviated, time: .shortened))  \(who): \(what)"
            if !e.reasons.isEmpty { line += " — \(e.reasons.joined(separator: ", "))" }
            if let r = e.rationale { line += "\n      \(r)" }
            if !e.quoteTags.isEmpty, e.kind != .comment { line += "\n      relied on: \(e.quoteTags.joined(separator: ", "))" }
            print(line)
        }

    case "add":
        guard let text = rest.options["text"] else { throw UsageError(description: "claims add needs --text") }
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        let claim = Claim(id: index.nextClaimID, text: text)
        index.claims.append(claim)
        library.projects[project] = index
        try library.save(to: url)
        History.record(HistoryEvent(kind: .claimEdited, project: project, title: "\(claim.id) added: \(text.prefix(80))"), forLibraryAt: url)
        print("Added \(claim.id)")

    case "import-notes":
        guard let path = rest.positionals.first else { throw UsageError(description: "claims import-notes needs your edited claims .md file") }
        let edited = try String(contentsOfFile: path, encoding: .utf8)
        let fresh = ClaimsReport(library: library, project: project).markdown()
        let notes = ReviewerNotes.added(edited: edited, generated: fresh)
        var index = try projectIndex(library, project)
        var updated: [String] = []
        for (id, text) in notes.sorted(by: { Int($0.key.dropFirst()) ?? 0 < Int($1.key.dropFirst()) ?? 0 }) {
            guard let i = index.claimIndex(id) else { continue }
            let existing = index.claims[i].note ?? ""
            guard !existing.contains(text) else { continue }
            index.claims[i].note = existing.isEmpty ? text : existing + "\n\n" + text
            updated.append(id)
        }
        library.projects[project] = index
        try library.save(to: url)
        if !updated.isEmpty {
            History.record(HistoryEvent(kind: .claimEdited, project: project, title: "Reviewer notes imported from \(URL(fileURLWithPath: path).lastPathComponent) on \(updated.joined(separator: ", "))",
                                        source: path), forLibraryAt: url)
        }
        print(updated.isEmpty ? "No new notes found." : "Saved your notes on \(updated.joined(separator: ", ")) — they'll appear in every export from now on.")

    case "evidence":
        // Candidate supporting passages from each linked source's PDF; --record N saves one as a verified IDI-Q.
        guard let cid = rest.positionals.first else { throw UsageError(description: "usage: claims evidence <C#> [--record N]") }
        let index = try projectIndex(library, project)
        guard let ci = index.claimIndex(cid) else { throw EvidenceError.unknownClaim(cid) }
        let claim = index.claims[ci]
        let pdfDir = Library.pdfDirectory(forLibraryAt: url)
        var all: [(IDI, Passage, PageLines)] = []
        for id in claim.references {
            guard let ref = library[id], let file = ref.fileName,
                  let pages = try? PDFText.pages(of: pdfDir.appendingPathComponent(file)) else {
                print("  IDI \(id): no readable PDF — attach one to search it"); continue
            }
            for p in EvidenceFinder.passages(for: claim.text, in: pages) { all.append((id, p, pages)) }
        }
        if let pick = rest.options["record"] {
            guard let n = Int(pick), all.indices.contains(n - 1) else { throw UsageError(description: "--record needs a number from the list") }
            let (id, p, pages) = all[n - 1]
            let sha = library[id]?.fileName.flatMap { Library.sha256(of: pdfDir.appendingPathComponent($0)) }
            let record = try library.addQuote(project: project, reference: id, text: p.text, claim: claim.id, pdfPages: pages, pdfSHA256: sha)
            try library.save(to: url)
            History.record(HistoryEvent(kind: .quoteVerified, project: project, title: "\(record.tag), p. \(record.page ?? 0) → \(claim.id)",
                                        idis: [id], quoteTags: [record.tag]), forLibraryAt: url)
            print("\(record.tag) recorded on \(claim.id) (p. \(record.page ?? 0), line \(record.line ?? 0)). Set its status when you've judged it: refware claims set \(claim.id) --status supported|overstated|unsupported")
            return
        }
        if rest.flags.contains("json") {
            struct P: Encodable { var number: Int; var idi: IDI; var page: Int; var line: Int; var text: String; var numbers: [String]; var score: Double }
            try printJSON(all.enumerated().map { i, t in P(number: i + 1, idi: t.0, page: t.1.page, line: t.1.line, text: t.1.text, numbers: t.1.numbers, score: t.1.score) })
            return
        }
        print("\(claim.id)\(claim.origin?.label.map { " (listed as \($0))" } ?? ""): \(claim.text)\n")
        if all.isEmpty { print("  No candidate passages found. Check the PDF by hand, or link the right source with `refware claims link`.") }
        for (i, (id, p, _)) in all.enumerated() {
            let who = library[id].map { CitationFormatter(references: [$0]).inlineBody($0) } ?? "IDI \(id)"
            print("  \(i + 1). [IDI \(id)] \(who) — p. \(p.page), line \(p.line)\(p.numbers.isEmpty ? "" : "  · numbers: \(p.numbers.joined(separator: ", "))")")
            print("     “\(p.text)”\n")
        }
        if !all.isEmpty { print("Record one with: refware claims evidence \(claim.id) --record N   (RefWare finds; you judge.)") }

    case "export":
        let md = ClaimsReport(library: library, project: project).markdown()
        let claims = library.projects[project]?.claims ?? []
        let archived = History.archive(Data(md.utf8), named: URL(fileURLWithPath: rest.options["output"] ?? "claims.md").lastPathComponent,
                                       project: project, forLibraryAt: url)
        History.record(HistoryEvent(kind: .claimsExport, project: project, title: "Claims list — \(claims.count) claims",
                                    idis: Array(Set(claims.flatMap(\.references))).sorted(), quoteTags: claims.flatMap(\.quotes),
                                    archived: archived, source: rest.options["output"]), forLibraryAt: url)
        if let out = rest.options["output"] {
            try md.write(toFile: out, atomically: true, encoding: .utf8)
            stderr("Wrote \(out)")
        } else {
            print(md, terminator: "")
        }

    default:
        throw UsageError(description: "unknown claims subcommand \"\(sub)\"")
    }
}

func pdf(_ args: Arguments) async throws {
    var rest = args
    guard !rest.positionals.isEmpty else { throw UsageError(description: "pdf needs a subcommand (fetch, attach)") }
    let sub = rest.positionals.removeFirst()
    let url = libraryURL(rest)
    var library = try Library.load(from: url)
    let dir = Library.pdfDirectory(forLibraryAt: url)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    switch sub {
    case "fetch":
        let targets: [Reference]
        if rest.flags.contains("all") {
            targets = library.references.values.filter { $0.fileName == nil }.sorted { $0.id < $1.id }
        } else {
            guard let raw = rest.positionals.first, let id = Int(raw), let ref = library[id] else { throw UsageError(description: "pdf fetch needs an IDI or --all") }
            targets = [ref]
        }
        let mailto = rest.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? RefWareConfig.load().mailto
        let http = URLSessionHTTPClient()
        let fetcher = PDFFetcher(http: http, unpaywall: mailto.map { UnpaywallClient(http: http, email: $0) })
        for var ref in targets {
            do {
                guard let data = try await fetcher.fetch(ref) else {
                    print("  [IDI \(ref.id)] no free PDF found — download it yourself, then: refware pdf attach \(ref.id) <file.pdf>  (web pages: refware capture <url>)")
                    continue
                }
                let name = Library.pdfFileName(for: ref)
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                ref.fileName = name
                ref.pdfSHA256 = Library.sha256(of: dir.appendingPathComponent(name))
                try library.update(ref)
                library.revalidateQuotes(of: ref.id, pdfDirectory: dir)
                try library.save(to: url)
                History.record(HistoryEvent(kind: .pdfAdded, title: "PDFs/\(name)", idis: [ref.id], source: "pdf fetch"), forLibraryAt: url)
                print("  [IDI \(ref.id)] saved PDFs/\(name)")
                try await Task.sleep(for: .seconds(1)) // be polite to arXiv
            } catch {
                print("  [IDI \(ref.id)] failed: \(error)")
            }
        }

    case "attach":
        guard rest.positionals.count == 2, let id = Int(rest.positionals[0]), let ref = library[id] else {
            throw UsageError(description: "usage: pdf attach <IDI> <file.pdf>")
        }
        _ = ref
        var source = URL(fileURLWithPath: (rest.positionals[1] as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: source.path) { source = dir.appendingPathComponent(rest.positionals[1]) } // an orphan's bare name
        let data = try Data(contentsOf: source)
        guard data.starts(with: Data("%PDF".utf8)) else { throw EvidenceError.notAPDF(source.path) }
        _ = try PDFText.pages(of: source) // refuse PDFs we can't read text from
        let r = try library.attachPDF(from: source, to: id, pdfDirectory: dir, move: rest.flags.contains("move"))
        try library.save(to: url)
        History.record(HistoryEvent(kind: .pdfAdded, title: "PDFs/\(r.name)", idis: [id], source: source.path), forLibraryAt: url)
        print("[IDI \(id)] attached as PDFs/\(r.name)\(r.replaced.map { " — previous PDF kept as PDFs/merged/\($0)" } ?? "")")

    case "orphans":
        let files = library.unattachedPDFs(in: dir)
        if files.isEmpty { print("No unattached PDFs.") }
        for f in files { print(f) }
        if !files.isEmpty { print("\nAttach one with: refware pdf attach <IDI> <file> --move") }

    default:
        throw UsageError(description: "unknown pdf subcommand \"\(sub)\"")
    }
}

func quote(_ args: Arguments) throws {
    var rest = args
    guard !rest.positionals.isEmpty else { throw UsageError(description: "quote needs a subcommand (add, check)") }
    let sub = rest.positionals.removeFirst()
    guard let raw = rest.positionals.first, let id = Int(raw) else { throw UsageError(description: "quote \(sub) needs an IDI") }
    guard let text = try rest.options["text"] ?? rest.options["text-file"].map({ try String(contentsOfFile: $0, encoding: .utf8) }) else {
        throw UsageError(description: "--text \"…\" (or --text-file) is required")
    }
    let url = libraryURL(rest)
    var library = try Library.load(from: url)
    guard let ref = library[id] else { throw LibraryError.unknownIDI(id) }
    guard let file = ref.fileName else { throw EvidenceError.noPDF(id) }
    let pages = try PDFText.pages(of: Library.pdfDirectory(forLibraryAt: url).appendingPathComponent(file))

    switch sub {
    case "check":
        switch QuoteVerifier.locate(text, in: pages) {
        case .found(let m):
            print("Found in IDI \(id) at p. \(m.page), line \(m.line)" + (m.occurrences > 1 ? " (occurs \(m.occurrences)×)" : ""))
        case .tooShort:
            throw EvidenceError.quoteTooShort
        case .notFound(let w, let t, let n):
            throw EvidenceError.quoteNotFound(id, matchedWords: w, totalWords: t, nearest: n.map { "p. \($0.page), line \($0.line)" })
        }
    case "add":
        let project = try requireProject(rest)
        let sha = Library.sha256(of: Library.pdfDirectory(forLibraryAt: url).appendingPathComponent(file))
        let record = try library.addQuote(project: project, reference: id, text: text, claim: rest.options["claim"], pdfPages: pages, pdfSHA256: sha)
        if let sub = record.submitted { print("  Stored the PDF's own wording: “\(record.text)” (you typed “\(sub)”)") }
        try library.save(to: url)
        History.record(HistoryEvent(kind: .quoteVerified, project: project, title: "\(record.tag), p. \(record.page ?? 0)" + (rest.options["claim"].map { " → \($0)" } ?? ""),
                                    idis: [id], quoteTags: [record.tag]), forLibraryAt: url)
        let who = CitationFormatter(references: [ref]).inlineBody(ref)
        print("\(record.tag) verified — \(who), p. \(record.page ?? 0), line \(record.line ?? 0)" + (rest.options["claim"].map { " → \($0)" } ?? ""))
    default:
        throw UsageError(description: "unknown quote subcommand \"\(sub)\"")
    }
}

func projectIndex(_ library: Library, _ project: String) throws -> ProjectCitationIndex {
    guard let index = library.projects[project] else { throw EvidenceError.unknownProject(project) }
    return index
}

/// `--reason a,b` → ["a", "b"]
func reasonList(_ args: Arguments) -> [String] {
    (args.options["reason"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func claimStatus(_ raw: String) throws -> ClaimStatus {
    guard let s = ClaimStatus(rawValue: raw) else {
        throw UsageError(description: "unknown status \"\(raw)\"; one of: \(ClaimStatus.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return s
}
