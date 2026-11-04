import AppKit
import PDFKit
import RefWareCore
import SwiftUI
import UniformTypeIdentifiers

struct RecordInspector: View {
    @ObservedObject var store: LibraryStore
    let id: IDI
    @State private var editing = false
    @State private var candidates: [IdentCandidate]?
    @State private var searching = false
    @State private var showPDF = true
    @State private var merging = false

    var ref: Reference? { store.library[id] }

    var body: some View {
        if let ref {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(ref)
                    if editing { EditForm(store: store, ref: ref) { editing = false } }
                    checkStatus(ref)
                    facts(ref)
                    actions(ref)
                    subprojects(ref)
                    duplicates(ref)
                    matches(ref)
                    quotesAndClaims(ref)
                    builds(ref)
                    if let f = ref.fileName {
                        DisclosureGroup("PDF preview", isExpanded: $showPDF) {
                            PDFPreview(url: store.pdfDir.appendingPathComponent(f)).frame(height: 460)
                        }
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Delete Record…", role: .destructive) { confirmDelete(ref) }
                            .controlSize(.small)
                            .help("Remove this record. Its number is retired, its PDF moves to PDFs/deleted/, and you choose what happens to claims citing it.")
                    }
                }
                .padding(16)
            }
            .sheet(isPresented: $merging) { MergeSheet(store: store, id: id) }
            .task(id: id) {
                candidates = nil
                if ref.fileName != nil, ref.authors.isEmpty || ref.year == nil || ref.provenance?.verified != true { await findMatches(ref) }
            }
        }
    }

    func header(_ r: Reference) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("IDI \(r.id)").font(.title2.bold())
                Spacer()
                Button(editing ? "Done" : "Edit") { editing.toggle() }
            }
            Text(CitationFormatter(references: [r]).referenceEntry(r)).textSelection(.enabled)
            Text("Cite as `[IDI \(r.id)]` · narrative `[IDI \(r.id), narrative]`").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    func facts(_ r: Reference) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow { Text("Metadata").foregroundStyle(.secondary); Text(provenance(r)) }
            GridRow { Text("Added").foregroundStyle(.secondary); Text(r.importDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—") }
            GridRow { Text("Type").foregroundStyle(.secondary); Text(r.publicationType.rawValue) }
            GridRow { Text("PDF").foregroundStyle(.secondary); Text(r.fileName ?? "none").lineLimit(1).truncationMode(.middle) }
            if let u = r.url { GridRow { Text("Link").foregroundStyle(.secondary); Text(u).lineLimit(1).truncationMode(.middle).textSelection(.enabled) } }
            if let d = r.doi { GridRow { Text("DOI").foregroundStyle(.secondary); Text(d).textSelection(.enabled) } }
        }
        .font(.callout)
    }

    func provenance(_ r: Reference) -> String {
        guard let p = r.provenance else { return "unknown" }
        if let who = p.confirmedBy { return "checked by \(who)" + (p.confirmedOn.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") }
        return "\(p.source.rawValue) — \(p.verified ? "verified" : "unverified")"
    }

    func actions(_ r: Reference) -> some View {
        HStack {
            if let f = r.fileName { Button("Open PDF") { NSWorkspace.shared.open(store.pdfDir.appendingPathComponent(f)) } }
            if let u = (r.doi.map { "https://doi.org/\($0)" } ?? r.url).flatMap(URL.init(string:)) { Button("Open Link") { NSWorkspace.shared.open(u) } }
            attachMenu(r)
            Button("Merge with…") { merging = true }
                .help("Combine this record with another — e.g. the verified record you captured to replace a broken one.")
            findSourceMenu(r)
            Button("Refresh details") { Task { await refreshDetails(r) } }
                .help("Re-read the PDF (its properties, cover, printed DOI) and the registry, and suggest updated details.")
            Spacer()
        }
        .controlSize(.small)
    }

    /// Whether a person has checked this record against its source — always visible.
    @ViewBuilder func checkStatus(_ r: Reference) -> some View {
        HStack(spacing: 8) {
            if let who = r.provenance?.confirmedBy {
                Label("Checked by \(who)\(r.provenance?.confirmedOn.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")",
                      systemImage: "person.fill.checkmark")
                    .foregroundStyle(.green).font(.callout.bold())
                Spacer()
                Button("Undo") {
                    if store.mutate({ lib in try lib.unconfirm(r.id); return "IDI \(r.id): check removed." }) {
                        store.record(HistoryEvent(kind: .recordUpdated, project: store.project, title: "IDI \(r.id) check removed", idis: [r.id]))
                    }
                }
                .controlSize(.small)
            } else {
                Label(r.provenance?.verified == true ? "Registry-verified · not yet checked by you" : "Not checked against the source yet",
                      systemImage: r.provenance?.verified == true ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(r.provenance?.verified == true ? Color.secondary : Color.orange).font(.callout)
                Spacer()
                let ready = !r.authors.isEmpty && r.year != nil
                Button("Mark as Checked") {
                    if store.mutate({ lib in try lib.confirm(r.id, by: store.reviewer); return "IDI \(r.id) marked as checked by \(store.reviewer)." }) {
                        store.record(HistoryEvent(kind: .recordUpdated, project: store.project, title: "IDI \(r.id) checked by \(store.reviewer)", idis: [r.id]))
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!ready)
                .help(ready ? "You've compared author, year and title against the source itself." : "Add the author and year first (Edit), then mark it checked.")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill((r.provenance?.confirmedBy != nil ? Color.green : Color.secondary).opacity(0.08)))
    }

    @ViewBuilder func subprojects(_ r: Reference) -> some View {
        if let project = store.project, let index = store.library.projects[project], !index.subprojects.isEmpty {
            let mine = Set(r.projects.first { $0.project == project }?.subprojects ?? [])
            VStack(alignment: .leading, spacing: 6) {
                Text("Sub-projects in \(project)").font(.caption.bold()).foregroundStyle(.secondary)
                FlowRow(items: index.subprojects) { s in
                    Button { toggle(s, in: project, on: !mine.contains(s), r) } label: {
                        Label(s, systemImage: mine.contains(s) ? "checkmark.circle.fill" : "circle").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    func toggle(_ s: String, in project: String, on: Bool, _ r: Reference) {
        store.mutate { lib in
            guard var ref = lib[r.id] else { return "" }
            if let i = ref.projects.firstIndex(where: { $0.project == project }) {
                if on { if !ref.projects[i].subprojects.contains(s) { ref.projects[i].subprojects.append(s) } } else { ref.projects[i].subprojects.removeAll { $0 == s } }
            } else if on {
                ref.projects.append(ProjectTag(project: project, subprojects: [s]))
            }
            try lib.update(ref)
            var index = lib.projects[project] ?? ProjectCitationIndex(project: project)
            index.addReference(r.id)
            lib.projects[project] = index
            return on ? "IDI \(r.id) added to “\(s)”." : "IDI \(r.id) removed from “\(s)”."
        }
    }

    @ViewBuilder func duplicates(_ r: Reference) -> some View {
        if let group = store.library.likelyDuplicates().first(where: { $0.contains(r.id) }) {
            GroupBox("Same title as") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.filter { $0 != r.id }, id: \.self) { other in
                        if let o = store.library[other] {
                            Text("IDI \(other): " + CitationFormatter(references: [o]).referenceEntry(o)).font(.callout)
                            HStack {
                                Button("Merge \(r.id) → \(other)") { merge(r.id, into: other) }
                                Button("Merge \(other) → \(r.id)") { merge(other, into: r.id) }
                                Button("Different works") {
                                    store.mutate { lib in lib.markDistinct(group); return "Noted: different works." }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder func matches(_ r: Reference) -> some View {
        if searching {
            HStack { ProgressView().controlSize(.small); Text("Reading the PDF and looking for matches…").font(.callout) }
        } else if let list = candidates {
            GroupBox("What this PDF appears to be") {
                VStack(alignment: .leading, spacing: 10) {
                    if list.isEmpty { Text("No match found — check the PDF, then Edit or Mark as Checked.").font(.callout) }
                    ForEach(list) { c in candidate(c, r) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if r.fileName != nil {
            Button("Find matches for this PDF") { Task { await findMatches(r) } }.controlSize(.small)
        }
    }

    @ViewBuilder func candidate(_ c: IdentCandidate, _ r: Reference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch c.kind {
            case .existing(let target):
                if let t = store.library[target] {
                    Text("Already in the library as IDI \(target)").bold()
                    Text(CitationFormatter(references: [t]).referenceEntry(t)).font(.callout)
                    Label(c.evidence, systemImage: c.strong ? "checkmark.seal" : "questionmark.circle").font(.caption)
                    Button("Merge IDI \(r.id) into IDI \(target)") { merge(r.id, into: target) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            case .registry(let m):
                let preview = m.makeReference(id: r.id, verified: c.verifies)
                Text(c.verifies ? "Registry record" : "Details read from the PDF").bold()
                Text(CitationFormatter(references: [preview]).referenceEntry(preview)).font(.callout)
                Label(c.evidence, systemImage: c.strong ? "checkmark.seal" : "questionmark.circle").font(.caption)
                Button(c.verifies ? "Use This Record" : "Use These Details") {
                    store.record(HistoryEvent(kind: .recordUpdated, project: store.project, title: "IDI \(r.id) updated: \(c.evidence)", idis: [r.id]))
                    store.mutate { lib in
                        try lib.adopt(m, for: r.id, verified: c.verifies, pdfDirectory: store.pdfDir)
                        let stale = m.url == nil ? lib[r.id]?.url : nil
                        return "IDI \(r.id) updated\(c.verifies ? " and verified" : " — still unverified (details read from the PDF)")."
                            + (stale.map { " Its Link still points to \($0) — Edit it if the PDF came from elsewhere." } ?? "")
                    }
                    candidates = nil
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder func quotesAndClaims(_ r: Reference) -> some View {
        let quotes = store.library.projects.values.flatMap(\.quotes).filter { $0.reference == r.id }
        let claims = store.library.projects.values.flatMap(\.claims).filter { $0.references.contains(r.id) }
        if !quotes.isEmpty || !claims.isEmpty {
            GroupBox("Quotes & claims") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(quotes, id: \.tag) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(q.tag) · p. \(q.page ?? 0), line \(q.line ?? 0)\(q.verified ? " · verified" : "")").font(.caption.bold())
                            Text("“\(q.text)”").font(.callout).textSelection(.enabled)
                            Text("Cite as `[\(q.tag.replacingOccurrences(of: "IDI ", with: "IDI "))]`").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    ForEach(claims, id: \.id) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(c.id)\(c.origin?.label.map { " (listed as \($0))" } ?? "") · \(c.status.rawValue)\(c.subproject.map { " · \($0)" } ?? "")").font(.caption.bold())
                                Spacer()
                                Button("Verify…") { UIEvents.shared.claimToShow = c.id; ClaimsWindow.show() }.controlSize(.mini)
                                    .help("Open this claim in Verify Claims — suggested passages come from this record's current PDF.")
                            }
                            Text(c.text).font(.callout).lineLimit(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder func builds(_ r: Reference) -> some View {
        let hits = store.history.events(.build).filter { $0.idis.map(store.library.canonical).contains(r.id) }
        GroupBox("C/R build hits") {
            VStack(alignment: .leading, spacing: 3) {
                if hits.isEmpty { Text("Not cited in any logged build yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(hits.prefix(12)) { e in
                    Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.title)\(e.project.map { " · \($0)" } ?? "")").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Operations

    func confirmDelete(_ r: Reference) {
        let citing = store.library.claimsCiting(r.id)
        let only = citing.filter(\.onlySource)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete IDI \(r.id)?"
        var info = "\(CitationFormatter(references: [r]).referenceEntry(r))\n\n"
        info += citing.isEmpty ? "No claims cite this record." : "Cited by \(citing.map(\.claim.id).joined(separator: ", ")); \(only.count) of them cite only this record."
        info += "\n\nIts number is retired for good: drafts tagged [IDI \(r.id)] will report that it was deleted. Its PDF moves to PDFs/deleted/."
        a.informativeText = info
        let reason = NSTextField(string: "")
        reason.placeholderString = "Reason (e.g. paywalled — not citable on principle)"
        reason.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let drop = NSButton(checkboxWithTitle: "Also mark the \(only.count) claim(s) that cite only this record as Dropped", target: nil, action: nil)
        drop.state = only.isEmpty ? .off : .on
        drop.isEnabled = !only.isEmpty
        let stack = NSStackView(views: [reason, drop])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 56)
        a.accessoryView = stack
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let why = reason.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : reason.stringValue.trimmingCharacters(in: .whitespaces)
        var summary = ""
        if store.mutate({ lib in
            let res = try lib.delete(r.id, reason: why, by: store.reviewer, dropClaims: drop.state == .on, pdfDirectory: store.pdfDir)
            summary = "IDI \(r.id) deleted\(why.map { " (\($0))" } ?? "")"
                + (res.droppedClaims.isEmpty ? "" : "; dropped \(res.droppedClaims.joined(separator: ", "))")
                + (res.parkedPDF.map { "; PDF moved to \($0)" } ?? "")
            return summary + "."
        }) {
            store.record(HistoryEvent(kind: .recordDeleted, project: store.project, title: summary, idis: [r.id]))
        }
    }

    func findMatches(_ r: Reference) async {
        guard let file = r.fileName else { return }
        searching = true
        defer { searching = false }
        let url = store.pdfDir.appendingPathComponent(file)
        guard let pages = await Task.detached(operation: { try? PDFText.pages(of: url) }).value else { candidates = []; return }
        candidates = await PDFIdentifier(cascade: store.cascade).identify(pages, library: store.library, excluding: r.id)
    }

    func merge(_ from: IDI, into: IDI) {
        var note = ""
        if store.mutate({ lib in
            let m = try lib.merge(from, into: into, pdfDirectory: store.pdfDir)
            note = "IDI \(m.retired) → IDI \(m.survivor)"
            return "Merged IDI \(m.retired) into IDI \(m.survivor). \(m.pdfNote ?? "")"
        }) {
            store.record(HistoryEvent(kind: .merge, title: note, idis: [into, from]))
        }
    }

    /// For broken links: search for the source by title and author.
    func findSourceMenu(_ r: Reference) -> some View {
        let q = ([r.title] + (r.authors.first.map { [$0.family] } ?? [])).joined(separator: " ")
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return Menu("Find source") {
            Button("Google Scholar") { NSWorkspace.shared.open(URL(string: "https://scholar.google.com/scholar?q=\(enc)")!) }
            Button("Google (PDF)") { NSWorkspace.shared.open(URL(string: "https://www.google.com/search?q=\(enc)+filetype%3Apdf")!) }
            Button("Google") { NSWorkspace.shared.open(URL(string: "https://www.google.com/search?q=\(enc)")!) }
            if let u = r.url, let host = CanonicalURL.host(u) {
                Button("Search \(host)") { NSWorkspace.shared.open(URL(string: "https://www.google.com/search?q=site%3A\(host)+\(enc)")!) }
            }
        }
        .fixedSize()
        .help("Link broken? Search for the source by title — then capture it with the browser extension and use Merge with… or the capture banner.")
    }

    func attachMenu(_ r: Reference) -> some View {
        Menu(r.fileName == nil ? "Attach PDF" : "Replace PDF") {
            Button("Choose File…") { attachPDF(r) }
            let recent = store.recentCaptures(excluding: r.id)
            if !recent.isEmpty {
                Section("Recently captured") {
                    ForEach(recent, id: \.0) { id, date in
                        if let c = store.library[id] {
                            Button("IDI \(id) · \(c.title.prefix(48)) — \(date.formatted(.relative(presentation: .named)))") {
                                store.useCaptured(id, for: r.id); candidates = nil
                            }
                        }
                    }
                }
            }
            let orphans = store.unattachedPDFs
            if !orphans.isEmpty {
                Section("Unattached PDFs in the library folder") {
                    ForEach(orphans, id: \.self) { f in
                        Button(f) { store.attach(file: store.pdfDir.appendingPathComponent(f), to: r.id, move: true); candidates = nil }
                    }
                }
            }
        }
        .fixedSize()
    }

    func attachPDF(_ r: Reference) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose the PDF for IDI \(r.id)"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        if store.attach(file: src, to: r.id) { candidates = nil }
    }

    /// Fresh suggestions for this record: the PDF's own details, the registry (by DOI), and library matches.
    func refreshDetails(_ r: Reference) async {
        searching = true
        defer { searching = false }
        var list: [IdentCandidate] = []
        if let f = r.fileName {
            let url = store.pdfDir.appendingPathComponent(f)
            if f.contains("_web-"), let link = r.url {
                // A snapshot of a web page: ask the page itself, not the screenshot's first line.
                if case .exact(let m, _) = await store.cascade.run(SearchQuery(url: link)).outcome {
                    list.append(IdentCandidate(kind: .registry(m), evidence: "the web page's own metadata (\(CanonicalURL.host(link) ?? link))", strong: false))
                }
            } else if let m = await Task.detached(operation: { PDFDetails.read(url) }).value {
                list.append(IdentCandidate(kind: .registry(m), evidence: "read from the PDF itself (document properties and cover)", strong: false))
            }
            if let pages = await Task.detached(operation: { try? PDFText.pages(of: url) }).value {
                list += await PDFIdentifier(cascade: store.cascade).identify(pages, library: store.library, excluding: r.id)
            }
        }
        if let doi = r.doi, let m = try? await store.cascade.lookup(doi: doi) {
            list.append(IdentCandidate(kind: .registry(m), evidence: "the registry record for DOI \(doi)", strong: true))
        }
        candidates = list
        if list.isEmpty { store.message = "Nothing new found for IDI \(r.id) — edit the fields by hand if they're wrong." }
    }
}

/// Simple field editor for a record.
struct EditForm: View {
    @ObservedObject var store: LibraryStore
    let ref: Reference
    let done: () -> Void
    @State private var title = ""
    @State private var authors = ""
    @State private var year = ""
    @State private var journal = ""
    @State private var volume = ""
    @State private var issue = ""
    @State private var pages = ""
    @State private var url = ""
    @State private var doi = ""
    @State private var type: PublicationType = .unclassified

    var body: some View {
        GroupBox("Edit") {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(PublicationType.allCases, id: \.self) { t in Text(Self.label(t)).tag(t) }
                }
                TextField("Title", text: $title, axis: .vertical)
                TextField("Authors", text: $authors, prompt: Text("Family, Given; Family, Given — or one organization"), axis: .vertical)
                TextField("Year", text: $year)
                TextField(type == .book || type == .report || type == .whitePaper ? "Publisher" : type == .bookChapter ? "Book (Editors, Title, pp.) / publisher" : "Journal / venue",
                          text: $journal)
                HStack { TextField("Vol.", text: $volume); TextField("Issue", text: $issue); TextField("Pages", text: $pages) }
                TextField("DOI", text: $doi, prompt: Text("10.xxxx/… (optional)"))
                TextField("Link", text: $url)
                HStack {
                    Spacer()
                    Button("Cancel", action: done)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            .onAppear(perform: load)
        }
    }

    func load() {
        title = ref.title
        authors = ref.authors.map { $0.isOrganization || $0.given == nil ? $0.family : "\($0.family), \($0.given!)" }.joined(separator: "; ")
        year = ref.year.map(String.init) ?? ""
        journal = ref.publication ?? ""
        volume = ref.indexing.volume ?? ""; issue = ref.indexing.issue ?? ""; pages = ref.indexing.pages ?? ""
        url = ref.url ?? ""
        doi = ref.doi ?? ""
        type = ref.publicationType
    }

    static func label(_ t: PublicationType) -> String {
        switch t {
        case .peerReviewed: "Peer-reviewed article"
        case .preprint: "Preprint"
        case .popularPress: "Popular press / news"
        case .industryMagazine: "Industry magazine"
        case .whitePaper: "White paper"
        case .developerDocumentation: "Developer documentation"
        case .book: "Book"
        case .bookChapter: "Book chapter"
        case .report: "Report"
        case .other: "Other"
        case .unclassified: "Unclassified"
        }
    }

    func save() {
        let parsed: [Author] = authors.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { a in
            let parts = a.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? Author(family: parts[0], given: parts[1]) : Author(family: a, isOrganization: true)
        }
        let blank = { (s: String) -> String? in let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        store.mutate { lib in
            guard var r = lib[ref.id] else { return "" }
            r.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            r.authors = parsed
            r.year = Int(year.trimmingCharacters(in: .whitespaces))
            r.publication = blank(journal)
            r.indexing.volume = blank(volume); r.indexing.issue = blank(issue); r.indexing.pages = blank(pages)
            r.url = blank(url)
            r.publicationType = type
            let newDOI = blank(doi).flatMap { DOI.normalize($0) ?? $0 }
            r.doi = newDOI
            // Hand edits mean the record is no longer exactly what a registry said.
            if var p = r.provenance, p.source == .crossref || p.source == .datacite {
                p.verified = false
                r.provenance = p
            }
            try lib.update(r)
            return "IDI \(ref.id) saved. Use Mark as Checked once you've compared it with the source."
        }
        store.record(HistoryEvent(kind: .recordUpdated, project: store.project, title: "IDI \(ref.id) edited by hand", idis: [ref.id]))
        done()
    }
}

/// Wrapping row of small views.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        // A simple vertical list is reliable at inspector widths; chips wrap one per line when narrow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 6) { ForEach(items, id: \.self, content: content) }
        }
    }
}
