import AppKit
import RefWareCore
import SwiftUI

/// Claim verification: linked sources, suggested supporting passages from their
/// PDFs (RefWare finds), recorded quotes, and the status (you judge).
struct ClaimsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var events = UIEvents.shared
    @State private var selection: String?
    @State private var fromFile = ""
    @State private var show: ReviewFilter = .all

    enum ReviewFilter: String, CaseIterable { case all = "All", unreviewed = "Unreviewed", decision = "Awaiting decision", questioned = "Questioned", stale = "Stale quotes" }

    var claims: [Claim] {
        let index = store.project.flatMap { store.library.projects[$0] }
        let all = index?.claims ?? []
        let fromHere = fromFile.isEmpty ? all : all.filter { $0.origin?.file == fromFile }
        switch show {
        case .all: return fromHere
        case .unreviewed: return fromHere.filter { $0.status == .unreviewed }
        case .decision: return fromHere.filter { !$0.pendingProposals.isEmpty }
        case .questioned: return fromHere.filter(\.isQuestioned)
        case .stale: return fromHere.filter { $0.quotes.contains { index?.quote(tag: $0)?.staleSince != nil } }
        }
    }
    var files: [String] {
        let all = store.project.flatMap { store.library.projects[$0]?.claims } ?? []
        var seen = Set<String>()
        return all.compactMap { $0.origin?.file }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("From", selection: $fromFile) {
                    Text("All claims").tag("")
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .padding([.horizontal, .top], 8)
                Picker("Show", selection: $show) {
                    ForEach(ReviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .padding(8)
                List(claims, id: \.id, selection: $selection) { c in ClaimRow(claim: c) }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if let id = selection, let claim = claims.first(where: { $0.id == id }) {
                ClaimDetail(store: store, claim: claim).id(claim.id)
            } else {
                ContentUnavailableView("Pick a claim", systemImage: "quote.bubble",
                                       description: Text(store.project == nil ? "Choose a project in the library window first." : "RefWare suggests supporting passages; you decide whether they support the claim."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let m = store.message {
                HStack { Image(systemName: "info.circle"); Text(m).lineLimit(2).textSelection(.enabled); Spacer()
                    Button("Dismiss") { store.message = nil }.buttonStyle(.borderless) }
                    .padding(10).background(.bar)
            }
        }
        .onAppear {
            if let want = events.claimToShow { fromFile = ""; selection = want; events.claimToShow = nil }
            else if selection == nil { fromFile = files.last ?? ""; selection = claims.first?.id }
        }
        .onChange(of: events.claimToShow) { _, want in
            if let want { fromFile = ""; selection = want; events.claimToShow = nil }
        }
    }
}

struct ClaimRow: View {
    let claim: Claim
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(claim.id).font(.callout.bold())
                    if let l = claim.origin?.label { Text("listed as \(l)").font(.caption).foregroundStyle(.secondary) }
                    if claim.flags.contains(.fragment) { Text("cut off").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(.orange.opacity(0.25))) }
                    let unresolved = claim.sources.filter { $0.reference == nil }.count
                    if unresolved > 0 { Text("\(unresolved) unresolved").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(.red.opacity(0.2))) }
                    if !claim.quotes.isEmpty { Text("Q\(claim.quotes.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    if claim.isQuestioned { Label("questioned", systemImage: "flag.fill").font(.caption2).foregroundStyle(.orange).help("Someone flagged this claim; the flag is still open") }
                    if !claim.pendingProposals.isEmpty { Label("proposal", systemImage: "sparkles").font(.caption2).foregroundStyle(.purple).help("An AI reviewer proposed a status — accept or decline it") }
                }
                Text(claim.text).font(.callout).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
    var icon: String {
        switch claim.status {
        case .supported: "checkmark.circle.fill"
        case .overstated, .unsupported: "exclamationmark.circle.fill"
        case .sourceNotFound, .selfCitation: "questionmark.circle.fill"
        case .dropped: "minus.circle"
        case .unreviewed: "circle"
        }
    }
    var color: Color {
        switch claim.status {
        case .supported: .green
        case .overstated, .unsupported: .orange
        case .sourceNotFound, .selfCitation: .red
        default: .secondary
        }
    }
}

struct ClaimDetail: View {
    @ObservedObject var store: LibraryStore
    let claim: Claim
    @State private var passages: [(IDI, Passage)] = []
    @State private var edited: [String: String] = [:]
    @State private var searching = false
    @State private var status: ClaimStatus = .unreviewed
    @State private var note = ""
    @State private var saved: Date?
    @State private var saveError: String?
    @State private var reviewText = ""

    var me: Reviewer { Reviewer(name: store.reviewer, type: .human) }

    var project: String { store.project ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(claim.id).font(.title2.bold())
                        if let l = claim.origin?.label { Text("listed as \(l)").foregroundStyle(.secondary) }
                    }
                    Text(claim.text).font(.body).textSelection(.enabled)
                    if let o = claim.origin { Text("\(o.file), line \(o.line)").font(.caption).foregroundStyle(.secondary) }
                    if claim.flags.contains(.fragment) {
                        Label("This claim looks cut off — compare it with the manuscript sentence before judging it.", systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                    }
                }
                sources
                evidence
                recorded
                judgment
                reviewTrail
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: claim.id) {
            status = claim.status
            note = claim.note ?? ""
            reviewText = ""
            saved = nil
            saveError = nil
            await findPassages()
        }
    }

    // MARK: Sources

    var sources: some View {
        GroupBox("Sources cited") {
            VStack(alignment: .leading, spacing: 8) {
                if claim.sources.isEmpty { Text("No citation in this claim.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(claim.sources.enumerated()), id: \.offset) { i, s in
                    if let id = s.reference, let r = store.library[id] {
                        HStack {
                            Text("IDI \(id)").bold()
                            Text("\(CitationFormatter(references: [r]).inlineBody(r)) — \(r.title)").lineLimit(1)
                            Spacer()
                            if let f = r.fileName {
                                Button("Open PDF") { NSWorkspace.shared.open(store.pdfDir.appendingPathComponent(f)) }.controlSize(.small)
                            } else {
                                Text("no PDF").font(.caption).foregroundStyle(.orange)
                            }
                            linkMenu(sourceIndex: i, title: "Change to…")
                        }
                        .font(.callout)
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(s.title ?? s.url ?? "unresolved").font(.callout).lineLimit(2)
                            Spacer()
                            linkMenu(sourceIndex: i)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func linkMenu(sourceIndex: Int, title: String = "Link to record…") -> some View {
        Menu(title) {
            ForEach(store.library.references.values.sorted { ($0.authors.first?.family ?? "") < ($1.authors.first?.family ?? "") }, id: \.id) { r in
                Button("IDI \(r.id) · \(CitationFormatter(references: [r]).inlineBody(r)) — \(r.title.prefix(50))") { link(r.id, sourceIndex: sourceIndex) }
            }
        }
        .controlSize(.small).fixedSize()
    }

    func link(_ id: IDI, sourceIndex: Int) {
        store.mutate { lib in
            guard var index = lib.projects[project], let ci = index.claimIndex(claim.id) else { return "" }
            let old = index.claims[ci].sources[sourceIndex].reference
            index.claims[ci].sources[sourceIndex].reference = id
            index.addReference(id)
            lib.projects[project] = index
            return old.map { "\(claim.id): source changed from IDI \($0) to IDI \(id). Quotes recorded from IDI \($0) stay on record but no longer count for this claim." } ?? "\(claim.id) linked to IDI \(id)."
        }
        Task { await findPassages() }
    }

    // MARK: Evidence

    var evidence: some View {
        GroupBox("Suggested supporting passages") {
            VStack(alignment: .leading, spacing: 12) {
                if searching {
                    HStack { ProgressView().controlSize(.small); Text("Searching the linked PDFs…").font(.callout) }
                } else if passages.isEmpty {
                    Text(claim.references.isEmpty ? "Link a source to search its PDF." : "No candidate passages found in the linked PDFs. Open the PDF to check by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(passages, id: \.1.id) { id, p in passageCard(id, p) }
                Text("RefWare finds; you judge. Recording verifies the text word for word against the PDF.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func passageCard(_ id: IDI, _ p: Passage) -> some View {
        let who = store.library[id].map { CitationFormatter(references: [$0]).inlineBody($0) } ?? "IDI \(id)"
        let binding = Binding(get: { edited[p.id] ?? p.text }, set: { edited[p.id] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("IDI \(id) · \(who) · p. \(p.page), line \(p.line)").font(.caption.bold())
                ForEach(p.numbers, id: \.self) { n in
                    Text(n).font(.caption2.monospacedDigit()).padding(.horizontal, 5).background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }
            TextEditor(text: binding).font(.callout).frame(minHeight: 64, maxHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("Trim or extend the text to the exact words you want to quote.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Record as quote") { record(id, text: binding.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
    }

    func findPassages() async {
        searching = true
        defer { searching = false }
        let refs = claim.references.compactMap { id in store.library[id].flatMap { r in r.fileName.map { (id, store.pdfDir.appendingPathComponent($0)) } } }
        let text = claim.text
        let found = await Task.detached { () -> [(IDI, Passage)] in
            refs.flatMap { id, url in
                (try? PDFText.pages(of: url)).map { EvidenceFinder.passages(for: text, in: $0).map { (id, $0) } } ?? []
            }
        }.value
        passages = found
    }

    func record(_ id: IDI, text: String) {
        guard let r = store.library[id], let f = r.fileName else { return }
        var tag = ""
        if store.mutate({ lib in
            let pages = try PDFText.pages(of: store.pdfDir.appendingPathComponent(f))
            let q = try lib.addQuote(project: project, reference: id, text: text, claim: claim.id, pdfPages: pages,
                                     pdfSHA256: Library.sha256(of: store.pdfDir.appendingPathComponent(f)))
            tag = "\(q.tag), p. \(q.page ?? 0)"
            return "\(q.tag) recorded on \(claim.id) (p. \(q.page ?? 0), line \(q.line ?? 0)). Now set the status."
        }) {
            store.record(HistoryEvent(kind: .quoteVerified, project: project, title: "\(tag) → \(claim.id)", idis: [id], quoteTags: [tag.components(separatedBy: ",").first ?? tag]))
        }
    }

    // MARK: Recorded + judgment

    @ViewBuilder var recorded: some View {
        let index = store.library.projects[project]
        let quotes = claim.quotes.compactMap { index?.quote(tag: $0) }
        if !quotes.isEmpty {
            GroupBox("Recorded quotes") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(quotes, id: \.tag) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(q.tag) · p. \(q.page ?? 0), line \(q.line ?? 0) · cite as [\(q.tag)]").font(.caption.bold()).textSelection(.enabled)
                                if q.staleSince != nil {
                                    Label("stale — the PDF changed and this passage wasn't found in it", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text("“\(q.text)”").font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var judgment: some View {
        GroupBox("Your judgment") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Status", selection: $status) {
                    ForEach(ClaimStatus.allCases, id: \.self) { Text(label($0)).tag($0) }
                }
                TextField("Note (e.g. “source says organizations, not pilots”)", text: $note, axis: .vertical)
                HStack {
                    if status == .supported && claim.quotes.isEmpty {
                        Text("Record a supporting quote first — Supported needs one.").font(.caption).foregroundStyle(.orange)
                    } else if let e = saveError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(3)
                    } else if let t = saved, !changed {
                        Label("Saved \(t.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    } else if changed {
                        Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!changed || (status == .supported && claim.quotes.isEmpty))
                }
            }
        }
    }

    /// Differs from what's stored.
    var changed: Bool { status != claim.status || note != (claim.note ?? "") }

    func save() {
        saveError = nil
        let ok = store.mutate { lib in
            try lib.judge(project: project, claim: claim.id, status: status, by: me, rationale: note.isEmpty ? nil : note, note: note)
            return "\(claim.id) → \(label(status))."
        }
        if ok {
            saved = Date()
            store.record(HistoryEvent(kind: .claimReviewed, project: project, title: "\(claim.id) → \(status.rawValue)\(note.isEmpty ? "" : " — \(note.prefix(80))")",
                                      idis: claim.references, quoteTags: claim.quotes))
        } else { saveError = store.message ?? "Couldn't save." }
    }

    // MARK: Review trail (who judged, flagged, commented — kept, never overwritten)

    var reviewTrail: some View {
        GroupBox("Review history") {
            VStack(alignment: .leading, spacing: 8) {
                if let p = claim.pendingProposals.last, let s = p.status {
                    HStack(alignment: .top) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(p.reviewer)\(p.model.map { " (\($0))" } ?? "") proposes: \(label(s))").font(.callout.bold())
                            if let r = p.rationale { Text(r).font(.callout).textSelection(.enabled) }
                            if !p.reasons.isEmpty { Text(p.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Accept") { review("accepted the proposal") { try $0.acceptProposal(project: project, claim: claim.id, by: me) } }
                        Button("Decline") { review("declined the proposal") { _ = try $0.rejectProposals(project: project, claim: claim.id, by: me, note: reviewText.isEmpty ? nil : reviewText) } }
                    }
                    Divider()
                }
                if claim.reviews.isEmpty {
                    Text(claim.reviewedBy.map { "No review events yet (status last set by \($0))." } ?? "No review events yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(claim.reviews.reversed()) { e in eventRow(e) }
                Divider()
                TextField("Comment, or why you're questioning this claim", text: $reviewText, axis: .vertical)
                HStack {
                    Button("Comment") { review("commented") { try $0.comment(project: project, claim: claim.id, by: me, text: reviewText) } }
                        .disabled(reviewText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { review("questioned") { try $0.flag(project: project, claim: claim.id, by: me, reasons: [], rationale: reviewText) } } label: { Label("Question", systemImage: "flag") }
                        .disabled(reviewText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Flag the claim for another look. Its status stays as it is.")
                    if claim.isQuestioned {
                        Button("Resolve flag") { review("resolved the flag") { _ = try $0.resolveFlags(project: project, claim: claim.id, by: me, note: reviewText.isEmpty ? nil : reviewText) } }
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder func eventRow(_ e: ReviewEvent) -> some View {
        let (icon, color, what): (String, Color, String) = switch e.kind {
        case .judgment: (e.state == .proposed ? "sparkles" : "checkmark.seal", e.state == .superseded ? .secondary : .blue,
                         "\(e.state == .proposed ? "proposed" : "judged") \(e.status.map(label) ?? "?")\(e.state == .superseded ? " (superseded)" : "")")
        case .flag: ("flag.fill", e.state == .open ? .orange : .secondary, e.state == .open ? "questioned" : "questioned (resolved)")
        case .comment: ("text.bubble", .secondary, "commented")
        case .resolution: ("flag.slash", .green, "resolved a flag")
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(e.reviewer).font(.caption.bold())
                    if e.reviewerType == .ai { Text("AI\(e.model.map { " · \($0)" } ?? "")").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(.purple.opacity(0.15))) }
                    Text(what).font(.caption)
                    Spacer()
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                if !e.reasons.isEmpty { Text(e.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                if let r = e.rationale { Text(r).font(.callout).textSelection(.enabled) }
                if !e.quoteTags.isEmpty, e.kind == .judgment || e.kind == .flag { Text("relied on \(e.quoteTags.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    func review(_ did: String, _ body: @escaping (inout Library) throws -> Void) {
        let text = reviewText
        if store.mutate({ lib in try body(&lib); return "\(claim.id): you \(did)." }) {
            store.record(HistoryEvent(kind: did.contains("proposal") ? .claimReviewed : .claimEdited, project: project,
                                      title: "\(claim.id): \(did)\(text.isEmpty ? "" : " — \(text.prefix(80))")", idis: claim.references))
            reviewText = ""
        }
    }

    func label(_ s: ClaimStatus) -> String {
        switch s {
        case .unreviewed: "Unreviewed"
        case .supported: "Supported"
        case .overstated: "Overstated"
        case .unsupported: "Unsupported by source"
        case .sourceNotFound: "Source not found"
        case .selfCitation: "Self-citation"
        case .dropped: "Dropped"
        }
    }
}

@MainActor
enum ClaimsWindow {
    static var window: NSWindow?
    static var isOpen: Bool { window?.isVisible == true }

    static func show() {
        let config = RefWareConfig.load()
        guard let lib = config.library else { return }
        let store = MainWindow.store ?? LibraryStore(libURL: URL(fileURLWithPath: lib), project: config.project)
        MainWindow.store = store
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "RefWare — Verify Claims"
        w.contentViewController = NSHostingController(rootView: ClaimsView(store: store))
        w.setFrameAutosaveName("RefWareClaims")
        if !w.setFrameUsingName("RefWareClaims") { w.center() }
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
