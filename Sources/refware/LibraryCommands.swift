import Foundation
import RefWareCore

func add(_ args: Arguments) async throws {
    let url = libraryURL(args)
    var library = try Library.load(from: url)
    let query = SearchQuery(
        doi: args.options["doi"], url: args.options["url"], title: args.options["title"],
        claim: args.options["claim"], outlet: args.options["outlet"], author: args.options["author"]
    )
    let tag = try projectTag(args)
    let type = try publicationType(args.options["type"])

    if let doi = query.doi, let existing = library.reference(forDOI: doi) {
        print("Already in library as IDI \(existing.id):\n\(describe(existing))")
        return
    }

    let mailto = args.options["mailto"] ?? ProcessInfo.processInfo.environment["REFWARE_MAILTO"]
    let cascade = SearchCascade(crossref: CrossrefClient(mailto: mailto))
    let result = await cascade.run(query)
    for entry in result.log { FileHandle.standardError.write(Data("  \(entry)\n".utf8)) }

    switch result.outcome {
    case .exact(let metadata, let step):
        if let doi = metadata.doi, let existing = library.reference(forDOI: doi) {
            print("Already in library as IDI \(existing.id):\n\(describe(existing))")
            return
        }
        var ref = metadata.makeReference(id: library.nextIDI, verified: true, projects: tag.map { [$0] } ?? [], fileName: args.options["file"])
        if let type { ref.publicationType = type }
        try library.add(ref)
        try library.save(to: url)
        print("Added (exact \(step.rawValue) match):\n\(describe(ref, in: library))")

    case .candidates(let found, let step):
        print("No exact match. \(found.count) candidate(s) from \(step.rawValue) search — nothing was added.")
        print("Confirm the right paper, then re-run with its DOI:\n")
        for (i, m) in found.enumerated() {
            let ref = m.makeReference(id: 0, verified: false)
            print("  \(i + 1). \(CitationFormatter(references: [ref]).referenceEntry(ref))")
            if let doi = m.doi { print("     refware add --doi \(doi)\n") }
        }

    case .notFound:
        throw UsageError(description: "no match found; nothing was added")
    }
}

func set(_ args: Arguments) throws {
    guard let raw = args.positionals.first, let id = Int(raw) else { throw UsageError(description: "set needs an IDI") }
    let url = libraryURL(args)
    var library = try Library.load(from: url)
    guard var ref = library[id] else { throw LibraryError.unknownIDI(id) }

    if let type = try publicationType(args.options["type"]) { ref.publicationType = type }
    if let file = args.options["file"] { ref.fileName = file }
    if let title = args.options["title"] { ref.title = title }
    if let org = args.options["org-author"] { ref.authors = [Author(family: org, isOrganization: true)] }
    if let list = args.options["authors"] {
        ref.authors = list.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { a in
            let parts = a.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? Author(family: parts[0], given: parts[1]) : Author(family: a, isOrganization: true)
        }
    }
    if let v = args.options["volume"] { ref.indexing.volume = v.isEmpty ? nil : v }
    if let v = args.options["issue"] { ref.indexing.issue = v.isEmpty ? nil : v }
    if let v = args.options["pages"] { ref.indexing.pages = v.isEmpty ? nil : v }
    if let d = args.options["doi"] { ref.doi = d.isEmpty ? nil : DOI.normalize(d) }
    // Hand edits mean the record is no longer exactly what a registry said.
    let edited = ["authors", "volume", "issue", "pages", "doi", "title", "year", "publication", "org-author"].contains { args.options[$0] != nil }
    if edited, var p = ref.provenance, p.source == .crossref || p.source == .datacite { p.verified = false; ref.provenance = p }
    let wasChecked = ref.provenance?.confirmedBy
    if let url = args.options["url"] { ref.url = url }
    if let publication = args.options["publication"] { ref.publication = publication }
    if let raw = args.options["year"] {
        guard let y = Int(raw) else { throw UsageError(description: "--year must be a number") }
        ref.year = y
    }
    if var tag = try projectTag(args) {
        if let i = ref.projects.firstIndex(where: { $0.project == tag.project }) {
            tag.subprojects = ref.projects[i].subprojects
            if tag.handle == nil { tag.handle = ref.projects[i].handle }
            ref.projects[i] = tag
        } else {
            ref.projects.append(tag)
        }
        if let s = args.options["subproject"], let i = ref.projects.firstIndex(where: { $0.project == tag.project }), !ref.projects[i].subprojects.contains(s) {
            ref.projects[i].subprojects.append(s)
            var index = library.projects[tag.project] ?? ProjectCitationIndex(project: tag.project)
            if !index.subprojects.contains(s) { index.subprojects.append(s) }
            library.projects[tag.project] = index
        }
    }
    let before = library[id].map { CitationFormatter(references: [$0]).referenceEntry($0) }
    try library.update(ref)
    try library.save(to: url)
    if let who = wasChecked, library[id]?.provenance?.confirmedBy == nil {
        print("IDI \(id): the check by \(who) was of the old details and has been removed — `refware confirm \(id)` once you've checked the new ones.")
    }
    let changed = args.options.keys.filter { !["library", "mailto", "by", "project", "handle"].contains($0) }.sorted()
    if !changed.isEmpty { History.record(HistoryEvent(kind: .recordUpdated, title: "IDI \(id) edited: \(changed.joined(separator: ", "))\(before.map { " — was: \($0)" } ?? "")", idis: [id]), forLibraryAt: url) }
    print(describe(library[id] ?? ref, in: library))
}

