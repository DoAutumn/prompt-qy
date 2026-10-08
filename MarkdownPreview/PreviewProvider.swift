import Cocoa
import Quartz
import WebKit

/// View-based Quick Look preview — same async model as the notes search panel:
/// HTML paints immediately; images keep loading in the background.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var pendingHandler: ((Error?) -> Void)?
    private var handlerCalled = false
    /// Don't wait forever for slow remote images / didFinish.
    private var fallbackWork: DispatchWorkItem?
    /// Keep security-scoped access alive while async images load.
    private var scopedURLs: [URL] = []
    /// Bumps on every prepare so the 0.15s fallback ignores stale work.
    private var loadToken = 0
    /// Only finish for the navigation started by the current prepare.
    private var expectedNavigation: WKNavigation?

    deinit {
        releaseScopedAccess()
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // No search-jump script in QL — disable JS to shrink XSS surface.
        if #available(macOS 11.0, *) {
            let page = WKWebpagePreferences()
            page.allowsContentJavaScript = false
            config.defaultWebpagePreferences = page
        }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        wv.navigationDelegate = self
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = .windowBackgroundColor
        }
        self.webView = wv
        self.view = wv
        preferredContentSize = DocumentPreviewPage.preferredPreviewSize()
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        beginScopedAccess(for: url)

        fallbackWork?.cancel()
        fallbackWork = nil
        // Finish any in-flight QL request so rapid Space browsing doesn't hang.
        if pendingHandler != nil, !handlerCalled {
            handlerCalled = true
            let prev = pendingHandler
            pendingHandler = nil
            prev?(nil)
        }

        loadToken += 1
        let token = loadToken
        pendingHandler = handler
        handlerCalled = false
        expectedNavigation = nil

        do {
            let html = try DocumentPreviewPage.fullHTML(forFileAt: url)
            let base = url.deletingLastPathComponent()
            expectedNavigation = webView.loadHTMLString(html, baseURL: base)

            // Show the preview as soon as the document shell is up — do not wait
            // for every <img> (remote ones can stall for seconds).
            let work = DispatchWorkItem { [weak self] in
                guard let self, token == self.loadToken else { return }
                self.finish(nil)
            }
            fallbackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } catch {
            finish(error)
        }
    }

    private func beginScopedAccess(for fileURL: URL) {
        releaseScopedAccess()
        let dir = fileURL.deletingLastPathComponent()
        // Prefer directory scope so sibling attachments resolve; also keep the file.
        if dir.startAccessingSecurityScopedResource() {
            scopedURLs.append(dir)
        }
        if fileURL.startAccessingSecurityScopedResource() {
            scopedURLs.append(fileURL)
        }
    }

    private func releaseScopedAccess() {
        for u in scopedURLs {
            u.stopAccessingSecurityScopedResource()
        }
        scopedURLs = []
    }

    private func finish(_ error: Error?) {
        guard !handlerCalled else { return }
        handlerCalled = true
        fallbackWork?.cancel()
        fallbackWork = nil
        let handler = pendingHandler
        pendingHandler = nil
        handler?(error)
    }

    private func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, let expected = expectedNavigation else { return false }
        return navigation === expected
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrent(navigation) else { return }
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard isCurrent(navigation) else { return }
        if isCancellation(error) { return }
        finish(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isCurrent(navigation) else { return }
        if isCancellation(error) { return }
        finish(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow the initial loadHTMLString; block link clicks / subframe nav.
        if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }
}
