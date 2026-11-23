import Foundation
import CryptoKit

// MARK: Accessions

/// The kinds of public sequence-archive identifiers RefWare recognises (INSDC: NCBI SRA/BioProject/BioSample,
/// ENA, DDBJ; plus GEO and dbGaP).
public enum AccessionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case bioproject      // PRJNA516684, PRJEB21446, PRJDB…
    case study           // SRP058681, ERP…, DRP…
    case run             // SRR8957147, ERR…, DRR…
    case experiment      // SRX…, ERX…, DRX…
    case sraSample = "sra-sample"   // SRS…, ERS…, DRS…
    case biosample       // SAMN11508613, SAMEA…, SAMD…
    case geoSeries = "geo-series"   // GSE316107
    case geoSample = "geo-sample"   // GSM9444893
    case dbgap           // phs000256 (controlled access)

    public var label: String {
        switch self {
        case .bioproject: "BioProject"
        case .study: "SRA study"
        case .run: "SRA run"
        case .experiment: "SRA experiment"
        case .sraSample: "SRA sample"
        case .biosample: "BioSample"
        case .geoSeries: "GEO series"
        case .geoSample: "GEO sample"
        case .dbgap: "dbGaP study"
        }
    }

    /// A project-level identifier (one dataset), as opposed to a run or a sample inside one.
    public var isStudyLevel: Bool { [.bioproject, .study, .geoSeries, .dbgap].contains(self) }
}

