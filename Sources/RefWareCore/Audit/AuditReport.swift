import Foundation

extension ManuscriptAudit {
    /// Adds every entry found by its own DOI/arXiv ID to the library under
    /// `project` (reusing existing IDIs), and records the IDI on the audit.
    /// Title-only matches are not imported: they need a confirmed DOI first.
    /// Two titles name the same work: equal, one a prefix of the other (subtitles), or most of
    /// the shorter one's words shared.
    static func sameWork(_ a: String, _ b: String) -> Bool {
        let x = TextCleanup.comparable(a), y = TextCleanup.comparable(b)
        if x.isEmpty || y.isEmpty { return false }
        if x == y || x.hasPrefix(y) || y.hasPrefix(x) { return true }
        let wx = Set(x.split(separator: " ").filter { $0.count > 2 }), wy = Set(y.split(separator: " ").filter { $0.count > 2 })
        guard !wx.isEmpty, !wy.isEmpty else { return false }
        return Double(wx.intersection(wy).count) / Double(min(wx.count, wy.count)) >= 0.6
    }

    public mutating func importVerified(into library: inout Library, project: String, includeUnverified: Bool = false, subproject: String? = nil) -> (added: [IDI], reused: [IDI]) {
        let tag = ProjectTag(project: project, subprojects: subproject.map { [$0] } ?? [])
        var added: [IDI] = [], reused: [IDI] = []
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        for i in entries.indices {
            // A DOI that resolves to a different work (another title altogether) is a wrong DOI,
            // not a verification: never import that registry record.
            var doiMismatch = false
            if entries[i].match == .doi, let m = entries[i].record, let t = entries[i].entry.title, !Self.sameWork(t, m.title) {
                doiMismatch = true
                importWarnings.append("\(entries[i].entry.doi.map { "DOI \($0)" } ?? "Its identifier") belongs to a different work (“\(m.title)”), not “\(t)” — added as written without it; find the right identifier")
            }
            guard entries[i].match == .doi, let m = entries[i].record, !doiMismatch else {
                guard includeUnverified, entries[i].importedAs == nil else { continue }
                // Unverified: the web page's cleaned record, or the entry exactly as written.
                var e = entries[i].entry
                if doiMismatch { e.doi = nil; if e.url?.contains("doi.org") == true { e.url = nil } }
                // Already held: same link or DOI (the one found by title included), or same title, year and first author.
                let existing = e.url.flatMap(library.reference(forURL:)) ?? e.doi.flatMap(library.reference(forDOI:))
                    ?? (doiMismatch ? nil : entries[i].record?.doi.flatMap(library.reference(forDOI:)))
                    ?? e.title.flatMap { t in library.references.values.first { r in
                        r.year == e.year && TextCleanup.comparable(r.title) == TextCleanup.comparable(t)
                            && (r.authors.first.map { a in e.authors.first.map { ManuscriptAuditor.sameName(a.family, $0.family) } ?? false } ?? false)
                    } }
                if let ref = existing {
                    entries[i].importedAs = ref.id
                    reused.append(ref.id)
                } else {
                    var ref: Reference
                    // A web page's own metadata is used only when it describes the same work ("Home" by a
                    // site's CMS account doesn't); otherwise the entry as written, with its link.
                    if !doiMismatch, entries[i].match == .title || (entries[i].match == .webPage && e.title.map { Self.sameWork($0, entries[i].record?.title ?? "") } ?? true),
                       let r = entries[i].record {
                        // Found by title (or web page) only: the registry's details, unverified until a person confirms.
                        ref = Self.rebuilt(e, from: r, match: entries[i].match).makeReference(id: library.nextIDI, verified: false, projects: [tag])
                    } else {
                        ref = Self.reference(from: e, id: library.nextIDI)
                        ref.projects = [tag]
                    }
                    guard (try? library.add(ref)) != nil else { continue }
                    entries[i].importedAs = ref.id
                    added.append(ref.id)
                }
                index.addReference(entries[i].importedAs!)
                continue
            }
            let m2 = Self.rebuilt(entries[i].entry, from: m, match: .doi) // restores accents the registry dropped
            let existing = m.doi.flatMap(library.reference(forDOI:)) ?? m.arxiv.flatMap(library.reference(forArXiv:))
            if var ref = existing {
                var changed = false
                if !ref.projects.contains(where: { $0.project == project }) {
                    ref.projects.append(tag)
                    changed = true
                } else if let s = subproject, let j = ref.projects.firstIndex(where: { $0.project == project }), !ref.projects[j].subprojects.contains(s) {
                    ref.projects[j].subprojects.append(s)
                    changed = true
                }
                // Same names, now with their diacritics: "Gulay" → "Gülay".
                let fold = { (a: [Author]) in a.map { $0.family.folding(options: .diacriticInsensitive, locale: nil) } }
                if ref.authors != m2.authors, fold(ref.authors) == fold(m2.authors), ref.authors.count == m2.authors.count {
                    ref.authors = m2.authors
                    changed = true
                }
                if changed { try? library.update(ref) }
                entries[i].importedAs = ref.id
                reused.append(ref.id)
            } else {
                let ref = m2.makeReference(id: library.nextIDI, verified: true, projects: [tag])
                guard (try? library.add(ref)) != nil else { continue }
                entries[i].importedAs = ref.id
                added.append(ref.id)
            }
            index.addReference(entries[i].importedAs!)
        }
        if let s = subproject, !index.subprojects.contains(s) { index.subprojects.append(s) }
        library.projects[project] = index
        return (added, reused)
    }

