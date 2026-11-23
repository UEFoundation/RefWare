import Foundation
import RefWareCore

func archiveClient(_ args: Arguments) -> ArchiveClient {
    ArchiveClient(mailto: args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"] ?? RefWareConfig.load().mailto)
}

/// A dataset record named by IDI or by any of its accessions.
func datasetRecord(_ raw: String?, _ library: Library) throws -> Reference {
    guard let raw else { throw UsageError(description: "name a dataset by IDI or accession") }
    if let n = Int(raw) {
        guard let ref = library[n] else { throw LibraryError.unknownIDI(n) }
        guard ref.dataset != nil else { throw DatasetError.notADataset(n) }
        return ref
    }
    guard let ref = library.dataset(forAccession: raw) else {
        throw UsageError(description: "no dataset record for \(raw) — add it with `refware dataset add \(raw)`")
    }
    return ref
}

func writeOrPrint(_ text: String, _ args: Arguments) throws {
    if let out = args.options["output"] {
        try text.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        print("Wrote \(out)")
    } else {
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    }
}

func describeDataset(_ ref: Reference, in library: Library) -> String {
    let d = ref.dataset!
    var lines = ["[IDI \(ref.id)] \(d.accession)  \(d.kind.label) · \(d.repository)\(d.access == .controlled ? " · CONTROLLED ACCESS" : "")",
                 "  title:     \(d.archiveTitle ?? ref.title)"]
    if !d.otherAccessions.isEmpty { lines.append("  also:      \(d.otherAccessions.joined(separator: ", "))") }
    if let o = d.organism, !o.isEmpty { lines.append("  organism:  \(o)") }
    if let s = d.submitter { lines.append("  submitter: \(s)") }
    if let r = d.released { lines.append("  released:  \(r)") }
    if !d.assays.isEmpty || !d.platforms.isEmpty { lines.append("  assay:     \(d.assays.joined(separator: ", "))\(d.platforms.isEmpty ? "" : " · \(d.platforms.joined(separator: ", "))")") }
    lines.append("  size:      \(d.samples.map { "\($0) samples" } ?? "? samples") · \(d.runs.map { "\($0) runs" } ?? "? runs")")
    for p in ref.projects { lines.append("  project:   \(p.project)\(p.subprojects.isEmpty ? "" : " › " + p.subprojects.joined(separator: "; "))") }
    let f = CitationFormatter(references: Array(library.references.values))
    for p in d.papers { if let paper = library[p] { lines.append("  paper:     IDI \(p) \(f.inline([paper])) — link \(d.paperLink?.rawValue ?? "not checked")") } }
    if !d.mentionedBy.isEmpty { lines.append("  cited by:  \(d.mentionedBy.prefix(6).joined(separator: ", "))\(d.mentionedBy.count > 6 ? " (+\(d.mentionedBy.count - 6))" : "")") }
    for s in d.snapshots.sorted(by: { $0.fetched < $1.fetched }) {
        lines.append("  run table: \(s.fetched.formatted(date: .abbreviated, time: .shortened)) · \(s.runs) runs, \(s.samples) samples · SHA-256 \(s.sha256.prefix(12))… · datasets/\(s.file)")
    }
    for r in d.keyRules { lines.append("  key rule:  \(r.name)\(r.retired == nil ? "" : " (retired)") — \(r.field) =~ /\(r.pattern)/ → \(r.groups.joined(separator: ", ")) · \(r.by ?? "?"), \(r.on.formatted(date: .abbreviated, time: .omitted))\(r.note.map { " · \($0)" } ?? "")") }
    for w in d.warnings { lines.append("  ⚠︎ \(w)") }
    lines.append("  cite as:   [IDI \(ref.id)] → \(f.referenceEntry(ref))")
    return lines.joined(separator: "\n")
}

/// `refware dataset add|list|show|runs|diff|key|keys|link|table`
func dataset(_ args: Arguments) async throws {
    var rest = args
    let sub = rest.positionals.isEmpty ? "list" : rest.positionals.removeFirst()
    let libURL = libraryURL(rest)
    var library = try Library.load(from: libURL)
    let client = archiveClient(rest)
    let by = HistoryEvent.defaultActor

    switch sub {
    case "add":
        guard !rest.positionals.isEmpty else { throw UsageError(description: "usage: refware dataset add <PRJNA…|SRP…|GSE…|phs…>… [--project P] [--paper IDI] [--expect \"what you think it is\"] [--anyway]") }
        let tag = try projectTag(rest)
        let papers = rest.options["paper"].map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        var failures = 0
        for acc in rest.positionals {
            do {
                let r = try await DatasetAdder(client: client).add(acc, to: &library, libraryURL: libURL, project: tag, papers: papers,
                                                                   expect: rest.options["expect"], fetchRuns: !rest.flags.contains("no-runs"), by: by,
                                                                   anyway: rest.flags.contains("anyway"))
                try library.save(to: libURL)
                if r.isNew {
                    History.record(HistoryEvent(kind: .recordUpdated, project: tag?.project, title: "Dataset \(r.record.dataset!.accession) added as IDI \(r.record.id)\(r.warnings.isEmpty ? "" : " — \(r.warnings.count) warning(s)")",
                                                idis: [r.record.id], source: "archive"), forLibraryAt: libURL)
                }
                print((r.isNew ? "Added " : "") + describeDataset(r.record, in: library))
                for n in r.notes { print("  · \(n)") }
                if r.isNew, !r.mentioning.isEmpty {
                    print("  Papers whose text cites it:")
                    for p in r.mentioning.prefix(5) { print("    - \(p.authors.prefix(60)) (\(p.year ?? "n.d.")) \(p.title)\(p.doi.map { " https://doi.org/\($0)" } ?? "")") }
                }
                print("")
            } catch {
                failures += 1
                stderr("✗ \(acc): \(error)")
            }
        }
        if failures > 0 { exit(1) }

    case "list":
        let project = rest.options["project"] ?? (rest.flags.contains("all") ? nil : RefWareConfig.load().project)
        let list = library.datasets.filter { project == nil || $0.projects.contains { $0.project == project } }
        if rest.flags.contains("json") { try printJSON(list); return }
        if list.isEmpty { print("No dataset records\(project.map { " in \($0)" } ?? "")."); return }
        for ref in list {
            let d = ref.dataset!
            print("[IDI \(ref.id)] \(d.accession)\(d.otherAccessions.isEmpty ? "" : " (\(d.otherAccessions.joined(separator: ", ")))")  \(d.runs.map { "\($0) runs" } ?? "")  \(d.archiveTitle ?? ref.title)\(d.warnings.isEmpty ? "" : "  ⚠︎")")
        }

    case "show":
        let ref = try datasetRecord(rest.positionals.first, library)
        if rest.flags.contains("json") { try printJSON(ref); return }
        print(describeDataset(ref, in: library))

    case "runs":
        var ref = try datasetRecord(rest.positionals.first, library)
        var d = ref.dataset!
        if rest.flags.contains("refresh") || d.snapshots.isEmpty {
            guard let target = d.allAccessions.first(where: { [.bioproject, .study].contains(Accession.kind(of: $0)) }) else {
                throw UsageError(description: "\(d.accession) has no BioProject or SRA study to fetch runs for")
            }
            let rows = try await client.runTable(target)
            guard !rows.isEmpty else { throw DatasetError.noRunTable(target) }
            let previous = d.latestSnapshot
            let (snap, isNew) = try DatasetStore.save(rows, for: d.accession, source: "ENA filereport \(target)", libraryURL: libURL, previous: previous, by: by)
            if isNew {
                d.snapshots.append(snap); d.runs = snap.runs; d.samples = snap.samples
                d.assays = Array(Set(rows.compactMap(\.strategy))).sorted(); d.platforms = Array(Set(rows.compactMap(\.instrument))).sorted()
                ref.dataset = d
                try library.update(ref)
                try library.save(to: libURL)
                History.record(HistoryEvent(kind: .recordUpdated, title: "Run table for \(d.accession): \(snap.runs) runs (SHA-256 \(snap.sha256.prefix(12)))", idis: [ref.id], source: snap.file), forLibraryAt: libURL)
                if let previous, let old = try? DatasetStore.rows(previous, libraryURL: libURL) {
                    let diff = RunTable.diff(old: old, new: rows)
                    print("The archive's run table changed since \(previous.fetched.formatted(date: .abbreviated, time: .shortened)):")
                    printDiff(diff)
                } else {
                    print("Saved the run table: \(snap.runs) runs, \(snap.samples) samples → datasets/\(snap.file)")
                }
            } else {
                print("Unchanged since \(snap.fetched.formatted(date: .abbreviated, time: .shortened)) (same SHA-256).")
            }
        }
        guard let snap = d.latestSnapshot else { throw DatasetError.noRunTable(d.accession) }
        let rows = try DatasetStore.rows(snap, libraryURL: libURL)
        if rest.options["output"] != nil { try writeOrPrint(RunTable.tsv(rows), rest); return }
        if rest.flags.contains("json") { try printJSON(rows); return }
        print("\(d.accession): \(rows.count) runs, \(snap.samples) samples · \(DatasetStore.url(snap, libraryURL: libURL).path)")
        for r in rows.prefix(rest.flags.contains("all") ? .max : 10) {
            print("  \(r.run)  \(r.biosample ?? "-")  \(r.alias ?? "-")  \(r.strategy ?? "")  \(r.reads.map { "\($0) reads" } ?? "")")
        }
        if rows.count > 10, !rest.flags.contains("all") { print("  … \(rows.count - 10) more (--all, --json, or -o runs.tsv)") }

    case "diff":
        let ref = try datasetRecord(rest.positionals.first, library)
        let snaps = ref.dataset!.snapshots.sorted { $0.fetched < $1.fetched }
        guard snaps.count >= 2 else { print("Only \(snaps.count) run table on record — `refware dataset runs \(ref.dataset!.accession) --refresh` fetches another to compare."); return }
        let (a, b) = (snaps[snaps.count - 2], snaps[snaps.count - 1])
        print("\(ref.dataset!.accession): \(a.fetched.formatted(date: .abbreviated, time: .shortened)) → \(b.fetched.formatted(date: .abbreviated, time: .shortened))")
        printDiff(RunTable.diff(old: try DatasetStore.rows(a, libraryURL: libURL), new: try DatasetStore.rows(b, libraryURL: libURL)))

    case "key":
        // `dataset key PRJNA516684 --name couple --pattern '(\d{2}-\d{2}-\d{2})-(\d{5})(\d)' --groups date,couple,member [--field alias] [--note "…"]`
        var ref = try datasetRecord(rest.positionals.first, library)
        guard let name = rest.options["name"], let pattern = rest.options["pattern"], let groups = rest.options["groups"] else {
            throw UsageError(description: "usage: refware dataset key <IDI|ACC> --name NAME --pattern REGEX --groups a,b,c [--field alias|title|run|biosample] [--note \"why\"]")
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else { throw DatasetError.badPattern(pattern) }
        let names = groups.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard re.numberOfCaptureGroups == names.count else {
            throw UsageError(description: "the pattern has \(re.numberOfCaptureGroups) capture group(s) but --groups names \(names.count)")
        }
        let rule = SampleKeyRule(name: name, field: rest.options["field"] ?? "alias", pattern: pattern, groups: names, note: rest.options["note"], by: by)
        // Preview on the run table before recording.
        if let snap = ref.dataset!.latestSnapshot {
            let cw = try rule.crosswalk(try DatasetStore.rows(snap, libraryURL: libURL))
            printCrosswalkSummary(cw, rule: rule)
        }
        var d = ref.dataset!
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var retired: [String] = []
        for i in d.keyRules.indices where d.keyRules[i].name == name && d.keyRules[i].retired == nil {
            d.keyRules[i].retired = now; retired.append(d.keyRules[i].pattern)
        }
        d.keyRules.append(rule)
        ref.dataset = d
        try library.update(ref)
        try library.save(to: libURL)
        History.record(HistoryEvent(kind: .recordUpdated, title: "Key rule “\(name)” for \(d.accession): \(rule.field) =~ /\(pattern)/ → \(names.joined(separator: ", "))\(retired.isEmpty ? "" : " (replaces /\(retired.joined(separator: "/, /"))/)")",
                                    idis: [ref.id]), forLibraryAt: libURL)
        print(retired.isEmpty ? "Recorded key rule “\(name)”." : "Recorded key rule “\(name)”; the earlier version is kept, marked retired.")

    case "keys":
        let ref = try datasetRecord(rest.positionals.first, library)
        let d = ref.dataset!
        guard let rule = rest.options["rule"].flatMap({ n in d.activeKeyRules.first { $0.name == n } }) ?? (rest.options["rule"] == nil ? d.activeKeyRules.last : nil) else {
            throw rest.options["rule"].map { DatasetError.unknownRule($0) } ?? UsageError(description: "\(d.accession) has no key rule — record one with `refware dataset key`")
        }
        guard let snap = d.latestSnapshot else { throw DatasetError.noRunTable(d.accession) }
        let cw = try rule.crosswalk(try DatasetStore.rows(snap, libraryURL: libURL))
        if rest.options["output"] != nil {
            try writeOrPrint(cw.tsv, rest)
            printCrosswalkSummary(cw, rule: rule)
        } else if rest.flags.contains("json") {
            try printJSON(cw.rows.map { Dictionary(uniqueKeysWithValues: zip(cw.header, $0)) })
        } else {
            printCrosswalkSummary(cw, rule: rule)
            print(cw.header.joined(separator: "\t"))
            for r in cw.rows.prefix(20) { print(r.joined(separator: "\t")) }
            if cw.rows.count > 20 { print("… \(cw.rows.count - 20) more (-o crosswalk.tsv)") }
        }

    case "link":
        var ref = try datasetRecord(rest.positionals.first, library)
        guard let raw = rest.options["paper"], let paper = Int(raw), let p = library[paper] else { throw UsageError(description: "usage: refware dataset link <IDI|ACC> --paper IDI") }
        var d = ref.dataset!
        if !d.papers.contains(paper) { d.papers.append(paper) }
        var mentioning: [ArchiveClient.Paper] = []
        for a in d.allAccessions.prefix(3) { mentioning += (try? await client.papers(citing: a)) ?? [] }
        d.mentionedBy = Array(Set(d.mentionedBy + mentioning.compactMap { $0.doi?.lowercased() })).sorted()
        if let doi = p.doi?.lowercased(), d.mentionedBy.contains(doi) {
            d.paperLink = .confirmed
            print("Confirmed: IDI \(paper)'s full text cites \(d.accession).")
        } else if !d.mentionedBy.isEmpty {
            d.paperLink = .otherPapers
            print("⚠︎ IDI \(paper) isn't among the papers indexed as citing \(d.accession):")
            for m in mentioning.prefix(5) { print("   - \(m.authors.prefix(50)) (\(m.year ?? "n.d.")) \(m.title)") }
        } else {
            d.paperLink = .unconfirmed
            print("No indexed paper cites \(d.accession); the link is recorded as stated, not confirmed.")
        }
        ref.dataset = d
        try library.update(ref)
        try library.save(to: libURL)
        History.record(HistoryEvent(kind: .recordUpdated, title: "Dataset \(d.accession) linked to IDI \(paper) (\(d.paperLink!.rawValue))", idis: [ref.id, paper]), forLibraryAt: libURL)

    case "table":
        let project = rest.options["project"] ?? (rest.flags.contains("all") ? nil : RefWareConfig.load().project)
        let md = rest.options["output"].map { $0.hasSuffix(".md") } ?? !rest.flags.contains("tsv")
        try writeOrPrint(md ? DatasetTable.markdown(library, project: project) : DatasetTable.tsv(library, project: project), rest)

    default:
        throw UsageError(description: "unknown dataset subcommand \"\(sub)\" (add, list, show, runs, diff, key, keys, link, table)")
    }
}

func printDiff(_ diff: RunTable.Diff) {
    if diff.isEmpty { print("  no differences"); return }
    if !diff.added.isEmpty { print("  + \(diff.added.count) run(s) added: \(diff.added.prefix(12).joined(separator: ", "))\(diff.added.count > 12 ? " …" : "")") }
    if !diff.removed.isEmpty { print("  − \(diff.removed.count) run(s) removed: \(diff.removed.prefix(12).joined(separator: ", "))\(diff.removed.count > 12 ? " …" : "")") }
    for c in diff.changed.prefix(20) { print("  ~ \(c.run): \(c.changes.joined(separator: "; "))") }
    if diff.changed.count > 20 { print("  … \(diff.changed.count - 20) more changed") }
}

func printCrosswalkSummary(_ cw: SampleKeyRule.Crosswalk, rule: SampleKeyRule) {
    print("Rule “\(rule.name)”: \(cw.rows.count) runs matched, \(cw.unmatched.count) didn't.")
    for g in rule.groups {
        guard let sizes = cw.groupSizes[g], let n = cw.distinct[g] else { continue }
        let shown = sizes.sorted { $0.key < $1.key }
        print("  \(g): \(n) distinct — runs per \(g): " + shown.prefix(8).map { "\($0.value)×\($0.key)" }.joined(separator: " · ") + (shown.count > 8 ? " …" : ""))
    }
    if !cw.unmatched.isEmpty {
        print("  unmatched, e.g.: " + cw.unmatched.prefix(5).map { "\($0.run) “\(rule.value(in: $0) ?? "")”" }.joined(separator: ", "))
    }
}

/// `refware accessions <file|folder>… [--project P] [-o report.md] [--json]`
func accessions(_ args: Arguments) async throws {
    guard !args.positionals.isEmpty else { throw UsageError(description: "usage: refware accessions <file or folder>… [--project UEF-XXXX] [-o report.md]") }
    let fm = FileManager.default
    let exts: Set<String> = ["md", "txt", "tsv", "csv", "json", "rtf", "py", "r", "sh", "html", "tex"]
    var files: [(String, String)] = []
    for p in args.positionals {
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw UsageError(description: "no such file: \(p)") }
        // In a folder: documents and tables, not pipeline scratch (per-run work files, reads, reference databases, run-table copies).
        let skipDirs: (String) -> Bool = { d in
            d.hasPrefix(".") || d.hasPrefix("work") || d.hasPrefix("fastq") || ["ref", "refs", "refware", "run-tables", "__pycache__", "node_modules", "datasets", "PDFs"].contains(d)
        }
        let urls: [URL] = isDir.boolValue ? (fm.subpaths(atPath: url.path) ?? []).filter { rel in
            let parts = rel.split(separator: "/").map(String.init)
            return args.flags.contains("everything") || !parts.dropLast().contains(where: skipDirs)
        }.map { url.appendingPathComponent($0) } : [url]
        for u in urls where exts.contains(u.pathExtension.lowercased()) || !isDir.boolValue {
            if let size = try? fm.attributesOfItem(atPath: u.path)[.size] as? Int, size > (isDir.boolValue ? 5_000_000 : 50_000_000) { continue }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let rel = isDir.boolValue ? String(u.path.dropFirst(url.path.count + 1)) : u.lastPathComponent
            files.append((rel, text))
        }
    }
    let libURL = libraryURL(args)
    let library = try Library.load(from: libURL)
    let project = args.options["project"] ?? RefWareConfig.load().project
    let report = await AccessionAudit(client: archiveClient(args)).run(files: files, library: library, libraryURL: libURL, project: project)
    if args.flags.contains("json") { try printJSON(report); return }
    if let out = args.options["output"] {
        try report.markdown.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        let e = report.findings.filter { $0.severity == .error }, w = report.findings.filter { $0.severity == .warning }
        print("\(report.checked.count + report.unchecked.count) accessions in \(files.count) file(s): \(e.count) errors, \(w.count) warnings. Report: \(out)")
        for f in (e + w).prefix(15) { print("  \(f.severity.symbol) \(f.accession): \(f.message)") }
    } else {
        print(report.markdown)
    }
    History.record(HistoryEvent(kind: .other, project: project, title: "Accession audit: \(report.checked.count) checked, \(report.findings.filter { $0.severity == .error }.count) errors, \(report.findings.filter { $0.severity == .warning }.count) warnings",
                                source: args.positionals.joined(separator: ", ")), forLibraryAt: libURL)
}

/// `refware manifest <samples.tsv|.csv> [--run-column C] [--project-column C] [--biosample-column C] [--alias-column C] [--reads-column C]`
func manifest(_ args: Arguments) async throws {
    var rest = args
    if rest.positionals.first == "check" { rest.positionals.removeFirst() }
    guard let path = rest.positionals.first else { throw UsageError(description: "usage: refware manifest <samples.tsv|.csv> [-o report.md] [--json]") }
    let text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    let libURL = libraryURL(rest)
    let library = try Library.load(from: libURL)
    var overrides: [String: String] = [:]
    for role in ["run", "project", "biosample", "alias", "reads"] { if let c = rest.options["\(role)-column"] { overrides[role] = c } }
    let report = await ManifestCheck(client: archiveClient(rest)).run(text: text, name: (path as NSString).lastPathComponent, library: library,
                                                                     libraryURL: libURL, overrides: overrides, fetchMissing: !rest.flags.contains("no-fetch"))
    if rest.flags.contains("json") { try printJSON(report); return }
    if let out = rest.options["output"] {
        try report.markdown.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        let e = report.issues.filter { $0.severity == .error }
        print("\(report.rows) rows, \(report.runsChecked) runs checked: \(e.count) errors, \(report.issues.filter { $0.severity == .warning }.count) warnings. Report: \(out)")
        for i in e.prefix(15) { print("  ✗ row \(i.row) \(i.run ?? ""): \(i.message)") }
    } else {
        print(report.markdown)
    }
    History.record(HistoryEvent(kind: .other, title: "Manifest check of \(report.file): \(report.runsChecked) runs, \(report.issues.filter { $0.severity == .error }.count) errors", source: path), forLibraryAt: libURL)
    if report.issues.contains(where: { $0.severity == .error }) { exit(2) }
}

/// `refware fastq <folder> [-o report.md] [--json]`
func fastq(_ args: Arguments) async throws {
    var rest = args
    if rest.positionals.first == "verify" { rest.positionals.removeFirst() }
    guard let path = rest.positionals.first else { throw UsageError(description: "usage: refware fastq <folder of downloaded reads> [-o report.md] [--json]") }
    let libURL = libraryURL(rest)
    let library = try Library.load(from: libURL)
    let items = try await FastqCheck(client: archiveClient(rest)).run(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), library: library, libraryURL: libURL)
    if rest.flags.contains("json") { try printJSON(items); return }
    var counts: [FastqCheck.Status: Int] = [:]
    for i in items { counts[i.status, default: 0] += 1 }
    var lines = ["# FASTQ check: \(path)", "", "\(items.count) files: " + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", "), ""]
    for i in items where ![.complete, .partial].contains(i.status) { lines.append("- **\(i.status.rawValue)** \(i.file): \(i.detail)") }
    if items.contains(where: { $0.status == .partial }) {
        lines.append("")
        lines.append("Partial (records intact): " + items.filter { $0.status == .partial }.prefix(40).map(\.file).joined(separator: ", ") + (items.filter { $0.status == .partial }.count > 40 ? " …" : ""))
    }
    try writeOrPrint(lines.joined(separator: "\n") + "\n", rest)
}

/// `refware export --project P --to DIR [--no-pdfs]` — a project's references, datasets, claims and PDFs as plain
/// files in a folder others can read (e.g. a MAVIS project folder, for collaborators without the CLI).
func export(_ args: Arguments) throws {
    let project = try requireProject(args)
    guard let to = args.options["to"] ?? args.positionals.first else { throw UsageError(description: "usage: refware export --project UEF-XXXX --to <folder> [--no-pdfs]") }
    let libURL = libraryURL(args)
    let library = try Library.load(from: libURL)
    try requireKnownProject(project, subproject: nil, in: library)
    let dir = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let refs = library.references.values.filter { $0.projects.contains { $0.project == project } || library.projects[project]?.references.contains($0.id) == true }
        .sorted { $0.id < $1.id }
    let f = CitationFormatter(references: Array(library.references.values), markup: .markdown)
    let papers = refs.filter { $0.dataset == nil }, datasets = refs.filter { $0.dataset != nil }
    var md = ["# \(project) — references", "", "Exported from RefWare \(Date().formatted(date: .abbreviated, time: .shortened)). Cite with the [IDI n] tags; don't retype accessions or citations.", ""]
    md.append("## Papers (\(papers.count))")
    for r in papers { md.append("- **[IDI \(r.id)]** \(f.referenceEntry(r))\(r.provenance?.verified == true ? "" : " *(unverified)*")\(r.fileName.map { " — PDF: `PDFs/\($0)`" } ?? "")") }
    md += ["", "## Datasets (\(datasets.count))"]
    for r in datasets { md.append("- **[IDI \(r.id)]** \(r.dataset!.accession) — \(f.referenceEntry(r))") }
    try (md.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("references.md"), atomically: true, encoding: .utf8)
    try DatasetTable.tsv(library, project: project).write(to: dir.appendingPathComponent("datasets.tsv"), atomically: true, encoding: .utf8)
    if library.projects[project]?.claims.isEmpty == false {
        try ClaimsReport(library: library, project: project).markdown().write(to: dir.appendingPathComponent("claims.md"), atomically: true, encoding: .utf8)
    }
    var copied = 0, runTables = 0
    if !args.flags.contains("no-pdfs") {
        let src = Library.pdfDirectory(forLibraryAt: libURL), pdfs = dir.appendingPathComponent("PDFs")
        try fm.createDirectory(at: pdfs, withIntermediateDirectories: true)
        for r in papers {
            guard let file = r.fileName, fm.fileExists(atPath: src.appendingPathComponent(file).path) else { continue }
            let target = pdfs.appendingPathComponent(file)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: src.appendingPathComponent(file), to: target)
            copied += 1
        }
    }
    let runDir = dir.appendingPathComponent("run-tables")
    for r in datasets {
        guard let snap = r.dataset!.latestSnapshot else { continue }
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let target = runDir.appendingPathComponent("\(r.dataset!.accession).tsv")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: DatasetStore.url(snap, libraryURL: libURL), to: target)
        runTables += 1
    }
    History.record(HistoryEvent(kind: .referenceExport, project: project, title: "Exported \(project) to \(OutputEvidence.displayPath(dir)): \(papers.count) papers (\(copied) PDFs), \(datasets.count) datasets",
                                idis: refs.map(\.id), source: dir.path), forLibraryAt: libURL)
    print("Exported \(project) to \(dir.path): references.md, datasets.tsv\(library.projects[project]?.claims.isEmpty == false ? ", claims.md" : ""), \(copied) PDFs, \(runTables) run tables.")
    print("These are copies — the library stays the record. Re-run the export after changes.")
}
