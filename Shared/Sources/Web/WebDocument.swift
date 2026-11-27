#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
import WebKit

/// One page of the detail pane (the conversation or the files diff) in a single web view.
///
/// The page loads once and lives as long as the detail pane: showing another item sends it new
/// JSON, which it patches in by block id. Scrolling, text selection and find are the browser's, so
/// long timelines and diffs scroll at full speed, and nothing has to measure web content heights.
/// What differs by platform (the view hosting it, menus, find) is in each app's `WebDocument+…`.
@MainActor
final class WebDocument: NSObject {
    enum Kind: String {
        case timeline, files
    }

    /// A menu the page asks for: right-clicking (or long-pressing) a person, a reaction button or
    /// a file's header.
    enum MenuRequest {
        case login(String)
        case reaction(subject: String)
        /// `viewed` is the file's "Viewed" mark, nil when the page offers none.
        case file(path: String, url: String, viewed: Bool?)
    }

    let kind: Kind
    /// Opens issue or PR `number` of a repository (`owner/name`) in the app, for a link to it.
    var openItem: ((String, Int) -> Void)?
    /// Adds or takes back the viewer's reaction on a node, for clicking a reaction under it.
    var toggleReaction: ((Reaction.Content, String) -> Void)?
    /// Ticks or clears a file's "Viewed" mark, by path.
    var setFileViewed: ((String, Bool) -> Void)?

    #if os(iOS)
        /// Shows a menu the page asks for at a point of the window, set by the view showing the page.
        var menuHandler: ((MenuRequest, CGPoint) -> Void)?
    #endif

    #if os(macOS)
        /// The menu for right-clicking a person, set by the view showing the page.
        var loginMenu: ((String) -> NSMenu)?
        /// The menu of reactions to add on a comment, review or description, by node id.
        var reactionMenu: ((String) -> NSMenu?)?

        /// The find bar over the page (⌘F), WebKit being the text finder's client.
        let textFinder: NSTextFinder = {
            let finder = NSTextFinder()
            finder.isIncrementalSearchingEnabled = true
            finder.incrementalSearchingShouldDimContentView = false
            return finder
        }()
    #endif

    /// Every page's base URL, so relative links in GitHub's HTML resolve.
    static let baseURL = URL(string: "https://github.com/")!

    init(kind: Kind) {
        self.kind = kind
        super.init()
        Self.documents.add(self)
    }

    /// Every document, to find the one on screen.
    static let documents = NSHashTable<WebDocument>.weakObjects()

    /// Created on first use: views holding a document are initialized far more often than shown.
    private(set) var loadedWebView: DocumentWebView?
    var webView: DocumentWebView {
        if let loadedWebView { return loadedWebView }
        let webView = makeWebView()
        loadedWebView = webView
        return webView
    }

    private var isReady = false
    private var shownKey: String?
    private var sentPayload: String?
    /// The latest render, waiting for the page to be ready.
    private var pendingRender: String?
    /// Settings scripts by name, run again whenever the page (re)loads.
    private var settings: [String: String] = [:]
    /// One-off scripts waiting for the page, in order.
    private var pendingScripts: [String] = []
    /// A comment to scroll to (GitHub's fragment, `#issuecomment-…`) once the document for `key`
    /// shows it, which may take the fresh detail after the cached one; gives up after a few renders.
    private var pendingAnchor: (key: String, fragment: String, tries: Int)?

    /// Shows `payload`, a JSON document for the page; a new `key` starts the page over.
    func render(key: String, payload: String) {
        guard payload != sentPayload else { return }
        sentPayload = payload
        if key != shownKey {
            shownKey = key
            if pendingAnchor?.key != key { pendingAnchor = nil }
            // Hidden until the new document is in, rather than showing the previous item's.
            setPageShown(false)
        }
        guard isReady else {
            pendingRender = payload
            return
        }
        send(payload)
    }

    private func send(_ payload: String) {
        let function = kind == .timeline ? "renderTimeline" : "renderFiles"
        webView.callAsyncJavaScript(
            "PRDesk.\(function)(JSON.parse(payload))",
            arguments: ["payload": payload], in: nil, in: .page
        ) { [weak self] result in
            if case let .failure(error) = result {
                NSLog("PR Desk: rendering the \(self?.kind.rawValue ?? "") page failed: \(error)")
            }
            self?.setPageShown(true)
            #if os(macOS)
                self?.textFinder.noteClientStringWillChange()
            #endif
            self?.revealPendingAnchor()
        }
    }

