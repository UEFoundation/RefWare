import Foundation

public struct MergeResult: Sendable {
    public var survivor: IDI
    public var retired: IDI
    /// Where the retired record's PDF went: attached to the survivor, or kept aside.
    public var pdfNote: String?
    /// Old → new quote tags (`IDI 57-Q1` → `IDI 37-Q3`).
    public var retaggedQuotes: [String: String]
}

extension Library {
    /// Merges record `from` into record `into`. The survivor keeps its own
    /// metadata; it gains the PDF (if it had none), any missing link, project
    /// tags, claim links, and quotes. `from` is retired: its number is never
    /// reissued and becomes an alias, so tags written against it still resolve.
    ///
    /// When both records have PDFs, the survivor's is kept and the other is moved
    /// to `PDFs/merged/` rather than deleted.
    @discardableResult
    public mutating func merge(_ fromID: IDI, into intoID: IDI, pdfDirectory: URL?, preferIncomingPDF: Bool = false,
                               takeIncomingDetails: Bool = false) throws -> MergeResult {
        let fromID = canonical(fromID), intoID = canonical(intoID)
        guard fromID != intoID else { throw LibraryError.unknownIDI(fromID) }
        guard var target = references[intoID] else { throw LibraryError.unknownIDI(intoID) }
        guard let source = references[fromID] else { throw LibraryError.unknownIDI(fromID) }

        // PDF.
        var pdfNote: String?
        if let dir = pdfDirectory, let incoming = source.fileName {
            let fm = FileManager.default
            let incomingURL = dir.appendingPathComponent(incoming)
            if target.fileName == nil || preferIncomingPDF {
                if let old = target.fileName {
                    try? fm.createDirectory(at: dir.appendingPathComponent("merged"), withIntermediateDirectories: true)
                    try? fm.moveItem(at: dir.appendingPathComponent(old), to: dir.appendingPathComponent("merged/\(old)"))
                }
                let name = Library.pdfFileName(for: target, keepingSnapshotFrom: incoming)
                if fm.fileExists(atPath: incomingURL.path) {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                    try fm.moveItem(at: incomingURL, to: dir.appendingPathComponent(name))
                }
                target.fileName = name
                pdfNote = "PDF attached as \(name)"
            } else if fm.fileExists(atPath: incomingURL.path) {
                try? fm.createDirectory(at: dir.appendingPathComponent("merged"), withIntermediateDirectories: true)
                try fm.moveItem(at: incomingURL, to: dir.appendingPathComponent("merged/\(incoming)"))
                pdfNote = "IDI \(intoID) already had a PDF; the other copy is in PDFs/merged/\(incoming)"
            }
        }

        if takeIncomingDetails {
            // Keep the survivor's number, projects and claims; take the other record's bibliographic details.
            // What the other record doesn't state is kept, not erased.
            if !source.authors.isEmpty { target.authors = source.authors }
            target.year = source.year ?? target.year
            target.title = source.title
            target.publication = source.publication ?? target.publication
            if source.indexing.volume != nil || source.indexing.pages != nil || source.indexing.issue != nil { target.indexing = source.indexing }
            target.doi = source.doi ?? target.doi
            target.url = source.url ?? target.url
            target.arxiv = source.arxiv ?? target.arxiv
            if source.publicationType != .unclassified { target.publicationType = source.publicationType }
            target.provenance = source.provenance
            // Rename the PDF to match the new author/year.
            if let dir = pdfDirectory, let f = target.fileName {
                let name = Library.pdfFileName(for: target, keepingSnapshotFrom: f)
                if name != f, (try? FileManager.default.moveItem(at: dir.appendingPathComponent(f), to: dir.appendingPathComponent(name))) != nil {
                    target.fileName = name
                }
            }
        }
        // Fill gaps, never overwrite.
        if target.url == nil { target.url = source.url }
        if target.arxiv == nil { target.arxiv = source.arxiv } // the source is retired below, so no collision
        for p in source.projects where !target.projects.contains(where: { $0.project == p.project }) { target.projects.append(p) }

        // Retire the source before updating the target (its DOI/arXiv must not collide).
        references[fromID] = nil
        references[intoID] = target
        aliases[fromID] = intoID
        for (k, v) in aliases where v == fromID { aliases[k] = intoID }
        lastIssuedIDI = max(lastIssuedIDI, fromID)

        // Projects: reference lists, claim sources, quotes (renumbered on the survivor).
        var retagged: [String: String] = [:]
        for key in projects.keys {
            var index = projects[key]!
            index.references = index.references.map { $0 == fromID ? intoID : $0 }
            var seen = Set<IDI>()
            index.references = index.references.filter { seen.insert($0).inserted }
            for q in index.quotes.indices where index.quotes[q].reference == fromID {
                let oldTag = index.quotes[q].tag
                let label = index.nextQuoteLabel(for: intoID)
                index.quotes[q].reference = intoID
                index.quotes[q].label = label
                retagged[oldTag] = index.quotes[q].tag
            }
            for c in index.claims.indices {
                for s in index.claims[c].sources.indices where index.claims[c].sources[s].reference == fromID {
                    index.claims[c].sources[s].reference = intoID
                }
                index.claims[c].quotes = index.claims[c].quotes.map { retagged[$0] ?? $0 }
            }
            projects[key] = index
        }
        for (old, new) in retagged { quoteAliases[old] = new }
        if let dir = pdfDirectory { revalidateQuotes(of: intoID, pdfDirectory: dir) }
        return MergeResult(survivor: intoID, retired: fromID, pdfNote: pdfNote, retaggedQuotes: retagged)
    }

