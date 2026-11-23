import Foundation

/// Looks accessions up in the public archives:
/// - ENA Portal API (https://www.ebi.ac.uk/ena/portal/api) for BioProjects, SRA studies, runs, samples and
///   file checksums — ENA mirrors every INSDC submission, NCBI's included;
/// - NCBI E-utilities for GEO series;
/// - Europe PMC for the papers whose text cites an accession.
public struct ArchiveClient: Sendable {
    public var http: HTTPClient
    public var mailto: String?
    var ena = "https://www.ebi.ac.uk/ena/portal/api"
    var eutils = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
    var europePMC = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    public init(http: HTTPClient = URLSessionHTTPClient(), mailto: String? = nil) {
        self.http = http
        self.mailto = mailto
    }

    /// What one archive lookup found.
    public struct Study: Sendable, Hashable {
        public var accession: String
        public var kind: AccessionKind
        public var otherAccessions: [String] = []
        public var title: String?
        public var description: String?
        public var organism: String?
        public var submitter: String?
        public var released: String?
        public var samples: Int?
        public var runs: Int?
        public var repository: String
        public var access: DatasetInfo.Access = .open
        /// PubMed IDs the archive links (GEO).
        public var pubmedIDs: [String] = []
    }

    public struct Paper: Sendable, Hashable {
        public var title: String
        public var authors: String
        public var year: String?
        public var doi: String?
        public var pmid: String?
    }

    var headers: [String: String] { ["Accept": "application/json", "User-Agent": "RefWare/1.3 (+https://github.com/UEFoundation/RefWare)"] }

