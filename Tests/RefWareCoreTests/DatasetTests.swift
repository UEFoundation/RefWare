import Foundation
import Testing
@testable import RefWareCore

private let ena = "https://www.ebi.ac.uk/ena/portal/api"
private let epmc = "https://www.ebi.ac.uk/europepmc/webservices/rest"

private func studyRoute(_ acc: String) -> String {
    "\(ena)/search?result=study&query=" + ArchiveClient.q("study_accession=\"\(acc)\" OR secondary_study_accession=\"\(acc)\"")
}

private func tempLibrary() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-ds-\(UUID())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("library.json")
}

private func row(_ run: String, study: String, sample: String, alias: String, reads: Int) -> String {
    #"{"run_accession":"\#(run)","sample_accession":"\#(sample)","study_accession":"\#(study)","secondary_study_accession":"SRP193889","sample_alias":"\#(alias)","library_strategy":"AMPLICON","instrument_model":"Illumina MiSeq","read_count":"\#(reads)","fastq_md5":"","fastq_bytes":"","fastq_ftp":""}"#
}

@Suite struct AccessionTests {
    @Test func findsAndClassifiesAccessions() {
        let text = "Data: BioProject PRJNA516684 (SRA SRP193889); run SRR8957147, sample SAMN11508613.\nGEO GSE316107, dbGaP phs000256.v3.p2"
        let found = Accession.find(in: text)
        #expect(found.map(\.accession) == ["PRJNA516684", "SRP193889", "SRR8957147", "SAMN11508613", "GSE316107", "phs000256.v3.p2"])
        #expect(found.map(\.kind) == [.bioproject, .study, .run, .biosample, .geoSeries, .dbgap])
        #expect(found[4].line == 2)
        #expect(Accession.kind(of: "prjna516684") == .bioproject)
        #expect(Accession.kind(of: "PRJNA51668X") == nil)
        #expect(Accession.find(in: "XPRJNA516684 and PRJNA516684Z").isEmpty)
    }

    @Test func nearMissesCatchTyposAndTranspositions() {
        let known = ["SRR32046594", "SRR32046595", "PRJNA922536"]
        #expect(Accession.nearMisses(of: "SRR32046549", among: known) == ["SRR32046594"])   // swapped digits
        #expect(Accession.nearMisses(of: "SRR32046596", among: known) == ["SRR32046594", "SRR32046595"]) // one changed digit
        #expect(Accession.nearMisses(of: "PRJNA92253", among: known) == ["PRJNA922536"])    // dropped digit
        #expect(Accession.nearMisses(of: "PRJNA589514", among: known).isEmpty)
    }
}