    /// Replaces a placeholder's metadata with a registry record, keeping its IDI,
    /// PDF, and project/claim links.
    public mutating func adopt(_ m: ResolvedMetadata, for id: IDI, verified: Bool, pdfDirectory: URL?) throws {
        guard let old = references[canonical(id)] else { throw LibraryError.unknownIDI(id) }
        var ref = m.makeReference(id: old.id, verified: verified, projects: old.projects, fileName: old.fileName)
        if ref.url == nil { ref.url = old.url }
        // A suggestion replaces what it states; it never erases what it doesn't. (A web page
        // with no byline must not wipe the record's author.)
        if ref.authors.isEmpty { ref.authors = old.authors }
        if ref.year == nil { ref.year = old.year }
        if ref.publication == nil { ref.publication = old.publication }
        if ref.doi == nil, let d = old.doi { ref.doi = d }
        if ref.publicationType == .unclassified { ref.publicationType = old.publicationType }
        if ref.indexing.volume == nil && ref.indexing.pages == nil && ref.indexing.issue == nil { ref.indexing = old.indexing }
        // Same PDF, same fingerprint: its quotes stay bound to it.
        ref.pdfSHA256 = old.pdfSHA256
        ref.added = old.added
        try update(ref)
        // Rename the PDF to match the new author/year.
        if let dir = pdfDirectory, let file = old.fileName {
            let name = Library.pdfFileName(for: ref, keepingSnapshotFrom: file)
            if name != file, (try? FileManager.default.moveItem(at: dir.appendingPathComponent(file), to: dir.appendingPathComponent(name))) != nil {
                ref.fileName = name
                try update(ref)
            }
        }
    }

    /// Records that look like duplicates of each other: same normalized title,
    /// minus pairs a person has marked as distinct works.
    public func likelyDuplicates() -> [[IDI]] {
        Dictionary(grouping: references.values) { TextCleanup.comparable($0.title) }
            .values.filter { $0.count > 1 }.map { $0.map(\.id).sorted() }
            .filter { !distinctWorks.contains($0) }
            .sorted { $0[0] < $1[0] }
    }

    /// "These are different works" — e.g. Anthropic's 2023 post and 2026 document, same title.
    public mutating func markDistinct(_ ids: [IDI]) {
        let key = ids.sorted()
        if !distinctWorks.contains(key) { distinctWorks.append(key) }
    }

    /// A person has checked this record's metadata against the source itself.
    public mutating func confirm(_ id: IDI, by person: String, on date: Date = Date()) throws {
        guard var r = self[id] else { throw LibraryError.unknownIDI(id) }
        var p = r.provenance ?? Provenance(source: .manual, key: r.url ?? r.title, retrieved: date, verified: false)
        p.verified = true
        p.confirmedBy = person
        p.confirmedOn = date
        r.provenance = p
        try update(r)
    }

    /// Removes a hand check. Registry-sourced records stay verified by the registry; others become unverified.
    public mutating func unconfirm(_ id: IDI) throws {
        guard var r = self[id], var p = r.provenance else { throw LibraryError.unknownIDI(id) }
        p.confirmedBy = nil
        p.confirmedOn = nil
        p.verified = [.crossref, .datacite, .webMetadata].contains(p.source)
        r.provenance = p
        try update(r)
    }

    /// Records needing a human look: placeholders (no authors or year), and
    /// unverified records — the review window's worklist.
    public func needsReview() -> [Reference] {
        references.values.filter { r in
            r.provenance?.verified != true || r.authors.isEmpty || r.year == nil
        }.sorted { $0.id < $1.id }
    }
}

