import Foundation

public enum DatasetError: Error, CustomStringConvertible {
    case notAnAccession(String)
    case notStudyLevel(String, kind: AccessionKind, study: String?)
    case notFound(String, nearMisses: [String])
    case notADataset(IDI)
    case noRunTable(String)
    case snapshotChanged(String)
    case badPattern(String)
    case excerptNotFound(String, file: String)
    case unknownRule(String)
    case doesNotMatch(String, [String])

    public var description: String {
        switch self {
        case .notAnAccession(let s): "“\(s)” isn't an accession RefWare recognises (BioProject PRJ…, SRA SRP/SRR/SRX/SRS, BioSample SAM…, GEO GSE/GSM, dbGaP phs…)"
        case .notStudyLevel(let a, let kind, let study):
            "\(a) is an \(kind.label), not a dataset — " + (study.map { "it belongs to \($0); add that instead" } ?? "add the study it belongs to")
        case .notFound(let a, let near):
            "\(a) was not found in the archives" + (near.isEmpty ? "" : " — did you mean \(near.joined(separator: " or "))?")
        case .notADataset(let id): "IDI \(id) is not a dataset record"
        case .noRunTable(let a): "no run table for \(a) yet — run `refware dataset runs \(a)` first"
        case .snapshotChanged(let f): "the run-table file \(f) no longer matches its recorded SHA-256 — it was edited after it was fetched; fetch a fresh one with `refware dataset runs --refresh`"
        case .badPattern(let p): "the pattern \(p) isn't a valid regular expression"
        case .excerptNotFound(let e, let f): "“\(e)” is not in \(f) — copy the text exactly as the file has it (numbers, signs and decimals must match)"
        case .unknownRule(let n): "no active key rule named “\(n)”"
        case .doesNotMatch(let a, let w): "\(a) was NOT added — it doesn't look like what you described:\n" + w.map { "  ⚠︎ \($0)" }.joined(separator: "\n") + "\nIf it really is the right dataset, re-run with --anyway; otherwise find the right accession (the paper's data-availability statement)."
        }
    }
}

extension Library {
    /// `datasets/` next to the library: one folder per dataset, holding its dated run tables.
    public static func datasetDirectory(forLibraryAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("datasets", isDirectory: true)
    }

    /// Dataset records, by IDI.
    public var datasets: [Reference] { references.values.filter { $0.dataset != nil }.sorted { $0.id < $1.id } }

    /// The dataset record holding this accession (main or alternate).
    public func dataset(forAccession accession: String) -> Reference? {
        datasets.first { $0.dataset!.matches(accession) }
    }

    /// Every run listed in the latest snapshot of any dataset record, by run accession.
    public func knownRuns(libraryURL: URL) -> [String: (row: RunRow, dataset: IDI)] {
        var out: [String: (RunRow, IDI)] = [:]
        for ref in datasets {
            guard let snap = ref.dataset?.latestSnapshot, let rows = try? DatasetStore.rows(snap, libraryURL: libraryURL) else { continue }
            for r in rows { out[r.run] = (r, ref.id) }
        }
        return out
    }
}

/// Run-table files next to the library.
public enum DatasetStore {
    /// Writes a run table as a dated, fingerprinted TSV. Returns the existing snapshot instead when nothing changed.
    public static func save(_ rows: [RunRow], for accession: String, source: String, libraryURL: URL,
                            previous: RunTableSnapshot?, by: String?) throws -> (snapshot: RunTableSnapshot, isNew: Bool) {
        let text = RunTable.tsv(rows)
        let data = Data(text.utf8)
        let sha = SHA256Hex.of(data)
        if let previous, previous.sha256 == sha { return (previous, false) }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let rel = "\(accession)/runs_\(day)_\(sha.prefix(8)).tsv"
        let url = Library.datasetDirectory(forLibraryAt: libraryURL).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let samples = Set(rows.compactMap { $0.biosample ?? $0.sraSample }).count
        return (RunTableSnapshot(file: rel, sha256: sha, fetched: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                                 source: source, runs: rows.count, samples: samples, by: by), true)
    }

    public static func url(_ snapshot: RunTableSnapshot, libraryURL: URL) -> URL {
        Library.datasetDirectory(forLibraryAt: libraryURL).appendingPathComponent(snapshot.file)
    }

    /// The snapshot's rows — refused if the file no longer matches its fingerprint.
    public static func rows(_ snapshot: RunTableSnapshot, libraryURL: URL) throws -> [RunRow] {
        let data = try Data(contentsOf: url(snapshot, libraryURL: libraryURL))
        guard SHA256Hex.of(data) == snapshot.sha256 else { throw DatasetError.snapshotChanged(snapshot.file) }
        return RunTable.parse(String(decoding: data, as: UTF8.self))
    }
}

