import AppKit
import WebKit

/// Images the shared web pages need, drawn with AppKit.
@MainActor
enum WebImages {
    static func isDark(_ webView: WKWebView) -> Bool {
        webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// An SF Symbol centered in a square at twice its size, as a PNG for a sharp CSS mask.
    static func symbolPNG(_ name: String) -> Data? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        else { return nil }
        let side = ceil(max(symbol.size.width, symbol.size.height))
        return png(side: side, appearance: nil) {
            symbol.draw(in: NSRect(
                x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            ))
        }
    }

    /// The badge's image (a bundled logo or brand tile) fitted into a square of `side` points.
    static func badgePNG(_ badge: Badge, side: CGFloat, isDark: Bool) -> Data? {
        guard let image = badge.image else { return nil }
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return png(side: side, appearance: NSAppearance(named: isDark ? .darkAqua : .aqua)) {
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }

    /// Draws into a square bitmap of `side` points at twice the size, for Retina screens.
    private static func png(side: CGFloat, appearance: NSAppearance?, draw: () -> Void) -> Data? {
        var data: Data?
        withoutActuallyEscaping(draw) { draw in
            let render = {
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { return }
                bitmap.size = NSSize(width: side, height: side)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                draw()
                NSGraphicsContext.restoreGraphicsState()
                data = bitmap.representation(using: .png, properties: [:])
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(render) } else { render() }
        }
        return data
    }
}
