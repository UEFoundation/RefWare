import Foundation

/// Chrome native-messaging host: the extension sends {"action":"capture","url":…} (or
/// {"action":"review"}), and RefWare is told directly — no refware:// link in the browser,
/// so no permission prompt and no helper tab. Chrome launches this binary with the
/// extension's origin as its argument and speaks length-prefixed JSON on stdin/stdout.
func nativeHost() -> Never {
    func reply(_ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        var len = UInt32(data.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &len, count: 4))
        FileHandle.standardOutput.write(data)
    }
    let header = FileHandle.standardInput.readData(ofLength: 4)
    guard header.count == 4 else { exit(0) }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    let body = FileHandle.standardInput.readData(ofLength: Int(length))
    guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        reply(["ok": false, "error": "unreadable message"]); exit(0)
    }
    var link: String
    switch msg["action"] as? String {
    case "review": link = "refware://review"
    case "library": link = "refware://library"
    default:
        guard let url = msg["url"] as? String, url.hasPrefix("http") else { reply(["ok": false, "error": "no http(s) URL"]); exit(0) }
        var c = URLComponents(string: "refware://capture")!
        c.queryItems = [URLQueryItem(name: "url", value: url)]
        link = c.url!.absoluteString
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [link]
    do {
        try p.run()
        p.waitUntilExit()
        reply(p.terminationStatus == 0 ? ["ok": true] : ["ok": false, "error": "RefWare didn't open (status \(p.terminationStatus)) — is RefWare.app installed?"])
    } catch {
        reply(["ok": false, "error": "\(error)"])
    }
    exit(0)
}
