import Foundation

/// One dated thing that happened to the library: a C/R build, an export, an import,
/// a PDF added, a quote verified. Kept in `refware-history.json` beside the library
/// (separate from it, so builds against a frozen library are still recorded).
public struct HistoryEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Cite/ref build: tags in a document expanded, reference list generated.
        case build
        case claimsExport = "claims-export"
        case referenceExport = "reference-export"
        case transcriptImport = "transcript-import"
        case pdfAdded = "pdf-added"
        case quoteVerified = "quote-verified"
        case merge
        case freeze
        /// A claim's status was set (supported, overstated…).
        case claimReviewed = "claim-reviewed"
        /// A record's details were changed, adopted, or confirmed by hand.
        case recordUpdated = "record-updated"
        case recordDeleted = "record-deleted"
        /// A claim was added, linked, annotated, flagged or commented on.
        case claimEdited = "claim-edited"
        /// A project was created, given a sub-project, or its review policy changed.
        case projectEdited = "project-edited"
        /// A kind this build doesn't know (written by a newer RefWare); its name is kept in `kindName`.
        case other
    }

    /// The original kind name when `kind == .other`.
    public var kindName: String?

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var project: String?
    public var subproject: String?
    /// Human summary: the document built, the file exported, the PDF added…
    public var title: String
    /// IDIs involved — for a build, every IDI cited ("hits").
    public var idis: [IDI]
    /// IDI-Q tags involved — for a build, every quote cited; for a claims export, every quote listed.
    public var quoteTags: [String]
    /// Archived copy, relative to the library folder (`Exports/…`).
    public var archived: String?
    /// The original file or URL.
    public var source: String?
    /// Who did it: a person's initials ("SMH") or an agent's name ("Claude Opus 4.8").
    public var actor: String?

    /// Default actor for this process: `REFWARE_ACTOR`, set by agents (and by the app to the reviewer's initials).
    public static var defaultActor: String? {
        get { actorOverride ?? ProcessInfo.processInfo.environment["REFWARE_ACTOR"] }
        set { actorOverride = newValue }
    }
    nonisolated(unsafe) private static var actorOverride: String?

    private enum CodingKeys: String, CodingKey { case id, date, kind, project, subproject, title, idis, quoteTags, archived, source, actor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        let raw = try c.decode(String.self, forKey: .kind)
        kind = Kind(rawValue: raw) ?? .other
        kindName = kind == .other && raw != "other" ? raw : nil
        project = try c.decodeIfPresent(String.self, forKey: .project)
        subproject = try c.decodeIfPresent(String.self, forKey: .subproject)
        title = try c.decode(String.self, forKey: .title)
        idis = try c.decodeIfPresent([IDI].self, forKey: .idis) ?? []
        quoteTags = try c.decodeIfPresent([String].self, forKey: .quoteTags) ?? []
        archived = try c.decodeIfPresent(String.self, forKey: .archived)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        actor = try c.decodeIfPresent(String.self, forKey: .actor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(kindName ?? kind.rawValue, forKey: .kind)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(subproject, forKey: .subproject)
        try c.encode(title, forKey: .title)
        try c.encode(idis, forKey: .idis)
        try c.encode(quoteTags, forKey: .quoteTags)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(actor, forKey: .actor)
    }

    public init(kind: Kind, date: Date = Date(), project: String? = nil, subproject: String? = nil, title: String,
                idis: [IDI] = [], quoteTags: [String] = [], archived: String? = nil, source: String? = nil) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.project = project
        self.subproject = subproject
        self.title = title
        self.idis = idis
        self.quoteTags = quoteTags
        self.archived = archived
        self.source = source
        self.actor = HistoryEvent.defaultActor
    }
}

public struct History: Codable, Sendable {
    public var events: [HistoryEvent] = []

    public init(events: [HistoryEvent] = []) {
        self.events = events
    }

    public static func url(forLibraryAt lib: URL) -> URL {
        lib.deletingLastPathComponent().appendingPathComponent("refware-history.json")
    }

    public static func exportsDirectory(forLibraryAt lib: URL) -> URL {
        lib.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
    }

