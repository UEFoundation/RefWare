import Foundation

public enum Severity: String, Codable, Sendable, Comparable {
    case error, warning, note
    var rank: Int { switch self { case .error: 0; case .warning: 1; case .note: 2 } }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var symbol: String { switch self { case .error: "✗"; case .warning: "⚠︎"; case .note: "·" } }
}

// MARK: Accession audit (any text)

/// Finds every accession in a set of files and checks each against the archives: does it exist, is it the kind the
/// text calls it, does a run belong to the study named beside it, and do stated run counts match.
public struct AccessionAudit: Sendable {
    public var client: ArchiveClient
    public init(client: ArchiveClient) { self.client = client }

    public struct Place: Hashable, Codable, Sendable { public var file: String; public var line: Int }

    public struct Finding: Codable, Sendable {
        public var accession: String
        public var kind: AccessionKind
        public var severity: Severity
        public var message: String
        public var places: [Place]
    }

    public struct Checked: Codable, Sendable {
        public var accession: String
        public var kind: AccessionKind
        public var title: String?
        public var study: String?
        public var dataset: IDI?
        public var places: [Place]
    }

    public struct Report: Codable, Sendable {
        public var files: [String]
        public var checked: [Checked]
        public var findings: [Finding]
        public var unchecked: [String]

        public var markdown: String {
            var out = ["# Accession audit", "", "\(checked.count + unchecked.count) accessions in \(files.count) file(s): " +
                       "\(findings.filter { $0.severity == .error }.count) errors, \(findings.filter { $0.severity == .warning }.count) warnings, \(findings.filter { $0.severity == .note }.count) notes.", ""]
            for sev in [Severity.error, .warning, .note] {
                let list = findings.filter { $0.severity == sev }
                guard !list.isEmpty else { continue }
                out.append("## " + (sev == .error ? "Errors" : sev == .warning ? "Warnings" : "Notes"))
                for f in list {
                    out.append("- \(sev.symbol) **\(f.accession)** (\(f.kind.label)): \(f.message)  ")
                    out.append("  at " + f.places.prefix(6).map { "\($0.file):\($0.line)" }.joined(separator: ", ") + (f.places.count > 6 ? " (+\(f.places.count - 6) more)" : ""))
                }
                out.append("")
            }
            let lower = checked.filter { !$0.kind.isStudyLevel }
            out.append("## Checked")
            if !lower.isEmpty {
                let byStudy = Dictionary(grouping: lower) { $0.study ?? "?" }.map { "\($0.key): \($0.value.count)" }.sorted()
                out.append("\(lower.count) runs, experiments and samples found in the archive — by study: \(byStudy.joined(separator: ", ")).")
                out.append("")
            }
            out.append("| Accession | Kind | Archive title | Library |")
            out.append("|---|---|---|---|")
            for c in checked.filter({ $0.kind.isStudyLevel }).sorted(by: { $0.accession < $1.accession }) {
                out.append("| \(c.accession) | \(c.kind.label) | \((c.title ?? c.study.map { "in \($0)" } ?? "").replacingOccurrences(of: "|", with: "/")) | \(c.dataset.map { "IDI \($0)" } ?? "—") |")
            }
            if !unchecked.isEmpty { out += ["", "Not checked (no public lookup): " + unchecked.joined(separator: ", ")] }
            return out.joined(separator: "\n") + "\n"
        }
    }

    static let labels: [(String, Set<AccessionKind>)] = [
        ("bioproject", [.bioproject]), ("biosample", [.biosample]), ("geo", [.geoSeries, .geoSample]),
        ("sra", [.study, .run, .experiment, .sraSample, .bioproject]), ("dbgap", [.dbgap]),
    ]

    /// The archive label written just before an accession ("BioProject PRJNA…", "GEO accession GSE…").
    static func label(before occ: Accession.Occurrence) -> (String, Set<AccessionKind>)? {
        let ns = occ.context as NSString
        let start = max(0, occ.offset - 28)
        let lead = ns.substring(with: NSRange(location: start, length: occ.offset - start)).lowercased()
        // Only a label that directly introduces this accession (no other accession in between).
        guard Accession.find(in: lead).isEmpty else { return nil }
        let words = lead.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let last = words.last else { return nil }
        // "BioProject PRJ…", "GEO: GSE…", or "BioProject accession PRJ…" — not "BioSample audit of PRJ…".
        if let l = labels.first(where: { $0.0 == last }) { return l }
        if ["accession", "accessions", "id", "no", "number", "project", "series"].contains(last), words.count >= 2,
           let l = labels.first(where: { $0.0 == words[words.count - 2] }) { return l }
        return nil
    }

