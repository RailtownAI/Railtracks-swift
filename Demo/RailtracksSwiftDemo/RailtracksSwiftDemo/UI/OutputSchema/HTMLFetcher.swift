import Foundation
import WebKit

enum HTMLFetcherError: Error {
    case timeout
    case emptyContent
}

struct HTMLFetcher {
    /// `nonisolated`: read by `fetchText`'s default argument, which is checked outside any actor.
    /// Safe for a constant `Sendable` value.
    nonisolated static let defaultTimeout: Duration = .seconds(15)

    /// A helper function that grabs the text of a given URL
    @MainActor
    static func fetchText(from url: URL, timeout: Duration = defaultTimeout) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }

        if contentType.contains("text/html") {
            Log.trace("URL: \(url.absoluteString) — rendering with WKWebView (timeout: \(timeout))")
            return try await fetchWithWebView(html: text, baseURL: url, timeout: timeout)
        }

        Log.trace("URL: \(url.absoluteString) \nText: \(text)")
        return text
    }

    @MainActor
    private static func fetchWithWebView(html: String, baseURL: URL, timeout: Duration) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            WebViewLoader.start(html: html, baseURL: baseURL, timeout: timeout, continuation: continuation)
        }
    }
}

@MainActor
private final class WebViewLoader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let handlerName = "domStable"
    private static let domSettleDelay = 500  // ms of DOM silence → page is stable
    private static var pending: [ObjectIdentifier: WebViewLoader] = [:]

    private let continuation: CheckedContinuation<String, Error>
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    static func start(html: String, baseURL: URL, timeout: Duration, continuation: CheckedContinuation<String, Error>) {
        let loader = WebViewLoader(html: html, baseURL: baseURL, timeout: timeout, continuation: continuation)
        pending[ObjectIdentifier(loader)] = loader
    }

    private init(html: String, baseURL: URL, timeout: Duration, continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
        super.init()

        let controller = WKUserContentController()
        controller.add(self, name: Self.handlerName)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.navigationDelegate = self
        webView = view
        view.loadHTMLString(html, baseURL: baseURL)

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            Log.trace("WebViewLoader timed out for \(baseURL)")
            self.finish(throwing: HTMLFetcherError.timeout)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        // MutationObserver fires postMessage after domSettleDelay ms of DOM silence.
        // The initial setTimeout handles pages that are already stable when didFinish fires.
        let js = """
        (function() {
            var t;
            function send() {
                window.webkit.messageHandlers.\(Self.handlerName).postMessage(
                    document.body ? document.body.innerText : ''
                );
            }
            var obs = new MutationObserver(function() {
                clearTimeout(t);
                t = setTimeout(function() { obs.disconnect(); send(); }, \(Self.domSettleDelay));
            });
            obs.observe(document.body || document.documentElement,
                        { childList: true, subtree: true, characterData: true });
            t = setTimeout(function() { obs.disconnect(); send(); }, \(Self.domSettleDelay));
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(throwing: error)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let text = message.body as? String else { return }
        finish(with: text)
    }

    // MARK: - Private

    private func finish(with text: String) {
        guard !finished else { return }
        guard !text.isEmpty else {
            finish(throwing: HTMLFetcherError.emptyContent)
            return
        }
        finished = true
        Log.trace("WebViewLoader extracted \(text.count) chars from \(webView?.url?.absoluteString ?? "?")")
        cleanup()
        continuation.resume(returning: text)
    }

    private func finish(throwing error: Error) {
        guard !finished else { return }
        finished = true
        cleanup()
        continuation.resume(throwing: error)
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView?.navigationDelegate = nil
        webView = nil
        Self.pending.removeValue(forKey: ObjectIdentifier(self))
    }
}