    /// Loads the history. An unreadable file is never overwritten: it's set aside as
    /// `refware-history.unreadable-<date>.json` and a fresh history notes where it went.
    public static func load(forLibraryAt lib: URL) -> History {
        let file = url(forLibraryAt: lib)
        guard let data = try? Data(contentsOf: file) else { return History() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let h = try? d.decode(History.self, from: data) { return h }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let aside = file.deletingLastPathComponent().appendingPathComponent("refware-history.unreadable-\(f.string(from: Date())).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        FileHandle.standardError.write(Data("warning: the history file couldn't be read; it was kept as \(aside.lastPathComponent) and a new history started\n".utf8))
        var fresh = History()
        fresh.events.append(HistoryEvent(kind: .other, title: "History restarted — the previous file was unreadable and is kept as \(aside.lastPathComponent)"))
        try? fresh.save(forLibraryAt: lib)
        return fresh
    }

    public func save(forLibraryAt lib: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: Self.url(forLibraryAt: lib), options: .atomic)
    }

    /// Appends one event (re-reading the file first, so concurrent writers don't clobber each other).
    public static func record(_ event: HistoryEvent, forLibraryAt lib: URL) {
        var h = load(forLibraryAt: lib)
        h.events.append(event)
        try? h.save(forLibraryAt: lib)
    }

    /// Copies an exported/imported file into `Exports/` as `YYYY-MM-DD_HHMM_<project>_<name>`; returns its relative path.
    public static func archive(_ data: Data, named name: String, project: String?, forLibraryAt lib: URL, date: Date = Date()) -> String? {
        let dir = exportsDirectory(forLibraryAt: lib)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let file = "\(f.string(from: date))_\(project.map { "\($0)_" } ?? "")\(safe)"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
        return "Exports/\(file)"
    }

    public func last(_ kind: HistoryEvent.Kind, project: String? = nil) -> HistoryEvent? {
        events.filter { $0.kind == kind && (project == nil || $0.project == project) }.max { $0.date < $1.date }
    }

    public func events(_ kind: HistoryEvent.Kind, project: String? = nil) -> [HistoryEvent] {
        events.filter { $0.kind == kind && (project == nil || $0.project == project) }.sorted { $0.date > $1.date }
    }
}

/// The library questions the Stats / Status panels ask.
public struct LibraryInsights: Sendable {
    public var library: Library
    public var history: History
    /// Limit to a project (and optionally a sub-project); nil = whole library.
    public var project: String?
    public var subproject: String?

    public init(library: Library, history: History, project: String? = nil, subproject: String? = nil) {
        self.library = library
        self.history = history
        self.project = project
        self.subproject = subproject
    }

    /// Records in scope: tagged with the project (and sub-project), or listed in the project's index.
    public var references: [Reference] {
        let listed = Set(project.flatMap { library.projects[$0]?.references } ?? [])
        return library.references.values.filter { r in
            guard let project else { return true }
            let tag = r.projects.first { $0.project == project }
            guard tag != nil || listed.contains(r.id) else { return false }
            return subproject == nil || (tag?.subprojects.contains(subproject!) ?? false)
        }.sorted { $0.id < $1.id }
    }

    var indexes: [ProjectCitationIndex] {
        project.flatMap { library.projects[$0] }.map { [$0] } ?? Array(library.projects.values)
    }

    /// Verified quotations still found in their record's current PDF, filtered to the current scope.
    public var verifiedQuotes: [QuoteRecord] {
        let ids = Set(references.map(\.id))
        return indexes.flatMap(\.quotes).filter { $0.isCurrent && ids.contains($0.reference) }
    }

    /// Quotes whose PDF changed and no longer contains them (kept on record; `refware recheck`).
    public var staleQuotes: [QuoteRecord] {
        let ids = Set(references.map(\.id))
        return indexes.flatMap(\.quotes).filter { $0.staleSince != nil && ids.contains($0.reference) }
    }

    /// Claims in scope.
    public var claims: [Claim] { indexes.flatMap(\.claims).filter { subproject == nil || $0.subproject == subproject } }
    public var supportedClaims: [Claim] { claims.filter { $0.status == .supported } }
    /// Claims with an open flag ("questioned"), whatever their status.
    public var questionedClaims: [Claim] { claims.filter(\.isQuestioned) }
    /// Claims with an AI proposal awaiting a person.
    public var claimsWithProposals: [Claim] { claims.filter { !$0.pendingProposals.isEmpty } }

    /// Quote tags attached to a claim (the "verified claims").
    public var claimQuoteTags: Set<String> {
        Set(indexes.flatMap(\.claims).filter { subproject == nil || $0.subproject == subproject }.flatMap(\.quotes))
    }