    public func run(files: [(name: String, text: String)], library: Library, libraryURL: URL, project: String? = nil) async -> Report {
        var occ: [String: [(String, Accession.Occurrence)]] = [:]
        for f in files { for o in Accession.find(in: f.text) { occ[o.accession, default: []].append((f.name, o)) } }
        let all = Set(occ.keys)
        func places(_ a: String) -> [Place] {
            var seen = Set<Place>()
            return (occ[a] ?? []).map { Place(file: $0.0, line: $0.1.line) }.filter { seen.insert($0).inserted }
        }
        var findings: [Finding] = [], checked: [Checked] = [], unchecked: [String] = []
        var studies: [String: ArchiveClient.Study] = [:]
        var runRows: [String: RunRow] = [:]

        // Study-level lookups.
        for a in all.sorted() where Accession.kind(of: a)!.isStudyLevel {
            if Accession.kind(of: a) == .dbgap { unchecked.append(a); continue }
            do {
                if let s = try await client.study(a) { studies[a] = s }
            } catch {
                findings.append(Finding(accession: a, kind: Accession.kind(of: a)!, severity: .note, message: "couldn't be looked up (\(error)) — try again later", places: places(a)))
            }
        }
        // Runs and samples: the library's run tables first, then the archive in batches.
        var index: [String: RunRow] = [:]
        for (_, hit) in library.knownRuns(libraryURL: libraryURL) {
            for k in [hit.row.run, hit.row.experiment, hit.row.sraSample, hit.row.biosample].compactMap({ $0 }) where index[k] == nil { index[k] = hit.row }
        }
        var pending: [String] = []
        for a in all where [.run, .experiment, .sraSample, .biosample].contains(Accession.kind(of: a)!) {
            if let hit = index[a] { runRows[a] = hit } else { pending.append(a) }
        }
        if !pending.isEmpty, let rows = try? await client.runs(matching: pending) {
            for r in rows { for a in [r.run, r.experiment, r.sraSample, r.biosample].compactMap({ $0 }) where all.contains(a) && runRows[a] == nil { runRows[a] = r } }
        }

        let knownAccessions = all.union(library.datasets.flatMap { $0.dataset!.allAccessions })
        for a in all.sorted() {
            let kind = Accession.kind(of: a)!
            if kind == .dbgap || kind == .geoSample {
                if kind == .geoSample { unchecked.append(a) }
                continue
            }
            let ds = library.dataset(forAccession: a)
            let resolvedStudy = studies[a]
            let row = runRows[a]
            if resolvedStudy == nil && row == nil {
                if findings.contains(where: { $0.accession == a }) { continue }
                let near = Accession.nearMisses(of: a, among: knownAccessions.filter { Accession.kind(of: $0) == kind })
                findings.append(Finding(accession: a, kind: kind, severity: .error,
                                        message: "not found in the archives" + (near.isEmpty ? "" : " — one keystroke from \(near.joined(separator: ", "))"), places: places(a)))
                continue
            }
            checked.append(Checked(accession: a, kind: kind, title: resolvedStudy?.title, study: row?.study, dataset: ds?.id, places: places(a)))

            // Labelled as the wrong kind?
            for (file, o) in occ[a] ?? [] {
                guard let (word, kinds) = Self.label(before: o), !kinds.contains(kind) else { continue }
                let alt = (resolvedStudy?.otherAccessions ?? []).first { kinds.contains(Accession.kind(of: $0) ?? .run) }
                findings.append(Finding(accession: a, kind: kind, severity: .warning,
                                        message: "called a \(word == "geo" ? "GEO" : word == "sra" ? "SRA" : word == "dbgap" ? "dbGaP" : word == "bioproject" ? "BioProject" : "BioSample") accession, but it is a \(kind.label)" + (alt.map { " (its \(Accession.kind(of: $0)!.label) is \($0))" } ?? ""),
                                        places: [Place(file: file, line: o.line)]))
            }
            // A run or sample on the same line as a different study.
            if let row {
                for (file, o) in occ[a] ?? [] {
                    let named = Accession.find(in: o.context).filter { [.bioproject, .study].contains($0.kind) }.map(\.accession)
                    guard !named.isEmpty, !named.contains(where: row.inStudy) else { continue }
                    findings.append(Finding(accession: a, kind: kind, severity: .warning,
                                            message: "named beside \(named.joined(separator: ", ")), but it belongs to \(row.study ?? row.secondaryStudy ?? "another study")" + (row.alias.map { " (sample “\($0)”)" } ?? ""),
                                            places: [Place(file: file, line: o.line)]))
                }
            }
            // Two study accessions written as one dataset ("SRP058681 / PRJNA285182") that are different projects.
            if let s = resolvedStudy {
                for (file, o) in occ[a] ?? [] {
                    let ns = o.context as NSString
                    let end = o.offset + (o.accession as NSString).length
                    let tail = ns.substring(from: min(end, ns.length))
                    // Only an SRA study or GEO series written with a BioProject (two BioProjects side by side are usually a list).
                    guard let next = Accession.find(in: tail).first, next.kind.isStudyLevel, next.offset <= 6,
                          Set([kind, next.kind]).contains(.bioproject), kind != next.kind,
                          tail.prefix(next.offset).range(of: #"^[\s`*_]*(/|=|\(|aka|a\.k\.a\.)[\s`*_]*$"#, options: .regularExpression) != nil else { continue }
                    let same = s.accession == next.accession || s.otherAccessions.contains(next.accession)
                    if !same, let other = studies[next.accession] {
                        guard !(other.otherAccessions.contains(a) || other.accession == a) else { continue }
                        findings.append(Finding(accession: a, kind: kind, severity: .error,
                                                message: "written as the same dataset as \(next.accession), but they are different projects: \(a) is “\(s.title ?? "?")” (BioProject \(s.accession)); \(next.accession) is “\(other.title ?? "?")”",
                                                places: [Place(file: file, line: o.line)]))
                    }
                }
            }
            // Stated run / sample counts.
            if let s = resolvedStudy {
                let archiveRuns = ds?.dataset?.runs ?? s.runs
                let archiveSamples = ds?.dataset?.samples ?? s.samples
                for (file, o) in occ[a] ?? [] {
                    // "SRP058681 + PRJNA516684 (2,020 runs)" is a combined count, not this accession's.
                    let before = (o.context as NSString).substring(to: o.offset)
                    if let prev = Accession.find(in: before).last, before.count - prev.offset - prev.accession.count <= 8 { continue }
                    let after = (o.context as NSString).substring(from: o.offset)
                    if let next = Accession.find(in: String(after.dropFirst(o.accession.count))).first, next.offset <= 8 { continue }
                    for (n, unit) in Self.statedCounts(in: after) {
                        let actual = unit == "run" ? archiveRuns : archiveSamples
                        guard let actual, actual != n else { continue }
                        findings.append(Finding(accession: a, kind: kind, severity: .note,
                                                message: "the text says \(n) \(unit)s; the archive lists \(actual) (check whether the difference is deliberate, e.g. samples excluded)",
                                                places: [Place(file: file, line: o.line)]))
                    }
                }
                if ds == nil {
                    findings.append(Finding(accession: a, kind: kind, severity: .note,
                                            message: "not yet a dataset record — `refware dataset add \(a)\(project.map { " --project \($0)" } ?? "")`", places: places(a)))
                } else if let project, let ds, !ds.projects.contains(where: { $0.project == project }) {
                    findings.append(Finding(accession: a, kind: kind, severity: .note, message: "IDI \(ds.id) isn't filed in \(project) — `refware dataset add \(a) --project \(project)`", places: places(a)))
                }
            }
        }
        // One finding per accession and message, with all its places.
        var merged: [Finding] = []
        for f in findings {
            if let i = merged.firstIndex(where: { $0.accession == f.accession && $0.message == f.message }) {
                for p in f.places where !merged[i].places.contains(p) { merged[i].places.append(p) }
            } else { merged.append(f) }
        }
        findings = merged
        findings.sort { ($0.severity, $0.accession) < ($1.severity, $1.accession) }
        return Report(files: files.map(\.name), checked: checked, findings: findings, unchecked: unchecked.sorted())
    }

    /// "… 28 runs", "42 samples" right after an accession, before the next accession.
    static func statedCounts(in text: String) -> [(Int, String)] {
        // Only within the accession's own phrase: up to the next accession, ; | ) or 60 characters.
        var t = String(text.prefix(60))
        if let next = Accession.find(in: String(t.dropFirst(3))).first {
            t = String((t as NSString).substring(to: min((t as NSString).length, next.offset + 3)))
        }
        if let stop = t.dropFirst(3).firstIndex(where: { ";|)".contains($0) }) { t = String(t[..<stop]) }
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,3}(?:,\d{3})*|\d+)\s+(?:paired\s+|public\s+|sequenced\s+)?(runs?|samples?)\b"#, options: .caseInsensitive) else { return [] }
        let ns = t as NSString
        return re.matches(in: t, range: NSRange(location: 0, length: ns.length)).prefix(1).compactMap { m in
            guard let n = Int(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")) else { return nil }
            return (n, ns.substring(with: m.range(at: 2)).lowercased().hasPrefix("run") ? "run" : "sample")
        }
    }
}

