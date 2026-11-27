import Foundation

/// The pages' HTML, styles and scripts, from the app bundle.
@MainActor
enum WebResources {
    static let markdownCSS = text("markdown", "css")
    private static let detailCSS = text("detail", "css")
    private static let detailJS = text("detail", "js") + "\nwindow.PRDesk = PRDesk;"
    private static let highlightJS = [text("highlight.min", "js"), text("hljs-cmake.min", "js"), text("hljs-dockerfile.min", "js")]

    /// Mermaid, which draws the diagrams in bodies: megabytes, so only sent to a page that has one
    /// (`loadMermaid` in `detail.js`), and read from the bundle on first use.
    static let mermaidJS = text("mermaid.min", "js") + "\nPRDesk.mermaidLoaded();"

    static func scripts(for kind: WebDocument.Kind) -> [String] {
        (kind == .files ? highlightJS : []) + [detailJS]
    }

    static func page(_ kind: WebDocument.Kind) -> String {
        """
        <!doctype html>
        <html data-page="\(kind.rawValue)" data-repos="\(SyncEngine.repo) \(Parity.repo)"\(platformAttributes)><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">\(viewport)
        <style>\(markdownCSS)
        \(detailCSS)
        \(WebSymbols.css)</style></head>
        <body><main id="root"></main></body></html>
        """
    }

    /// The phone lays the page out at its own width, and sizes text itself rather than letting
    /// WebKit inflate some paragraphs (see `detail.css`).
    #if os(macOS)
        private static let platformAttributes = ""
        private static let viewport = ""
    #else
        private static let platformAttributes = #" data-platform="phone""#
        private static let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
    #endif

    private static func text(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("Missing web resource \(name).\(ext)")
            return ""
        }
        return text
    }
}

/// SF Symbols for the pages, as CSS masks (`<i class="sym s-eye-circle">`) colored by the text.
@MainActor
enum WebSymbols {
    static let names = [
        "arrow.up.right", "chevron.right", "checkmark.seal",
        "doc.text", "arrow.up.circle", "arrow.triangle.2.circlepath", "arrow.triangle.merge", "xmark.circle",
        "arrow.uturn.left.circle", "eye", "pencil.circle", "person.badge.plus", "xmark.seal", "tag", "link",
        "person.crop.circle.badge.checkmark", "pencil", "eye.circle", "circle",
        "plus.square", "minus.square", "arrow.right.square", "square.and.pencil", "face.smiling",
        "square", "checkmark.square.fill", "square.stack.3d.up",
    ]

    static func className(_ name: String) -> String {
        "s-" + name.replacingOccurrences(of: ".", with: "-")
    }

    static let css: String = names.compactMap { rule($0) }.joined(separator: "\n")

    /// The symbol as a mask, drawn by the platform (`WebImages.symbolPNG`).
    private static func rule(_ name: String) -> String? {
        guard let png = WebImages.symbolPNG(name) else { return nil }
        return ".\(className(name)) { --sym: url(data:image/png;base64,\(png.base64EncodedString())); }"
    }
}

extension String {
    /// Escaped for HTML text and attribute values.
    var htmlEscaped: String {
        guard contains(where: { "&<>\"'".contains($0) }) else { return self }
        var result = ""
        result.reserveCapacity(utf8.count + 16)
        for character in self {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
