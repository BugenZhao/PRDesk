import AppKit
import SwiftUI
import WebKit

/// One page of the detail pane (the conversation or the files diff) in a single web view.
///
/// The page loads once and lives as long as the detail pane: showing another item sends it new
/// JSON, which it patches in by block id. Scrolling, text selection and find are the browser's, so
/// long timelines and diffs scroll at full speed, and nothing has to measure web content heights.
@MainActor
final class WebDocument: NSObject {
    enum Kind: String {
        case timeline, files
    }

    let kind: Kind
    /// The menu for right-clicking a person, set by the view showing the page.
    var loginMenu: ((String) -> NSMenu)?
    /// Opens issue or PR `number` of a repository (`owner/name`) in the app, for a link to it.
    var openItem: ((String, Int) -> Void)?
    /// The menu of reactions to add on a comment, review or description, by node id.
    var reactionMenu: ((String) -> NSMenu?)?
    /// Adds or takes back the viewer's reaction on a node, for clicking a reaction under it.
    var toggleReaction: ((Reaction.Content, String) -> Void)?

    /// Every page's base URL, so relative links in GitHub's HTML resolve.
    static let baseURL = URL(string: "https://github.com/")!

    init(kind: Kind) {
        self.kind = kind
        super.init()
        Self.documents.add(self)
    }

    /// Every document, to find the one on screen for the Find commands.
    private static let documents = NSHashTable<WebDocument>.weakObjects()

    /// The find bar over the page (⌘F), WebKit being the text finder's client.
    let textFinder: NSTextFinder = {
        let finder = NSTextFinder()
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        return finder
    }()

    /// Runs a Find command (show the bar, next, previous) on the page on screen, if any.
    static func performFind(_ action: NSTextFinder.Action) {
        guard let document = documents.allObjects.first(where: { $0._webView?.window != nil }) else { return }
        // Diffs are built as they come near the screen; find needs the rest too.
        if action == .showFindInterface, document.kind == .files { document.run("PRDesk.buildExpandedFiles()") }
        document.textFinder.performAction(action)
        // The finder installs its bar but, unlike when closing it, doesn't say it is visible.
        if action == .showFindInterface { document.textFinder.findBarContainer?.isFindBarVisible = true }
    }