/// Adds a public dataset to the library after looking it up, and reports anything that doesn't fit.
public struct DatasetAdder: Sendable {
    public var client: ArchiveClient

    public init(client: ArchiveClient) { self.client = client }

    public struct Result: Sendable {
        public var record: Reference
        public var isNew: Bool
        public var warnings: [String]
        public var notes: [String]
        public var mentioning: [ArchiveClient.Paper]
    }

    public func add(_ raw: String, to library: inout Library, libraryURL: URL, project: ProjectTag?, papers: [IDI] = [],
                    expect: String? = nil, fetchRuns: Bool = true, by: String? = nil, anyway: Bool = false) async throws -> Result {
        let acc = Accession.normalize(raw)
        guard let kind = Accession.kind(of: acc) else { throw DatasetError.notAnAccession(raw) }
        guard kind.isStudyLevel else {
            let row = try? await client.runs(matching: [acc]).first
            throw DatasetError.notStudyLevel(acc, kind: kind, study: row?.study)
        }
        if var existing = library.dataset(forAccession: acc) {
            var notes = ["already in the library as IDI \(existing.id)"]
            if let project, !existing.projects.contains(where: { $0.project == project.project }) {
                existing.projects.append(project); notes.append("filed in \(project.project)")
            }
            for p in papers where !(existing.dataset!.papers.contains(p)) { existing.dataset!.papers.append(p) }
            try library.update(existing)
            if let project { library.projects[project.project, default: ProjectCitationIndex(project: project.project)].addReference(existing.id) }
            return Result(record: existing, isNew: false, warnings: existing.dataset!.warnings, notes: notes, mentioning: [])
        }
        guard let study = try await client.study(acc) else {
            let known = library.datasets.flatMap { $0.dataset!.allAccessions }
            throw DatasetError.notFound(acc, nearMisses: Accession.nearMisses(of: acc, among: known))
        }
        let lib = library
        if let other = study.otherAccessions.compactMap({ lib.dataset(forAccession: $0) }).first {
            return try await add(other.dataset!.accession, to: &library, libraryURL: libraryURL, project: project, papers: papers, expect: expect, fetchRuns: false, by: by)
        }

        // A GEO series keeps its GSE as the main accession; an SRA study is filed under its BioProject.
        var info = DatasetInfo(accession: kind == .geoSeries ? acc : study.accession, kind: kind == .geoSeries ? .geoSeries : study.kind,
                               repository: study.repository, access: study.access)
        info.otherAccessions = ([acc, study.accession] + study.otherAccessions).filter { $0 != info.accession }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        info.archiveTitle = study.title
        info.archiveDescription = study.description
        info.organism = study.organism
        info.submitter = study.submitter
        info.released = study.released
        info.samples = study.samples
        info.runs = study.runs
        info.papers = papers
        var warnings: [String] = [], notes: [String] = []
        if study.access == .controlled { notes.append("controlled access (dbGaP): reads need an approved data-access request") }

        // Run table: for BioProjects and SRA studies directly, for a GEO series through its BioProject.
        var rows: [RunRow] = []
        if fetchRuns, let target = info.allAccessions.first(where: { [.bioproject, .study].contains(Accession.kind(of: $0)) }) {
            rows = (try? await client.runTable(target)) ?? []
            if !rows.isEmpty {
                let (snap, _) = try DatasetStore.save(rows, for: info.accession, source: "ENA filereport \(target)", libraryURL: libraryURL, previous: nil, by: by)
                info.snapshots = [snap]
                info.runs = rows.count
                info.samples = snap.samples
                info.assays = Array(Set(rows.compactMap(\.strategy))).sorted()
                info.platforms = Array(Set(rows.compactMap(\.instrument))).sorted()
                if info.organism == nil { info.organism = Array(Set(rows.compactMap(\.organism))).sorted().joined(separator: "; ") }
            } else if study.access == .open {
                notes.append("the archive lists no public runs for \(target)")
            }
        }

        // Which papers cite it.
        var mentioning: [ArchiveClient.Paper] = []
        for a in info.allAccessions.prefix(3) { mentioning += (try? await client.papers(citing: a)) ?? [] }
        var dois = mentioning.compactMap(\.doi)
        dois += (try? await client.dois(forPubMed: study.pubmedIDs)) ?? []
        info.mentionedBy = Array(Set(dois.map { $0.lowercased() })).sorted()
        var seen = Set<String>()
        mentioning = mentioning.filter { seen.insert($0.doi?.lowercased() ?? $0.title).inserted }

        if !papers.isEmpty {
            let stated = papers.compactMap { library[$0]?.doi?.lowercased() }
            if stated.contains(where: info.mentionedBy.contains) {
                info.paperLink = .confirmed
            } else if !info.mentionedBy.isEmpty {
                info.paperLink = .otherPapers
                let names = mentioning.prefix(3).map { "\($0.authors.split(separator: ",").first ?? "") (\($0.year ?? "n.d.")) “\($0.title)”" }
                warnings.append("the papers that cite \(info.accession) don't include IDI \(papers.map(String.init).joined(separator: ", ")) — they are: \(names.joined(separator: "; ")). Check that this is the paper's dataset.")
            } else {
                info.paperLink = .unconfirmed
                notes.append("no indexed paper cites \(info.accession), so the link to IDI \(papers.map(String.init).joined(separator: ", ")) is as stated, not confirmed")
            }
        }

        if let expect, !expect.isEmpty {
            let w = Self.expectationWarnings(expect, info: info, aliases: rows.prefix(200).compactMap { $0.alias ?? $0.title })
            if !w.isEmpty, !anyway {
                // Nothing is kept: remove the run table written above.
                for s in info.snapshots { try? FileManager.default.removeItem(at: DatasetStore.url(s, libraryURL: libraryURL)) }
                throw DatasetError.doesNotMatch(info.accession, w)
            }
            warnings += w
        }
        info.warnings = warnings

        var ref = Reference(id: library.nextIDI,
                            authors: study.submitter.map { [Author(family: $0, isOrganization: true)] } ?? [],
                            year: study.released.flatMap { Int($0.prefix(4)) },
                            title: study.title ?? info.accession,
                            publication: study.repository,
                            url: Accession.url(for: info.accession),
                            publicationType: .other,
                            projects: project.map { [$0] } ?? [],
                            provenance: Provenance(source: .archive, key: info.accession, retrieved: Date(), verified: true))
        ref.dataset = info
        try library.add(ref)
        if let project { library.projects[project.project, default: ProjectCitationIndex(project: project.project)].addReference(ref.id) }
        return Result(record: library[ref.id]!, isNew: true, warnings: warnings, notes: notes, mentioning: mentioning)
    }

