import AppKit
import SwiftUI
import WebKit

/// Renders GitHub's `bodyHTML` for one comment in a self-sizing web view.
///
/// The surrounding timeline is native; only the body is HTML, so code blocks, tables,
/// images and `<details>` look as on GitHub. The view is exactly as tall as its content,
/// and forwards scrolling to the enclosing native scroll view.
struct HTMLBodyView: View {
    let id: String
    let html: String

    @State private var height: CGFloat

    init(id: String, html: String) {
        self.id = id
        self.html = html
        _height = State(initialValue: HeightCache.shared[id] ?? 20)
    }

    var body: some View {
        WebBody(html: html) { newHeight in
            guard abs(newHeight - height) > 0.5 else { return }
            height = newHeight
            HeightCache.shared[id] = newHeight
        }
        .frame(height: height)
    }
}

/// Last measured heights, so recycled rows don't jump while re-measuring.
@MainActor
private final class HeightCache {
    static let shared = HeightCache()
    private var heights: [String: CGFloat] = [:]

    subscript(id: String) -> CGFloat? {
        get { heights[id] }
        set { heights[id] = newValue }
    }
}

private struct WebBody: NSViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeight: onHeight)
    }

    func makeNSView(context: Context) -> PassthroughWebView {
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(context.coordinator), name: "height")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.load(html, into: webView)
    }

    /// Fill whatever is offered rather than the web view's own fitting size; the measured
    /// content height is applied by the caller.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: PassthroughWebView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onHeight: (CGFloat) -> Void
        private var loadedHTML: String?

        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
        }

        func load(_ html: String, into webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            webView.loadHTMLString(HTMLTemplate.page(html), baseURL: URL(string: "https://github.com/"))
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if let height = message.body as? Double {
                onHeight(ceil(height))
            }
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The body itself loads in place; every link opens in the browser.
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Lets the outer native scroll view handle scrolling; the body never scrolls itself.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Breaks the retain cycle between the content controller and its handler.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

enum HTMLTemplate {
    static func page(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>\(css)</style></head>
        <body><div id="content">\(body)</div>
        <script>
          const content = document.getElementById('content');
          const post = () => window.webkit.messageHandlers.height.postMessage(content.getBoundingClientRect().height);
          new ResizeObserver(post).observe(content);
          window.addEventListener('load', post);
          document.querySelectorAll('img').forEach(img => img.addEventListener('load', post));
          post();
        </script></body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
    body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.5; color: CanvasText; overflow-wrap: anywhere; }
    #content { display: flow-root; }
    #content > :first-child { margin-top: 0; }
    #content > :last-child { margin-bottom: 0; }
    p, ul, ol, pre, table, blockquote, details { margin: 0 0 8px; }
    ul, ol { padding-left: 22px; }
    a { color: -apple-system-control-accent; text-decoration: none; }
    a:hover { text-decoration: underline; }
    h1, h2, h3, h4 { margin: 12px 0 6px; line-height: 1.25; }
    h1 { font-size: 17px; } h2 { font-size: 15px; } h3, h4 { font-size: 13px; }
    code, pre, tt { font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { background: rgba(127,127,127,.15); padding: 1px 4px; border-radius: 4px; }
    pre { background: rgba(127,127,127,.12); padding: 8px 10px; border-radius: 6px; white-space: pre-wrap; }
    pre code { background: none; padding: 0; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    td, th { border: 1px solid rgba(127,127,127,.3); padding: 3px 8px; }
    blockquote { padding-left: 10px; border-left: 3px solid rgba(127,127,127,.35); color: GrayText; }
    details summary { cursor: pointer; }
    hr { border: none; border-top: 1px solid rgba(127,127,127,.3); }
    input[type=checkbox] { margin: 0 4px 0 0; }
    .user-mention, .team-mention { font-weight: 600; }
    .pl-k, .pl-kos { color: #cf222e; } .pl-s, .pl-pds, .pl-sr { color: #0a3069; }
    .pl-c { color: #6e7781; } .pl-en, .pl-e { color: #8250df; } .pl-c1, .pl-v { color: #0550ae; }
    .pl-smi, .pl-s1 { color: inherit; } .pl-mi1 { color: #116329; background: #dafbe1; } .pl-md { color: #82071e; background: #ffebe9; }
    @media (prefers-color-scheme: dark) {
      .pl-k, .pl-kos { color: #ff7b72; } .pl-s, .pl-pds, .pl-sr { color: #a5d6ff; }
      .pl-c { color: #8b949e; } .pl-en, .pl-e { color: #d2a8ff; } .pl-c1, .pl-v { color: #79c0ff; }
      .pl-mi1 { color: #aff5b4; background: #033a16; } .pl-md { color: #ffdcd7; background: #67060c; }
    }
    """
}
