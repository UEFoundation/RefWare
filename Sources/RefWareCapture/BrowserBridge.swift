import Foundation

/// Lets the RefWare Chrome extension talk to this app ("native messaging") in every
/// Chrome-family browser installed. Runs at each launch, so a downloaded app works
/// without the install script, and the bridge follows the app if it's moved.
enum BrowserBridge {
    /// Fixed by the `key` in browser/chrome/manifest.json.
    static let extensionID = "gjhkilaogdpgoffbffmnmoeijkgjhccm"
    static let browsers = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
                           "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data"]

    static func register() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refware")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        let manifest: [String: Any] = [
            "name": "ai.uefoundation.refware",
            "description": "RefWare — send pages and PDFs to your reference library",
            "path": cli.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for b in browsers {
            let base = support.appendingPathComponent(b)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            let dir = base.appendingPathComponent("NativeMessagingHosts")
            let file = dir.appendingPathComponent("ai.uefoundation.refware.json")
            if (try? Data(contentsOf: file)) == data { continue }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