// MARK: Sample manifests (TSV / CSV)

/// Checks a sample manifest row by row against the archive's run tables: every run exists, belongs to the project
/// and sample the row says, and the read count matches.
public struct ManifestCheck: Sendable {
    public var client: ArchiveClient
    public init(client: ArchiveClient) { self.client = client }

    public struct Issue: Codable, Sendable {
        public var row: Int
        public var run: String?
        public var severity: Severity
        public var message: String
    }

    public struct Report: Codable, Sendable {
        public var file: String
        public var rows: Int
        public var columns: [String: String]
        public var runsChecked: Int
        public var studies: [String]
        public var issues: [Issue]

        public var markdown: String {
            var out = ["# Manifest check: \(file)", "",
                       "\(rows) rows · \(runsChecked) runs checked against \(studies.isEmpty ? "the archive" : studies.joined(separator: ", ")) · columns: " +
                       columns.sorted { $0.key < $1.key }.map { "\($0.key) = “\($0.value)”" }.joined(separator: ", "), ""]
            let e = issues.filter { $0.severity == .error }.count, w = issues.filter { $0.severity == .warning }.count
            out.append(issues.isEmpty ? "No problems found." : "\(e) errors, \(w) warnings, \(issues.count - e - w) notes.")
            out.append("")
            for i in issues.sorted(by: { ($0.severity, $0.row) < ($1.severity, $1.row) }) {
                out.append("- \(i.severity.symbol) row \(i.row)\(i.run.map { " · \($0)" } ?? ""): \(i.message)")
            }
            return out.joined(separator: "\n") + "\n"
        }
    }

