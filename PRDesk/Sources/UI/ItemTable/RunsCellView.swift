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
    /// Differently styled pieces of one string that truncate together, e.g. a dimmed title prefix.
    case segments([TextSegment], font: NSFont = CellFont.regular, flexible: Bool = false)
    /// Small rounded image, e.g. an org avatar.
    case image(NSImage)
    /// A short label on a solid rounded square the size of `image`, so it sits among org avatars.
    case tile(String, color: NSColor)
    /// A person's avatar in a circle; a placeholder circle while it loads.
    case avatar(NSImage?)
    /// Takes whatever width is left over, pushing the runs after it to the far edge.
    case spring
    /// A run drawn see-through, e.g. a mark for a write still under way. Only the run fades,
    /// not the cell (see `RunsCellView.opacity`).
    case faded(CellRun, opacity: CGFloat)
    /// A run left out while a flexible run that isn't optional (e.g. a title) would be cut short,
    /// or, when flexible itself, while it would get less than `minWidth`. The lowest `priority`
    /// goes first; runs of one priority go together.
    case optional(CellRun, priority: Int, minWidth: CGFloat = 0)
}

/// A piece of `CellRun.segments`; `font` replaces the run's, e.g. for inline code.
struct TextSegment {
    var text: String
    var color: NSColor
    var font: NSFont?
}

/// NSFont is immutable, so sharing these across isolation domains is safe.
enum CellFont {
    nonisolated(unsafe) static let regular = NSFont.systemFont(ofSize: 12)
    nonisolated(unsafe) static let regularBold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let regularItalic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
    nonisolated(unsafe) static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static let small = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let chip = NSFont.systemFont(ofSize: 10, weight: .medium)
    nonisolated(unsafe) static let tile = NSFont.systemFont(ofSize: 8, weight: .bold)
    /// Inline code in 12-point text: SF Mono a point smaller looks the same size.
    nonisolated(unsafe) static let code = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static let codeBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
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

    // Row views set this again on every frame of a row animation; redraw only when it changes.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
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
        let shown = widths.compactMap(\.self)
        let total = shown.reduce(0, +) + Self.spacing * CGFloat(shown.count - 1)
        var x = alignment == .trailing ? bounds.maxX - Self.inset - total : Self.inset
        for (run, width) in zip(runs, widths) {
            guard let width else { continue }
            draw(run, in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + Self.spacing
        }
    }

    /// The width each run gets, nil for an optional run left out: optional runs shrink to their
    /// minimum and then give way, lowest priority first, until the other flexible runs get all
    /// they need or none are left.
    private func layoutWidths(natural: [CGFloat]) -> [CGFloat?] {
        var widths = layoutWidths(natural: natural, dropping: [])
        let priorities = Set(runs.compactMap(\.dropPriority)).sorted()
        var dropping: Set<Int> = []
        for priority in priorities {
            let short = runs.indices.contains { index in
                guard runs[index].isFlexible, let width = widths[index] else { return false }
                let needed = if case let .optional(_, _, minWidth) = runs[index] { min(minWidth, natural[index]) } else { natural[index] }
                return width < needed - 0.5
            }
            guard short else { break }
            dropping.insert(priority)
            widths = layoutWidths(natural: natural, dropping: dropping)
        }
        return widths
    }

    /// Flexible runs share what the fixed ones leave, earlier runs first; springs get the rest.
    private func layoutWidths(natural: [CGFloat], dropping: Set<Int>) -> [CGFloat?] {
        let shown = runs.map { run in run.dropPriority.map { !dropping.contains($0) } ?? true }
        let count = shown.filter(\.self).count
        let gaps = Self.spacing * CGFloat(max(0, count - 1))
        let available = bounds.width - 2 * Self.inset - gaps
        let fixed = runs.indices.reduce(0) { $0 + (shown[$1] && !runs[$1].isFlexible ? natural[$1] : 0) }
        var remaining = max(0, available - fixed)
        var widths = runs.indices.map { index -> CGFloat? in
            guard shown[index] else { return nil }
            guard runs[index].isFlexible else { return natural[index] }
            let given = min(natural[index], remaining)
            remaining -= given
            return given
        }
        let springs = runs.indices.filter { if case .spring = runs[$0] { true } else { false } }
        for index in springs {
            widths[index] = remaining / CGFloat(springs.count)
        }
        return widths
    }