    /// Created on first use: views holding a document are initialized far more often than shown.
    private var _webView: DocumentWebView?
    var webView: DocumentWebView {
        if let _webView { return _webView }
        let webView = makeWebView()
        _webView = webView
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

    /// Shows `payload`, a JSON document for the page; a new `key` starts the page over.
    func render(key: String, payload: String) {
        guard payload != sentPayload else { return }
        sentPayload = payload
        if key != shownKey {
            shownKey = key
            // Hidden until the new document is in, rather than showing the previous item's.
            webView.alphaValue = 0
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
            self?.webView.alphaValue = 1
            self?.textFinder.noteClientStringWillChange()
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
        let webView = DocumentWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
            webView.isInspectable = true
        #endif
        textFinder.client = webView
        load(webView)
        return webView
    }

    private func load(_ webView: WKWebView) {
        isReady = false
        webView.loadHTMLString(WebResources.page(kind), baseURL: Self.baseURL)
    }

    private func popUp(_ menu: NSMenu, x: Double, y: Double) {
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    private func fileMenu(path: String, url: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        if let link = URL(string: url), !url.isEmpty {
            menu.addItem(ClosureMenuItem("Open on GitHub") { NSWorkspace.shared.open(link) })
        }
        return menu
    }
}

extension WebDocument: WKScriptMessageHandler {
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let x = body["x"] as? Double ?? 0
        let y = body["y"] as? Double ?? 0
        switch type {
        case "ready":
            pageReady()
        case "loginMenu":
            if let login = body["login"] as? String, let menu = loginMenu?(login) { popUp(menu, x: x, y: y) }
        case "reactionMenu":
            if let subject = body["subject"] as? String, let menu = reactionMenu?(subject) { popUp(menu, x: x, y: y) }
        case "react":
            if let subject = body["subject"] as? String, let content = (body["content"] as? String).flatMap(Reaction.Content.init) {
                toggleReaction?(content, subject)
            }
        case "openProfile":
            if let login = body["login"] as? String { AppModel.openProfile(login) }
        case "openItem":
            if let repo = body["repo"] as? String, let number = body["number"] as? Int { openItem?(repo, number) }
        case "fileMenu":
            if let path = body["path"] as? String { popUp(fileMenu(path: path, url: body["url"] as? String ?? ""), x: x, y: y) }
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
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // Only the page itself loads here: a dropped file or a frame in a body never replaces it.
        return url == Self.baseURL || url.scheme == "about" ? .allow : .cancel
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Start over with the last document; the page's own state (scroll, expansion) is gone.
        pendingRender = sentPayload
        shownKey = nil
        load(webView)
    }
}

/// The page's web view, without the browser-only items of WebKit's context menu.
final class DocumentWebView: WKWebView {
    private static let unwantedMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierInspectElement",
    ]

    /// Read-only, so the find bar offers no Replace.
    override var isEditable: Bool { false }

    /// The list's single-key shortcuts (j/k, w/b/s/m, 1/2/3, …) keep working while reading the
    /// page; the page has no text fields of its own to type into.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.charactersIgnoringModifiers != "\u{1b}",
           let table = window?.contentView?.firstDescendant(of: ItemNSTableView.self),
           table.keyHandler?(event) == true
        {
            return
        }
        super.keyDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        #if DEBUG
            let unwanted = Self.unwantedMenuItems.subtracting(["WKMenuItemIdentifierInspectElement"])
        #else
            let unwanted = Self.unwantedMenuItems
        #endif
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        // Tidy separators left at the ends or doubled up.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

/// Hosts a document's web view, which moves into whichever container is showing.
struct WebDocumentView: NSViewRepresentable {
    let document: WebDocument
    let key: String
    let payload: String

    func makeNSView(context _: Context) -> WebDocumentContainer {
        let container = WebDocumentContainer()
        container.host(document)
        document.render(key: key, payload: payload)
        return container
    }

    func updateNSView(_ container: WebDocumentContainer, context _: Context) {
        container.host(document)
        document.render(key: key, payload: payload)
    }

    /// Fill whatever is offered; the page scrolls itself.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: WebDocumentContainer, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }
}

/// The web view with the find bar above it when shown.
final class WebDocumentContainer: NSView, @MainActor NSTextFinderBarContainer {
    private weak var webView: NSView?

    override var isFlipped: Bool { true }

    func host(_ document: WebDocument) {
        let webView = document.webView
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        addSubview(webView)
        self.webView = webView
        document.textFinder.findBarContainer = self
        arrange()
    }

    var findBarView: NSView? {
        didSet {
            if let oldValue {
                oldValue.removeFromSuperview()
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: oldValue)
            }
            if let findBarView {
                findBarView.isHidden = !findBarShown
                addSubview(findBarView)
                // The bar settles its height after it is shown, without saying so.
                findBarView.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(findBarFrameChanged),
                    name: NSView.frameDidChangeNotification, object: findBarView
                )
            }
            arrange()
        }
    }

    @objc private func findBarFrameChanged() {
        arrange()
    }

    private var findBarShown = false

    /// Spelled out for AppKit, which hides the bar through `setFindBarVisible:`, a name Swift
    /// wouldn't give this property on its own.
    var isFindBarVisible: Bool {
        @objc(isFindBarVisible) get { findBarShown }
        @objc(setFindBarVisible:) set {
            findBarShown = newValue
            findBarView?.isHidden = !newValue
            arrange()
        }
    }

    func findBarViewDidChangeHeight() {
        arrange()
    }

    func contentView() -> NSView? {
        webView
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        arrange()
    }

    /// The find bar across the top, the page below it.
    private func arrange() {
        var top: CGFloat = 0
        if findBarShown, let findBarView {
            top = findBarView.frame.height
            let frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
            if findBarView.frame != frame { findBarView.frame = frame }
        }
        let frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        if webView?.frame != frame { webView?.frame = frame }
    }
}

/// Serves `prdesk-avatar://avatar/<login>` from the app's avatar cache, so pages show avatars
/// already on disk at once, and `prdesk-avatar://badge/<org>` as the list draws that badge.
@MainActor
final class AvatarSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = AvatarSchemeHandler()
    static let scheme = "prdesk-avatar"

    static func url(for login: String) -> String {
        "\(scheme)://avatar/\(login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login)"
    }

    static func url(for badge: Badge) -> String {
        "\(scheme)://badge/\(badge.org.rawValue)\(badge.isSecondary ? "-secondary" : "")"
    }

    private var running: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        let appearance = webView.effectiveAppearance
        Task {
            let data = if url.host == "badge" { await Self.badgeData(name, appearance: appearance) } else { await AvatarCache.data(for: name) }
            guard running.remove(id) != nil else { return }
            guard let data else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": Self.mimeType(of: data), "Cache-Control": "max-age=86400"]
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// The badge's image (a bundled logo, or the org's avatar), drawn for the page's appearance.
    private static func badgeData(_ name: String, appearance: NSAppearance) async -> Data? {
        let isSecondary = name.hasSuffix("-secondary")
        guard let org = Org(rawValue: isSecondary ? String(name.dropLast("-secondary".count)) : name) else { return nil }
        let badge = Badge(org: org, source: "", secondaryName: isSecondary ? "" : nil)
        guard let image = badge.image else { return await AvatarCache.data(for: org.avatarLogin) }
        return png(image, side: 26, appearance: appearance)
    }

    /// Draws `image` fitted into a square, at twice the size for Retina screens.
    private static func png(_ image: NSImage, side: CGFloat, appearance: NSAppearance) -> Data? {
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            bitmap.size = NSSize(width: side, height: side)
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            data = bitmap.representation(using: .png, properties: [:])
        }
        return data
    }

    private static func mimeType(of data: Data) -> String {
        switch data.first {
        case 0xFF: "image/jpeg"
        case 0x47: "image/gif"
        default: "image/png"
        }
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

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
        self.state = state
        if let systemImage { image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
