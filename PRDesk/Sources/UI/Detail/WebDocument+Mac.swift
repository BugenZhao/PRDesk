import AppKit
import SwiftUI
import WebKit

/// The Mac's side of `WebDocument`: the find bar, right-click menus, and the view hosting the page.
extension WebDocument {
    /// Runs a Find command (show the bar, next, previous) on the page on screen, if any.
    static func performFind(_ action: NSTextFinder.Action) {
        guard let document = documents.allObjects.first(where: { $0.loadedWebView?.window != nil }) else { return }
        // Diffs are built as they come near the screen; find needs the rest too.
        if action == .showFindInterface, document.kind == .files { document.run("PRDesk.buildExpandedFiles()") }
        document.textFinder.performAction(action)
        // The finder installs its bar but, unlike when closing it, doesn't say it is visible.
        if action == .showFindInterface { document.textFinder.findBarContainer?.isFindBarVisible = true }
    }

    /// Sets up a new web view: no background of its own, and the find bar's client.
    func prepare(_ webView: DocumentWebView) {
        webView.setValue(false, forKey: "drawsBackground")
        textFinder.client = webView
    }

    /// Pops up the menu the page asked for where it was right-clicked.
    func showMenu(_ request: MenuRequest, at point: CGPoint) {
        let menu: NSMenu? = switch request {
        case let .login(login): loginMenu?(login)
        case let .reaction(subject): reactionMenu?(subject)
        case let .file(path, url, viewed): fileMenu(path: path, url: url, viewed: viewed)
        }
        guard let menu else { return }
        let location = NSPoint(x: point.x, y: webView.isFlipped ? point.y : webView.bounds.height - point.y)
        menu.popUp(positioning: nil, at: location, in: webView)
    }

    private func fileMenu(path: String, url: String, viewed: Bool?) -> NSMenu {
        let menu = NSMenu()
        if let viewed, let script = Self.jsonLiteral(path).map({ "PRDesk.toggleViewed(\($0))" }) {
            menu.addItem(ClosureMenuItem("Viewed", state: viewed ? .on : .off) { [weak self] in self?.run(script) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Copy Path") { Platform.copy(path) })
        if let link = URL(string: url), !url.isEmpty {
            menu.addItem(ClosureMenuItem("Open on GitHub") { Platform.open(link) })
        }
        return menu
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

    /// The list's single-key shortcuts (j/k, w/b/s/m, 1/2/3, ⌥e, …) keep working while reading the
    /// page; the page has no text fields of its own to type into.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty,
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