    // MARK: Accessibility

    // The cell draws its text rather than holding text fields, so it speaks for itself.

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityValue() -> Any? {
        let text = runs.compactMap(\.spokenText).joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    /// The full text of runs cut short at the current width (e.g. a long title), one per line;
    /// asked for only when a tooltip is about to show.
    var truncatedText: String? {
        let widths = layoutWidths(natural: naturalWidths)
        let cut = zip(runs, widths).compactMap { run, width -> String? in
            guard let width else { return nil }
            return run.fullWidth.map { $0 > width + 0.5 } == true ? run.fullText : nil
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
        case let .faded(run, _), let .optional(run, _, _):
            naturalWidth(run)
        case .symbol, .icon:
            Self.symbolSize
        case .image, .tile, .avatar:
            Self.imageSize
        case .spring:
            0
        case let .segments(parts, font, _):
            Self.segmentsWidth(parts, font: font)
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

    private static var segmentWidths: [[WidthKey]: CGFloat] = [:]

    fileprivate static func segmentsWidth(_ parts: [TextSegment], font: NSFont) -> CGFloat {
        if parts.allSatisfy({ $0.font == nil }) { return textWidth(parts.map(\.text).joined(), font: font) }
        let key = parts.map { WidthKey(text: $0.text, font: $0.font ?? font) }
        if let width = segmentWidths[key] { return width }
        let width = ceil(attributed(parts, font: font, override: nil).size().width)
        if segmentWidths.count > 5000 { segmentWidths.removeAll() }
        segmentWidths[key] = width
        return width
    }

    private static func attributed(_ parts: [TextSegment], font: NSFont, override: NSColor?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString()
        for part in parts {
            result.append(NSAttributedString(string: part.text, attributes: [
                .font: part.font ?? font,
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

        case let .faded(run, opacity):
            guard let context = NSGraphicsContext.current?.cgContext else { return draw(run, in: rect) }
            context.saveGState()
            context.setAlpha(opacity)
            draw(run, in: rect)
            context.restoreGState()

        case let .optional(run, _, _):
            draw(run, in: rect)

        case let .slot(run, _, trailing):
            guard let run else { return }
            let width = min(naturalWidth(run), rect.width)
            draw(run, in: NSRect(x: trailing ? rect.maxX - width : rect.minX, y: rect.minY, width: width, height: rect.height))

        case let .symbol(name, color, pointSize):
            guard let image = Self.symbol(name, color: emphasized ? .alternateSelectedControlTextColor : color, pointSize: pointSize) else { return }
            let size = image.size
            drawRaster(.symbol(name, pointSize), color: emphasized ? .alternateSelectedControlTextColor : color, shape: .none, in: NSRect(
                x: rect.minX + (rect.width - size.width) / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )) { bounds in image.draw(in: bounds) }

        case let .image(image):
            let size = Self.imageSize
            drawRaster(.image(Self.identity(of: image)), shape: .rounded, in: NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)) { bounds in
                image.draw(in: bounds)
            }

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
            let target = NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
            if let image {
                drawRaster(.image(Self.identity(of: image)), shape: .circle, in: target) { bounds in image.draw(in: bounds) }
            } else {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(ovalIn: target).fill()
            }

        case let .icon(.symbol(name), color):
            draw(.symbol(name, color: color), in: rect)

        case let .icon(.asset(name), color):
            guard let image = NSImage(named: name) else { return }
            let size = Self.symbolSize
            let tint = emphasized ? NSColor.alternateSelectedControlTextColor : color
            let target = NSRect(x: rect.minX + (rect.width - size) / 2, y: rect.midY - size / 2, width: size, height: size)
            drawRaster(.asset(name), color: tint, shape: .none, in: target) { bounds in
                // Tint the template: draw it, then fill the color over its alpha.
                image.draw(in: bounds)
                tint.setFill()
                bounds.fill(using: .sourceIn)
            }
        }
    }

    // MARK: Rasterized images

    // Images are drawn from bitmaps made once per screen scale and appearance: an NSImage picks
    // a representation, resamples and (here) clips or tints on every draw, which added up to a
    // large share of the time rows take to scroll in and redraw on resize.

    private enum RasterSource: Hashable {
        case image(ObjectIdentifier)
        case asset(String)
        case symbol(String, CGFloat)
    }

    private enum RasterShape: Hashable { case none, circle, rounded }

    private struct RasterKey: Hashable {
        var source: RasterSource
        /// Resolved in the appearance, so dynamic colors are drawn as they look in it.
        var color: NSColor?
        var shape: RasterShape
        var size: NSSize
        var scale: CGFloat
        var appearance: NSAppearance.Name
    }

    private static var rasters: [RasterKey: CGImage] = [:]
    /// Images keyed by identity are kept alive, so an identity can't come back as a different
    /// image. Few: avatars and org logos.
    private static var rasterSources: [ObjectIdentifier: NSImage] = [:]
    private static let rasterColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private static func identity(of image: NSImage) -> ObjectIdentifier {
        let id = ObjectIdentifier(image)
        if rasterSources[id] == nil { rasterSources[id] = image }
        return id
    }

    /// Draws what `draw` paints into a `rect`-sized box, from a bitmap made on first use.
    private func drawRaster(_ source: RasterSource, color: NSColor? = nil, shape: RasterShape, in rect: NSRect, draw: (NSRect) -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let appearance = NSAppearance.currentDrawing()
        let key = RasterKey(source: source, color: color, shape: shape, size: rect.size, scale: scale, appearance: appearance.name)
        let raster: CGImage
        if let cached = Self.rasters[key] {
            raster = cached
        } else {
            guard let made = Self.rasterize(size: rect.size, scale: scale, shape: shape, appearance: appearance, draw: draw) else { return }
            if Self.rasters.count > 3000 { Self.rasters.removeAll() }
            Self.rasters[key] = made
            raster = made
        }
        // Whole device pixels, so the bitmap isn't resampled into a blur.
        let origin = NSPoint(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale)
        context.saveGState()
        // The cell is flipped; the bitmap is not.
        context.translateBy(x: origin.x, y: origin.y + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(raster, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func rasterize(size: NSSize, scale: CGFloat, shape: RasterShape, appearance: NSAppearance, draw: (NSRect) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rasterColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        let bounds = NSRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            switch shape {
            case .none: break
            case .circle: NSBezierPath(ovalIn: bounds).addClip()
            case .rounded: NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
            }
            draw(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
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
        case let .optional(run, _, _): run.isFlexible
        default: false
        }
    }

    var dropPriority: Int? {
        if case let .optional(_, priority, _) = self { priority } else { nil }
    }

    /// What VoiceOver reads for the run; nil for pure decoration.
    var spokenText: String? {
        switch self {
        case let .text(string, _, _, _, _), let .chip(string, _), let .tile(string, _): string
        case let .segments(parts, _, _): parts.map(\.text).joined()
        case let .slot(run?, _, _), let .faded(run, _), let .optional(run, _, _): run.spokenText
        default: nil
        }
    }

    /// The text of a run that can be cut short.
    var fullText: String? {
        switch self {
        case let .text(string, _, _, _, _): string
        case let .segments(parts, _, _): parts.map(\.text).joined()
        case let .optional(run, _, _): run.fullText
        default: nil
        }
    }

    /// The width the whole text needs, uncapped; nil for runs that can't be cut short.
    @MainActor var fullWidth: CGFloat? {
        switch self {
        case let .text(string, _, font, _, _): RunsCellView.textWidth(string, font: font)
        case let .segments(parts, font, _): RunsCellView.segmentsWidth(parts, font: font)
        case let .optional(run, _, _): run.fullWidth
        default: nil
        }
    }
}