    public static func parseTable(_ text: String) -> (header: [String], rows: [[String]]) {
        var lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return ([], []) }
        let first = lines.removeFirst()
        let tab = first.contains("\t")
        func split(_ l: String) -> [String] {
            if tab { return l.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
            var out: [String] = [], cur = "", quoted = false
            for ch in l {
                if ch == "\"" { quoted.toggle() } else if ch == ",", !quoted { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
            }
            out.append(cur.trimmingCharacters(in: .whitespaces))
            return out
        }
        return (split(first), lines.map(split))
    }

    /// Which column holds runs, samples, projects, aliases and archive read counts.
    static func detect(header: [String], rows: [[String]], overrides: [String: String]) -> [String: Int] {
        var cols: [String: Int] = [:]
        let lower = header.map { $0.lowercased() }
        for (role, name) in overrides { if let i = lower.firstIndex(of: name.lowercased()) { cols[role] = i } }
        func share(_ i: Int, _ kinds: Set<AccessionKind>) -> Double {
            let vals = rows.prefix(200).compactMap { i < $0.count ? $0[i] : nil }.filter { !$0.isEmpty }
            guard !vals.isEmpty else { return 0 }
            return Double(vals.filter { Accession.kind(of: $0).map(kinds.contains) ?? false }.count) / Double(vals.count)
        }
        func pick(_ role: String, names: [String], kinds: Set<AccessionKind>?) {
            guard cols[role] == nil else { return }
            if let i = lower.firstIndex(where: names.contains) { cols[role] = i; return }
            if let kinds, let i = header.indices.max(by: { share($0, kinds) < share($1, kinds) }), share(i, kinds) > 0.6 { cols[role] = i }
        }
        pick("run", names: ["run", "run_accession", "run accession", "runs", "srr", "acc"], kinds: [.run])
        pick("biosample", names: ["biosample", "sample_accession", "biosample_accession"], kinds: [.biosample])
        pick("project", names: ["project", "bioproject", "study", "study_accession", "bioproject_accession"], kinds: [.bioproject, .study])
        pick("alias", names: ["sample_alias", "alias", "sample_name", "samplename", "library_name"], kinds: nil)
        if cols["reads"] == nil, let i = lower.firstIndex(where: { $0 == "read_count" || $0 == "spots" || $0.contains("reads_in_archive") || $0.contains("archive_reads") }) { cols["reads"] = i }
        return cols
    }

    public func run(text: String, name: String, library: Library, libraryURL: URL, overrides: [String: String] = [:], fetchMissing: Bool = true) async -> Report {
        let (header, rows) = Self.parseTable(text)
        let cols = Self.detect(header: header, rows: rows, overrides: overrides)
        var issues: [Issue] = []
        var report = Report(file: name, rows: rows.count, columns: cols.mapValues { header[$0] }, runsChecked: 0, studies: [], issues: [])
        guard let runCol = cols["run"] else {
            report.issues = [Issue(row: 0, run: nil, severity: .error, message: "no column of run accessions (SRR/ERR/DRR) found — name it with --run-column")]
            return report
        }
        func cell(_ r: [String], _ role: String) -> String? {
            guard let i = cols[role], i < r.count, !r[i].isEmpty else { return nil }
            return r[i]
        }
        var known = library.knownRuns(libraryURL: libraryURL).mapValues(\.row)
        var studiesUsed = Set<String>(), fetched = Set<String>()
        // Fetch the run tables of projects the manifest names but the library doesn't hold.
        if fetchMissing {
            let named = Set(rows.compactMap { cell($0, "project") }.map(Accession.normalize).filter { [.bioproject, .study].contains(Accession.kind(of: $0)) })
            for p in named.sorted() where !known.values.contains(where: { $0.inStudy(p) }) {
                if let t = try? await client.runTable(p), !t.isEmpty { for r in t { known[r.run] = r }; fetched.insert(p) }
            }
        }
        // Runs still unknown: look them up one batch at a time (they may belong to another study, or not exist).
        let unknown = Array(Set(rows.compactMap { cell($0, "run").map(Accession.normalize) }.filter { known[$0] == nil && Accession.kind(of: $0) == .run })).sorted()
        if !unknown.isEmpty, let found = try? await client.runs(matching: Array(unknown.prefix(2000))) { for r in found { known[r.run] = r } }

        var seen: [String: Int] = [:]
        for (i, r) in rows.enumerated() {
            let rowNo = i + 2   // 1-based, after the header
            guard runCol < r.count else { continue }
            let run = Accession.normalize(r[runCol])
            guard Accession.kind(of: run) == .run else {
                if Accession.find(in: r[runCol]).isEmpty && r[runCol].range(of: #"[SED]RR\d"#, options: [.regularExpression, .caseInsensitive]) == nil {
                    if !r[runCol].isEmpty { issues.append(Issue(row: rowNo, run: nil, severity: .note, message: "“\(r[runCol])” isn't a run — row skipped")) }
                } else {
                    issues.append(Issue(row: rowNo, run: r[runCol], severity: .error, message: "“\(r[runCol])” isn't a valid run accession"))
                }
                continue
            }
            if let first = seen[run] { issues.append(Issue(row: rowNo, run: run, severity: .warning, message: "listed again (first at row \(first))")) } else { seen[run] = rowNo }
            let project = cell(r, "project").map(Accession.normalize)
            guard let a = known[run] else {
                let pool = known.values.filter { project.map($0.inStudy) ?? true }.map(\.run)
                let near = Accession.nearMisses(of: run, among: pool)
                issues.append(Issue(row: rowNo, run: run, severity: .error, message: "not in the archive" + (near.isEmpty ? "" : " — one keystroke from \(near.prefix(3).joined(separator: ", "))")))
                continue
            }
            report.runsChecked += 1
            if let s = a.study { studiesUsed.insert(s) }
            if let project, Accession.kind(of: project) != nil, !a.inStudy(project) {
                // A typo that happens to be someone else's run: is there a one-keystroke neighbour in the stated project?
                let pool = known.values.filter { $0.inStudy(project) }
                let near = Accession.nearMisses(of: run, among: pool.map(\.run))
                let rowSample = cell(r, "biosample").map(Accession.normalize), rowAlias = cell(r, "alias")
                let best = near.first { n in let x = known[n]; return (rowSample != nil && x?.biosample == rowSample) || (rowAlias != nil && x?.alias == rowAlias) }
                issues.append(Issue(row: rowNo, run: run, severity: .error, message: "the row says \(project), but the run belongs to \(a.study ?? a.secondaryStudy ?? "another study")" +
                                    (best.map { " — probably a typo for \($0), which is this row's sample in \(project)" } ?? (near.isEmpty ? "" : " — one keystroke from \(near.prefix(3).joined(separator: ", ")) in \(project)"))))
                continue
            }
            if let bs = cell(r, "biosample").map(Accession.normalize), let real = a.biosample, bs != real, bs != a.sraSample {
                issues.append(Issue(row: rowNo, run: run, severity: .error, message: "the row says sample \(bs), but the run's sample is \(real)"))
            }
            if let alias = cell(r, "alias"), let real = a.alias, alias != real, alias != a.title {
                issues.append(Issue(row: rowNo, run: run, severity: .warning, message: "sample name “\(alias)” — the archive says “\(real)”"))
            }
            if let raw = cell(r, "reads"), let n = Int(raw.replacingOccurrences(of: ",", with: "")), let real = a.reads, n != real {
                issues.append(Issue(row: rowNo, run: run, severity: .warning, message: "\(n) reads — the archive lists \(real)"))
            }
        }
        report.studies = studiesUsed.sorted().map { fetched.contains($0) ? "\($0) (fetched; not in the library)" : $0 }
        report.issues = issues
        return report
    }
}

// MARK: Downloaded reads

/// Checks downloaded FASTQ files against the archive: full `.fastq.gz` downloads by size and MD5, decompressed or
/// partial files by record structure and read count.
public struct FastqCheck: Sendable {
    public var client: ArchiveClient
    public init(client: ArchiveClient) { self.client = client }

