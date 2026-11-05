import AppKit

/// The pages' HTML, styles and scripts, from the app bundle.
@MainActor
enum WebResources {
    static let markdownCSS = text("markdown", "css")
    private static let detailCSS = text("detail", "css")
    private static let detailJS = text("detail", "js") + "\nwindow.PRDesk = PRDesk;"
    private static let highlightJS = [text("highlight.min", "js"), text("hljs-cmake.min", "js"), text("hljs-dockerfile.min", "js")]

    static func scripts(for kind: WebDocument.Kind) -> [String] {
        (kind == .files ? highlightJS : []) + [detailJS]
    }

    static func page(_ kind: WebDocument.Kind) -> String {
        """
        <!doctype html>
        <html data-page="\(kind.rawValue)" data-repos="\(SyncEngine.repo) \(Parity.repo)"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>\(markdownCSS)
        \(detailCSS)
        \(WebSymbols.css)</style></head>
        <body><main id="root"></main></body></html>
        """
    }

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
        "arrow.up.right", "chevron.right", "checkmark.seal", "hand.thumbsup.fill", "hand.thumbsdown.fill",
        "doc.text", "arrow.up.circle", "arrow.triangle.2.circlepath", "arrow.triangle.merge", "xmark.circle",
        "arrow.uturn.left.circle", "eye", "pencil.circle", "person.badge.plus", "xmark.seal", "tag", "link",
        "person.crop.circle.badge.checkmark", "pencil", "eye.circle", "circle",
        "plus.square", "minus.square", "arrow.right.square", "square.and.pencil", "face.smiling",
        "square", "checkmark.square.fill",
    ]

    static func className(_ name: String) -> String {
        "s-" + name.replacingOccurrences(of: ".", with: "-")
    }

    static let css: String = names.compactMap { rule($0) }.joined(separator: "\n")

    /// Draws the symbol centered in a square at twice its size, for a sharp mask.
    private static func rule(_ name: String) -> String? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        else { return nil }
        let side = ceil(max(symbol.size.width, symbol.size.height))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        symbol.draw(in: NSRect(
            x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
            width: symbol.size.width, height: symbol.size.height
        ))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
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
