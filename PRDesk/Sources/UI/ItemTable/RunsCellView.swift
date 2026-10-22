import AppKit

/// One visual piece of a table cell. Runs are laid out left to right on a single line.
indirect enum CellRun {
    /// Text; a `flexible` run absorbs any shortage of width by truncating.
    /// `maxWidth` caps a non-flexible run, which then truncates.
    case text(String, color: NSColor = .labelColor, font: NSFont = CellFont.regular, flexible: Bool = false, maxWidth: CGFloat? = nil)
    /// Small rounded tag tinted with `color`.
    case chip(String, color: NSColor)
    case dot(NSColor)
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
    /// A short label on a solid rounded square the size of `image`, so it sits among org avatars.
    case tile(String, color: NSColor)
    /// A person's avatar in a circle; a placeholder circle while it loads.
    case avatar(NSImage?)
    /// Takes whatever width is left over, pushing the runs after it to the far edge.
    case spring
}

/// NSFont is immutable, so sharing these across isolation domains is safe.
enum CellFont {
    nonisolated(unsafe) static let regular = NSFont.systemFont(ofSize: 12)
    nonisolated(unsafe) static let regularBold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static let small = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let chip = NSFont.systemFont(ofSize: 10, weight: .medium)
    nonisolated(unsafe) static let tile = NSFont.systemFont(ofSize: 8, weight: .bold)
}

/// A cell that draws its runs directly, which keeps dense tables cheap to scroll.
final class RunsCellView: NSTableCellView {
    enum Alignment { case leading, trailing }

    var runs: [CellRun] = [] {
        didSet {
            cachedNaturalWidths = nil
            needsDisplay = true
        }
    }
    var alignment: Alignment = .leading { didSet { needsDisplay = true } }
    /// Fades the whole cell, e.g. for closed items. Applied while drawing rather than through
    /// `alphaValue`, which makes AppKit render the cell offscreen first when it draws into its
    /// row's layer.
    var opacity: CGFloat = 1 {
        didSet { if opacity != oldValue { needsDisplay = true } }
    }

    nonisolated static let spacing: CGFloat = 4
    nonisolated static let inset: CGFloat = 2
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

    /// Measured once per set of runs: drawing and live resizing ask again and again.
    private var cachedNaturalWidths: [CGFloat]?
    private var naturalWidths: [CGFloat] {
        if let cachedNaturalWidths { return cachedNaturalWidths }
        let widths = runs.map(naturalWidth)
        cachedNaturalWidths = widths
        return widths
    }