    public var withPDF: [Reference] { references.filter { $0.fileName != nil } }
    public var unverifiedPDFs: [Reference] { withPDF.filter { $0.provenance?.verified != true } }

    /// Verified-metadata PDFs with no verified claim (IDI-Q) attached.
    public var verifiedPDFsWithoutClaims: [Reference] {
        let backed = Set(verifiedQuotes.filter { claimQuoteTags.contains($0.tag) }.map(\.reference))
        return withPDF.filter { $0.provenance?.verified == true && !backed.contains($0.id) }
    }

    public func hasVerifiedClaims(_ id: IDI) -> Bool {
        verifiedQuotes.contains { $0.reference == id && claimQuoteTags.contains($0.tag) }
    }

    var exportedQuoteTags: Set<String> { Set(history.events(.claimsExport, project: project).flatMap(\.quoteTags)) }
    var exportedIDIs: Set<IDI> { Set(history.events(.claimsExport, project: project).flatMap(\.idis)) }

    public func claimsExported(_ id: IDI) -> Bool { exportedIDIs.contains(id) }

    /// Verified quotes never included in an exported claims list.
    public var quotesNotExported: [QuoteRecord] { verifiedQuotes.filter { !exportedQuoteTags.contains($0.tag) } }

    public enum BuildScope: String, CaseIterable, Sendable { case ever = "Ever", last = "Last build" }

    var builds: [HistoryEvent] { history.events(.build, project: project) }

    public func hitIDIs(_ scope: BuildScope) -> Set<IDI> {
        switch scope {
        case .ever: Set(builds.flatMap(\.idis).map(library.canonical))
        case .last: Set((builds.first?.idis ?? []).map(library.canonical))
        }
    }

    public func hitQuoteTags(_ scope: BuildScope) -> Set<String> {
        switch scope {
        case .ever: Set(builds.flatMap(\.quoteTags))
        case .last: Set(builds.first?.quoteTags ?? [])
        }
    }

    /// Records never cited in a C/R build (ever, or in the most recent one).
    public func notHit(_ scope: BuildScope) -> [Reference] {
        let hits = hitIDIs(scope)
        return references.filter { !hits.contains($0.id) }
    }

    public func quotesNotHit(_ scope: BuildScope) -> [QuoteRecord] {
        let hits = hitQuoteTags(scope)
        return verifiedQuotes.filter { !hits.contains($0.tag) }
    }

    /// Most recent C/R build date for a record.
    public func lastBuild(of id: IDI) -> Date? {
        builds.first { $0.idis.map(library.canonical).contains(id) }?.date
    }

    public var subprojectCount: Int {
        indexes.reduce(0) { $0 + $1.subprojects.count }
    }
}

extension History {
    /// Logs a C/R build: every IDI and IDI-Q cited ("hits"), with the generated
    /// reference list archived under Exports/.
    public static func recordBuild(document: String, project: String?, cited: [IDI], quoteTags: [String], library: Library, libraryURL: URL) {
        let refs = cited.compactMap { library[$0] }
        let list = CitationFormatter(references: refs).referenceList(refs)
        let base = URL(fileURLWithPath: document).deletingPathExtension().lastPathComponent
        let archived = list.isEmpty ? nil : archive(Data((list + "\n").utf8), named: "\(base)_references.txt", project: project, forLibraryAt: libraryURL)
        record(HistoryEvent(kind: .build, project: project, title: URL(fileURLWithPath: document).lastPathComponent,
                            idis: cited.map(library.canonical), quoteTags: quoteTags, archived: archived, source: document), forLibraryAt: libraryURL)
        if archived != nil {
            record(HistoryEvent(kind: .referenceExport, project: project, title: "Reference list — \(URL(fileURLWithPath: document).lastPathComponent)",
                                idis: cited.map(library.canonical), archived: archived, source: document), forLibraryAt: libraryURL)
        }
    }
}

extension History {
    /// Logs a capture that saved a document.
    public static func recordCapture(_ r: CaptureResult, url: String, project: String?, libraryURL: URL) {
        guard let doc = r.document, doc != .alreadyAttached, let file = r.reference.fileName else { return }
        record(HistoryEvent(kind: .pdfAdded, project: project, title: "PDFs/\(file) — \(doc.rawValue)", idis: [r.reference.id], source: url),
               forLibraryAt: libraryURL)
    }
}
