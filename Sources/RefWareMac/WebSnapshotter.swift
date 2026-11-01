#if os(macOS)
import AppKit
import Foundation
import RefWareCore
import WebKit

public enum SnapshotError: Error, CustomStringConvertible {
    case loadFailed(String)
    case timedOut
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .loadFailed(let s): "page failed to load: \(s)"
        case .timedOut: "page took too long to load"
        case .httpStatus(let code): "the page returned HTTP \(code)"
        }
    }
}

/// Renders a page with WebKit (Safari's engine) and saves it as a PDF, so
/// web-only sources — press releases, blogs, docs — get an archival copy whose
/// text the quote verifier can search.
public struct WebSnapshotter: PageSnapshotter {
    public var settle: Duration
    public var timeout: Duration

    public init(settle: Duration = .seconds(2), timeout: Duration = .seconds(45)) {
        self.settle = settle
        self.timeout = timeout
    }

    public func snapshot(_ url: URL) async throws -> (pdf: Data, text: String) {
        try await Renderer(settle: settle, timeout: timeout).render(url)
    }
}

@MainActor
private final class Renderer: NSObject, WKNavigationDelegate {
    let settle: Duration, timeout: Duration
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var mainStatus: Int?

    init(settle: Duration, timeout: Duration) {
        self.settle = settle
        self.timeout = timeout
    }

    func render(_ url: URL) async throws -> (pdf: Data, text: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 1400), configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = self
        webView = web

        let limit = timeout
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            self?.finish(SnapshotError.timedOut)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            web.load(URLRequest(url: url, timeoutInterval: 30))
        }
        if let code = mainStatus, code >= 400 { throw SnapshotError.httpStatus(code) }
        // Let late scripts and challenge pages settle (a JS challenge may redirect to the real page).
        try await Task.sleep(for: settle)

        let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
        let pdf = try await web.pdf(configuration: WKPDFConfiguration())
        return (pdf, text)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            if navigationResponse.isForMainFrame { mainStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error {
            c.resume(throwing: error as? SnapshotError ?? SnapshotError.loadFailed(error.localizedDescription))
        } else {
            c.resume()
        }
    }
}
#endif
