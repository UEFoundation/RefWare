import Foundation

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case duplicateIDI(IDI)
    case duplicateDOI(String, existing: IDI)
    case duplicateArXiv(String, existing: IDI)
    case unknownIDI(IDI)
    case unsupportedSchemaVersion(Int)
    case frozen(String)
    case pdfInUse(IDI, file: String)
    case conflict

    public var description: String {
        switch self {
        case .duplicateIDI(let id): "IDI \(id) already exists in the library"
        case .duplicateDOI(let doi, let existing): "DOI \(doi) is already stored as IDI \(existing)"
        case .duplicateArXiv(let id, let existing): "arXiv \(id) is already stored as IDI \(existing)"
        case .unknownIDI(let id): "IDI \(id) is not in the library"
        case .unsupportedSchemaVersion(let v): "library schema version \(v) is newer than this build supports"
        case .pdfInUse(let id, let file): "that PDF (\(file)) is already IDI \(id)'s — two records shouldn't share one document; merge them instead (refware merge / Merge with…)"
        case .conflict: "the library changed on disk while this command was running (the app or another agent saved); nothing was written — run the command again"
        case .frozen(let who): "the library is frozen (\(who)) — unfreeze it first (`refware unfreeze`, or untick Freeze in the window)"
        }
    }
}

/// The reference database. Persisted as one human-readable JSON file with
/// sorted keys so it diffs cleanly and syncs predictably through iCloud Drive.
public struct Library: Codable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public internal(set) var references: [IDI: Reference]
    public var projects: [String: ProjectCitationIndex]
    /// Merged-away IDIs → the record they were merged into. A draft still
    /// tagged `[IDI 57]` keeps resolving after 57 is merged into 37.
    public internal(set) var aliases: [IDI: IDI]
    /// Highest IDI ever issued. Numbers are never reused, even after a merge.
    public internal(set) var lastIssuedIDI: IDI
    /// Same-title groups a person has marked as different works.
    public internal(set) var distinctWorks: [[IDI]]
    /// Set when the library is locked as a read-only snapshot (e.g. as submitted).
    public var frozen: Freeze?
    /// Quote tags renumbered by merges (`IDI 57-Q1` → `IDI 37-Q2`), so old tags keep resolving.
    public internal(set) var quoteAliases: [String: String] = [:]
    /// Deleted records: their numbers are retired, and tags using them get a clear error.
    public internal(set) var deleted: [IDI: Deletion] = [:]
    /// Fingerprint of the file this library was loaded from (not saved). A save refuses to
    /// overwrite a file that changed since — someone else's edits would be lost.
    var diskFingerprint: String?

    public func canonicalQuoteTag(_ tag: String) -> String {
        var t = tag, hops = 0
        while let next = quoteAliases[t], hops < 32 { t = next; hops += 1 }
        return t
    }

    public init() {
        schemaVersion = Self.schemaVersion
        references = [:]
        projects = [:]
        aliases = [:]
        lastIssuedIDI = 0
        distinctWorks = []
        frozen = nil
    }

    public var nextIDI: IDI { max(lastIssuedIDI, references.keys.max() ?? 0, aliases.keys.max() ?? 0, deleted.keys.max() ?? 0) + 1 }

    /// Follows merge aliases: `library[57]` is IDI 37's record once 57 is merged into 37.
    public subscript(id: IDI) -> Reference? { references[canonical(id)] }

    public func canonical(_ id: IDI) -> IDI {
        var current = id, hops = 0
        while references[current] == nil, let next = aliases[current], hops < 32 { current = next; hops += 1 }
        return current
    }

    public func reference(forDOI doi: String) -> Reference? {
        return references.values.first { $0.doi.map { DOI.same($0, doi) } ?? false }
    }

    public func reference(forArXiv id: String) -> Reference? {
        references.values.first { $0.arxiv == id }
    }

    /// Matches arXiv links by identifier (any version/mirror) and other links by canonical URL.
    public func reference(forURL url: String) -> Reference? {
        if let id = ArXiv.id(in: url) { return reference(forArXiv: id) }
        if let doi = DOI.find(in: url), let ref = reference(forDOI: doi) { return ref }
        let key = CanonicalURL.key(url)
        return references.values.sorted { $0.id < $1.id }.first { $0.url.map(CanonicalURL.key) == key }
    }

    /// Exact title match after normalizing case, punctuation and markup.
    public func references(titled title: String) -> [Reference] {
        let target = TextCleanup.comparable(title)
        return references.values.filter { TextCleanup.comparable($0.title) == target }.sorted { $0.id < $1.id }
    }

    /// Inserts a new reference. Rejects duplicate IDIs and duplicate DOIs so
    /// one paper can never be cited under two indices.
    public mutating func add(_ reference: Reference) throws {
        if references[reference.id] != nil { throw LibraryError.duplicateIDI(reference.id) }
        if let doi = reference.doi, let existing = self.reference(forDOI: doi) {
            throw LibraryError.duplicateDOI(doi, existing: existing.id)
        }
        if let arxiv = reference.arxiv, let existing = self.reference(forArXiv: arxiv) {
            throw LibraryError.duplicateArXiv(arxiv, existing: existing.id)
        }
        var reference = reference
        // Whole seconds: the JSON date format drops fractions.
        if reference.added == nil { reference.added = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
        references[reference.id] = reference
        lastIssuedIDI = max(lastIssuedIDI, reference.id)
    }

    public mutating func update(_ reference: Reference) throws {
        guard references[reference.id] != nil else { throw LibraryError.unknownIDI(reference.id) }
        if let doi = reference.doi, let existing = self.reference(forDOI: doi), existing.id != reference.id {
            throw LibraryError.duplicateDOI(doi, existing: existing.id)
        }
        var reference = reference
        if let old = references[reference.id] {
            let detailsChanged = old.title != reference.title || old.year != reference.year || old.authors != reference.authors
            // A person's check was of the old details; it doesn't carry over to new ones
            // (unless the caller is setting a new check along with them).
            if detailsChanged, let p = reference.provenance, p.confirmedBy != nil,
               p.confirmedBy == old.provenance?.confirmedBy, p.confirmedOn == old.provenance?.confirmedOn {
                reference.provenance?.confirmedBy = nil
                reference.provenance?.confirmedOn = nil
            }
            // "Different works" was judged on the old details or PDF; let the duplicate check look again.
            if detailsChanged || old.fileName != reference.fileName || old.pdfSHA256 != reference.pdfSHA256 {
                distinctWorks.removeAll { $0.contains(reference.id) }
            }
        }
        references[reference.id] = reference
    }

    // MARK: Persistence

    private enum CodingKeys: String, CodingKey { case schemaVersion, references, projects, aliases, lastIssuedIDI, distinctWorks, frozen, quoteAliases, deleted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let list = try c.decode([Reference].self, forKey: .references)
        references = [:]
        for ref in list {
            guard references[ref.id] == nil else { throw LibraryError.duplicateIDI(ref.id) }
            references[ref.id] = ref
        }
        projects = try c.decodeIfPresent([String: ProjectCitationIndex].self, forKey: .projects) ?? [:]
        let raw = try c.decodeIfPresent([String: IDI].self, forKey: .aliases) ?? [:]
        aliases = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        lastIssuedIDI = max(try c.decodeIfPresent(IDI.self, forKey: .lastIssuedIDI) ?? 0, references.keys.max() ?? 0)
        distinctWorks = try c.decodeIfPresent([[IDI]].self, forKey: .distinctWorks) ?? []
        frozen = try c.decodeIfPresent(Freeze.self, forKey: .frozen)
        quoteAliases = try c.decodeIfPresent([String: String].self, forKey: .quoteAliases) ?? [:]
        let dels = try c.decodeIfPresent([String: Deletion].self, forKey: .deleted) ?? [:]
        deleted = Dictionary(uniqueKeysWithValues: dels.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// References are written as an array ordered by IDI (an `Int`-keyed
    /// dictionary would encode as an unreadable flat key/value array).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(references.values.sorted { $0.id < $1.id }, forKey: .references)
        try c.encode(projects, forKey: .projects)
        if !aliases.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: aliases.map { (String($0.key), $0.value) }), forKey: .aliases)
        }
        try c.encode(lastIssuedIDI, forKey: .lastIssuedIDI)
        if !distinctWorks.isEmpty { try c.encode(distinctWorks, forKey: .distinctWorks) }
        try c.encodeIfPresent(frozen, forKey: .frozen)
        if !quoteAliases.isEmpty { try c.encode(quoteAliases, forKey: .quoteAliases) }
        if !deleted.isEmpty { try c.encode(Dictionary(uniqueKeysWithValues: deleted.map { (String($0.key), $0.value) }), forKey: .deleted) }
    }

    public static func load(from url: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let data = try Data(contentsOf: url)
        var library = try decoder.decode(Library.self, from: data)
        library.diskFingerprint = SHA256Hex.of(data)
        if library.schemaVersion > Self.schemaVersion {
            throw LibraryError.unsupportedSchemaVersion(library.schemaVersion)
        }
        return library
    }

    /// Saves the library, under a file lock. Refused when:
    /// - the library on disk is frozen (checked on disk every time — never trusts memory), or
    /// - the file changed since this copy was loaded (the app or another agent saved meanwhile);
    ///   nothing is written, so their changes survive — re-run the command.
    public mutating func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        if let data = try? Data(contentsOf: url) {
            if let onDisk = try? Self.decoder.decode(Library.self, from: data), let f = onDisk.frozen {
                throw LibraryError.frozen("since \(f.on.formatted(date: .abbreviated, time: .omitted)) by \(f.by)")
            }
            if let mine = diskFingerprint, SHA256Hex.of(data) != mine { throw LibraryError.conflict }
        }
        let out = try Self.encoder.encode(self)
        try out.write(to: url, options: .atomic)
        diskFingerprint = SHA256Hex.of(out)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// A read-only lock on the library ("as submitted to the journal").