    public enum Status: String, Codable, Sendable {
        case complete, partial, truncated, corrupt, mismatch
        case unknownRun = "unknown-run"
        case unchecked
    }

    public struct Item: Codable, Sendable {
        public var file: String
        public var run: String
        public var status: Status
        public var detail: String
    }

    static let nameRE = try! NSRegularExpression(pattern: #"^([SED]RR\d{6,})(?:_(?:R)?([12]))?\.(?:fastq|fq)(\.gz)?$"#)

    public func run(directory: URL, library: Library, libraryURL: URL) async throws -> [Item] {
        let fm = FileManager.default
        let files = Self.listFiles(directory)
        var known = library.knownRuns(libraryURL: libraryURL).mapValues(\.row)
        let missing = Array(Set(files.map(\.1).filter { known[$0] == nil }))
        if !missing.isEmpty { for r in (try? await client.runs(matching: missing)) ?? [] { known[r.run] = r } }

        var out: [Item] = []
        for (url, run, gz) in files.sorted(by: { $0.0.path < $1.0.path }) {
            let rel = url.path.hasPrefix(directory.path + "/") ? String(url.path.dropFirst(directory.path.count + 1)) : url.lastPathComponent
            guard let row = known[run] else { out.append(Item(file: rel, run: run, status: .unknownRun, detail: "\(run) isn't in the archive")); continue }
            // Which archive file this is: same name, with or without .gz.
            let gzName = gz ? url.lastPathComponent : url.lastPathComponent + ".gz"
            let idx = row.fastqURLs.firstIndex { ($0 as NSString).lastPathComponent == gzName }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if gz {
                guard let idx, idx < row.fastqBytes.count, idx < row.fastqMD5.count else {
                    let ok = Self.gzipIntact(url)
                    out.append(Item(file: rel, run: run, status: ok ? .unchecked : .corrupt, detail: ok ? "gzip intact; the archive lists no checksum for this file name" : "gzip stream is damaged or cut off"))
                    continue
                }
                let expected = row.fastqBytes[idx]
                if size < expected {
                    out.append(Item(file: rel, run: run, status: .truncated, detail: "\(size) of \(expected) bytes — download cut off"))
                } else if size > expected {
                    out.append(Item(file: rel, run: run, status: .mismatch, detail: "\(size) bytes; the archive's file is \(expected)"))
                } else {
                    let md5 = (try? FileHash.md5(of: url)) ?? ""
                    out.append(md5 == row.fastqMD5[idx]
                               ? Item(file: rel, run: run, status: .complete, detail: "size and MD5 match the archive")
                               : Item(file: rel, run: run, status: .mismatch, detail: "MD5 \(md5) ≠ archive \(row.fastqMD5[idx])"))
                }
            } else {
                let s = Self.scanFastq(url)
                if let bad = s.malformedAt {
                    out.append(Item(file: rel, run: run, status: .corrupt, detail: "malformed record \(bad) (\(s.records) good records before it)"))
                } else if s.cutMidRecord {
                    out.append(Item(file: rel, run: run, status: .truncated, detail: "ends mid-record after \(s.records) complete reads"))
                } else if let total = row.reads, s.records == total {
                    out.append(Item(file: rel, run: run, status: .complete, detail: "\(s.records) reads, as the archive lists"))
                } else if let total = row.reads, s.records < total {
                    out.append(Item(file: rel, run: run, status: .partial, detail: "\(s.records) of \(total) reads, records intact (fine if you downloaded a subset on purpose)"))
                } else {
                    out.append(Item(file: rel, run: run, status: s.records > (row.reads ?? .max) ? .mismatch : .unchecked,
                                    detail: "\(s.records) reads" + (row.reads.map { "; the archive lists \($0)" } ?? "")))
                }
            }
        }
        return out
    }

    static func listFiles(_ directory: URL) -> [(URL, String, Bool)] {
        var files: [(URL, String, Bool)] = []
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let u as URL in e {
            let name = u.lastPathComponent as NSString
            guard let m = nameRE.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)) else { continue }
            files.append((u, name.substring(with: m.range(at: 1)), m.range(at: 3).location != NSNotFound))
        }
        return files
    }

