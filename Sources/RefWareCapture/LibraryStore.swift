import AppKit
import Foundation
import RefWareCore
import RefWareMac
import SwiftUI

/// The window's view of the library. Shares `library.json` with the `refware`
/// CLI (and any agent using it): every edit re-reads the file, applies the change,
/// and saves — never writing back a stale copy — and the file is watched, so
/// changes made elsewhere appear within a couple of seconds.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var history = History()
    @Published var project: String?
    @Published var subproject: String?
    @Published var message: String?
    @Published var busy: String?
    @Published private(set) var loadedAt = Date()

    let libURL: URL
    var pdfDir: URL { Library.pdfDirectory(forLibraryAt: libURL) }
    private var stamps: (Date?, Date?) = (nil, nil)
    private var timer: Timer?
    private let config = RefWareConfig.load()

    init(libURL: URL, project: String?) {
        self.libURL = libURL
        self.project = project
        HistoryEvent.defaultActor = RefWareConfig.load().reviewer ?? NSFullUserName().split(separator: " ").compactMap(\.first).map(String.init).joined()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
    }

    /// Read fresh each time, so `refware config --reviewer` applies without restarting.
    var reviewer: String {
        RefWareConfig.load().reviewer ?? NSFullUserName().split(separator: " ").compactMap(\.first).map(String.init).joined()
    }
    var mailto: String? { config.mailto }

    var insights: LibraryInsights { LibraryInsights(library: library, history: history, project: project, subproject: subproject) }
    var projectNames: [String] { library.projects.keys.sorted() }
    var subprojects: [String] { project.flatMap { library.projects[$0]?.subprojects } ?? [] }

    func reload() {
        if let l = try? Library.load(from: libURL) { library = l }
        history = History.load(forLibraryAt: libURL)
        stamps = (modified(libURL), modified(History.url(forLibraryAt: libURL)))
        if let p = project, library.projects[p] == nil { project = library.projects.keys.sorted().first }
        loadedAt = Date()
    }

    // MARK: Attaching documents

    /// PDFs in the library folder that no record points to.
    var unattachedPDFs: [String] { library.unattachedPDFs(in: pdfDir) }

    /// Records captured in the last day (newest first), for "use this capture's PDF".
    func recentCaptures(excluding id: IDI) -> [(IDI, Date)] {
        let cutoff = Date().addingTimeInterval(-86_400)
        var seen = Set<IDI>(), out: [(IDI, Date)] = []
        for e in history.events(.pdfAdded) where e.date > cutoff {
            for raw in e.idis {
                let i = library.canonical(raw)
                if i != id, library[i]?.fileName != nil, seen.insert(i).inserted { out.append((i, e.date)) }
            }
        }
        return out
    }

    /// Puts a PDF file on a record (copied, or moved for files already in the PDFs folder).
    /// A PDF the record already had is kept in PDFs/merged/, never deleted.
    @discardableResult
    func attach(file src: URL, to id: IDI, move: Bool = false) -> Bool {
        var name = ""
        let ok = mutate { lib in
            let r = try lib.attachPDF(from: src, to: id, pdfDirectory: pdfDir, move: move)
            name = r.name
            return "Attached \(src.lastPathComponent) to IDI \(id) as PDFs/\(r.name)\(r.replaced.map { " — the previous PDF (\($0)) is kept in PDFs/merged/" } ?? "")."
        }
        if ok { record(HistoryEvent(kind: .pdfAdded, project: project, title: "PDFs/\(name)", idis: [id], source: src.path)) }
        return ok
    }

    /// Uses a captured record's PDF for `target`. A new or placeholder capture is merged into
    /// the target (its number retired); an established, different record keeps its PDF and the
    /// target gets a copy.
    func useCaptured(_ captured: IDI, for target: IDI) {
        guard let c = library[captured], let file = c.fileName else { return }
        // Merge only a placeholder, or a fresh capture nothing else uses yet; never an established record.
        let inUse = library.projects.values.contains { p in
            p.quotes.contains { $0.reference == captured } || p.claims.contains { $0.references.contains(captured) }
        }
        let fresh = (c.added.map { Date().timeIntervalSince($0) < 7_200 } ?? false) && !inUse
        if c.authors.isEmpty || c.year == nil || fresh {
            var note = ""
            if mutate({ lib in
                let m = try lib.merge(captured, into: target, pdfDirectory: pdfDir, preferIncomingPDF: true)
                note = "IDI \(m.retired) → IDI \(m.survivor)"
                return "The captured PDF is now IDI \(target)'s. IDI \(captured) was merged in and retired; any previous PDF is in PDFs/merged/."
            }) { record(HistoryEvent(kind: .merge, project: project, title: note, idis: [target, captured])) }
        } else {
            attach(file: pdfDir.appendingPathComponent(file), to: target)
        }
    }

    private func reloadIfChanged() {
        let now = (modified(libURL), modified(History.url(forLibraryAt: libURL)))
        if now.0 != stamps.0 || now.1 != stamps.1 { reload() }
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Fresh load → change → save. The closure returns the message to show.
    @discardableResult
    func mutate(_ body: (inout Library) throws -> String) -> Bool {
        HistoryEvent.defaultActor = reviewer
        do {
            var fresh = try Library.load(from: libURL)
            let note = try body(&fresh)
            try fresh.save(to: libURL)
            reload()
            message = note
            return true
        } catch {
            message = "\(error)"
            reload()
            return false
        }
    }

    func record(_ e: HistoryEvent) {
        var e = e
        e.actor = reviewer
        History.record(e, forLibraryAt: libURL)
        reload()
    }

    var cascade: SearchCascade {
        let http = URLSessionHTTPClient()
        return SearchCascade(crossref: CrossrefClient(http: http, mailto: config.mailto), http: http)
    }

    // MARK: Freeze

    var isFrozen: Bool { library.frozen != nil }

    func setFrozen(_ on: Bool) {
        do {
            if on {
                try Library.freeze(at: libURL, by: reviewer, note: nil)
                record(HistoryEvent(kind: .freeze, title: "Frozen by \(reviewer)"))
                message = "Library frozen. Builds still work (and are logged); edits are refused until you untick Freeze."
            } else {
                try Library.unfreeze(at: libURL)
                record(HistoryEvent(kind: .freeze, title: "Unfrozen by \(reviewer)"))
                message = "Library unfrozen."
            }
        } catch { message = "\(error)" }
        reload()
    }
}
