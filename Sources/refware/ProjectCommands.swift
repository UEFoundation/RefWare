import Foundation
import RefWareCore

/// `refware project list | create <UEF-XXXX> | add-subproject <UEF-XXXX> <name>`
func project(_ args: Arguments) throws {
    var rest = args
    let sub = rest.positionals.isEmpty ? "list" : rest.positionals.removeFirst()
    let libURL = libraryURL(rest)
    var library = try Library.load(from: libURL)
    switch sub {
    case "list":
        let insights = LibraryInsights(library: library, history: History.load(forLibraryAt: libURL))
        for (name, index) in library.projects.sorted(by: { $0.key < $1.key }) {
            let scoped = LibraryInsights(library: library, history: insights.history, project: name)
            print("\(name)  \(scoped.references.count) records · \(index.claims.count) claims · \(index.quotes.count) quotes")
            for s in index.subprojects {
                print("  › \(s)  \(LibraryInsights(library: library, history: insights.history, project: name, subproject: s).references.count) records")
            }
        }
    case "create":
        guard let name = rest.positionals.first, name.range(of: #"^UEF-\w+$"#, options: .regularExpression) != nil else {
            throw UsageError(description: "usage: refware project create UEF-XXXX [--subproject NAME]")
        }
        var index = library.projects[name] ?? ProjectCitationIndex(project: name)
        if let s = rest.options["subproject"], !index.subprojects.contains(s) { index.subprojects.append(s) }
        library.projects[name] = index
        try library.save(to: libURL)
        History.record(HistoryEvent(kind: .projectEdited, project: name, title: "Project \(name) created\(rest.options["subproject"].map { " with sub-project “\($0)”" } ?? "")"), forLibraryAt: libURL)
        print("Project \(name) ready\(rest.options["subproject"].map { " with sub-project “\($0)”" } ?? "").")
    case "add-subproject":
        guard rest.positionals.count == 2 else { throw UsageError(description: "usage: refware project add-subproject UEF-XXXX \"Section 1.3\"") }
        let (name, s) = (rest.positionals[0], rest.positionals[1])
        guard var index = library.projects[name] else { throw EvidenceError.unknownProject(name) }
        if !index.subprojects.contains(s) { index.subprojects.append(s) }
        library.projects[name] = index
        try library.save(to: libURL)
        History.record(HistoryEvent(kind: .projectEdited, project: name, subproject: s, title: "Sub-project “\(s)” added"), forLibraryAt: libURL)
        print("Added sub-project “\(s)” to \(name).")
    case "policy":
        // `refware project policy UEF-XXXX [--ai-may-finalize yes|no]`
        guard let name = rest.positionals.first ?? rest.options["project"], var index = library.projects[name] else {
            throw UsageError(description: "usage: refware project policy UEF-XXXX [--ai-may-finalize yes|no]")
        }
        if let v = rest.options["ai-may-finalize"] {
            guard currentReviewer().type == .human else { throw UsageError(description: "the review policy is set by a person, not an agent") }
            let on = ["yes", "true", "on", "1"].contains(v.lowercased())
            index.aiMayFinalize = on ? true : nil
            library.projects[name] = index
            try library.save(to: libURL)
            History.record(HistoryEvent(kind: .projectEdited, project: name, title: "Review policy: AI judgments \(on ? "may set a claim's status" : "are proposals for a person to accept")"), forLibraryAt: libURL)
        }
        print("\(name): AI judgments \(index.aiMayFinalize == true ? "may set a claim's status" : "are recorded as proposals for a person to accept (default)").")
    default:
        throw UsageError(description: "unknown project subcommand \"\(sub)\"")
    }
}

/// `refware freeze [--note "as submitted to JASIST"]` / `refware unfreeze`
func freeze(_ args: Arguments, on: Bool) throws {
    let libURL = libraryURL(args)
    let who = HistoryEvent.defaultActor ?? personInitials()
    if on {
        try Library.freeze(at: libURL, by: who, note: args.options["note"])
        History.record(HistoryEvent(kind: .freeze, title: "Frozen by \(who)\(args.options["note"].map { " — \($0)" } ?? "")"), forLibraryAt: libURL)
        print("Library frozen. Builds still work (and are logged); edits, merges and imports are refused until `refware unfreeze`.")
    } else {
        try Library.unfreeze(at: libURL)
        History.record(HistoryEvent(kind: .freeze, title: "Unfrozen by \(who)"), forLibraryAt: libURL)
        print("Library unfrozen.")
    }
}

/// `refware status [--project P] [--subproject S]` — the Stats and Status panels as text.
func status(_ args: Arguments) throws {
    let libURL = libraryURL(args)
    let library = try Library.load(from: libURL)
    let history = History.load(forLibraryAt: libURL)
    let project = args.options["project"] ?? RefWareConfig.load().project
    let i = LibraryInsights(library: library, history: history, project: project, subproject: args.options["subproject"])
    if args.flags.contains("json") {
        struct Out: Encodable {
            var project: String?; var subproject: String?; var frozen: Bool
            var records: Int; var withPDF: Int; var verifiedClaimQuotes: Int; var verifiedQuotations: Int; var staleQuotations: [String]
            var claims: Int; var supportedClaims: Int; var questionedClaims: [String]; var claimsAwaitingDecision: [String]; var subprojects: Int
            var lastClaimsExport: Date?; var lastBuild: Date?
            var unverifiedPDFs: [IDI]; var verifiedPDFsWithoutClaims: [IDI]; var quotesNotExported: [String]
            var notHitEver: [IDI]; var notHitLast: [IDI]; var quotesNotHitEver: [String]; var quotesNotHitLast: [String]
        }
        try printJSON(Out(project: project, subproject: args.options["subproject"], frozen: library.frozen != nil,
                          records: i.references.count, withPDF: i.withPDF.count,
                          verifiedClaimQuotes: i.verifiedQuotes.filter { i.claimQuoteTags.contains($0.tag) }.count,
                          verifiedQuotations: i.verifiedQuotes.count, staleQuotations: i.staleQuotes.map(\.tag),
                          claims: i.claims.count, supportedClaims: i.supportedClaims.count, questionedClaims: i.questionedClaims.map(\.id),
                          claimsAwaitingDecision: i.claimsWithProposals.map(\.id), subprojects: i.subprojectCount,
                          lastClaimsExport: history.last(.claimsExport, project: project)?.date, lastBuild: history.last(.build, project: project)?.date,
                          unverifiedPDFs: i.unverifiedPDFs.map(\.id), verifiedPDFsWithoutClaims: i.verifiedPDFsWithoutClaims.map(\.id),
                          quotesNotExported: i.quotesNotExported.map(\.tag), notHitEver: i.notHit(.ever).map(\.id), notHitLast: i.notHit(.last).map(\.id),
                          quotesNotHitEver: i.quotesNotHit(.ever).map(\.tag), quotesNotHitLast: i.quotesNotHit(.last).map(\.tag)))
        return
    }
    func pct(_ n: Int, _ of: Int) -> String { of == 0 ? "\(n)" : "\(n) (\(Int((Double(n) / Double(of) * 100).rounded()))%)" }
    let date = { (d: Date?) in d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never" }
    print("\(project ?? "Whole library")\(args.options["subproject"].map { " › \($0)" } ?? "")\(library.frozen.map { "  ❄︎ frozen since \($0.on.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
    print("Stats")
    print("  PDFs (IDIs with a PDF)            \(i.withPDF.count) of \(i.references.count)")
    print("  Verified quotations (on claims)   \(i.verifiedQuotes.filter { i.claimQuoteTags.contains($0.tag) }.count) of \(i.verifiedQuotes.count) verified")
    print("  Supported claims                  \(pct(i.supportedClaims.count, i.claims.count))")
    if !i.questionedClaims.isEmpty { print("  Questioned claims (open flags)    \(i.questionedClaims.map(\.id).joined(separator: ", "))") }
    if !i.claimsWithProposals.isEmpty { print("  AI proposals awaiting a person    \(i.claimsWithProposals.map(\.id).joined(separator: ", "))") }
    if !i.staleQuotes.isEmpty { print("  Stale quotations (PDF changed)    \(i.staleQuotes.map(\.tag).joined(separator: ", "))  — refware recheck") }
    print("  Sub-projects                      \(i.subprojectCount)")
    print("  Last claims-list export           \(date(history.last(.claimsExport, project: project)?.date))")
    print("  Last cite/ref build               \(date(history.last(.build, project: project)?.date))")
    print("Status")
    print("  PDFs with unverified metadata     \(pct(i.unverifiedPDFs.count, i.withPDF.count))")
    print("  Verified PDFs, no quotations      \(pct(i.verifiedPDFsWithoutClaims.count, i.withPDF.count))")
    print("  Quotations not yet exported       \(pct(i.quotesNotExported.count, i.verifiedQuotes.count))")
    print("  IDIs not hit in a C/R build       ever \(pct(i.notHit(.ever).count, i.references.count)) · last \(pct(i.notHit(.last).count, i.references.count))")
    print("  IDI-Qs not hit in a C/R build     ever \(pct(i.quotesNotHit(.ever).count, i.verifiedQuotes.count)) · last \(pct(i.quotesNotHit(.last).count, i.verifiedQuotes.count))")
}

/// `refware nohit [--last] [--quotes]` — records (or quotes) not cited in any / the last C/R build.
func nohit(_ args: Arguments) throws {
    let libURL = libraryURL(args)
    let library = try Library.load(from: libURL)
    let i = LibraryInsights(library: library, history: History.load(forLibraryAt: libURL),
                            project: args.options["project"] ?? RefWareConfig.load().project, subproject: args.options["subproject"])
    let scope: LibraryInsights.BuildScope = args.flags.contains("last") ? .last : .ever
    if args.flags.contains("quotes") {
        for q in i.quotesNotHit(scope) { print("\(q.tag)  p. \(q.page ?? 0)  \(q.text.prefix(80))") }
    } else {
        for r in i.notHit(scope) { print("IDI \(r.id)  \(CitationFormatter(references: [r]).inline([r]))  \(r.title)") }
    }
}