    static func gzipIntact(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-t", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    struct Scan { var records = 0; var malformedAt: Int?; var cutMidRecord = false }

    /// Walks a plain FASTQ file four lines at a time.
    static func scanFastq(_ url: URL) -> Scan {
        var s = Scan()
        guard let h = try? FileHandle(forReadingFrom: url) else { s.malformedAt = 1; return s }
        defer { try? h.close() }
        var buffer = Data(), rec: [Data] = []
        func take(_ line: Data) -> Bool {
            rec.append(line)
            guard rec.count == 4 else { return true }
            defer { rec.removeAll(keepingCapacity: true) }
            guard rec[0].first == UInt8(ascii: "@"), rec[2].first == UInt8(ascii: "+"), rec[1].count == rec[3].count, !rec[1].isEmpty else {
                s.malformedAt = s.records + 1; return false
            }
            s.records += 1
            return true
        }
        reading: while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<nl]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                buffer.removeSubrange(buffer.startIndex...nl)
                if !take(Data(line)) { break reading }
            }
        }
        if s.malformedAt == nil {
            if !buffer.isEmpty { _ = take(buffer) }
            if !rec.isEmpty, s.malformedAt == nil { s.cutMidRecord = true }
        }
        return s
    }
}

// MARK: Results bound to output files

