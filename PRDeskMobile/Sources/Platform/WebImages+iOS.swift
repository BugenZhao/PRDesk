import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import WebKit

/// Images the shared web pages need, drawn with UIKit.
@MainActor
enum WebImages {
    static func isDark(_ webView: WKWebView) -> Bool {
        webView.traitCollection.userInterfaceStyle == .dark
    }

    /// An SF Symbol centered in a square at twice its size, as a PNG for a sharp CSS mask.
    static func symbolPNG(_ name: String) -> Data? {
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        else { return nil }
        let side = ceil(max(symbol.size.width, symbol.size.height))
        return png(side: side, style: .unspecified) {
            symbol.draw(in: CGRect(
                x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            ))
        }
    }

    /// The badge's image (a bundled logo or brand tile) fitted into a square of `side` points.
    static func badgePNG(_ badge: Badge, side: CGFloat, isDark: Bool) -> Data? {
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        guard let image = BadgeImages.image(for: badge, style: style) else { return nil }
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return png(side: side, style: style) {
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }

    private static func png(side: CGFloat, style: UIUserInterfaceStyle, draw: () -> Void) -> Data? {
        let format = UIGraphicsImageRendererFormat(for: UITraitCollection(userInterfaceStyle: style))
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in draw() }
    }
}

/// Org badges as images: the bundled logo (without color for a secondary badge), or a brand tile
/// for orgs that only have a text logo.
@MainActor
enum BadgeImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for badge: Badge, style: UIUserInterfaceStyle) -> UIImage? {
        let key = "\(badge.org.rawValue)/\(badge.isSecondary)/\(style.rawValue)"
        if let image = cache[key] { return image }
        let image = colored(badge, style: style).flatMap { badge.isSecondary && badge.org.brandTile == nil ? grayscale($0) : $0 }
        cache[key] = image
        return image
    }

    /// The brand tile or the logo in its colors, whether or not the badge is secondary.
    private static func colored(_ badge: Badge, style: UIUserInterfaceStyle) -> UIImage? {
        if let tile = badge.org.brandTile { return brandTile(tile.text, hex: tile.hex) }
        guard let name = badge.org.logoAsset else { return nil }
        return UIImage(named: name, in: nil, compatibleWith: UITraitCollection(userInterfaceStyle: style))
    }

    private static var bitmaps: [String: UIImage] = [:]

    /// The badge drawn at the pixels it is shown at. SwiftUI drew a logo (an SVG) at its own
    /// size and scaled the pixels to the badge's, which left stairs at every edge, and smoother
    /// scaling or a bitmap a few times larger still blurred them a little: drawn at the size
    /// shown, the edges are the vector's own.
    static func bitmap(for badge: Badge, style: UIUserInterfaceStyle, side: CGFloat, scale: CGFloat) -> UIImage? {
        let pixels = max(1, (side * scale).rounded())
        let key = "\(badge.org.rawValue)/\(badge.isSecondary)/\(style.rawValue)/\(pixels)/\(scale)"
        if let image = bitmaps[key] { return image }
        let square = pixels / scale
        if let tile = badge.org.brandTile {
            let image = brandTile(tile.text, hex: tile.hex, side: square, scale: scale)
            bitmaps[key] = image
            return image
        }
        guard let source = colored(badge, style: style) else { return nil }
        let fit = min(square / max(source.size.width, 1), square / max(source.size.height, 1))
        let size = CGSize(width: source.size.width * fit, height: source.size.height * fit)
        let format = UIGraphicsImageRendererFormat(for: UITraitCollection(userInterfaceStyle: style))
        format.scale = scale
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: square, height: square), format: format).image { context in
            context.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(x: (square - size.width) / 2, y: (square - size.height) / 2, width: size.width, height: size.height))
        }
        let image = badge.isSecondary && badge.org.brandTile == nil ? grayscale(drawn) ?? drawn : drawn
        bitmaps[key] = image
        return image
    }

    /// `text` in white on a rounded square of the color `hex`, shrunk to fit.
    private static func brandTile(_ text: String, hex: String, side: CGFloat = 13, scale: CGFloat? = nil) -> UIImage {
        let value = Int(hex, radix: 16) ?? 0
        let color = UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        if let scale { format.scale = scale }
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 3 / 13).fill()
            var font = UIFont.systemFont(ofSize: rect.height * 8 / 13, weight: .heavy)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            let room = rect.width * 0.88
            if width > room { font = UIFont.systemFont(ofSize: font.pointSize * room / width, weight: .heavy) }
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: [.font: font, .foregroundColor: UIColor.white]
            )
        }
    }

    private static func grayscale(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.saturation = 0
        guard let output = filter.outputImage, let cgImage = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