    override func draw(_: NSRect) {
        guard !runs.isEmpty else { return }
        if opacity < 1, let context = NSGraphicsContext.current?.cgContext {
            // One layer for the whole cell, so overlapping pieces (a chip and its text) fade as one.
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }
            drawRuns()
        } else {
            drawRuns()
        }
    }

    private func drawRuns() {
        let widths = layoutWidths(natural: naturalWidths)
        let total = widths.reduce(0, +) + Self.spacing * CGFloat(runs.count - 1)
        var x = alignment == .trailing ? bounds.maxX - Self.inset - total : Self.inset
        for (run, width) in zip(runs, widths) {
            draw(run, in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + Self.spacing
        }
    }

    /// The width each run gets: flexible runs share what the fixed ones leave, earlier runs first;
    /// springs get the rest.
    private func layoutWidths(natural: [CGFloat]) -> [CGFloat] {
        let gaps = Self.spacing * CGFloat(runs.count - 1)
        let available = bounds.width - 2 * Self.inset - gaps
        let fixed = zip(runs, natural).reduce(0) { $0 + ($1.0.isFlexible ? 0 : $1.1) }
        var remaining = max(0, available - fixed)
        var widths = zip(runs, natural).map { run, width -> CGFloat in
            guard run.isFlexible else { return width }
            let given = min(width, remaining)
            remaining -= given
            return given
        }
        let springs = runs.indices.filter { if case .spring = runs[$0] { true } else { false } }
        for index in springs {
            widths[index] = remaining / CGFloat(springs.count)
        }
        return widths
    }

    /// The full text of runs cut short at the current width (e.g. a long title), one per line;
    /// asked for only when a tooltip is about to show.
    var truncatedText: String? {
        let widths = layoutWidths(natural: naturalWidths)
        let cut = zip(runs, widths).compactMap { run, width in
            run.fullWidth.map { $0 > width + 0.5 } == true ? run.fullText : nil
        }
        return cut.isEmpty ? nil : cut.joined(separator: "\n")
    }

    private func naturalWidth(_ run: CellRun) -> CGFloat {
        switch run {
        case let .text(string, _, font, _, maxWidth):
            min(Self.textWidth(string, font: font), maxWidth ?? .infinity)
        case let .chip(string, _):
            ceil(string.size(withAttributes: [.font: CellFont.chip]).width) + 2 * Self.chipPadding
        case .dot:
            Self.dotSize
        case let .slot(_, width, _):
            width
        case .symbol, .icon:
            Self.symbolSize
        case .image, .tile, .avatar:
            Self.imageSize
        case .spring:
            0
        case let .segments(parts, font, _):
            Self.textWidth(parts.map(\.text).joined(), font: font)
        }
    }

    private struct WidthKey: Hashable {
        var text: String
        var font: NSFont
    }

    /// Measured text widths: the same titles, ages and counts come back as rows scroll in and out.
    private static var textWidths: [WidthKey: CGFloat] = [:]

    fileprivate static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = WidthKey(text: text, font: font)
        if let width = textWidths[key] { return width }
        let width = ceil(text.size(withAttributes: [.font: font]).width)
        if textWidths.count > 20000 { textWidths.removeAll() }
        textWidths[key] = width
        return width
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

        case let .slot(run, _, trailing):
            guard let run else { return }
            let width = min(naturalWidth(run), rect.width)
            draw(run, in: NSRect(x: trailing ? rect.maxX - width : rect.minX, y: rect.minY, width: width, height: rect.height))

        case let .symbol(name, color, pointSize):
            guard let image = Self.symbol(name, color: emphasized ? .alternateSelectedControlTextColor : color, pointSize: pointSize) else { return }
            let size = image.size
            image.draw(in: NSRect(
                x: rect.minX + (rect.width - size.width) / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))

        case let .image(image):
            drawImage(image, in: rect)

        case let .tile(string, color):
            let size = Self.imageSize
            let target = NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
            color.setFill()
            NSBezierPath(roundedRect: target, xRadius: 3, yRadius: 3).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: string, attributes: [
                .font: CellFont.tile,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
            let lineHeight = ceil(CellFont.tile.ascender - CellFont.tile.descender)
            text.draw(
                with: NSRect(x: target.minX, y: target.midY - lineHeight / 2, width: size, height: lineHeight),
                options: [.usesLineFragmentOrigin]
            )

        case .spring:
            break

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

    private struct SymbolKey: Hashable {
        var name: String
        var color: NSColor
        var pointSize: CGFloat
    }

    /// Configured symbol images, reused across cells and redraws. Dynamic colors resolve when
    /// drawn, so one image serves both appearances.
    private static var symbols: [SymbolKey: NSImage] = [:]

    private static func symbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        let key = SymbolKey(name: name, color: color, pointSize: pointSize)
        if let image = symbols[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: pointSize < 11 ? .bold : .medium)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if symbols.count > 500 { symbols.removeAll() }
        symbols[key] = image
        return image
    }

    private func drawImage(_ image: NSImage, in rect: NSRect) {
        let size = Self.imageSize
        let target = NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: target, xRadius: 3, yRadius: 3).addClip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let truncatingTail: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()

    private func drawText(_ string: String, color: NSColor, font: NSFont, in rect: NSRect) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: Self.truncatingTail,
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

    /// The text of a run that can be cut short.
    var fullText: String? {
        switch self {
        case let .text(string, _, _, _, _): string
        case let .segments(parts, _, _): parts.map(\.text).joined()
        default: nil
        }
    }

    /// The width the whole text needs, uncapped; nil for runs that can't be cut short.
    @MainActor var fullWidth: CGFloat? {
        switch self {
        case let .text(string, _, font, _, _): RunsCellView.textWidth(string, font: font)
        case let .segments(parts, font, _): RunsCellView.textWidth(parts.map(\.text).joined(), font: font)
        default: nil
        }
    }
}
