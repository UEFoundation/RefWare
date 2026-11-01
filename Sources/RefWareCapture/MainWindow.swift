import AppKit
import RefWareCore
import SwiftUI

// MARK: Sections (GUI design: S. M. Hykin, 2026-10-12)

enum MenuSection: String, CaseIterable, Identifiable {
    case stats = "Stats", sort = "Sort", status = "Status", actions = "Actions",
         exports = "Exports", records = "Records", projects = "Projects"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .stats: Color(red: 0.96, green: 0.62, blue: 0.52)
        case .sort: Color(red: 0.62, green: 0.84, blue: 0.30)
        case .status: Color(red: 0.97, green: 0.83, blue: 0.40)
        case .actions: Color(red: 0.40, green: 0.56, blue: 0.95)
        case .exports: Color(red: 0.88, green: 0.45, blue: 0.52)
        case .records: Color(red: 0.30, green: 0.68, blue: 0.32)
        case .projects: Color(red: 0.98, green: 0.62, blue: 0.20)
        }
    }
}

enum TableFilter: Hashable {
    case all, hasPDF, unverifiedPDFs, verifiedNoClaims, quotesNotExported, verifiedClaims, needsReview
    case notHit(LibraryInsights.BuildScope), quotesNotHit(LibraryInsights.BuildScope)
    case ids(Set<IDI>, String)

    var label: String {
        switch self {
        case .all: "All records"
        case .hasPDF: "Records with a PDF"
        case .unverifiedPDFs: "PDFs with unverified metadata"
        case .verifiedNoClaims: "Verified PDFs without verified claims"
        case .quotesNotExported: "Records with verified Qs not yet exported"
        case .verifiedClaims: "Records with verified quotations (IDI-Qs)"
        case .needsReview: "Needs review"
        case .notHit(let s): "Not cited in a C/R build (\(s.rawValue.lowercased()))"
        case .quotesNotHit(let s): "Records with IDI-Qs not cited in a C/R build (\(s.rawValue.lowercased()))"
        case .ids(_, let l): l
        }
    }
}

enum YesNo: String, CaseIterable, Identifiable { case any = "Any", yes = "Yes", no = "No"; var id: String { rawValue } }

enum SortKey: String, CaseIterable, Identifiable {
    case idi = "IDI", author = "Author", pubDate = "Pub date", importDate = "Import date", journal = "Journal (A–Z)",
         title = "Title (A–Z)", pubType = "Pub type", buildDate = "Cite/Ref build date"
    var id: String { rawValue }
}

@MainActor
final class ViewState: ObservableObject {
    @Published var expanded: Set<MenuSection> = [.stats, .status]
    @Published var tabs = false               // collapsed submenus as tabs under the table
    @Published var activeTab: MenuSection?
    @Published var swapped = false            // active card on the left, menu beside it
    @Published var filter: TableFilter = .all
    @Published var sortKey: SortKey = .author
    @Published var ascending = true
    @Published var search = ""
    @Published var hasClaims: YesNo = .any
    @Published var exported: YesNo = .any
    @Published var showSubprojects = false
    @Published var selection: IDI?
    @Published var buildScope: LibraryInsights.BuildScope = .ever

    func toggle(_ s: MenuSection) {
        if expanded.contains(s) { expanded.remove(s) } else { expanded.insert(s); activeTab = s }
    }
}

// MARK: Rows

struct Row: Identifiable, Hashable {
    let id: IDI
    let author: String
    let title: String
    let year: Int
    let journal: String
    let doi: String
    let pubType: String
    let hasPDF: Bool
    let verified: Bool
    let checked: Bool
    let quotes: Int
    let importDate: Date
    let lastBuild: Date
    let subprojects: String
}

func searchText(_ r: Reference) -> String {
    var parts: [String] = [r.title, "idi \(r.id)"]
    if let p = r.publication { parts.append(p) }
    if let d = r.doi { parts.append(d) }
    if let u = r.url { parts.append(u) }
    if let y = r.year { parts.append(String(y)) }
    for a in r.authors { parts.append(a.family) }
    return parts.joined(separator: " ").lowercased()
}

