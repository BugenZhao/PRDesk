import AppKit

/// One visual piece of a table cell. Runs are laid out left to right on a single line.
indirect enum CellRun {
    /// Text; a `flexible` run absorbs any shortage of width by truncating.
    /// `maxWidth` caps a non-flexible run, which then truncates.
    case text(String, color: NSColor = .labelColor, font: NSFont = CellFont.regular, flexible: Bool = false, maxWidth: CGFloat? = nil)
    /// Small rounded tag tinted with `color`.
    case chip(String, color: NSColor)
    case dot(NSColor)
    /// A dot drawn as an outline.
    case ring(NSColor)
    /// Fixed width, so what follows lines up from row to row; the run (if any) sits at its start,
    /// or its end when `trailing`.
    case slot(CellRun?, width: CGFloat, trailing: Bool = false)
    case symbol(String, color: NSColor, pointSize: CGFloat = 11)
    /// An item state icon (asset template or SF Symbol), tinted.
    case icon(StateIcon, color: NSColor)
    /// Differently colored pieces of one string that truncate together, e.g. a dimmed title prefix.
    case segments([(text: String, color: NSColor)], font: NSFont = CellFont.regular, flexible: Bool = false)
    /// Small rounded image, e.g. an org avatar.
    case image(NSImage)
    /// A person's avatar in a circle; a placeholder circle while it loads.
    case avatar(NSImage?)
}

/// NSFont is immutable, so sharing these across isolation domains is safe.
enum CellFont {
    nonisolated(unsafe) static let regular = NSFont.systemFont(ofSize: 12)
    nonisolated(unsafe) static let regularBold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static let small = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let chip = NSFont.systemFont(ofSize: 10, weight: .medium)
}

/// A cell that draws its runs directly, which keeps dense tables cheap to scroll.
final class RunsCellView: NSTableCellView {
    enum Alignment { case leading, trailing }

    var runs: [CellRun] = [] { didSet { needsDisplay = true } }
    var alignment: Alignment = .leading { didSet { needsDisplay = true } }

    private let spacing: CGFloat = 4
    private let inset: CGFloat = 2
    private static let dotSize: CGFloat = 7
    private static let symbolSize: CGFloat = 13
    private static let imageSize: CGFloat = 13
    private static let chipHeight: CGFloat = 14
    private static let chipPadding: CGFloat = 4

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private var emphasized: Bool { backgroundStyle == .emphasized }

    override func draw(_: NSRect) {
        guard !runs.isEmpty else { return }
        let natural = runs.map(naturalWidth)
        let gaps = spacing * CGFloat(runs.count - 1)
        let available = bounds.width - 2 * inset - gaps
        let fixed = zip(runs, natural).reduce(0) { $0 + ($1.0.isFlexible ? 0 : $1.1) }
        let widths = zip(runs, natural).map { run, width in
            run.isFlexible ? max(0, min(width, available - fixed)) : width
        }
        let total = widths.reduce(0, +) + gaps
        var x = alignment == .trailing ? bounds.maxX - inset - total : inset
        for (run, width) in zip(runs, widths) {
            draw(run, in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func naturalWidth(_ run: CellRun) -> CGFloat {
        switch run {
        case let .text(string, _, font, _, maxWidth):
            min(ceil(string.size(withAttributes: [.font: font]).width), maxWidth ?? .infinity)
        case let .chip(string, _):
            ceil(string.size(withAttributes: [.font: CellFont.chip]).width) + 2 * Self.chipPadding
        case .dot, .ring:
            Self.dotSize
        case let .slot(_, width, _):
            width
        case .symbol, .icon:
            Self.symbolSize
        case .image, .avatar:
            Self.imageSize
        case let .segments(parts, font, _):
            ceil(Self.attributed(parts, font: font, override: nil).size().width)
        }
    }

    private static func attributed(_ parts: [(text: String, color: NSColor)], font: NSFont, override: NSColor?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString()
        for part in parts {
            result.append(NSAttributedString(string: part.text, attributes: [
                .font: font,
                .foregroundColor: override ?? part.color,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    private func draw(_ run: CellRun, in rect: NSRect) {
        guard rect.width > 0 else { return }
        switch run {
        case let .text(string, color, font, _, _):
            drawText(string, color: emphasized ? .alternateSelectedControlTextColor : color, font: font, in: rect)

        case let .segments(parts, font, _):
            let text = Self.attributed(parts, font: font, override: emphasized ? .alternateSelectedControlTextColor : nil)
            let lineHeight = ceil(font.ascender - font.descender)
            text.draw(
                with: NSRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )

        case let .chip(string, color):
            let chipRect = NSRect(x: rect.minX, y: rect.midY - Self.chipHeight / 2, width: rect.width, height: Self.chipHeight)
            (emphasized ? NSColor.white.withAlphaComponent(0.22) : color.withAlphaComponent(0.16)).setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3).fill()
            drawText(
                string,
                color: emphasized ? .alternateSelectedControlTextColor : color,
                font: CellFont.chip,
                in: chipRect.insetBy(dx: Self.chipPadding, dy: 0)
            )

        case let .dot(color):
            let size = Self.dotSize
            (emphasized ? NSColor.alternateSelectedControlTextColor : color).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)).fill()

        case let .ring(color):
            let size = Self.dotSize
            (emphasized ? NSColor.alternateSelectedControlTextColor : color).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size).insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()

        case let .slot(run, _, trailing):
            guard let run else { return }
            let width = min(naturalWidth(run), rect.width)
            draw(run, in: NSRect(x: trailing ? rect.maxX - width : rect.minX, y: rect.minY, width: width, height: rect.height))

        case let .symbol(name, color, pointSize):
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: pointSize < 11 ? .bold : .medium)
                .applying(.init(paletteColors: [emphasized ? .alternateSelectedControlTextColor : color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            else { return }
            let size = image.size
            image.draw(in: NSRect(
                x: rect.minX + (rect.width - size.width) / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))

        case let .image(image):
            drawImage(image, in: rect)

        case let .avatar(image):
            let size = Self.imageSize
            let circle = NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size))
            if let image {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                image.draw(in: circle.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.quaternaryLabelColor.setFill()
                circle.fill()
            }

        case let .icon(.symbol(name), color):
            draw(.symbol(name, color: color), in: rect)

        case let .icon(.asset(name), color):
            guard let image = NSImage(named: name) else { return }
            let size = Self.symbolSize
            let target = NSRect(x: rect.minX + (rect.width - size) / 2, y: rect.midY - size / 2, width: size, height: size)
            // Tint the template: draw it in a transparency layer, then fill the color over its alpha.
            let context = NSGraphicsContext.current!.cgContext
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (emphasized ? NSColor.alternateSelectedControlTextColor : color).setFill()
            target.fill(using: .sourceIn)
            context.endTransparencyLayer()
        }
    }

    private func drawImage(_ image: NSImage, in rect: NSRect) {
        let size = Self.imageSize
        let target = NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: target, xRadius: 3, yRadius: 3).addClip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(_ string: String, color: NSColor, font: NSFont, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        let lineHeight = ceil(font.ascender - font.descender)
        attributed.draw(
            with: NSRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}

private extension CellRun {
    var isFlexible: Bool {
        switch self {
        case let .text(_, _, _, flexible, _), let .segments(_, _, flexible): flexible
        default: false
        }
    }
}