public struct Freeze: Codable, Hashable, Sendable {
    public var on: Date
    public var by: String
    public var note: String?

    public init(on: Date = Date(), by: String, note: String? = nil) {
        self.on = on
        self.by = by
        self.note = note
    }
}

extension Library {
    /// Locks the library on disk.
    public static func freeze(at url: URL, by person: String, note: String?) throws {
        var lib = try load(from: url)
        guard lib.frozen == nil else { return }
        lib.frozen = Freeze(by: person, note: note)
        try encoder.encode(lib).write(to: url, options: .atomic)
    }

    /// Unlocks the library on disk.
    public static func unfreeze(at url: URL) throws {
        var lib = try load(from: url)
        lib.frozen = nil
        try encoder.encode(lib).write(to: url, options: .atomic)
    }
}

/// Why and when a record was deleted (kept so tags using its number fail clearly).
public struct Deletion: Codable, Hashable, Sendable {
    public var on: Date
    public var by: String?
    public var reason: String?
    /// The citation it had, for the error message: "Ciftci et al., 2025".
    public var citation: String

    public init(on: Date = Date(), by: String?, reason: String?, citation: String) {
        self.on = Date(timeIntervalSince1970: on.timeIntervalSince1970.rounded(.down))
        self.by = by
        self.reason = reason
        self.citation = citation
    }
}