@MainActor
func rows(_ store: LibraryStore, _ v: ViewState) -> [Row] {
    let i = store.insights
    var refs = i.references
    switch v.filter {
    case .all: break
    case .hasPDF: refs = i.withPDF
    case .unverifiedPDFs: refs = i.unverifiedPDFs
    case .verifiedNoClaims: refs = i.verifiedPDFsWithoutClaims
    case .quotesNotExported: let ids = Set(i.quotesNotExported.map(\.reference)); refs = refs.filter { ids.contains($0.id) }
    case .verifiedClaims: refs = refs.filter { i.hasVerifiedClaims($0.id) }
    case .needsReview: let ids = Set(store.library.needsReview().map(\.id)); refs = refs.filter { ids.contains($0.id) }
    case .notHit(let s): refs = i.notHit(s)
    case .quotesNotHit(let s): let ids = Set(i.quotesNotHit(s).map(\.reference)); refs = refs.filter { ids.contains($0.id) }
    case .ids(let set, _): refs = refs.filter { set.contains($0.id) }
    }
    if v.hasClaims != .any { refs = refs.filter { i.hasVerifiedClaims($0.id) == (v.hasClaims == .yes) } }
    if v.exported != .any { refs = refs.filter { i.claimsExported($0.id) == (v.exported == .yes) } }
    let q = v.search.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
        let words = q.split(separator: " ").map(String.init)
        refs = refs.filter { r in
            let hay = searchText(r)
            return words.allSatisfy { hay.contains($0) }
        }
    }
    let quoteCounts = Dictionary(grouping: i.verifiedQuotes, by: \.reference).mapValues(\.count)
    var out = refs.map { r -> Row in
        let a = r.authors
        let author = a.isEmpty ? "—" : a.count == 1 ? a[0].family : a.count == 2 ? "\(a[0].family) & \(a[1].family)" : "\(a[0].family) et al."
        return Row(id: r.id, author: author, title: r.title, year: r.year ?? 0, journal: r.publication ?? "", doi: r.doi ?? "",
                   pubType: r.publicationType.rawValue, hasPDF: r.fileName != nil, verified: r.provenance?.verified == true, checked: r.provenance?.confirmedBy != nil,
                   quotes: quoteCounts[r.id] ?? 0, importDate: r.importDate ?? .distantPast, lastBuild: i.lastBuild(of: r.id) ?? .distantPast,
                   subprojects: r.projects.first { $0.project == store.project }?.subprojects.joined(separator: ", ") ?? "")
    }
    let asc = v.ascending
    func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
    func text(_ a: String, _ b: String) -> Bool {
        let c = a.localizedCaseInsensitiveCompare(b)
        return asc ? c == .orderedAscending : c == .orderedDescending
    }
    out.sort { a, b in
        switch v.sortKey {
        case .idi: cmp(a.id, b.id)
        case .author: text(a.author, b.author)
        case .pubDate: a.year == b.year ? text(a.author, b.author) : cmp(a.year, b.year)
        case .importDate: cmp(a.importDate, b.importDate)
        case .journal: a.journal == b.journal ? text(a.author, b.author) : text(a.journal, b.journal)
        case .title: text(a.title, b.title)
        case .pubType: a.pubType == b.pubType ? text(a.author, b.author) : text(a.pubType, b.pubType)
        case .buildDate: cmp(a.lastBuild, b.lastBuild)
        }
    }
    return out
}

// MARK: Window

struct MainView: View {
    @ObservedObject var store: LibraryStore
    @StateObject var v = ViewState()
    @ObservedObject var events = UIEvents.shared

