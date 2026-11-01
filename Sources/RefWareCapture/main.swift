import AppKit
import Foundation
import RefWareCore
import RefWareMac

/// RefWare Capture — a background helper (no Dock icon, no window).
///
/// • Opened with a `refware://capture?url=…[&project=UEF-XXXX][&claim=C9]` link
///   (browser bookmarklet, claims report) → captures that URL.
/// • Opened directly (Spotlight, Dock, a keyboard shortcut) → captures the front
///   tab of the frontmost browser — this also works for PDFs, where bookmarklets can't run.
///
/// Uses the library and project set with `refware config`. Reports by notification
/// and in ~/Library/Logs/RefWare/capture.log, then quits.
@MainActor
final class CaptureApp: NSObject, NSApplicationDelegate {
    private var handledURL = false
    private var previousApp: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        BrowserBridge.register()
        // A URL event arrives right after launch when opened by link; give it a moment.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !handledURL else { return }
            // Opened directly (Dock, Spotlight, Finder): the library window.
            // Front-tab capture is `refware://capture` with no URL (extension, bookmark, hotkey).
            MainWindow.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock / Launchpad / Finder click while RefWare is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    /// Quit after a capture unless a window is open.
    func finishIfIdle() {
        if !ReviewWindow.isOpen && !MainWindow.isOpen && !ClaimsWindow.isOpen { NSApp.terminate(nil) }
    }

    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Library Window", action: #selector(openLibrary), keyEquivalent: "l")
        appMenu.addItem(withTitle: "Review Window", action: #selector(openReview), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Verify Claims", action: #selector(openClaims), keyEquivalent: "k")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Copy Bookmarklet", action: #selector(copyBookmarklet), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit RefWare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        // Text fields only get ⌘X/⌘C/⌘V/⌘Z through these menu items.
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func openLibrary() { MainWindow.show() }
    @objc func openReview() { ReviewWindow.show() }
    @objc func openClaims() { ClaimsWindow.show() }

    @objc func copyBookmarklet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bookmarklet.source, forType: .string)
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        handledURL = true
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s) else { return }
        let q = Dictionary((comps.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        if comps.host == "review" {
            ReviewWindow.show(select: q["idi"].flatMap { Int($0) })
            return
        }
        if comps.host == "claims" {
            ClaimsWindow.show()
            return
        }
        if comps.host == "library" || comps.host == "open" {
            MainWindow.show(select: q["idi"].flatMap { Int($0) })
            return
        }
        Task {
            if let url = q["url"], !url.isEmpty {
                await run(url: url, project: q["project"], claim: q["claim"])
            } else if let url = frontBrowserURL() {
                await run(url: url, project: q["project"], claim: q["claim"])
            } else {
                notify("RefWare", "No URL to capture.")
            }
            finishIfIdle()
        }
    }

    // MARK: Capture

    func run(url: String, project: String?, claim: String?) async {
        let config = RefWareConfig.load()
        guard let libPath = config.library, let project = project ?? config.project else {
            notify("RefWare — not set up", "Run: refware config --library <path> --project UEF-XXXX")
            log("not configured; skipped \(url)")
            return
        }
        let libURL = URL(fileURLWithPath: libPath)
        notify("RefWare", "Capturing \(URL(string: url)?.host ?? url)…")
        do {
            var library = try Library.load(from: libURL)
            let http = URLSessionHTTPClient()
            let capture = Capture(cascade: SearchCascade(crossref: CrossrefClient(http: http, mailto: config.mailto), http: http), http: http,
                                  snapshotter: WebSnapshotter(), unpaywall: config.mailto.map { UnpaywallClient(http: http, email: $0) })
            let r = try await capture.run(url, project: project, claim: claim, library: &library, pdfDirectory: Library.pdfDirectory(forLibraryAt: libURL))
            try library.save(to: libURL)
            let ref = r.reference
            if r.needsReview {
                notify("RefWare · IDI \(ref.id) needs a decision", r.candidates.isEmpty ? "Couldn't identify this PDF — opening RefWare Review." : "Possible matches found — opening RefWare Review.")
                log("\(project) IDI \(ref.id) — needs review (\(r.candidates.count) suggestion(s)) — \(url)")
                ReviewWindow.show(select: ref.id, candidates: r.candidates)
                return
            }
            let who = CitationFormatter(references: [ref]).inline([ref])
            let doc = r.document.map { $0 == .alreadyAttached ? "PDF already in library" : "saved \($0.rawValue)" } ?? (r.documentNote != nil ? "no free PDF — attach by hand" : "no document")
            let verified = (ref.provenance?.verified == true ? "" : " · unverified metadata") + (r.matchEvidence.map { " · matched: \($0)" } ?? "")
            notify("RefWare · \(r.isNew ? "Added" : "Updated") IDI \(ref.id) \(who)", "\(doc)\(verified)\(r.linkedClaim.map { " · → \($0)" } ?? "")")
            // Tell any open window, so the capture can be shown — or attached to the record being resolved.
            History.recordCapture(r, url: url, project: project, libraryURL: libURL)
            MainWindow.store?.reload()
            UIEvents.shared.capture = .init(idi: ref.id, summary: "\(who) — \(ref.title.prefix(70)) · \(doc)", isNew: r.isNew)
            log("\(project) IDI \(ref.id) \(who) — \(ref.title) — \(doc)\(verified)\(r.linkedClaim.map { " — claim \($0)" } ?? "") — \(url)")
        } catch {
            notify("RefWare — couldn't capture", String(describing: error))
            log("FAILED \(url): \(error)")
        }
    }

    // MARK: Front browser tab

    func frontBrowserURL() -> String? {
        let scripts: [String: String] = [
            "com.apple.Safari": #"tell application "Safari" to return URL of front document"#,
            "com.apple.SafariTechnologyPreview": #"tell application "Safari Technology Preview" to return URL of front document"#,
            "com.google.Chrome": #"tell application "Google Chrome" to return URL of active tab of front window"#,
            "com.brave.Browser": #"tell application "Brave Browser" to return URL of active tab of front window"#,
            "com.microsoft.edgemac": #"tell application "Microsoft Edge" to return URL of active tab of front window"#,
            "company.thebrowser.Browser": #"tell application "Arc" to return URL of active tab of front window"#,
        ]
        // The app that was in front when we launched, then any running browser.
        var order: [String] = []
        if let id = previousApp?.bundleIdentifier, scripts[id] != nil { order.append(id) }
        order += NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { scripts[$0] != nil && !order.contains($0) }
        for id in order {
            var error: NSDictionary?
            if let url = NSAppleScript(source: scripts[id]!)?.executeAndReturnError(&error).stringValue, url.hasPrefix("http") {
                return url
            }
        }
        return nil
    }

    // MARK: Feedback

    func notify(_ title: String, _ message: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var error: NSDictionary?
        NSAppleScript(source: "display notification \"\(esc(message))\" with title \"\(esc(title))\"")?.executeAndReturnError(&error)
    }

    func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RefWare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("capture.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp)  \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "RefWare Capture"
        alert.informativeText = """
        Open a page or PDF in your browser, then launch RefWare Capture (Spotlight, or a keyboard shortcut) — \
        the front tab goes to your RefWare library with its metadata.

        Or add the “Send to RefWare” bookmarklet to your bookmarks bar (Copy Bookmarklet, then paste it as a bookmark’s address).

        Library: \(RefWareConfig.load().library ?? "not set — run refware config")
        Project: \(RefWareConfig.load().project ?? "not set")
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Bookmarklet")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Bookmarklet.source, forType: .string)
        }
    }
}

enum Bookmarklet {
    static let source = "javascript:(()=>{location.href='refware://capture?url='+encodeURIComponent(location.href)})()"
}

let app = NSApplication.shared
let delegate = CaptureApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
