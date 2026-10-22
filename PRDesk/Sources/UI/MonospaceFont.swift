import AppKit
import CoreText
import SwiftUI

/// The monospaced font chosen in Settings, for code, diffs, commit lines, paths and branch names.
enum MonospaceFont {
    /// UserDefaults key of the family name; empty means the system's (SF Mono).
    static let key = "monospaceFont"

    static var family: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// The font for native text at `size` points.
    static func font(family: String, size: CGFloat) -> Font {
        family.isEmpty ? .system(size: size, design: .monospaced) : .custom(family, size: size)
    }

    /// Installed fixed-pitch families, for the Settings picker.
    @MainActor
    static func installedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
    }

    /// CSS that points the pages' `--mono` at `family`. Web content can't reach fonts the user
    /// installed (WebKit hides them, `local()` included), so the app serves the faces itself.
    @MainActor
    static func css(family: String) -> String {
        guard !family.isEmpty else { return "" }
        let base = LocalResourceHandler.url("font", family)
        let faces = [("regular", 400, "normal"), ("bold", 700, "normal"), ("italic", 400, "italic"), ("bolditalic", 700, "italic")]
        return faces.map { face, weight, style in
            #"@font-face { font-family: "PR Desk Mono"; src: url("\#(base)/\#(face)"); font-weight: \#(weight); font-style: \#(style); }"#
        }.joined(separator: "\n")
            + #"\n:root { --mono: "PR Desk Mono", ui-monospace, SFMono-Regular, Menlo, monospace; }"#
    }

    /// One face (`regular`, `bold`, `italic`, `bolditalic`) of `family` as a standalone font file;
    /// the regular face stands in for a style the family lacks.
    @MainActor
    static func fontFile(family: String, face: String) -> CTFont? {
        let manager = NSFontManager.shared
        let bold = face.contains("bold")
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if face.contains("italic") { traits.insert(.italicFontMask) }
        let font = manager.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: 12)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: 12)
        return font.map { $0 as CTFont }
    }
}

/// Writes a font's tables back out as an OpenType file, for fonts that only exist inside a
/// collection (like the user's Iosevka builds) or that a web page can't load by name.
enum SFNT {
    static func data(from font: CTFont) -> Data? {
        guard let available = CTFontCopyAvailableTables(font, []) else { return nil }
        // The array holds raw tags, not CF objects.
        let tags = (0 ..< CFArrayGetCount(available))
            .map { CTFontTableTag(UInt(bitPattern: CFArrayGetValueAtIndex(available, $0))) }
            .sorted()
        let tables = tags.compactMap { tag in CTFontCopyTable(font, tag, []).map { (tag: tag, data: $0 as Data) } }
        guard !tables.isEmpty else { return nil }

        let isCFF = tables.contains { $0.tag == tag("CFF ") || $0.tag == tag("CFF2") }
        var selector = 0
        while 1 << (selector + 1) <= tables.count { selector += 1 }
        let searchRange = (1 << selector) * 16

        var file = Data()
        file.append(uint32: isCFF ? 0x4F54_544F : 0x0001_0000)
        file.append(uint16: tables.count)
        file.append(uint16: searchRange)
        file.append(uint16: selector)
        file.append(uint16: tables.count * 16 - searchRange)

        var offset = 12 + 16 * tables.count
        var body = Data()
        var headOffset: Int?
        for (tag, original) in tables {
            var data = original
            if tag == self.tag("head"), data.count >= 12 {
                // checkSumAdjustment is computed over the whole file below.
                data.replaceSubrange(8 ..< 12, with: [0, 0, 0, 0])
                headOffset = offset
            }
            file.append(uint32: Int(tag))
            file.append(uint32: Int(checksum(data)))
            file.append(uint32: offset)
            file.append(uint32: data.count)
            body.append(data)
            let padding = (4 - data.count % 4) % 4
            body.append(contentsOf: [UInt8](repeating: 0, count: padding))
            offset += data.count + padding
        }
        file.append(body)
        if let headOffset {
            let adjustment = 0xB1B0_AFBA &- checksum(file)
            file.replaceSubrange(headOffset + 8 ..< headOffset + 12, with: withUnsafeBytes(of: adjustment.bigEndian, Array.init))
        }
        return file
    }

    private static func tag(_ string: String) -> CTFontTableTag {
        string.utf8.reduce(0) { $0 << 8 | CTFontTableTag($1) }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var word: UInt32 = 0
        for (index, byte) in data.enumerated() {
            word = word << 8 | UInt32(byte)
            if index % 4 == 3 {
                sum &+= word
                word = 0
            }
        }
        let remainder = data.count % 4
        if remainder != 0 { sum &+= word << (8 * UInt32(4 - remainder)) }
        return sum
    }
}

private extension Data {
    mutating func append(uint32 value: Int) {
        append(contentsOf: Swift.withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian, Array.init))
    }

    mutating func append(uint16 value: Int) {
        append(contentsOf: Swift.withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian, Array.init))
    }
}