    var body: some View {
        HStack(spacing: 0) {
            if v.swapped, let card = activeCard {
                SectionCard(section: card, store: store, v: v).frame(width: 300)
                Divider()
            }
            TitleCard(store: store, v: v).frame(width: 230)
            Divider()
            if !v.tabs && !v.expanded.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(MenuSection.allCases.filter { v.expanded.contains($0) }) { s in
                            SectionCard(section: s, store: store, v: v)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 310)
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
            }
            VStack(spacing: 0) {
                if let n = events.capture { CaptureBanner(store: store, selection: $v.selection, notice: n, onShow: { v.filter = .all; v.search = "" }) }
                ResourceView(store: store, v: v)
                if v.tabs && !v.expanded.isEmpty { TabStrip(store: store, v: v) }
            }
        }
        .inspector(isPresented: Binding(get: { v.selection != nil }, set: { if !$0 { v.selection = nil } })) {
            if let id = v.selection, store.library[id] != nil {
                RecordInspector(store: store, id: id).inspectorColumnWidth(min: 380, ideal: 460, max: 700)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.message != nil || store.busy != nil {
                HStack(spacing: 8) {
                    if let b = store.busy { ProgressView().controlSize(.small); Text(b) } else { Image(systemName: "info.circle") }
                    if let m = store.message { Text(m).lineLimit(2).textSelection(.enabled) }
                    Spacer()
                    if store.message != nil { Button("Dismiss") { store.message = nil }.buttonStyle(.borderless) }
                }
                .padding(10).background(.bar)
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .onChange(of: events.select) { _, s in if let s { v.filter = .all; v.selection = s; events.select = nil } }
    }

    var activeCard: MenuSection? { v.activeTab.flatMap { v.expanded.contains($0) ? $0 : nil } ?? v.expanded.sorted { $0.rawValue < $1.rawValue }.first }
}

struct TitleCard: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RefWare").font(.system(size: 30, weight: .semibold, design: .serif))
            Picker("Project", selection: Binding(get: { store.project ?? "" }, set: { store.project = $0.isEmpty ? nil : $0; store.subproject = nil })) {
                Text("Whole library").tag("")
                ForEach(store.projectNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Subdirectories?", isOn: $v.showSubprojects)
                if v.showSubprojects {
                    Picker("Sub-project", selection: Binding(get: { store.subproject ?? "" }, set: { store.subproject = $0.isEmpty ? nil : $0 })) {
                        Text("All sub-projects").tag("")
                        ForEach(store.subprojects, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().disabled(store.subprojects.isEmpty)
                    if store.subprojects.isEmpty { Text("No sub-projects yet — add one under Actions.").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Freeze?", isOn: Binding(get: { store.isFrozen }, set: { on in confirmFreeze(on) }))
                if let f = store.library.frozen {
                    Text("❄︎ Frozen \(f.on.formatted(date: .abbreviated, time: .omitted)) by \(f.by)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(MenuSection.allCases) { s in
                    Button { v.toggle(s) } label: {
                        HStack {
                            Text(s.rawValue).font(.system(size: 19, weight: .medium, design: .rounded)).foregroundStyle(s.color)
                            Spacer()
                            Image(systemName: v.expanded.contains(s) ? "minus" : "plus").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            HStack {
                Picker("", selection: $v.tabs) {
                    Image(systemName: "rectangle.split.3x1").tag(false).help("Submenus as stacked cards")
                    Image(systemName: "rectangle.bottomthird.inset.filled").tag(true).help("Submenus as tabs under the table")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 90)
                Button { v.swapped.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap the menu and the active submenu").disabled(v.expanded.isEmpty)
            }
            CreditLine()
        }
        .padding(16)
    }

    func confirmFreeze(_ on: Bool) {
        let a = NSAlert()
        a.messageText = on ? "Freeze the library?" : "Unfreeze the library?"
        a.informativeText = on
            ? "The library becomes read-only — no edits, merges, imports or captures — so a submitted reference list can't drift. Cite/ref builds still work and are logged. Your drafting Claude will get a clear “library is frozen” message if it tries to change anything."
            : "Edits, merges and imports will be allowed again."
        a.addButton(withTitle: on ? "Freeze" : "Unfreeze")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { store.setFrozen(on) }
    }
}

struct ResourceView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        let data = rows(store, v)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Resource View").font(.headline)
                if v.filter != .all {
                    HStack(spacing: 4) {
                        Text(v.filter.label)
                        Button { v.filter = .all } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Text("\(data.count) record\(data.count == 1 ? "" : "s")").foregroundStyle(.secondary).font(.callout)
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh — updated \(store.loadedAt.formatted(date: .omitted, time: .standard)). The view also refreshes by itself when the library changes.")
                TextField("Search authors, titles, journals, DOIs…", text: $v.search).textFieldStyle(.roundedBorder).frame(width: 280)
            }
            .padding(10)
            Table(data, selection: $v.selection) {
                TableColumn("IDI") { r in Text("\(r.id)").monospacedDigit() }.width(40)
                TableColumn("Author") { r in Text(r.author) }.width(min: 90, ideal: 130)
                TableColumn("Title") { r in Text(r.title).lineLimit(2) }.width(min: 200, ideal: 340)
                TableColumn("Year") { r in Text(r.year == 0 ? "n.d." : String(r.year)) }.width(46)
                TableColumn("Journal") { r in Text(r.journal).lineLimit(1) }.width(min: 80, ideal: 160)
                TableColumn("DOI") { r in Text(r.doi).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }.width(min: 60, ideal: 130)
                TableColumn("") { r in
                    HStack(spacing: 4) {
                        Image(systemName: r.hasPDF ? "doc.fill" : "doc").foregroundStyle(r.hasPDF ? .primary : .tertiary).help(r.hasPDF ? "PDF in library" : "No PDF")
                        Image(systemName: r.verified ? "checkmark.seal.fill" : "exclamationmark.triangle").foregroundStyle(r.verified ? Color.green : Color.orange)
                            .help(r.verified ? "Verified metadata" : "Unverified metadata")
                        if r.checked { Image(systemName: "person.fill.checkmark").foregroundStyle(.green).help("Checked against the source by a person") }
                        if r.quotes > 0 { Text("Q\(r.quotes)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("\(r.quotes) verified quote(s)") }
                    }
                }.width(86)
                TableColumn("Last build") { r in Text(r.lastBuild == .distantPast ? "—" : r.lastBuild.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }.width(80)
                TableColumn("Sub-projects") { r in Text(r.subprojects).foregroundStyle(.secondary).lineLimit(1) }.width(min: 0, ideal: v.showSubprojects ? 110 : 0)
            }
        }
    }
}

struct TabStrip: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var v: ViewState

    var body: some View {
        VStack(spacing: 0) {
            if let active = v.activeTab, v.expanded.contains(active), !v.swapped {
                ScrollView { SectionCard(section: active, store: store, v: v, showHeader: false).padding(10) }
                    .frame(height: 260)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
            HStack(spacing: 2) {
                ForEach(MenuSection.allCases.filter { v.expanded.contains($0) }) { s in
                    Button { v.activeTab = v.activeTab == s ? nil : s } label: {
                        Text(s.rawValue).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.black.opacity(0.8))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(s.color.opacity(v.activeTab == s ? 1 : 0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(.bar)
        }
    }
}

// MARK: Window controller

@MainActor
enum MainWindow {
    static var window: NSWindow?
    /// Shared by every RefWare window (library, review, claims) so they never disagree.
    static var store: LibraryStore?

    static var isOpen: Bool { window?.isVisible == true }

    static func show(select id: IDI? = nil) {
        let config = RefWareConfig.load()
        guard let lib = config.library else {
            let a = NSAlert()
            a.messageText = "RefWare isn't set up"
            a.informativeText = "Run in Terminal: refware config --library <path to library.json> --project UEF-XXXX"
            a.runModal()
            return
        }
        NSApp.setActivationPolicy(.regular)
        if let window, let store, window.contentViewController != nil {
            store.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let s = store ?? LibraryStore(libURL: URL(fileURLWithPath: lib), project: config.project)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "RefWare"
        w.contentViewController = NSHostingController(rootView: MainView(store: s))
        w.setFrameAutosaveName("RefWareLibrary")
        if !w.setFrameUsingName("RefWareLibrary") { w.center() }
        w.isReleasedWhenClosed = false
        store = s
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// "Just captured" — so a capture from the browser is visible, and can be attached
/// to the record you were resolving instead of standing alone.
struct CaptureBanner: View {
    @ObservedObject var store: LibraryStore
    @Binding var selection: IDI?
    let notice: UIEvents.CaptureNotice
    var onShow: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.isNew ? "Captured — new record IDI \(notice.idi)" : "Already in your library as IDI \(notice.idi)").font(.callout.bold())
                Text(notice.summary).font(.caption).lineLimit(1)
            }
            Spacer()
            Button("Show") { onShow(); selection = notice.idi; UIEvents.shared.capture = nil }
            if let target = selection, target != notice.idi, store.library[target] != nil {
                Button("Attach to IDI \(target)") {
                    store.useCaptured(notice.idi, for: target)
                    selection = target
                    UIEvents.shared.capture = nil
                }
                .buttonStyle(.borderedProminent)
                .help("Use this capture's PDF for the record you have selected. A new capture is merged into it; an established record keeps its own PDF and IDI \(target) gets a copy.")
            }
            Button { UIEvents.shared.capture = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
    }
}