public enum Accession {
    static let patterns: [(AccessionKind, String)] = [
        (.bioproject, #"PRJ(?:NA|EB|DB|DA)\d{3,}"#),
        (.study, #"[SED]RP\d{6,}"#),
        (.run, #"[SED]RR\d{6,}"#),
        (.experiment, #"[SED]RX\d{6,}"#),
        (.sraSample, #"[SED]RS\d{6,}"#),
        (.biosample, #"SAM(?:N|EA|D)\d{5,}"#),
        (.geoSeries, #"GSE\d{3,}"#),
        (.geoSample, #"GSM\d{3,}"#),
        (.dbgap, #"phs\d{6}(?:\.v\d+\.p\d+)?"#),
    ]

    /// The kind of a single identifier, or nil if it isn't one. Case-insensitive except dbGaP's `phs`.
    public static func kind(of raw: String) -> AccessionKind? {
        let s = normalize(raw)
        for (kind, p) in patterns where s.range(of: "^" + p + "$", options: .regularExpression) != nil { return kind }
        return nil
    }

    /// `prjna516684` → `PRJNA516684`; dbGaP keeps its lower-case `phs`.
    public static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "`*_()[],;.")))
        return t.lowercased().hasPrefix("phs") ? t.lowercased() : t.uppercased()
    }

    public struct Occurrence: Hashable, Sendable {
        public var accession: String
        public var kind: AccessionKind
        /// 1-based line number.
        public var line: Int
        /// The whole line it was found on (trimmed).
        public var context: String
        /// Character offset of the accession in `context`.
        public var offset: Int
    }

    /// Every accession in a text, in order, with its line.
    public static func find(in text: String) -> [Occurrence] {
        let alternation = patterns.map { "(?:\($0.1))" }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:"# + alternation + #")(?![A-Za-z0-9])"#) else { return [] }
        var out: [Occurrence] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                guard let kind = kind(of: raw) else { continue }
                out.append(Occurrence(accession: normalize(raw), kind: kind, line: i + 1, context: line, offset: m.range.location))
            }
        }
        return out
    }

    /// Accessions one keystroke away: one changed, dropped or added digit, or two neighbours swapped.
    public static func nearMisses(of accession: String, among known: some Sequence<String>) -> [String] {
        let a = Array(accession)
        return known.filter { $0 != accession && isOneEditAway(a, Array($0)) }.sorted()
    }

    static func isOneEditAway(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return false }
        if a.count == b.count {
            let diffs = a.indices.filter { a[$0] != b[$0] }
            if diffs.count == 1 { return true }
            if diffs.count == 2, diffs[1] == diffs[0] + 1, a[diffs[0]] == b[diffs[1]], a[diffs[1]] == b[diffs[0]] { return true }
            return false
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        var i = 0, j = 0, skipped = false
        while i < long.count, j < short.count {
            if long[i] == short[j] { i += 1; j += 1 } else if skipped { return false } else { skipped = true; i += 1 }
        }
        return true
    }

    /// Where a person can look an accession up.
    public static func url(for accession: String) -> String? {
        switch kind(of: accession) {
        case .bioproject: "https://www.ncbi.nlm.nih.gov/bioproject/\(accession)"
        case .study, .run, .experiment, .sraSample: "https://www.ncbi.nlm.nih.gov/sra/?term=\(accession)"
        case .biosample: "https://www.ncbi.nlm.nih.gov/biosample/\(accession)"
        case .geoSeries, .geoSample: "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=\(accession)"
        case .dbgap: "https://www.ncbi.nlm.nih.gov/projects/gap/cgi-bin/study.cgi?study_id=\(accession)"
        case nil: nil
        }
    }
}

// MARK: Dataset records

/// What the archive says about a public dataset. Stored on a library record (`Reference.dataset`), so a dataset
/// gets an IDI, can be cited with `[IDI n]`, filed in projects, and linked to claims like any paper.
public struct DatasetInfo: Codable, Hashable, Sendable {
    public enum Access: String, Codable, Hashable, Sendable { case open, controlled }

    /// The main accession (a BioProject where there is one).
    public var accession: String
    public var kind: AccessionKind
    /// The same dataset's other identifiers (SRA study, GEO series, BioProject…).
    public var otherAccessions: [String]
    public var repository: String
    public var archiveTitle: String?
    public var archiveDescription: String?
    public var organism: String?
    public var submitter: String?
    /// First public date as the archive gives it (`2019-11-19`).
    public var released: String?
    /// Library strategies (`AMPLICON`, `WGS`, `RNA-Seq`) and instruments seen in the runs.
    public var assays: [String]
    public var platforms: [String]
    public var samples: Int?
    public var runs: Int?
    public var access: Access
    /// Papers the archive links to, or that Europe PMC finds mentioning this accession (DOIs).
    public var mentionedBy: [String]
    /// The library papers this dataset comes from (stated by whoever added it; see `paperLink`).
    public var papers: [IDI]
    /// Whether an archive or literature index confirms the link to `papers`.
    public var paperLink: PaperLink?
    /// Run tables fetched over time — each a dated, fingerprinted file next to the library.
    public var snapshots: [RunTableSnapshot]
    /// How sample names split into keys (participant, couple, visit…). Earlier rules are kept, retired.
    public var keyRules: [SampleKeyRule]
    /// Differences between what someone said this dataset is and what the archive says.
    public var warnings: [String]

    public enum PaperLink: String, Codable, Hashable, Sendable {
        /// The archive links the paper, or the paper's full text cites the accession.
        case confirmed
        /// Nothing indexed connects them — as stated, not checked.
        case unconfirmed
        /// Indexed papers mention this accession, but not the stated one.
        case otherPapers = "other-papers"
    }

    public init(accession: String, kind: AccessionKind, repository: String, access: Access = .open) {
        self.accession = accession
        self.kind = kind
        self.otherAccessions = []
        self.repository = repository
        self.assays = []
        self.platforms = []
        self.access = access
        self.mentionedBy = []
        self.papers = []
        self.snapshots = []
        self.keyRules = []
        self.warnings = []
    }

    public var allAccessions: [String] { [accession] + otherAccessions }
    public var latestSnapshot: RunTableSnapshot? { snapshots.max { $0.fetched < $1.fetched } }
    public var activeKeyRules: [SampleKeyRule] { keyRules.filter { $0.retired == nil } }

    public func matches(_ accession: String) -> Bool {
        let a = Accession.normalize(accession)
        return allAccessions.contains { $0 == a }
    }
}

// MARK: Run tables

/// One sequencing run as the archive lists it.
public struct RunRow: Codable, Hashable, Sendable {
    public var run: String
    public var biosample: String?
    public var sraSample: String?
    public var experiment: String?
    public var study: String?          // PRJ…
    public var secondaryStudy: String? // SRP…
    public var alias: String?
    public var title: String?
    public var strategy: String?
    public var layout: String?
    public var platform: String?
    public var instrument: String?
    public var reads: Int?
    public var bases: Int?
    /// One per file (`_1`, `_2`), in the archive's order.
    public var fastqMD5: [String]
    public var fastqBytes: [Int]
    public var fastqURLs: [String]
    public var firstPublic: String?
    public var organism: String?

    public init(run: String) {
        self.run = run
        fastqMD5 = []; fastqBytes = []; fastqURLs = []
    }

    static let columns = ["run", "biosample", "sra_sample", "experiment", "study", "secondary_study", "alias", "title", "strategy",
                          "layout", "platform", "instrument", "reads", "bases", "fastq_md5", "fastq_bytes", "fastq_url", "first_public", "organism"]

    var tsvFields: [String] {
        [run, biosample, sraSample, experiment, study, secondaryStudy, alias, title, strategy, layout, platform, instrument,
         reads.map(String.init), bases.map(String.init), fastqMD5.joined(separator: ";"), fastqBytes.map(String.init).joined(separator: ";"),
         fastqURLs.joined(separator: ";"), firstPublic, organism].map { ($0 ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    }

    init?(tsv fields: [String], header: [String]) {
        func v(_ name: String) -> String? {
            guard let i = header.firstIndex(of: name), i < fields.count, !fields[i].isEmpty else { return nil }
            return fields[i]
        }
        guard let run = v("run") else { return nil }
        self.init(run: run)
        biosample = v("biosample"); sraSample = v("sra_sample"); experiment = v("experiment")
        study = v("study"); secondaryStudy = v("secondary_study"); alias = v("alias"); title = v("title")
        strategy = v("strategy"); layout = v("layout"); platform = v("platform"); instrument = v("instrument")
        reads = v("reads").flatMap(Int.init); bases = v("bases").flatMap(Int.init)
        fastqMD5 = v("fastq_md5")?.split(separator: ";").map(String.init) ?? []
        fastqBytes = v("fastq_bytes")?.split(separator: ";").compactMap { Int($0) } ?? []
        fastqURLs = v("fastq_url")?.split(separator: ";").map(String.init) ?? []
        firstPublic = v("first_public"); organism = v("organism")
    }

    /// Belongs to this study (by BioProject or SRA study accession).
    public func inStudy(_ accession: String) -> Bool {
        let a = Accession.normalize(accession)
        return study == a || secondaryStudy == a
    }
}

/// A run table as fetched on one date: the file holding it and its SHA-256.
public struct RunTableSnapshot: Codable, Hashable, Sendable {
    /// Path relative to the library's `datasets/` folder.
    public var file: String
    public var sha256: String
    public var fetched: Date
    public var source: String
    public var runs: Int
    public var samples: Int
    public var by: String?
}

public enum RunTable {
    public static func tsv(_ rows: [RunRow]) -> String {
        ([RunRow.columns.joined(separator: "\t")] + rows.sorted { $0.run < $1.run }.map { $0.tsvFields.joined(separator: "\t") })
            .joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) -> [RunRow] {
        var lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().components(separatedBy: "\t")
        return lines.compactMap { RunRow(tsv: $0.components(separatedBy: "\t"), header: header) }
    }

    public struct Diff: Sendable {
        public var added: [String] = []
        public var removed: [String] = []
        /// run → what changed ("reads 15776 → 15800").
        public var changed: [(run: String, changes: [String])] = []
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    public static func diff(old: [RunRow], new: [RunRow]) -> Diff {
        let o = Dictionary(old.map { ($0.run, $0) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.map { ($0.run, $0) }, uniquingKeysWith: { a, _ in a })
        var d = Diff()
        d.added = n.keys.filter { o[$0] == nil }.sorted()
        d.removed = o.keys.filter { n[$0] == nil }.sorted()
        for run in n.keys.sorted() {
            guard let a = o[run], let b = n[run] else { continue }
            var c: [String] = []
            func cmp(_ label: String, _ x: String?, _ y: String?) { if x != y { c.append("\(label) \(x ?? "–") → \(y ?? "–")") } }
            cmp("sample", a.biosample, b.biosample)
            cmp("alias", a.alias, b.alias)
            cmp("study", a.study, b.study)
            cmp("reads", a.reads.map(String.init), b.reads.map(String.init))
            cmp("strategy", a.strategy, b.strategy)
            if a.fastqMD5 != b.fastqMD5 { c.append("files changed (MD5)") }
            if !c.isEmpty { d.changed.append((run, c)) }
        }
        return d
    }
}

// MARK: Sample keys

/// A rule for reading keys out of sample names: e.g. Kisumu aliases `Mehta428-03-11-14-405461-mea`
/// → date `03-11-14`, couple `40546`, member `1`. Recorded with who set it, so it can be reviewed.
public struct SampleKeyRule: Codable, Hashable, Sendable {
    public var name: String
    /// `alias`, `title`, `run` or `biosample`.
    public var field: String
    /// A regular expression whose capture groups are the keys.
    public var pattern: String
    /// One name per capture group (`date,couple,member`).
    public var groups: [String]
    public var note: String?
    public var by: String?
    public var on: Date
    public var retired: Date?

    public init(name: String, field: String = "alias", pattern: String, groups: [String], note: String? = nil, by: String? = nil, on: Date = Date()) {
        self.name = name
        self.field = field
        self.pattern = pattern
        self.groups = groups
        self.note = note
        self.by = by
        self.on = Date(timeIntervalSince1970: on.timeIntervalSince1970.rounded(.down))
    }

    public func value(in row: RunRow) -> String? {
        switch field {
        case "title": row.title
        case "run": row.run
        case "biosample", "sample": row.biosample
        default: row.alias
        }
    }

    /// The keys for one row, or nil if the name doesn't match the pattern.
    public func keys(for row: RunRow) throws -> [String]? {
        let re = try NSRegularExpression(pattern: pattern)
        guard let s = value(in: row) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    public struct Crosswalk: Sendable {
        public var header: [String]
        public var rows: [[String]]
        public var unmatched: [RunRow]
        /// Per key: how many distinct values have 1, 2, 3… runs ("couples with exactly two samples").
        public var groupSizes: [String: [Int: Int]]
        /// Per key: how many distinct values.
        public var distinct: [String: Int]
        public var tsv: String { ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n" }
    }

    public func crosswalk(_ runs: [RunRow]) throws -> Crosswalk {
        var rows: [[String]] = [], unmatched: [RunRow] = []
        var counts: [String: [String: Int]] = [:]
        for r in runs.sorted(by: { $0.run < $1.run }) {
            guard let k = try keys(for: r) else { unmatched.append(r); continue }
            rows.append([r.run, r.biosample ?? "", value(in: r) ?? ""] + k)
            for (name, v) in zip(groups, k) where !v.isEmpty { counts[name, default: [:]][v, default: 0] += 1 }
        }
        var sizes: [String: [Int: Int]] = [:]
        for (name, c) in counts { for (_, n) in c { sizes[name, default: [:]][n, default: 0] += 1 } }
        return Crosswalk(header: ["run", "biosample", field] + groups, rows: rows, unmatched: unmatched, groupSizes: sizes, distinct: counts.mapValues(\.count))
    }
}

// MARK: Results bound to analysis output

/// A number or statement in an analysis output file that a claim rests on — the computed counterpart of a verified
/// quote. Bound to the file's SHA-256: when a rerun changes the file and the excerpt is gone, it goes stale.
public struct OutputEvidence: Codable, Hashable, Sendable {
    /// Absolute path (`~` for the home folder).
    public var path: String
    /// The exact text in the file, as it appears there.
    public var excerpt: String
    public var line: Int
    public var sha256: String
    public var boundOn: Date
    public var by: String?
    /// Datasets the result was computed from.
    public var datasets: [IDI]
    public var staleSince: Date?
    public var staleReason: String?

    public var isCurrent: Bool { staleSince == nil }

    public init(path: String, excerpt: String, line: Int, sha256: String, by: String?, datasets: [IDI]) {
        self.path = path
        self.excerpt = excerpt
        self.line = line
        self.sha256 = sha256
        self.boundOn = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        self.by = by
        self.datasets = datasets
    }

    public var fileURL: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    public static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Whitespace-insensitive, otherwise exact (digits, signs, decimal points and symbols must match).
    static func squeeze(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The 1-based line where `excerpt` starts in `text`, or nil if it isn't there.
    public static func locate(_ excerpt: String, in text: String) -> Int? {
        let target = squeeze(excerpt)
        guard !target.isEmpty else { return nil }
        let lines = text.components(separatedBy: "\n")
        // Within one line first (the common case), then across lines.
        if let i = lines.firstIndex(where: { squeeze($0).contains(target) }) { return i + 1 }
        let whole = squeeze(text)
        guard let r = whole.range(of: target) else { return nil }
        let prefixWords = whole[..<r.lowerBound].split(separator: " ").count
        var seen = 0
        for (i, l) in lines.enumerated() {
            seen += l.split(whereSeparator: \.isWhitespace).count
            if seen > prefixWords { return i + 1 }
        }
        return lines.count
    }
}

enum FileHash {
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func md5(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.MD5()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