extension Library {
    /// Binds an exact excerpt of an analysis output file to a claim. The excerpt must be in the file.
    @discardableResult
    public mutating func bindOutput(project: String, claim claimID: String, file: URL, excerpt: String, datasets: [IDI], by: String?) throws -> OutputEvidence {
        guard var index = projects[project] else { throw EvidenceError.unknownProject(project) }
        guard let c = index.claimIndex(claimID) else { throw EvidenceError.unknownClaim(claimID) }
        for d in datasets { guard self[d]?.dataset != nil else { throw DatasetError.notADataset(d) } }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let line = OutputEvidence.locate(excerpt, in: text) else { throw DatasetError.excerptNotFound(excerpt, file: OutputEvidence.displayPath(file)) }
        let ev = OutputEvidence(path: OutputEvidence.displayPath(file), excerpt: OutputEvidence.squeeze(excerpt), line: line,
                                sha256: try FileHash.sha256(of: file), by: by, datasets: datasets.map(canonical))
        var outs = index.claims[c].outputs ?? []
        outs.removeAll { $0.path == ev.path && $0.excerpt == ev.excerpt }
        outs.append(ev)
        index.claims[c].outputs = outs
        // Datasets a result was computed from become sources of the claim.
        for d in ev.datasets where !index.claims[c].references.contains(d) {
            index.claims[c].sources.append(ClaimSource(title: self[d]?.dataset?.accession, reference: d))
        }
        for d in ev.datasets { index.addReference(d) }
        projects[project] = index
        return ev
    }

