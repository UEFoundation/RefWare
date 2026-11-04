import AppKit
import RefWareCore
import RefWareMac
import SwiftUI
import UniformTypeIdentifiers

struct SectionCard: View {
    let section: MenuSection
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState
    var showHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HStack {
                    Text(section.rawValue).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Spacer()
                    Button { v.toggle(section) } label: { Image(systemName: "minus") }.buttonStyle(.plain).help("Close")
                }
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(section.color)
            }
            Group {
                switch section {
                case .stats: StatsPanel(store: store, v: v)
                case .sort: SortPanel(v: v)
                case .status: StatusPanel(store: store, v: v)
                case .actions: ActionsPanel(store: store, v: v)
                case .exports: ExportsPanel(store: store)
                case .records: RecordsPanel(store: store, v: v)
                case .projects: ProjectsPanel(store: store, v: v)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(section.color, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A row whose number filters the table when clicked ("click to show in panel").
struct CountRow: View {
    let label: String
    let value: String
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer()
            if let action {
                Button(action: action) { Text(value).monospacedDigit().bold() }
                    .buttonStyle(.bordered).controlSize(.small).help("Show these in the Resource View")
            } else {
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

func pct(_ n: Int, _ of: Int) -> String { of == 0 ? "\(n)" : "\(n) · \(Int((Double(n) / Double(of) * 100).rounded()))%" }
func when(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never" }

// MARK: Stats

struct StatsPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        let i = store.insights
        let verifiedClaims = i.verifiedQuotes.filter { i.claimQuoteTags.contains($0.tag) }
        VStack(alignment: .leading, spacing: 8) {
            CountRow(label: "# PDFs (IDI)", value: "\(i.withPDF.count)") { v.filter = .hasPDF }
            CountRow(label: "# Verified quotations (on claims)", value: "\(verifiedClaims.count)") { v.filter = .verifiedClaims }
            CountRow(label: "# Supported claims", value: pct(i.supportedClaims.count, i.claims.count)) { ClaimsWindow.show() }
            if !i.questionedClaims.isEmpty || !i.claimsWithProposals.isEmpty {
                CountRow(label: "# Questioned · awaiting decision", value: "\(i.questionedClaims.count) · \(i.claimsWithProposals.count)") { ClaimsWindow.show() }
            }
            if !i.staleQuotes.isEmpty {
                CountRow(label: "# Stale quotations (PDF changed)", value: "\(i.staleQuotes.count)") { ReviewWindow.show() }
            }
            CountRow(label: "# Sub-projects", value: "\(i.subprojectCount)") { v.expanded.insert(.projects); v.activeTab = .projects }
            CountRow(label: "Last claims-list export", value: when(store.history.last(.claimsExport, project: store.project)?.date)) {
                v.expanded.insert(.exports); v.activeTab = .exports
            }
            CountRow(label: "Last cite/ref build", value: when(store.history.last(.build, project: store.project)?.date)) {
                v.expanded.insert(.records); v.activeTab = .records
            }
            Text("for \(store.project ?? "the whole library")\(store.subproject.map { " › \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Sort

struct SortPanel: View {
    @ObservedObject var v: ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sort by…", selection: $v.sortKey) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Ascending", isOn: $v.ascending)
            TextField("Keyword search", text: $v.search).textFieldStyle(.roundedBorder)
            LabeledContent("Has verified claims") {
                Picker("", selection: $v.hasClaims) { ForEach(YesNo.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            LabeledContent("Claims exported") {
                Picker("", selection: $v.exported) { ForEach(YesNo.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
        }
        .font(.callout)
    }
}

// MARK: Status

struct StatusPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        let i = store.insights
        let s = v.buildScope
        VStack(alignment: .leading, spacing: 8) {
            CountRow(label: "PDFs with unverified metadata", value: pct(i.unverifiedPDFs.count, i.withPDF.count)) { v.filter = .unverifiedPDFs }
            CountRow(label: "Verified PDFs w/o verified quotations", value: pct(i.verifiedPDFsWithoutClaims.count, i.withPDF.count)) { v.filter = .verifiedNoClaims }
            CountRow(label: "Quotations not in an exported claims list", value: pct(i.quotesNotExported.count, i.verifiedQuotes.count)) { v.filter = .quotesNotExported }
            Divider()
            Picker("C/R build", selection: $v.buildScope) {
                ForEach(LibraryInsights.BuildScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            CountRow(label: "IDIs not hit in a C/R build", value: pct(i.notHit(s).count, i.references.count)) { v.filter = .notHit(s) }
            CountRow(label: "IDI-Qs not hit in a C/R build", value: pct(i.quotesNotHit(s).count, i.verifiedQuotes.count)) { v.filter = .quotesNotHit(s) }
            if store.history.events(.build, project: store.project).isEmpty {
                Text("No builds logged yet — they're recorded from the next `refware cite` on.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Actions

struct ActionsPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            action("Resolve unverified-metadata PDFs", "wand.and.stars") {
                v.filter = .unverifiedPDFs
                v.selection = store.insights.unverifiedPDFs.first?.id
            }
            action("Import transcript or claims list…", "text.bubble") { Task { await importTranscript() } }
            action("Verify claims (find supporting passages)…", "quote.bubble") { ClaimsWindow.show() }
            action("Create new project or sub-project…", "folder.badge.plus") { createProject() }
            action("Export verified claims list…", "square.and.arrow.up") { exportClaims() }
            action("Pull no-hit IDI / IDI-Q list…", "list.bullet.rectangle") { pullNoHit() }
            action("Fetch missing PDFs & snapshots", "arrow.down.doc") { Task { await fetchMissing() } }
        }
        .disabled(store.busy != nil)
    }

    func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.bordered)
    }

    func needProject() -> String? {
        if let p = store.project { return p }
        store.message = "Choose a project in the menu first."
        return nil
    }

    func importTranscript() async {
        guard let project = needProject() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Choose a chat transcript to import into \(project)"
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let file = url.lastPathComponent
        var count = 0
        var isList = false
        var summary = ""
        // A citation matrix usually ends with its bibliography: check that against the registries
        // first, so the claims arrive linked to records.
        var bibliography: ManuscriptAudit?
        if !ClaimsListImporter.looksLikeClaimsList(text), CitationMatrixImporter.looksLikeCitationMatrix(text),
           !ManuscriptParser.parse(text).entries.isEmpty {
            store.busy = "Checking the bibliography against Crossref, DataCite and arXiv…"
            bibliography = await ManuscriptAuditor(cascade: store.cascade).audit(text) { i, n in
                Task { @MainActor in store.busy = "Checking the bibliography against the registries… \(i) of \(n)" }
            }
            store.busy = nil
        }
        var addedRefs: [IDI] = []
        guard store.mutate({ lib in
            var refNote = ""
            if var b = bibliography {
                let (added, reused) = b.importVerified(into: &lib, project: project, includeUnverified: true, subproject: store.subproject)
                addedRefs = added
                let unverified = added.filter { lib[$0]?.provenance?.verified != true }.count
                refNote = " Bibliography: \(added.count) reference(s) added\(unverified > 0 ? " (\(unverified) unverified — check each against the work itself, then Mark as Checked)" : ""), \(reused.count) already in the library."
            }
            var index = lib.projects[project] ?? ProjectCitationIndex(project: project)
            let next = Int(index.nextClaimID.dropFirst()) ?? 1
            var found: [Claim]
            var extra = ""
            if !ClaimsListImporter.looksLikeClaimsList(text), CitationMatrixImporter.looksLikeCitationMatrix(text) {
                let r = CitationMatrixImporter(file: file).claims(from: text, library: lib, firstID: next)
                found = r.claims
                let linked = found.filter { !$0.references.isEmpty }.count
                extra = refNote + " \(linked) of \(found.count) claims linked to library records" + (r.unresolved.isEmpty ? "." : "; \(r.unresolved.count) cited work(s) aren't in the library (\(r.unresolved.map { $0.components(separatedBy: " — ").first ?? $0 }.joined(separator: "; "))) — add them, then link them from each claim's Sources.")
            } else if ClaimsListImporter.looksLikeClaimsList(text) {
                let r = ClaimsListImporter(file: file).claims(from: text, library: lib, firstID: next)
                found = r.claims
                let linked = found.filter { !$0.references.isEmpty }.count
                extra = " \(linked) linked to library records; \(r.unresolved.count) citation(s) unresolved\(r.fragments.isEmpty ? "" : "; \(r.fragments.count) look cut off (\(r.fragments.joined(separator: ", ")))")."
            } else {
                found = TranscriptImporter(file: file).claims(from: text, firstID: next)
            }
            guard !found.isEmpty else {
                throw UsageMessage("No claims found in \(file). RefWare imports chat transcripts (**Me**: / **Assistant**: turns), claims lists (## C1 headings with the claim as a > quote), and citation matrices (a **Claim:** line followed by the works cited).")
            }
            isList = ClaimsListImporter.looksLikeClaimsList(text) || CitationMatrixImporter.looksLikeCitationMatrix(text)
            summary = extra
            if let s = store.subproject { for i in found.indices { found[i].subproject = s } }
            let (added, existing) = index.addClaims(found)
            count = added.count
            for id in added.flatMap(\.references) { index.addReference(id) }
            lib.projects[project] = index
            let skipped = existing.isEmpty ? "" : " \(existing.count) were already here (same text) and weren't added again."
            return "Imported \(added.count) claims from \(file).\(extra)\(skipped)"
        }) else { return }
        if !addedRefs.isEmpty {
            store.record(HistoryEvent(kind: .recordUpdated, project: project, subproject: store.subproject,
                                      title: "\(addedRefs.count) reference(s) added from the bibliography of \(file)", idis: addedRefs))
        }
        store.record(HistoryEvent(kind: .transcriptImport, project: project, subproject: store.subproject, title: "\(file) — \(count) claims",
                                  archived: History.archive((try? Data(contentsOf: url)) ?? Data(), named: file, project: project, forLibraryAt: store.libURL),
                                  source: url.path))
        // Claims lists arrive already linked to library records; chats need their sources looked up.
        if isList {
            store.message = "Imported \(count) claims from \(file).\(summary)"
            ClaimsWindow.show()
            return
        }
        store.busy = "Resolving the transcript's sources…"
        defer { store.busy = nil }
        do {
            var lib = try Library.load(from: store.libURL)
            let report = await ClaimResolver(cascade: store.cascade).resolve(project: project, in: &lib)
            try lib.save(to: store.libURL)
            store.reload()
            store.message = "Imported \(count) claims from \(file): linked \(report.linked) source(s), added \(report.added.count) reference(s), \(report.unresolved.count) unresolved."
        } catch { store.message = "\(error)" }
    }

    func createProject() {
        let a = NSAlert()
        a.messageText = "New project or sub-project"
        a.informativeText = "To add a sub-project to an existing project, keep its ID and name the sub-project. Leave the sub-project blank to create just the project."
        // Plain frames (not a stack view): an alert's accessory view isn't laid out automatically,
        // so a stack view collapses its fields.
        let width: CGFloat = 320
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 92))
        func label(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 0, y: y, width: width, height: 16)
            box.addSubview(l)
        }
        label("Project ID", y: 74)
        let p = NSTextField(frame: NSRect(x: 0, y: 48, width: width, height: 24))
        p.stringValue = store.project ?? "UEF-"
        p.placeholderString = "UEF-XXXX"
        box.addSubview(p)
        label("Sub-project (optional)", y: 26)
        let s = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        s.placeholderString = "e.g. Section 1.3, Talk deck"
        box.addSubview(s)
        p.nextKeyView = s; s.nextKeyView = p
        a.accessoryView = box
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.layout()
        // Already in a project: the likely task is a sub-project, so start there.
        a.window.initialFirstResponder = store.project == nil ? p : s
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = p.stringValue.trimmingCharacters(in: .whitespaces).uppercased(), sub = s.stringValue.trimmingCharacters(in: .whitespaces)
        guard name.range(of: #"^UEF-\w+$"#, options: .regularExpression) != nil else { store.message = "Project IDs look like UEF-XXXX."; return }
        var isNew = false, subIsNew = false
        if store.mutate({ lib in
            isNew = lib.projects[name] == nil
            var index = lib.projects[name] ?? ProjectCitationIndex(project: name)
            subIsNew = !sub.isEmpty && !index.subprojects.contains(sub)
            if subIsNew { index.subprojects.append(sub) }
            lib.projects[name] = index
            if sub.isEmpty { return isNew ? "Project \(name) created." : "Project \(name) already exists — to add a sub-project, name it in the second field." }
            return subIsNew ? "Sub-project “\(sub)” added to \(name). Add records to it from a record's detail panel (Sub-projects)." : "\(name) already has a sub-project “\(sub)”."
        }) {
            store.project = name
            if !sub.isEmpty { store.subproject = sub; v.showSubprojects = true }
            if isNew { store.record(HistoryEvent(kind: .projectEdited, project: name, title: "Project \(name) created")) }
            if subIsNew { store.record(HistoryEvent(kind: .projectEdited, project: name, subproject: sub, title: "Sub-project “\(sub)” added")) }
        }
    }

    func exportClaims() {
        guard let project = needProject() else { return }
        var lib = store.library
        if let s = store.subproject, var index = lib.projects[project] {
            index.claims = index.claims.filter { $0.subproject == s }
            lib.projects[project] = index
        }
        let claims = lib.projects[project]?.claims ?? []
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claims-\(project)\(store.subproject.map { "-\($0)" } ?? "").md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = ClaimsReport(library: lib, project: project).markdown()
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            store.record(HistoryEvent(kind: .claimsExport, project: project, subproject: store.subproject, title: "Claims list — \(claims.count) claims",
                                      idis: Array(Set(claims.flatMap(\.references))).sorted(), quoteTags: claims.flatMap(\.quotes),
                                      archived: History.archive(Data(md.utf8), named: url.lastPathComponent, project: project, forLibraryAt: store.libURL),
                                      source: url.path))
            store.message = "Exported \(claims.count) claims to \(url.lastPathComponent) (archived under Exports)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { store.message = "\(error)" }
    }

    func pullNoHit() {
        let i = store.insights
        let scope = v.buildScope
        var lines = ["No-hit list — \(store.project ?? "whole library")\(store.subproject.map { " › \($0)" } ?? "") — \(scope.rawValue.lowercased()) — \(Date().formatted())", "",
                     "IDIs not cited in a C/R build:"]
        lines += i.notHit(scope).map { "  IDI \($0.id)  \(CitationFormatter(references: [$0]).inline([$0]))  \($0.title)" }
        lines += ["", "IDI-Qs not cited in a C/R build:"]
        lines += i.quotesNotHit(scope).map { "  \($0.tag)  p. \($0.page ?? 0)  “\($0.text.prefix(90))”" }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "no-hit-\(store.project ?? "library").txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            v.filter = .notHit(scope)
            store.message = "Wrote \(url.lastPathComponent); the Resource View now shows the no-hit records."
        } catch { store.message = "\(error)" }
    }

    func fetchMissing() async {
        guard let project = needProject() else { return }
        store.busy = "Fetching missing PDFs and page snapshots…"
        defer { store.busy = nil }
        let http = URLSessionHTTPClient()
        let capture = Capture(cascade: store.cascade, http: http, snapshotter: WebSnapshotter(),
                              unpaywall: store.mailto.map { UnpaywallClient(http: http, email: $0) })
        var got = 0, failed = 0
        var noFreeCopy: [IDI] = []
        let todo = store.insights.references.filter { $0.fileName == nil && ($0.url != nil || $0.doi != nil) }
        let noLink = store.insights.references.filter { $0.fileName == nil && $0.url == nil && $0.doi == nil }
        for ref in todo {
            do {
                var lib = try Library.load(from: store.libURL)
                let r = try await capture.run(ref.url ?? "https://doi.org/\(ref.doi!)", project: project, claim: nil, library: &lib, pdfDirectory: store.pdfDir)
                try lib.save(to: store.libURL)
                History.recordCapture(r, url: ref.url ?? ref.doi!, project: project, libraryURL: store.libURL)
                if r.reference.fileName != nil { got += 1 } else { noFreeCopy.append(ref.id) }
            } catch { failed += 1 }
        }
        store.reload()
        var parts = ["Fetched \(got) of \(todo.count) records that have a link or DOI."]
        if !noFreeCopy.isEmpty { parts.append("No free copy found for IDI \(noFreeCopy.map(String.init).joined(separator: ", ")) (paywalled, a book, or the host blocks downloads) — download through your library access and use Attach PDF….") }
        if failed > 0 { parts.append("\(failed) couldn't be captured (dead links or bot checks).") }
        if !noLink.isEmpty { parts.append("\(noLink.count) record(s) have no link or DOI, so there was nothing to fetch (IDI \(noLink.map { String($0.id) }.joined(separator: ", "))) — add the report's web address in the record's details and fetch again, or attach the PDF.") }
        store.message = parts.joined(separator: " ")
    }
}

struct UsageMessage: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: Exports

struct ExportsPanel: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        let kinds: [HistoryEvent.Kind] = [.claimsExport, .referenceExport, .transcriptImport]
        let events = store.history.events.filter { kinds.contains($0.kind) && (store.project == nil || $0.project == store.project) }
            .sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text("Exported claims lists, reference lists from C/R builds, and imported chats will be archived here with date and project.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(events) { e in
                Button { open(e) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.callout).lineLimit(2)
                        Text("\(label(e.kind)) · \(e.date.formatted(date: .abbreviated, time: .shortened))\(e.project.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).disabled(e.archived == nil)
                .help(e.archived ?? "No archived copy")
            }
        }
    }

    func label(_ k: HistoryEvent.Kind) -> String {
        switch k {
        case .claimsExport: "Claims list"
        case .referenceExport: "Reference list"
        case .transcriptImport: "Imported chat"
        default: k.rawValue
        }
    }

    func open(_ e: HistoryEvent) {
        guard let rel = e.archived else { return }
        NSWorkspace.shared.open(store.libURL.deletingLastPathComponent().appendingPathComponent(rel))
    }
}

// MARK: Records

struct RecordsPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last…").font(.callout.bold())
            last("PDF added", .pdfAdded)
            last("IDI-Q verified", .quoteVerified)
            last("Verified claims list exported", .claimsExport)
            last("C/R build", .build)
            DisclosureGroup("All dated records", isExpanded: $showAll) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([HistoryEvent.Kind.transcriptImport, .claimsExport, .build, .pdfAdded, .quoteVerified, .claimReviewed, .recordUpdated, .recordDeleted, .merge, .freeze], id: \.self) { k in
                        let list = store.history.events(k, project: nil).filter { store.project == nil || $0.project == nil || $0.project == store.project }
                        if !list.isEmpty {
                            Text("\(name(k)) (\(list.count))").font(.caption.bold()).padding(.top, 4)
                            ForEach(list.prefix(25)) { e in eventRow(e) }
                        }
                    }
                }
            }
            .font(.callout)
            Divider()
            DevelopmentRecord()
        }
    }

    func name(_ k: HistoryEvent.Kind) -> String {
        switch k {
        case .transcriptImport: "Transcript imports"
        case .claimsExport: "Verified claims list exports"
        case .build: "C/R builds"
        case .pdfAdded: "PDFs added"
        case .quoteVerified: "IDI-Qs verified"
        case .merge: "Merges"
        case .freeze: "Freeze / unfreeze"
        case .referenceExport: "Reference lists"
        case .claimReviewed: "Claim judgments"
        case .recordUpdated: "Record updates"
        case .recordDeleted: "Deleted records"
        case .claimEdited: "Claim edits, flags and comments"
        case .projectEdited: "Project changes"
        case .other: "Other"
        }
    }

    @ViewBuilder func last(_ label: String, _ k: HistoryEvent.Kind) -> some View {
        let e = store.history.last(k, project: nil).flatMap { e in store.project == nil || e.project == nil || e.project == store.project ? e : nil }
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(when(e?.date)).font(.caption).foregroundStyle(.secondary)
            }
            if let e { eventRow(e, compact: true) }
        }
    }

    func eventRow(_ e: HistoryEvent, compact: Bool = false) -> some View {
        Button {
            if !e.idis.isEmpty { v.filter = .ids(Set(e.idis.map(store.library.canonical)), "\(name(e.kind)): \(e.title)") }
        } label: {
            Text(compact ? e.title : "\(e.date.formatted(date: .numeric, time: .shortened))  \(e.title)")
                .font(.caption).lineLimit(1).foregroundStyle(e.idis.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(e.idis.isEmpty ? e.title : "Show these \(e.idis.count) record(s) in the Resource View")
    }
}

// MARK: Projects

struct ProjectsPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.projectNames, id: \.self) { name in
                let index = store.library.projects[name]!
                let count = LibraryInsights(library: store.library, history: store.history, project: name).references.count
                Button { store.project = name; store.subproject = nil } label: {
                    HStack {
                        Image(systemName: store.project == name && store.subproject == nil ? "folder.fill" : "folder")
                        Text(name).bold()
                        Spacer()
                        Text("\(count) · \(index.claims.count) claims").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(index.subprojects, id: \.self) { s in
                    let n = LibraryInsights(library: store.library, history: store.history, project: name, subproject: s).references.count
                    Button { store.project = name; store.subproject = s; v.showSubprojects = true } label: {
                        HStack {
                            Text("›").foregroundStyle(.secondary)
                            Text(s)
                            Spacer()
                            Text("\(n)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 18).contentShape(Rectangle())
                        .fontWeight(store.subproject == s && store.project == name ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Whole library") { store.project = nil; store.subproject = nil }.buttonStyle(.link).padding(.top, 4)
            Text("Add records to a sub-project from a record's detail panel (Sub-projects).").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