    /// The rebuilt reference list alone, one entry per paragraph. Entries that
    /// couldn't be checked are kept as written, prefixed with ❓.
    public func rebuiltReferenceList() -> String {
        let records: [(Int, Reference)] = entries.enumerated().compactMap { i, a in
            a.record.map { (i, Self.rebuilt(a.entry, from: $0, match: a.match).makeReference(id: i + 1, verified: a.match == .doi)) }
        }
        let formatter = CitationFormatter(references: records.map(\.1))
        let rebuilt = records.map { (key: formatter.referenceEntry($0.1), line: formatter.referenceEntry($0.1) + (entries[$0.0].match == .title ? " 🔎" : "")) }
        let missing = entries.filter { $0.record == nil }.map { (key: $0.entry.raw, line: "❓ " + $0.entry.raw) }
        return (rebuilt + missing).sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map(\.line).joined(separator: "\n\n") + "\n"
    }

    public func markdown(file: String, project: String, generated: Date = Date()) -> String {
        var out: [String] = []
        let date = ISO8601DateFormatter.string(from: generated, timeZone: .current, formatOptions: [.withFullDate])
        out.append("# Reference Audit — \(project)")
        out.append("")
        out.append("`\(file)` · checked by RefWare on \(date)")
        out.append("")

        let clean = entries.filter(\.isClean).count
        let minorOnly = entries.filter { $0.match == .doi && $0.errors.isEmpty && !$0.discrepancies.isEmpty }.count
        let withErrors = entries.filter { $0.record != nil && !$0.errors.isEmpty }.count
        let byTitle = entries.filter { $0.match == .title }.count
        let badDOI = entries.filter { $0.match == .doiNotRegistered }.count
        let notFound = entries.filter { $0.match == .notFound }.count
        let web = entries.filter { $0.match == .webPage }.count
        let dead = entries.filter { if case .deadLink = $0.match { return true }; return false }.count
        let linkOnly = entries.filter { $0.match == .linkOnly }.count
        let uncited = entries.filter(\.citedBy.isEmpty).count

        out.append("| | |")
        out.append("|---|---|")
        out.append("| Reference entries | \(entries.count) |")
        out.append("| ✅ Every checked field matches the DOI record | \(clean - minorOnly) |")
        out.append("| ✅ Matches, minor notes only (initials, abbreviations, missing issue…) | \(minorOnly) |")
        out.append("| ❌ Has errors against the source record | \(withErrors) |")
        out.append("| 🔎 No DOI in entry — matched by exact title + first author (confirm) | \(byTitle) |")
        out.append("| 🌐 No DOI — checked against the linked web page | \(web) |")
        out.append("| ⛔ DOI not registered (typo?) | \(badDOI) |")
        out.append("| 🔗 No DOI — link works (PDF), nothing to compare | \(linkOnly) |")
        out.append("| 💀 Link is dead (404/410) | \(dead) |")
        out.append("| ❓ Not found in Crossref/DataCite/arXiv | \(notFound) |")
        out.append("| In-text citations found | \(citationCount) |")
        out.append("| In-text citation problems | \(citationIssues.count) |")
        out.append("| Entries never cited in the text | \(uncited) |")
        out.append("")
        if referenceHeadingLine == nil {
            out.append("> ⚠️ No “References” heading was found, so no reference list was parsed.")
            out.append("")
        }
        out.append("""
        Compared against the registry record (Crossref, or DataCite for Zenodo/arXiv DOIs). Title and journal \
        comparisons ignore capitalization and punctuation, so sentence- vs title-case is not flagged. Line numbers \
        are paragraphs for .docx input. Registry records are occasionally wrong themselves — your DOI check is the final word.
        """)

        let lintCounts = Dictionary(grouping: entries.flatMap { $0.entry.lint.map { l in l.replacingOccurrences(of: #"\"[^"]*\""#, with: "\"…\"", options: .regularExpression) } }, by: { $0 })
            .mapValues(\.count).sorted { $0.value > $1.value }
        if !lintCounts.isEmpty {
            out.append("")
            out.append("## Formatting Patterns")
            out.append("")
            out.append("| Entries | Pattern |")
            out.append("|---|---|")
            for (pattern, n) in lintCounts { out.append("| \(n) | \(Self.cell(pattern)) |") }
            out.append("")
            out.append("Rebuilding the list from source records (below) fixes all of these at once.")
        }

        if !citationIssues.isEmpty {
            out.append("")
            out.append("## In-Text Citation Problems")
            out.append("")
            out.append("| Line | As written | Problem |")
            out.append("|---|---|---|")
            for issue in citationIssues {
                out.append("| \(issue.citation.line) | \(Self.cell(issue.citation.raw)) | \(Self.cell(issue.problem)) |")
            }
        }

        // Corrected entries are formatted together so a/b suffixes are consistent.
        let records: [(Int, Reference)] = entries.enumerated().compactMap { i, a in
            a.record.map { (i, Self.rebuilt(a.entry, from: $0, match: a.match).makeReference(id: i + 1, verified: a.match == .doi)) }
        }
        let formatter = CitationFormatter(references: records.map(\.1))

        out.append("")
        out.append("## Reference Entries")
        for (i, a) in entries.enumerated() {
            out.append("")
            let icon: String = {
                if a.isClean { return "✅" }
                switch a.match {
                case .doiNotRegistered where a.record == nil: return "⛔"
                case .deadLink: return "💀"
                case .notFound: return "❓"
                case .title: return "🔎"
                case .webPage: return a.errors.isEmpty ? "🌐" : "❌"
                case .linkOnly: return "🔗"
                default: return "❌"
                }
            }()
            out.append("### \(i + 1). \(icon) line \(a.entry.line)")
            out.append("")
            out.append("> \(a.entry.raw)")
            out.append("")
            switch a.match {
            case .doi: out.append("- Matched by DOI (\(a.record?.source == .datacite ? "DataCite" : a.record?.source == .crossref ? "Crossref" : "arXiv")).")
            case .title: out.append("- No DOI in your entry. Matched by exact title + first author — **confirm this is the work you read.**")
            case .doiNotRegistered: out.append("- ⛔ The DOI `\(a.entry.doi ?? "")` is not registered with Crossref or DataCite." + (a.record != nil ? " A work with this exact title was found:" : ""))
            case .notFound: out.append("- ❓ Not found. Check it by hand, or add its DOI.")
            case .webPage: out.append("- 🌐 No DOI. Compared with the metadata the linked page declares (title, and authors/year when the page states them).")
            case .linkOnly: out.append("- 🔗 The link works (a PDF), but declares no metadata — check author, year and title by hand.")
            case .deadLink(let code): out.append("- 💀 The link returns HTTP \(code) — find the current URL or an archived copy.")
            }
            let shown = a.discrepancies.sorted { $0.severity == .error && $1.severity != .error }
            if !shown.isEmpty {
                out.append("")
                out.append("| | Field | Yours | Source | Note |")
                out.append("|---|---|---|---|---|")
                for d in shown {
                    out.append("| \(d.severity == .error ? "❌" : "·") | \(d.field) | \(Self.cell(d.yours)) | \(Self.cell(d.source)) | \(Self.cell(d.note ?? "")) |")
                }
            }
            if let ref = records.first(where: { $0.0 == i })?.1 {
                out.append("")
                out.append("**From the source record:** \(formatter.referenceEntry(ref))")
            }
            out.append("")
            if a.citedBy.isEmpty {
                out.append("- ⚠️ Never cited in the text.")
            } else {
                let lines = Array(Set(a.citedBy.map(\.line))).sorted().map(String.init).joined(separator: ", ")
                out.append("- Cited on line\(a.citedBy.count == 1 ? "" : "s") \(lines).")
            }
            if let id = a.importedAs { out.append("- Library: `[IDI \(id)]`") }
        }

        out.append("")
        out.append("## Reference List Rebuilt From Source Records")
        out.append("")
        out.append("Alphabetized; up to 10 authors named, then et al. Entries RefWare couldn't find are kept as you wrote them and marked ❓ — check those by hand.")
        out.append("")
        let rebuilt = records.map(\.1).map { ref in
            (key: formatter.referenceEntry(ref), line: formatter.referenceEntry(ref) + (entries[ref.id - 1].match == .title ? " 🔎" : ""))
        }
        let missing = entries.filter { $0.record == nil }.map { (key: $0.entry.raw, line: "❓ " + $0.entry.raw) }
        for item in (rebuilt + missing).sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            out.append(item.line)
            out.append("")
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// A library reference built from a hand-written entry (unverified).
    static func reference(from e: ParsedEntry, id: IDI) -> Reference {
        let title = (e.title ?? e.raw).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return Reference(id: id, authors: e.authors, year: e.year, title: title,
                         publication: e.publication.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }.flatMap { $0.isEmpty ? nil : $0 },
                         indexing: e.indexing, doi: e.doi, url: e.url,
                         provenance: Provenance(source: .manual, key: e.raw, retrieved: Date(), verified: false))
    }

    /// The record to print for an entry. Registry data wins, except where the
    /// registry is known to be lossy: accents dropped from names, and web pages
    /// whose <title> wraps the real title in site chrome.
    static func rebuilt(_ e: ParsedEntry, from r: ResolvedMetadata, match: EntryAudit.Match) -> ResolvedMetadata {
        var m = r
        m.authors = r.authors.map { a in
            guard let mine = e.authors.first(where: { ManuscriptAuditor.sameName($0.family, a.family) }),
                  mine.family != a.family, mine.family.folding(options: .diacriticInsensitive, locale: nil) != mine.family else { return a }
            var fixed = a
            fixed.family = mine.family // "Gulay" → "Gülay"
            return fixed
        }
        if match == .webPage {
            if let t = e.title, TextCleanup.comparable(r.title).contains(TextCleanup.comparable(t)) { m.title = t }
            m.title = m.title.replacingOccurrences(of: #"\s+[|–—-]\s+[^|–—-]{2,40}$"#, with: "", options: .regularExpression)
            m.publication = e.publication
        }
        return m
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