    public enum OutputRecheck: Sendable {
        case unchanged
        /// The file changed, but the excerpt is still there (now at this line).
        case stillPresent(line: Int)
        /// Newly stale: the excerpt is gone, or the file is.
        case stale(String)
        /// Was already stale and still is.
        case stillStale
        /// Was stale; the excerpt is back.
        case restored(line: Int)
    }

    /// Re-reads every bound output file. A changed file whose excerpt is gone makes the evidence stale — kept, never
    /// deleted, and no longer counted as support until it's rebound.
    public mutating func recheckOutputs(project only: String? = nil) -> [(project: String, claim: String, evidence: OutputEvidence, outcome: OutputRecheck)] {
        var log: [(String, String, OutputEvidence, OutputRecheck)] = []
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        for name in projects.keys.sorted() where only == nil || only == name {
            guard var index = projects[name] else { continue }
            for c in index.claims.indices {
                guard var outs = index.claims[c].outputs, !outs.isEmpty else { continue }
                for k in outs.indices {
                    var e = outs[k]
                    let outcome: OutputRecheck
                    if let sha = try? FileHash.sha256(of: e.fileURL), let text = try? String(contentsOf: e.fileURL, encoding: .utf8) {
                        if sha == e.sha256 && e.staleSince == nil {
                            outcome = .unchanged
                        } else if let line = OutputEvidence.locate(e.excerpt, in: text) {
                            outcome = e.staleSince == nil ? .stillPresent(line: line) : .restored(line: line)
                            e.sha256 = sha; e.line = line; e.staleSince = nil; e.staleReason = nil
                        } else if e.staleSince != nil {
                            outcome = .stillStale
                        } else {
                            e.staleSince = now
                            e.staleReason = "no longer in the file (changed after \(e.boundOn.formatted(date: .abbreviated, time: .shortened)))"
                            outcome = .stale(e.staleReason!)
                        }
                    } else if e.staleSince != nil {
                        outcome = .stillStale
                    } else {
                        e.staleSince = now
                        e.staleReason = "the file is missing"
                        outcome = .stale(e.staleReason!)
                    }
                    outs[k] = e
                    log.append((name, index.claims[c].id, e, outcome))
                }
                index.claims[c].outputs = outs
            }
            projects[name] = index
        }
        return log
    }
}

// MARK: Supplementary table

public enum DatasetTable {
    public static let header = ["IDI", "Accession", "Other accessions", "Repository", "Archive title", "Organism", "Assay", "Platform",
                                "Samples", "Runs", "Access", "From paper", "Paper link", "Run table (date, SHA-256)", "Key rules"]

    public static func rows(_ library: Library, project: String?) -> [[String]] {
        let f = CitationFormatter(references: Array(library.references.values))
        return library.datasets.filter { project == nil || $0.projects.contains { $0.project == project } }.map { ref in
            let d = ref.dataset!
            let snap = d.latestSnapshot.map { "\($0.fetched.formatted(.iso8601.year().month().day())) \($0.sha256.prefix(12))" } ?? ""
            return ["\(ref.id)", d.accession, d.otherAccessions.joined(separator: "; "), d.repository, d.archiveTitle ?? ref.title,
                    d.organism ?? "", d.assays.joined(separator: "; "), d.platforms.joined(separator: "; "),
                    d.samples.map(String.init) ?? "", d.runs.map(String.init) ?? "", d.access.rawValue,
                    d.papers.compactMap { library[$0] }.map { "IDI \($0.id) \(f.inline([$0]))" }.joined(separator: "; "),
                    d.paperLink?.rawValue ?? "", snap, d.activeKeyRules.map(\.name).joined(separator: "; ")]
        }
    }

    public static func tsv(_ library: Library, project: String?) -> String {
        ([header] + rows(library, project: project)).map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    public static func markdown(_ library: Library, project: String?) -> String {
        let cols = [0, 1, 2, 4, 6, 8, 9, 10, 11]
        var out = ["| " + cols.map { header[$0] }.joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: cols.count)]
        for r in rows(library, project: project) {
            out.append("| " + cols.map { r[$0].replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