    private func setPageShown(_ shown: Bool) {
        #if os(macOS)
            webView.alphaValue = shown ? 1 : 0
        #else
            webView.alpha = shown ? 1 : 0
        #endif
    }

    /// Scrolls the conversation of `key` to a comment, now if it shows it, or after a later render.
    func reveal(fragment: String, key: String) {
        pendingAnchor = (key, fragment, 0)
        if isReady, shownKey == key, pendingRender == nil, sentPayload != nil { revealPendingAnchor() }
    }

    private func revealPendingAnchor() {
        guard kind == .timeline, let anchor = pendingAnchor, anchor.key == shownKey else { return }
        webView.callAsyncJavaScript(
            "return PRDesk.revealAnchor(fragment)", arguments: ["fragment": anchor.fragment], in: nil, in: .page
        ) { [weak self] result in
            guard let self, pendingAnchor?.key == anchor.key, pendingAnchor?.fragment == anchor.fragment else { return }
            let found = (try? result.get()) as? Bool == true
            if found || anchor.tries >= 2 { pendingAnchor = nil } else { pendingAnchor?.tries += 1 }
        }
    }

    /// Runs a script now, or once the page is ready.
    func run(_ script: String) {
        if isReady {
            webView.evaluateJavaScript(script)
        } else {
            pendingScripts.append(script)
        }
    }

    /// Runs a script that sets up the page, now and after any reload.
    func setting(_ name: String, _ script: String) {
        guard settings[name] != script else { return }
        settings[name] = script
        run(script)
    }

    private func pageReady() {
        isReady = true
        for script in settings.values { webView.evaluateJavaScript(script) }
        if let pendingRender {
            self.pendingRender = nil
            send(pendingRender)
        }
        for script in pendingScripts { webView.evaluateJavaScript(script) }
        pendingScripts = []
    }

    private func makeWebView() -> DocumentWebView {
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(self), name: "prdesk")
        for script in WebResources.scripts(for: kind) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(AvatarSchemeHandler.shared, forURLScheme: AvatarSchemeHandler.scheme)
        #if os(iOS)
            // An iPad takes pages as a desktop would by default, and then sizes their text by
            // rules of its own: the page's zoom moved its boxes and left the text as small as
            // it was. As a phone's, the text follows the zoom.
            configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        #endif
        let webView = DocumentWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
            webView.isInspectable = true
        #endif
        prepare(webView)
        load(webView)
        return webView
    }

    private func load(_ webView: WKWebView) {
        isReady = false
        webView.loadHTMLString(WebResources.page(kind), baseURL: Self.baseURL)
    }

    /// `value` as a JavaScript literal.
    static func jsonLiteral(_ value: some Encodable) -> String? {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}

extension WebDocument: WKScriptMessageHandler {
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let point = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)
        switch type {
        case "ready":
            pageReady()
        case "loadMermaid":
            webView.evaluateJavaScript(WebResources.mermaidJS)
        case "loginMenu":
            if let login = body["login"] as? String { showMenu(.login(login), at: point) }
        case "reactionMenu":
            if let subject = body["subject"] as? String { showMenu(.reaction(subject: subject), at: point) }
        case "react":
            if let subject = body["subject"] as? String, let content = (body["content"] as? String).flatMap(Reaction.Content.init) {
                toggleReaction?(content, subject)
            }
        case "openProfile":
            if let login = body["login"] as? String { AppModel.openProfile(login) }
        case "openItem":
            if let repo = body["repo"] as? String, let number = body["number"] as? Int { openItem?(repo, number) }
        case "fileMenu":
            if let path = body["path"] as? String {
                showMenu(.file(path: path, url: body["url"] as? String ?? "", viewed: body["viewed"] as? Bool), at: point)
            }
        case "fileViewed":
            if let path = body["path"] as? String, let viewed = body["viewed"] as? Bool { setFileViewed?(path, viewed) }
        default:
            break
        }
    }
}

extension WebDocument: WKNavigationDelegate, WKUIDelegate {
    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.navigationType == .linkActivated {
            // In-page anchors (footnotes) scroll; every other link opens in the browser.
            if url.fragment != nil, url.absoluteString.hasPrefix(Self.baseURL.absoluteString + "#") { return .allow }
            Platform.open(url)
            return .cancel
        }
        // Only the page itself loads here: a dropped file or a frame in a body never replaces it.
        return url == Self.baseURL || url.scheme == "about" ? .allow : .cancel
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Platform.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Start over with the last document; the page's own state (scroll, expansion) is gone.
        pendingRender = sentPayload
        shownKey = nil
        load(webView)
    }
}

/// Breaks the retain cycle between a content controller and its handler.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