@Suite struct DatasetRecordTests {
    @Test func refusesAnAccessionThatContradictsWhatItWasSaidToBe() async throws {
        let http = MockHTTP()
        http.route(studyRoute("PRJNA589514"), body: #"[{"study_accession":"PRJNA589514","secondary_study_accession":"SRP249782","study_title":"Genetic origin and ancestry of the Koban archeological culture in the North Caucasus","scientific_name":"Homo sapiens","first_public":"2019-11-19","center_name":"Kurchatov Institute"}]"#)
        http.route("\(ena)/count", body: #"{"count":"17"}"#)
        http.route("\(ena)/filereport", body: "[" + #"{"run_accession":"SRR11015001","sample_accession":"SAMN14000001","study_accession":"PRJNA589514","library_strategy":"WGS","read_count":"10"}"# + "]")
        http.route(epmc, body: #"{"hitCount":0,"resultList":{"result":[]}}"#)
        let url = tempLibrary()
        var lib = Library()
        await #expect(throws: DatasetError.self) {
            _ = try await DatasetAdder(client: ArchiveClient(http: http)).add("PRJNA589514", to: &lib, libraryURL: url, project: nil, expect: "SIBO duodenal aspirates, 16S")
        }
        #expect(lib.datasets.isEmpty)
        // Its run table isn't left behind either.
        let dir = Library.datasetDirectory(forLibraryAt: url).appendingPathComponent("PRJNA589514")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        // With --anyway it's kept, warnings and all.
        let r = try await DatasetAdder(client: ArchiveClient(http: http)).add("PRJNA589514", to: &lib, libraryURL: url, project: nil, expect: "SIBO duodenal aspirates, 16S", anyway: true)
        #expect(r.warnings.count == 2)
        #expect(r.record.dataset?.warnings.count == 2)
    }

    @Test func addsAnSRAStudyUnderItsBioProjectWithARunTable() async throws {
        let http = MockHTTP()
        http.route(studyRoute("SRP058681"), body: #"[{"study_accession":"PRJNA283404","secondary_study_accession":"SRP058681","study_title":"Penile microbiota and female partner bacterial vaginosis in Rakai, Uganda","first_public":"2015-05-14","center_name":"TGen"}]"#)
        http.route("\(ena)/count", body: #"{"count":"2"}"#)
        http.route("\(ena)/filereport", body: "[" + row("SRR2000001", study: "PRJNA283404", sample: "SAMN1", alias: "A1", reads: 100) + "," + row("SRR2000002", study: "PRJNA283404", sample: "SAMN2", alias: "A2", reads: 200) + "]")
        http.route(epmc, body: #"{"hitCount":1,"resultList":{"result":[{"title":"Penile Microbiota and Female Partner Bacterial Vaginosis in Rakai, Uganda.","authorString":"Liu CM","pubYear":"2015","doi":"10.1128/mbio.00589-15"}]}}"#)
        let url = tempLibrary()
        var lib = Library()
        var paper = Reference(id: 1, authors: [Author(family: "Liu", given: "C. M.")], year: 2015, title: "Penile microbiota…", doi: "10.1128/mBio.00589-15")
        paper.publicationType = .peerReviewed
        try lib.add(paper)
        let r = try await DatasetAdder(client: ArchiveClient(http: http)).add("SRP058681", to: &lib, libraryURL: url, project: ProjectTag(project: "UEF-2607"), papers: [1])
        let d = try #require(r.record.dataset)
        #expect(d.accession == "PRJNA283404")
        #expect(d.otherAccessions == ["SRP058681"])
        #expect(d.paperLink == .confirmed)
        #expect(d.runs == 2 && d.samples == 2)
        #expect(d.assays == ["AMPLICON"])
        let snap = try #require(d.latestSnapshot)
        #expect(try DatasetStore.rows(snap, libraryURL: url).map(\.run) == ["SRR2000001", "SRR2000002"])
        #expect(lib.dataset(forAccession: "SRP058681")?.id == r.record.id)
        #expect(lib.projects["UEF-2607"]?.references.contains(r.record.id) == true)
        // Cited as an APA data set.
        let entry = CitationFormatter(references: [r.record]).referenceEntry(r.record)
        #expect(entry.contains("(PRJNA283404) [Data set]. NCBI BioProject / SRA (INSDC). https://www.ncbi.nlm.nih.gov/bioproject/PRJNA283404"))
        // Adding it again by another accession finds the same record.
        let again = try await DatasetAdder(client: ArchiveClient(http: http)).add("PRJNA283404", to: &lib, libraryURL: url, project: nil)
        #expect(!again.isNew && again.record.id == r.record.id)
    }

    @Test func warnsWhenOtherPapersCiteTheDataset() async throws {
        let http = MockHTTP()
        http.route(studyRoute("PRJNA516684"), body: #"[{"study_accession":"PRJNA516684","study_title":"Human associated vaginal and penile microbiome Metagenome"}]"#)
        http.route("\(ena)/count", body: #"{"count":"0"}"#)
        http.route("\(ena)/filereport", body: "[]")
        http.route(epmc, body: #"{"hitCount":1,"resultList":{"result":[{"title":"Host Genetic Factors Associated with Vaginal Microbiome Composition in Kenyan Women.","authorString":"Mehta SD","pubYear":"2020","doi":"10.1128/msystems.00502-20"}]}}"#)
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Other", given: "A.")], year: 2023, title: "Unrelated", doi: "10.1000/other"))
        let r = try await DatasetAdder(client: ArchiveClient(http: http)).add("PRJNA516684", to: &lib, libraryURL: tempLibrary(), project: nil, papers: [1], fetchRuns: false)
        #expect(r.record.dataset?.paperLink == .otherPapers)
        #expect(r.warnings.first?.contains("Host Genetic Factors") == true)
    }

    @Test func refusesARunAsADataset() async throws {
        let http = MockHTTP()
        http.route("\(ena)/search?result=read_run", body: "[" + row("SRR8957147", study: "PRJNA516684", sample: "SAMN11508613", alias: "x", reads: 1) + "]")
        var lib = Library()
        do {
            _ = try await DatasetAdder(client: ArchiveClient(http: http)).add("SRR8957147", to: &lib, libraryURL: tempLibrary(), project: nil)
            Issue.record("should have thrown")
        } catch let e as DatasetError {
            #expect(e.description.contains("belongs to PRJNA516684"))
        }
    }
}

@Suite struct RunTableTests {
    func rows() -> [RunRow] {
        var a = RunRow(run: "SRR1"); a.biosample = "SAMN1"; a.alias = "Mehta428-03-11-14-405461-mea"; a.reads = 10; a.study = "PRJNA516684"
        var b = RunRow(run: "SRR2"); b.biosample = "SAMN2"; b.alias = "Mehta-CVL224-03-11-14-405462"; b.reads = 20; b.study = "PRJNA516684"
        var c = RunRow(run: "SRR3"); c.biosample = "SAMN3"; c.alias = "Supriya1073"; c.reads = 30; c.study = "PRJNA516684"
        return [a, b, c]
    }

    @Test func roundTripsAndDiffs() {
        let r = rows()
        #expect(RunTable.parse(RunTable.tsv(r)) == r)
        var changed = r
        changed[1].reads = 25
        changed.removeLast()
        var d4 = RunRow(run: "SRR4"); d4.study = "PRJNA516684"
        changed.append(d4)
        let diff = RunTable.diff(old: r, new: changed)
        #expect(diff.added == ["SRR4"] && diff.removed == ["SRR3"])
        #expect(diff.changed.first?.run == "SRR2" && diff.changed.first?.changes == ["reads 20 → 25"])
    }

    @Test func keyRuleBuildsACrosswalkAndCountsGroups() throws {
        let rule = SampleKeyRule(name: "couple", pattern: #"(\d{2}-\d{2}-\d{2})-(\d{5})(\d)(?:-(mea|gcss))?$"#, groups: ["date", "couple", "member", "site"])
        let cw = try rule.crosswalk(rows())
        #expect(cw.rows.count == 2 && cw.unmatched.map(\.run) == ["SRR3"])
        #expect(cw.rows[0] == ["SRR1", "SAMN1", "Mehta428-03-11-14-405461-mea", "03-11-14", "40546", "1", "mea"])
        #expect(cw.groupSizes["couple"] == [2: 1])          // one couple, two runs
        #expect(cw.distinct["member"] == 2)
    }
}

@Suite struct ManifestAndFastqTests {
    func libraryWithSnapshot() throws -> (Library, URL) {
        let url = tempLibrary()
        var lib = Library()
        var rows: [RunRow] = []
        for (run, sample, reads) in [("SRR32046594", "SAMN46306682", 49100), ("SRR32046595", "SAMN46306683", 50000)] {
            var r = RunRow(run: run); r.biosample = sample; r.study = "PRJNA1207522"; r.reads = reads; r.alias = "37_\(run.suffix(2))"
            rows.append(r)
        }
        var other = RunRow(run: "SRR32046549"); other.study = "PRJNA66167"; other.biosample = "SAMN30347637"; other.reads = 9
        let (snap, _) = try DatasetStore.save(rows, for: "PRJNA1207522", source: "test", libraryURL: url, previous: nil, by: nil)
        var info = DatasetInfo(accession: "PRJNA1207522", kind: .bioproject, repository: "NCBI")
        info.snapshots = [snap]
        var ref = Reference(id: 1, authors: [], year: 2025, title: "Korczyńska")
        ref.dataset = info
        try lib.add(ref)
        let (snap2, _) = try DatasetStore.save([other], for: "PRJNA66167", source: "test", libraryURL: url, previous: nil, by: nil)
        var info2 = DatasetInfo(accession: "PRJNA66167", kind: .bioproject, repository: "NCBI")
        info2.snapshots = [snap2]
        var ref2 = Reference(id: 2, authors: [], year: 2012, title: "ENCODE")
        ref2.dataset = info2
        try lib.add(ref2)
        return (lib, url)
    }

    @Test func manifestCheckFindsWrongProjectsSamplesAndReads() async throws {
        let (lib, url) = try libraryWithSnapshot()
        let tsv = """
        project\trun\tbiosample\treads_in_archive
        PRJNA1207522\tSRR32046594\tSAMN46306682\t49100
        PRJNA1207522\tSRR32046549\tSAMN46306682\t49100
        PRJNA1207522\tSRR32046595\tSAMN00000001\t50000
        PRJNA1207522\tSRR32046595\tSAMN46306683\t12345
        42 GEO samples\t42 GEO samples\t\t
        """
        let http = MockHTTP()   // everything is in the library; any lookup returns nothing
        let report = await ManifestCheck(client: ArchiveClient(http: http)).run(text: tsv, name: "m.tsv", library: lib, libraryURL: url, fetchMissing: false)
        #expect(report.columns["reads"] == "reads_in_archive")
        let messages = report.issues.map { "\($0.row) \($0.severity.rawValue) \($0.message)" }
        #expect(messages.contains { $0.hasPrefix("3 error") && $0.contains("belongs to PRJNA66167") && $0.contains("probably a typo for SRR32046594") })
        #expect(messages.contains { $0.hasPrefix("4 error") && $0.contains("SAMN00000001") })
        #expect(messages.contains { $0.hasPrefix("5 warning") && $0.contains("listed again") })
        #expect(messages.contains { $0.hasPrefix("5 warning") && $0.contains("12345 reads") })
        #expect(messages.contains { $0.hasPrefix("6 note") })
        #expect(!messages.contains { $0.hasPrefix("2 ") })
    }

    @Test func fastqCheckSeparatesCompletePartialTruncatedAndCorrupt() async throws {
        let (lib, url) = try libraryWithSnapshot()
        let dir = url.deletingLastPathComponent().appendingPathComponent("reads")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec = "@r1\nACGT\n+\nIIII\n"
        try String(repeating: rec, count: 3).write(to: dir.appendingPathComponent("SRR32046594.fastq"), atomically: true, encoding: .utf8)
        try (rec + "@r2\nACG").write(to: dir.appendingPathComponent("SRR32046595_1.fastq"), atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nII\n".write(to: dir.appendingPathComponent("SRR32046549.fastq"), atomically: true, encoding: .utf8)
        let items = try await FastqCheck(client: ArchiveClient(http: MockHTTP())).run(directory: dir, library: lib, libraryURL: url)
        let byFile = Dictionary(uniqueKeysWithValues: items.map { ($0.file, $0.status) })
        #expect(byFile["SRR32046594.fastq"] == .partial)
        #expect(byFile["SRR32046595_1.fastq"] == .truncated)
        #expect(byFile["SRR32046549.fastq"] == .corrupt)
    }

    @Test func fastqGzipIsCheckedBySizeAndMD5() async throws {
        let url = tempLibrary()
        let dir = url.deletingLastPathComponent().appendingPathComponent("reads")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("SRR9000001_1.fastq")
        try String(repeating: "@r\nACGT\n+\nIIII\n", count: 200).write(to: plain, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-n", plain.path]
        try p.run(); p.waitUntilExit()
        let gz = dir.appendingPathComponent("SRR9000001_1.fastq.gz")
        let data = try Data(contentsOf: gz)
        var r = RunRow(run: "SRR9000001"); r.study = "PRJNA1"; r.reads = 200
        r.fastqURLs = ["ftp.sra.ebi.ac.uk/vol1/fastq/SRR900/001/SRR9000001/SRR9000001_1.fastq.gz"]
        r.fastqBytes = [data.count]; r.fastqMD5 = [try FileHash.md5(of: gz)]
        var lib = Library()
        let (snap, _) = try DatasetStore.save([r], for: "PRJNA1", source: "t", libraryURL: url, previous: nil, by: nil)
        var info = DatasetInfo(accession: "PRJNA1", kind: .bioproject, repository: "NCBI"); info.snapshots = [snap]
        var ref = Reference(id: 1, authors: [], year: nil, title: "t"); ref.dataset = info
        try lib.add(ref)
        var items = try await FastqCheck(client: ArchiveClient(http: MockHTTP())).run(directory: dir, library: lib, libraryURL: url)
        #expect(items.first?.status == .complete)
        try data.prefix(data.count / 2).write(to: gz)
        items = try await FastqCheck(client: ArchiveClient(http: MockHTTP())).run(directory: dir, library: lib, libraryURL: url)
        #expect(items.first?.status == .truncated)
    }
}

@Suite struct OutputEvidenceTests {
    @Test func boundResultGoesStaleWhenARerunRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-out-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("couple_oral_module_output.txt")
        try "Kisumu couples\noral module:   rho = +0.05,  p = 0.61\n".write(to: out, atomically: true, encoding: .utf8)
        var lib = Library()
        var info = DatasetInfo(accession: "PRJNA516684", kind: .bioproject, repository: "NCBI")
        info.runs = 1871
        var ds = Reference(id: 1, authors: [], year: 2020, title: "Kisumu"); ds.dataset = info
        try lib.add(ds)
        var index = ProjectCitationIndex(project: "UEF-2607")
        index.claims = [Claim(id: "C1", text: "No partner tracking of the oral module.")]
        lib.projects["UEF-2607"] = index

        #expect(throws: DatasetError.self) { try lib.bindOutput(project: "UEF-2607", claim: "C1", file: out, excerpt: "rho = +0.5", datasets: [], by: nil) }
        #expect(throws: EvidenceError.self) { try lib.checkSupportable(project: "UEF-2607", claim: "C1") }
        let ev = try lib.bindOutput(project: "UEF-2607", claim: "C1", file: out, excerpt: "rho = +0.05, p = 0.61", datasets: [1], by: "Fable")
        #expect(ev.line == 2)
        #expect(lib.projects["UEF-2607"]?.claims[0].references == [1])
        try lib.checkSupportable(project: "UEF-2607", claim: "C1")   // a current output counts as support

        // A change that keeps the excerpt: still current, re-fingerprinted.
        try "Kisumu couples (n = 185)\n\noral module: rho = +0.05, p = 0.61\n".write(to: out, atomically: true, encoding: .utf8)
        var log = lib.recheckOutputs()
        guard case .stillPresent(let line) = log.first?.outcome else { Issue.record("expected stillPresent"); return }
        #expect(line == 3)

        // The rerun with the corrected key: gone → stale, and no longer support.
        try "Kisumu couples (fixed key)\noral module: rho = +0.37, p = 0.0001\n".write(to: out, atomically: true, encoding: .utf8)
        log = lib.recheckOutputs()
        guard case .stale = log.first?.outcome else { Issue.record("expected stale"); return }
        #expect(lib.projects["UEF-2607"]?.claims[0].outputs?.first?.isCurrent == false)
        #expect(throws: EvidenceError.self) { try lib.checkSupportable(project: "UEF-2607", claim: "C1") }

        // Kept, not deleted; the report says so.
        let md = ClaimsReport(library: lib, project: "UEF-2607").markdown()
        #expect(md.contains("STALE") && md.contains("dataset **PRJNA516684**"))
    }

    @Test func locatesExcerptsAcrossLines() {
        #expect(OutputEvidence.locate("15 of 67 (22.4%)", in: "a\nwoman positive in 15 of\n67 (22.4%) couples") == 2)
        #expect(OutputEvidence.locate("22.4", in: "2.24") == nil)
    }
}

@Suite struct AccessionAuditTests {
    @Test func flagsMissingMislabelledAndMismatchedAccessions() async throws {
        let http = MockHTTP()
        http.route(studyRoute("SRP058681"), body: #"[{"study_accession":"PRJNA283404","secondary_study_accession":"SRP058681","study_title":"Penile microbiota and female partner bacterial vaginosis in Rakai, Uganda"}]"#)
        http.route(studyRoute("PRJNA285182"), body: #"[{"study_accession":"PRJNA285182","study_title":"Campylobacter fetus subsp. testudinum strain:D6659 Genome sequencing and assembly"}]"#)
        http.route(studyRoute("PRJNA922536"), body: #"[{"study_accession":"PRJNA922536","study_title":"Human small intestine Metagenome"}]"#)
        http.route(studyRoute("PRJNA92253"), body: "[]")
        http.route("\(ena)/count", body: #"{"count":"165"}"#)
        http.route("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=gds", body: #"{"esearchresult":{"idlist":["200316107"]}}"#)
        http.route("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=gds", body: #"{"result":{"uids":["200316107"],"200316107":{"accession":"GSE316107","title":"Myometrial Microbiota in Uterine Fibroids","n_samples":"42","bioproject":"PRJNA1400614","pubmedids":[]}}}"#)
        let text = """
        Liu 2015. BioProject `SRP058681` / `PRJNA285182`.
        Bertorello: BioProject GSE316107 (42 samples).
        Duodenum PRJNA922536; also PRJNA92253 (165 runs).
        """
        let report = await AccessionAudit(client: ArchiveClient(http: http)).run(files: [("ms.md", text)], library: Library(), libraryURL: tempLibrary())
        let m = report.findings.map { "\($0.severity.rawValue) \($0.accession): \($0.message)" }
        #expect(m.contains { $0.hasPrefix("error SRP058681") && $0.contains("Campylobacter") })
        #expect(m.contains { $0.hasPrefix("warning SRP058681") && $0.contains("called a BioProject") })
        #expect(m.contains { $0.hasPrefix("warning GSE316107") && $0.contains("PRJNA1400614") })
        #expect(m.contains { $0.hasPrefix("error PRJNA92253") && $0.contains("PRJNA922536") })
        #expect(!m.contains { $0.contains("GSE316107") && $0.contains("text says") })   // 42 samples matches
    }
}
