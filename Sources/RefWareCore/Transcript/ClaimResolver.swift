import Foundation

/// Links each claim source to an IDI.
///
/// - URLs go through the search cascade's URL step. Exact results are added to
///   the library (or matched to an existing entry by arXiv ID / DOI / URL).
/// - Titles without a link are matched only to references already in the
///   library by exact normalized title. Otherwise Crossref title candidates are
///   reported for a person to check; they are never linked automatically.
public struct ClaimResolver: Sendable {
    public var cascade: SearchCascade

    public init(cascade: SearchCascade) {
        self.cascade = cascade
    }

    public struct Report: Sendable {
        public var added: [IDI] = []
        public var linked = 0
        /// URL or title → reason.
        public var unresolved: [(source: String, reason: String)] = []
        public var titleCandidates: [(title: String, candidates: [ResolvedMetadata])] = []
    }

    public func resolve(project: String, in library: inout Library) async -> Report {
        var report = Report()
        guard var index = library.projects[project] else { return report }
        var urlCache: [String: IDI?] = [:]
        var titleCache: [String: IDI?] = [:]

        // URLs first, so titles can match references those URLs added.
        for pass in 0..<2 {
            for c in index.claims.indices {
                for s in index.claims[c].sources.indices where index.claims[c].sources[s].reference == nil {
                    let source = index.claims[c].sources[s]
                    var resolved: IDI?
                    if pass == 0, let url = source.url {
                        let key = CanonicalURL.key(url)
                        if let cached = urlCache[key] {
                            resolved = cached
                        } else {
                            resolved = await resolveURL(url, project: project, library: &library, report: &report)
                            urlCache[key] = resolved
                        }
                    } else if pass == 1, source.url == nil, let title = source.title {
                        let key = TextCleanup.comparable(title)
                        if let cached = titleCache[key] {
                            resolved = cached
                        } else {
                            resolved = await resolveTitle(title, library: library, report: &report)
                            titleCache[key] = resolved
                        }
                    }
                    if let id = resolved {
                        index.claims[c].sources[s].reference = id
                        index.addReference(id)
                        report.linked += 1
                    }
                }
            }
        }
        library.projects[project] = index
        return report
    }

    private func resolveURL(_ url: String, project: String, library: inout Library, report: inout Report) async -> IDI? {
        if let existing = library.reference(forURL: url) { return existing.id }
        let result = await cascade.run(SearchQuery(url: url))
        guard case .exact(let m, _) = result.outcome else {
            let reason = result.log.last?.note ?? "no metadata"
            report.unresolved.append((url, reason))
            return nil
        }
        if let doi = m.doi, let existing = library.reference(forDOI: doi) { return existing.id }
        if let arxiv = m.arxiv, let existing = library.reference(forArXiv: arxiv) { return existing.id }
        let ref = m.makeReference(id: library.nextIDI, verified: true, projects: [ProjectTag(project: project)])
        do {
            try library.add(ref)
            report.added.append(ref.id)
            return ref.id
        } catch {
            report.unresolved.append((url, String(describing: error)))
            return nil
        }
    }

    private func resolveTitle(_ title: String, library: Library, report: inout Report) async -> IDI? {
        if let match = library.references(titled: title).first { return match.id }
        let candidates = (try? await cascade.crossref.search(["query.title": title], rows: 3)) ?? []
        report.unresolved.append((title, "named without a link; no exact title match in the library"))
        report.titleCandidates.append((title, candidates))
        return nil
    }
}