extension Library {
    /// Puts a PDF on a record, named `IDI-0028_Foxit_2026.pdf`. A PDF the record
    /// already had is parked in PDFs/merged/ — never deleted. `move` is for files
    /// already in the PDFs folder (unattached ones).
    @discardableResult
    public mutating func attachPDF(from src: URL, to id: IDI, pdfDirectory dir: URL, move: Bool = false) throws -> (name: String, replaced: String?) {
        guard var ref = self[id] else { throw LibraryError.unknownIDI(id) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let srcSHA = Library.sha256(of: src)
        if let sha = srcSHA, let other = owner(ofPDFWithSHA: sha, excluding: id, pdfDirectory: dir) {
            throw LibraryError.pdfInUse(other, file: self[other]?.fileName ?? src.lastPathComponent)
        }
        let name = Library.pdfFileName(for: ref, keepingSnapshotFrom: src.lastPathComponent)
        var replaced: String?
        if let old = ref.fileName, fm.fileExists(atPath: dir.appendingPathComponent(old).path), src.lastPathComponent != old {
            try? fm.createDirectory(at: dir.appendingPathComponent("merged"), withIntermediateDirectories: true)
            let parked = dir.appendingPathComponent("merged/\(old)")
            try? fm.removeItem(at: parked)
            try fm.moveItem(at: dir.appendingPathComponent(old), to: parked)
            replaced = old
        }
        let dest = dir.appendingPathComponent(name)
        if dest.standardizedFileURL != src.standardizedFileURL {
            try? fm.removeItem(at: dest)
            if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
        }
        ref.fileName = name
        ref.pdfSHA256 = srcSHA
        try update(ref)
        revalidateQuotes(of: id, pdfDirectory: dir)
        return (name, replaced)
    }

    /// PDFs in the library folder that no record points to.
    public func unattachedPDFs(in dir: URL) -> [String] {
        let used = Set(references.values.compactMap(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".pdf") && !used.contains($0) }.sorted()
    }
}

public struct DeletionResult: Sendable {
    public var id: IDI
    /// Claims that lost this source.
    public var affectedClaims: [String]
    /// Claims marked Dropped because this was their only source.
    public var droppedClaims: [String]
    public var removedQuotes: [String]
    /// Where the PDF went (PDFs/deleted/…), if it had one.
    public var parkedPDF: String?
}

extension Library {
    /// Claims (by project) citing a record, and whether it's their only source.
    public func claimsCiting(_ id: IDI) -> [(project: String, claim: Claim, onlySource: Bool)] {
        projects.flatMap { name, index in
            index.claims.filter { $0.references.contains(id) }.map { (name, $0, $0.references == [id]) }
        }
    }

    /// Deletes a record. Its number is retired (never reissued; tags using it get a clear error),
    /// its quotes are removed, claims lose it as a source — and with `dropClaims`, claims that
    /// cited only this record are marked Dropped with the reason. Its PDF is moved to
    /// PDFs/deleted/, never erased.
    @discardableResult
    public mutating func delete(_ id: IDI, reason: String?, by person: String?, dropClaims: Bool, pdfDirectory: URL?) throws -> DeletionResult {
        guard let ref = references[id] else { throw LibraryError.unknownIDI(id) }
        var result = DeletionResult(id: id, affectedClaims: [], droppedClaims: [], removedQuotes: [], parkedPDF: nil)

        if let dir = pdfDirectory, let f = ref.fileName, FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
            let bin = dir.appendingPathComponent("deleted")
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: bin.appendingPathComponent(f))
            try FileManager.default.moveItem(at: dir.appendingPathComponent(f), to: bin.appendingPathComponent(f))
            result.parkedPDF = "PDFs/deleted/\(f)"
        }

        let citation = CitationFormatter(references: [ref]).inlineBody(ref)
        for key in projects.keys {
            var index = projects[key]!
            let tags = Set(index.quotes.filter { $0.reference == id }.map(\.tag))
            result.removedQuotes += tags.sorted()
            index.quotes.removeAll { $0.reference == id }
            index.references.removeAll { $0 == id }
            for c in index.claims.indices where index.claims[c].references.contains(id) {
                let only = index.claims[c].references == [id]
                result.affectedClaims.append(index.claims[c].id)
                for s in index.claims[c].sources.indices where index.claims[c].sources[s].reference == id {
                    index.claims[c].sources[s].reference = nil
                    index.claims[c].sources[s].title = "\(citation) — deleted from the library\(reason.map { " (\($0))" } ?? "")"
                }
                index.claims[c].quotes.removeAll { tags.contains($0) }
                if dropClaims && only {
                    index.claims[c].status = .dropped
                    let note = "Source deleted (\(citation))\(reason.map { ": \($0)" } ?? "")."
                    index.claims[c].note = index.claims[c].note.map { $0 + "\n\n" + note } ?? note
                    index.claims[c].reviewedBy = person
                    index.claims[c].reviewedOn = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                    result.droppedClaims.append(index.claims[c].id)
                }
            }
            projects[key] = index
        }
        references[id] = nil
        for (k, v) in aliases where v == id { aliases[k] = nil }   // merged-into-this numbers now fail clearly too
        deleted[id] = Deletion(by: person, reason: reason, citation: citation)
        lastIssuedIDI = max(lastIssuedIDI, id)
        return result
    }
}
