import AppKit
import PDFKit
import RefWareCore
import SwiftUI

/// RefWare Review: the worklist of records needing attention (possible duplicates,
/// placeholders, unverified records), with the same record panel as the library
/// window — so both windows always offer the same tools.
struct ReviewView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var events = UIEvents.shared
    @State var selection: IDI?

    var duplicates: [[IDI]] { store.library.likelyDuplicates() }
    var placeholders: [Reference] { store.library.needsReview().filter { $0.authors.isEmpty || $0.year == nil } }
    var unverified: [Reference] { store.library.needsReview().filter { !$0.authors.isEmpty && $0.year != nil } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !duplicates.isEmpty {
                    Section("Possible duplicates") {
                        ForEach(duplicates, id: \.self) { group in
                            row(group[0], badge: "doc.on.doc", extra: "same title as \(group.dropFirst().map { "IDI \($0)" }.joined(separator: ", "))")
                        }
                    }
                }
                if !placeholders.isEmpty {
                    Section("Placeholders — no author or year") {
                        ForEach(placeholders, id: \.id) { row($0.id, badge: "questionmark.square.dashed") }
                    }
                }
                if !unverified.isEmpty {
                    Section("Unverified") {
                        ForEach(unverified, id: \.id) { row($0.id, badge: "exclamationmark.triangle") }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
            .onChange(of: events.select) { _, s in if let s { selection = s; events.select = nil } }
        } detail: {
            VStack(spacing: 0) {
                if let n = events.capture { CaptureBanner(store: store, selection: $selection, notice: n) }
                if let id = selection, store.library[id] != nil {
                    RecordInspector(store: store, id: id).id(id)
                } else {
                    ContentUnavailableView("Nothing selected", systemImage: "books.vertical",
                                           description: Text(store.library.needsReview().isEmpty && duplicates.isEmpty
                                                             ? "Everything in the library is verified. 🎉" : "Pick a record on the left."))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh — updated \(store.loadedAt.formatted(date: .omitted, time: .standard))")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.message != nil || store.busy != nil {
                HStack(spacing: 8) {
                    if let b = store.busy { ProgressView().controlSize(.small); Text(b) } else { Image(systemName: "info.circle") }
                    if let m = store.message { Text(m).lineLimit(3).textSelection(.enabled) }
                    Spacer()
                    if store.message != nil { Button("Dismiss") { store.message = nil }.buttonStyle(.borderless) }
                }
                .padding(10).background(.bar)
            }
        }
    }

    @ViewBuilder func row(_ id: IDI, badge: String, extra: String? = nil) -> some View {
        if let r = store.library[id] {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: badge).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("IDI \(id) · \(CitationFormatter(references: [r]).inline([r]))").font(.callout.weight(.semibold))
                        if r.provenance?.confirmedBy != nil { Image(systemName: "person.fill.checkmark").foregroundStyle(.green).font(.caption) }
                    }
                    Text(r.title).font(.callout).lineLimit(2)
                    if let extra { Text(extra).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .tag(id)
        }
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

@MainActor
enum ReviewWindow {
    static var window: NSWindow?
    static var selection: IDI?

    static var isOpen: Bool { window?.isVisible == true }

    /// `candidates` is accepted for callers that already have suggestions; the record
    /// panel finds matches itself for placeholders and unverified records.
    static func show(select id: IDI? = nil, candidates: [IdentCandidate] = []) {
        let config = RefWareConfig.load()
        guard let lib = config.library else {
            let a = NSAlert()
            a.messageText = "RefWare isn't set up"
            a.informativeText = "Run: refware config --library <path to library.json> --project UEF-XXXX"
            a.runModal()
            return
        }
        let store = MainWindow.store ?? LibraryStore(libURL: URL(fileURLWithPath: lib), project: config.project)
        MainWindow.store = store
        store.reload()
        NSApp.setActivationPolicy(.regular)
        let first = id ?? store.library.likelyDuplicates().first?.first ?? store.library.needsReview().first?.id
        // Rebuild the content so a requested record is selected.
        let view = ReviewView(store: store, selection: first)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "RefWare Review — \(config.project ?? "library")"
        w.contentViewController = NSHostingController(rootView: view)
        w.setFrameAutosaveName("RefWareReview")
        if !w.setFrameUsingName("RefWareReview") { w.center() }
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