    static let stopwords: Set<String> = ["data", "dataset", "study", "from", "with", "this", "that", "their", "these", "samples", "sample",
                                         "sequencing", "sequence", "human", "using", "public", "analysis", "project", "cohort", "women", "between"]

    static func keywords(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 && !stopwords.contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 })
    }

    /// Someone said what the dataset is ("SIBO duodenal aspirates, 16S"); does the archive agree?
    static func expectationWarnings(_ expect: String, info: DatasetInfo, aliases: [String]) -> [String] {
        var out: [String] = []
        let archiveText = [info.archiveTitle, info.archiveDescription, info.organism].compactMap { $0 }.joined(separator: " ") + " " + aliases.joined(separator: " ")
        let shared = keywords(expect).intersection(keywords(archiveText))
        let e = expect.lowercased()
        let short = ["16s", "its", "wgs", "rna"].filter { e.contains($0) }
        if shared.isEmpty, short.isEmpty || !info.assays.isEmpty {
            out.append("the archive describes \(info.accession) as “\(info.archiveTitle ?? "untitled")” — nothing in common with “\(expect)”. Check the accession before using it.")
        }
        let assays = Set(info.assays.map { $0.uppercased() })
        if !assays.isEmpty {
            let wantsAmplicon = e.contains("16s") || e.contains("amplicon") || e.contains("its2") || e.contains("v3-v4") || e.contains("v4")
            let wantsShotgun = e.contains("shotgun") || e.contains("metagenom") && !wantsAmplicon || e.contains("wgs") || e.contains("whole genome")
            let wantsRNA = e.contains("rna-seq") || e.contains("transcriptom") || e.contains("metatranscriptom")
            if wantsAmplicon, !assays.contains("AMPLICON") { out.append("expected amplicon (16S) data, but the runs are \(assays.sorted().joined(separator: ", "))") }
            if wantsShotgun, !assays.contains("WGS"), !assays.contains("WGA") { out.append("expected shotgun data, but the runs are \(assays.sorted().joined(separator: ", "))") }
            if wantsRNA, !assays.contains("RNA-SEQ") { out.append("expected RNA-seq, but the runs are \(assays.sorted().joined(separator: ", "))") }
        }
        return out
    }
}
