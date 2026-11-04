import Foundation
import RefWareCore
import RefWareMac

func audit(_ args: Arguments) async throws {
    guard let path = args.positionals.first else { throw UsageError(description: "audit needs a manuscript file") }
    let project = try projectTag(args)?.project
    let text = try readManuscript(path)

    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"]
    let http = URLSessionHTTPClient()
    let auditor = ManuscriptAuditor(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http))
    var result = await auditor.audit(text) { i, n in stderr("  checking reference \(i)/\(n)…") }

    let importAll = args.flags.contains("import-all")
    if args.flags.contains("import") || importAll || args.flags.contains("claims") {
        guard let project else { throw UsageError(description: "--import needs --project UEF-XXXX") }
        let url = libraryURL(args)
        var library = try Library.load(from: url)
        let (added, reused) = result.importVerified(into: &library, project: project, includeUnverified: importAll, subproject: args.options["subproject"])
        try library.save(to: url)
        if !added.isEmpty {
            History.record(HistoryEvent(kind: .recordUpdated, project: project, subproject: args.options["subproject"],
                                        title: "\(added.count) reference(s) added from the reference list of \(URL(fileURLWithPath: path).lastPathComponent)", idis: added), forLibraryAt: url)
        }
        let unverified = added.filter { library[$0]?.provenance?.verified != true }
        stderr("Library: added \(added.count), already present \(reused.count)" + (importAll
            ? (unverified.isEmpty ? "." : " — \(unverified.count) added as written and unverified (IDI \(unverified.map(String.init).joined(separator: ", "))): check each against the work itself, then Mark as Checked.")
            : " (DOI-matched entries only; --import-all also adds the rest, unverified)."))
    }

    let file = URL(fileURLWithPath: path).lastPathComponent
    if args.flags.contains("claims") {
        guard let project else { throw UsageError(description: "--claims needs --project UEF-XXXX") }
        let url = libraryURL(args)
        var library = try Library.load(from: url)
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        let (found, existing) = index.addClaims(result.claims(from: text, file: file, firstID: Int(index.nextClaimID.dropFirst()) ?? 1))
        if !existing.isEmpty { stderr("Claims: \(existing.count) sentence(s) already in \(project) — not added again (\(existing.map(\.id).joined(separator: ", ")))") }
        for id in found.flatMap(\.references) { index.addReference(id) }
        library.projects[project] = index
        try library.save(to: url)
        History.record(HistoryEvent(kind: .transcriptImport, project: project, title: "\(file) — \(found.count) claims (manuscript)",
                                    archived: History.archive(try Data(contentsOf: URL(fileURLWithPath: path)), named: file, project: project, forLibraryAt: url),
                                    source: path), forLibraryAt: url)
        stderr("Claims: \(found.count) cited sentences added to \(project).")
    }
    if let refsOut = args.options["references-out"] {
        try result.rebuiltReferenceList().write(toFile: refsOut, atomically: true, encoding: .utf8)
        stderr("Wrote \(refsOut)")
    }
    let md = result.markdown(file: file, project: project ?? "(no project)")
    if let out = args.options["output"] {
        try md.write(toFile: out, atomically: true, encoding: .utf8)
        stderr("Wrote \(out)")
    } else {
        print(md, terminator: "")
    }
    let errors = result.entries.filter { $0.record != nil && !$0.errors.isEmpty }.count
    let unknown = result.entries.filter { $0.record == nil }.count
    stderr("\(result.entries.count) entries: \(result.entries.filter(\.isClean).count) clean, \(errors) with errors, \(unknown) not found; \(result.citationIssues.count) in-text problems.")
}

/// `refware tag`: audit + import every entry, then convert hand-typed citations to tags.
func tagManuscript(_ args: Arguments) async throws {
    guard let path = args.positionals.first, path.lowercased().hasSuffix(".docx") else { throw UsageError(description: "tag needs a .docx manuscript") }
    guard let output = args.options["output"] else { throw UsageError(description: "tag needs -o TAGGED.docx (the original is never overwritten)") }
    let inURL = URL(fileURLWithPath: path).standardizedFileURL, outURL = URL(fileURLWithPath: output).standardizedFileURL
    guard inURL != outURL else { throw UsageError(description: "-o must differ from the input") }
    let project = try requireProject(args)

    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"]
    let http = URLSessionHTTPClient()
    let auditor = ManuscriptAuditor(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: mailto), http: http))
    var result = await auditor.audit(try readManuscript(path)) { i, n in stderr("  checking reference \(i)/\(n)…") }

    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    let (added, reused) = result.importVerified(into: &library, project: project, includeUnverified: true)
    try library.save(to: libURL)
    let unverified = result.entries.filter { $0.match != .doi }.compactMap(\.importedAs)
    stderr("Library: added \(added.count), already present \(reused.count); \(unverified.count) unverified (no registry record).")

    var ids: [String: IDI] = [:]
    for e in result.entries { if let id = e.importedAs { ids[DocxTagger.key(forEntry: e.entry.raw)] = id } }
    let (data, report) = try DocxTagger(entryIDs: ids).tag(try Data(contentsOf: inURL))
    try data.write(to: outURL, options: .atomic)

    print("Wrote \(output)")
    print("  \(report.converted) citation(s) converted to [IDI] tags")
    print(report.referenceListReplaced
          ? "  reference section (\(report.referenceEntries) entries) → [IDI # - ALLREF]"
          : "  reference section kept as typed — \(report.unmappedEntries.count) entr(ies) not in the library")
    if !report.skipped.isEmpty {
        print("\n  Left as typed (\(report.skipped.count)) — fix these by hand, then re-run or tag them yourself:")
        for s in report.skipped { print("    ¶\(s.paragraph)  \(s.text)\n          \(s.reason)") }
    }
    if !unverified.isEmpty {
        print("\n  Unverified library entries (from your text or the web page, not a registry): " + unverified.map { "IDI \($0)" }.joined(separator: ", "))
        print("  Check them with `refware show <IDI>`; fix fields with `refware set <IDI> --title/--url/--year/--publication`.")
    }
    print("\nNext: refware cite \(output) -o <final>.docx --project \(project)")
}