func cite(_ args: Arguments) throws {
    guard let input = args.positionals.first else { throw UsageError(description: "cite needs an input file") }
    let libURL = libraryURL(args)
    var library = try Library.load(from: libURL)
    if input.lowercased().hasSuffix(".docx") {
        try citeDocx(input, args: args, library: &library, libURL: libURL)
        return
    }
    let text = try String(contentsOfFile: input, encoding: .utf8)

    let processor = DocumentProcessor(
        library: library,
        markup: args.flags.contains("markdown") ? .markdown : .plain,
        requireVerified: args.flags.contains("require-verified")
    )
    let result = try processor.process(text)

    if let output = args.options["output"] {
        // Never overwrite the tagged source with its cited version — the tags would be gone.
        if URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath() {
            throw UsageError(description: "-o is the input file — that would replace your tagged draft. Write to a new file, e.g. -o \(URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent)_cited.\(URL(fileURLWithPath: input).pathExtension)")
        }
        try result.text.write(toFile: output, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("Wrote \(output) — \(result.cited.count) reference(s) cited.\n".utf8))
    } else {
        print(result.text, terminator: "")
    }

    let project = try projectTag(args)?.project
    History.recordBuild(document: args.options["output"] ?? input, project: project, cited: result.cited, quoteTags: result.quoteTags,
                        library: library, libraryURL: libURL)
    if let project, library.frozen == nil {
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        for id in result.cited where !index.references.contains(id) { index.references.append(id) }
        library.projects[project] = index
        try library.save(to: libURL)
    }
}

func citeDocx(_ input: String, args: Arguments, library: inout Library, libURL: URL) throws {
    guard let output = args.options["output"] else { throw UsageError(description: "a .docx needs -o OUTPUT.docx (the original is never overwritten)") }
    let inURL = URL(fileURLWithPath: input).standardizedFileURL, outURL = URL(fileURLWithPath: output).standardizedFileURL
    guard inURL != outURL else { throw UsageError(description: "-o must differ from the input; the original is never overwritten") }
    let citer = DocxCiter(library: library, requireVerified: args.flags.contains("require-verified"), hangingIndent: !args.flags.contains("no-indent"))
    let result = try citer.process(try Data(contentsOf: inURL))
    try result.data.write(to: outURL, options: .atomic)
    stderr("Wrote \(output): \(result.citationsReplaced) citation(s), \(result.referenceListEntries) reference-list entr\(result.referenceListEntries == 1 ? "y" : "ies").")
    if !result.unverified.isEmpty {
        stderr("Unverified references cited (check by hand, or re-add by DOI): " + result.unverified.map { "IDI \($0)" }.joined(separator: ", "))
    }
    let project = try projectTag(args)?.project
    History.recordBuild(document: output, project: project, cited: result.cited, quoteTags: result.quoteTags, library: library, libraryURL: libURL)
    if let project, library.frozen == nil {
        var index = library.projects[project] ?? ProjectCitationIndex(project: project)
        for id in result.cited { index.addReference(id) }
        library.projects[project] = index
        try library.save(to: libURL)
    }
}