    func getJSON(_ s: String) async throws -> Any? {
        guard let url = URL(string: s) else { return nil }
        let r = try await http.get(url, headers: headers)
        if r.status == 404 || r.status == 204 || r.data.isEmpty { return nil }
        guard r.status == 200 else { throw SearchError.http(status: r.status, url: url) }
        return try? JSONSerialization.jsonObject(with: r.data)
    }

    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s }

    // MARK: Studies

    /// A BioProject, SRA study, GEO series or dbGaP study. Nil when the archive has no such accession.
    public func study(_ raw: String) async throws -> Study? {
        let acc = Accession.normalize(raw)
        switch Accession.kind(of: acc) {
        case .bioproject, .study: return try await enaStudy(acc)
        case .geoSeries: return try await geoSeries(acc)
        case .dbgap:
            var s = Study(accession: acc, kind: .dbgap, repository: "dbGaP")
            s.access = .controlled
            return s
        default: return nil
        }
    }

    func enaStudy(_ acc: String) async throws -> Study? {
        let query = "study_accession=\"\(acc)\" OR secondary_study_accession=\"\(acc)\""
        let fields = "study_accession,secondary_study_accession,study_title,study_description,scientific_name,first_public,center_name"
        guard let rows = try await getJSON("\(ena)/search?result=study&query=\(Self.q(query))&fields=\(fields)&format=json") as? [[String: Any]],
              let row = rows.first else { return nil }
        func v(_ k: String) -> String? { (row[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let primary = v("study_accession") ?? acc
        var s = Study(accession: primary, kind: Accession.kind(of: primary) ?? .bioproject, repository: "NCBI BioProject / SRA (INSDC)")
        s.otherAccessions = [v("secondary_study_accession")].compactMap { $0 }.flatMap { $0.split(separator: ";").map(String.init) }.filter { $0 != primary }
        s.title = v("study_title"); s.description = v("study_description"); s.organism = v("scientific_name")
        s.released = v("first_public"); s.submitter = v("center_name")
        if primary.hasPrefix("PRJEB") { s.repository = "ENA" }
        if let n = try? await count(result: "read_run", query: "study_accession=\"\(primary)\"") { s.runs = n }
        return s
    }

    func count(result: String, query: String) async throws -> Int? {
        guard let url = URL(string: "\(ena)/count?result=\(result)&query=\(Self.q(query))&format=json") else { return nil }
        let r = try await http.get(url, headers: headers)
        guard r.status == 200 else { return nil }
        if let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] {
            return (o["count"] as? Int) ?? (o["count"] as? String).flatMap(Int.init)
        }
        return Int(String(decoding: r.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func geoSeries(_ acc: String) async throws -> Study? {
        let tool = "tool=refware" + (mailto.map { "&email=\(Self.q($0))" } ?? "")
        guard let search = try await getJSON("\(eutils)/esearch.fcgi?db=gds&term=\(acc)%5BACCN%5D%20AND%20gse%5BETYP%5D&retmode=json&\(tool)") as? [String: Any],
              let ids = (search["esearchresult"] as? [String: Any])?["idlist"] as? [String], let uid = ids.first else { return nil }
        try? await Task.sleep(for: .milliseconds(350))   // NCBI: at most 3 requests a second without a key
        guard let sum = try await getJSON("\(eutils)/esummary.fcgi?db=gds&id=\(uid)&retmode=json&\(tool)") as? [String: Any],
              let result = sum["result"] as? [String: Any], let r = result[uid] as? [String: Any] else { return nil }
        func v(_ k: String) -> String? { (r[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard v("accession") == acc else { return nil }
        var s = Study(accession: acc, kind: .geoSeries, repository: "Gene Expression Omnibus (GEO)")
        s.title = v("title"); s.description = v("summary"); s.organism = v("taxon")
        s.released = v("pdat")?.replacingOccurrences(of: "/", with: "-")
        s.samples = v("n_samples").flatMap(Int.init)
        if let bp = v("bioproject") { s.otherAccessions.append(bp) }
        s.pubmedIDs = (r["pubmedids"] as? [Any])?.map { "\($0)" } ?? []
        return s
    }

    // MARK: Runs

    static let runFields = "run_accession,sample_accession,secondary_sample_accession,experiment_accession,study_accession,secondary_study_accession,sample_alias,sample_title,library_strategy,library_layout,instrument_platform,instrument_model,read_count,base_count,fastq_md5,fastq_bytes,fastq_ftp,first_public,scientific_name"

    /// Every run in a study (BioProject or SRA study accession).
    public func runTable(_ study: String) async throws -> [RunRow] {
        let acc = Accession.normalize(study)
        guard let rows = try await getJSON("\(ena)/filereport?accession=\(acc)&result=read_run&fields=\(Self.runFields)&format=json&limit=0") as? [[String: Any]] else { return [] }
        return rows.compactMap(Self.runRow)
    }

    /// Runs found by run, experiment, SRA-sample or BioSample accession, looked up in batches.
    public func runs(matching accessions: [String]) async throws -> [RunRow] {
        var out: [RunRow] = []
        let groups = Dictionary(grouping: accessions.map(Accession.normalize)) { Accession.kind(of: $0) }
        for (kind, list) in groups {
            let field: String
            switch kind {
            case .run: field = "run_accession"
            case .experiment: field = "experiment_accession"
            case .sraSample: field = "secondary_sample_accession"
            case .biosample: field = "sample_accession"
            default: continue
            }
            for start in stride(from: 0, to: list.count, by: 40) {
                let batch = Array(Set(list[start..<min(start + 40, list.count)])).sorted()
                let query = batch.map { "\(field)=\"\($0)\"" }.joined(separator: " OR ")
                if let rows = try await getJSON("\(ena)/search?result=read_run&query=\(Self.q(query))&fields=\(Self.runFields)&format=json&limit=0") as? [[String: Any]] {
                    out += rows.compactMap(Self.runRow)
                }
            }
        }
        return out
    }

    static func runRow(_ row: [String: Any]) -> RunRow? {
        func v(_ k: String) -> String? { (row[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let run = v("run_accession") else { return nil }
        var r = RunRow(run: run)
        r.biosample = v("sample_accession"); r.sraSample = v("secondary_sample_accession"); r.experiment = v("experiment_accession")
        r.study = v("study_accession"); r.secondaryStudy = v("secondary_study_accession")
        r.alias = v("sample_alias"); r.title = v("sample_title"); r.strategy = v("library_strategy"); r.layout = v("library_layout")
        r.platform = v("instrument_platform"); r.instrument = v("instrument_model")
        r.reads = v("read_count").flatMap(Int.init); r.bases = v("base_count").flatMap(Int.init)
        r.fastqMD5 = v("fastq_md5")?.split(separator: ";").map(String.init) ?? []
        r.fastqBytes = v("fastq_bytes")?.split(separator: ";").compactMap { Int($0) } ?? []
        r.fastqURLs = v("fastq_ftp")?.split(separator: ";").map(String.init) ?? []
        r.firstPublic = v("first_public"); r.organism = v("scientific_name")
        return r
    }

    // MARK: Literature

    /// Papers whose indexed text cites the accession (Europe PMC), most-cited first.
    public func papers(citing accession: String, limit: Int = 25) async throws -> [Paper] {
        let query = "\"\(Accession.normalize(accession))\""
        guard let o = try await getJSON("\(europePMC)/search?query=\(Self.q(query))&format=json&resultType=lite&pageSize=\(limit)") as? [String: Any],
              let list = (o["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return [] }
        return list.map { r in
            Paper(title: (r["title"] as? String ?? "").trimmingCharacters(in: .whitespaces), authors: r["authorString"] as? String ?? "",
                  year: r["pubYear"] as? String, doi: r["doi"] as? String, pmid: r["pmid"] as? String)
        }
    }

    /// DOIs for PubMed IDs (via Europe PMC).
    public func dois(forPubMed ids: [String]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let query = ids.map { "EXT_ID:\($0) AND SRC:MED" }.joined(separator: " OR ")
        guard let o = try await getJSON("\(europePMC)/search?query=\(Self.q(query))&format=json&resultType=lite&pageSize=\(ids.count)") as? [String: Any],
              let list = (o["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["doi"] as? String }
    }
}
