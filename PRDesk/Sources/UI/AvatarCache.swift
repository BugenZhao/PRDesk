import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation

/// GitHub avatars (users and orgs) as images, kept in memory; the data comes from `AvatarStore`.
@MainActor
@Observable
final class AvatarCache {
    static let shared = AvatarCache()

    /// Bumped whenever an image finishes loading, so views showing avatars can redraw.
    private(set) var version = 0

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var grayscaleImages: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// Returns the avatar if loaded; otherwise starts loading it and returns nil.
    func image(for login: String) -> NSImage? {
        let key = login.lowercased()
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task { await load(key) }
        return nil
    }

    @ObservationIgnored private var brandTiles: [String: NSImage] = [:]

    /// `text` in white on a rounded square of the color `hex`, shrunk to fit; one image per tile,
    /// so the list's raster cache keeps it.
    func brandTile(_ text: String, hex: String) -> NSImage {
        let key = "\(text)/\(hex)"
        if let image = brandTiles[key] { return image }
        let value = Int(hex, radix: 16) ?? 0
        let color = NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width * 3 / 13, yRadius: rect.height * 3 / 13).fill()
            var font = NSFont.systemFont(ofSize: rect.height * 8 / 13, weight: .heavy)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            let room = rect.width * 0.88
            if width > room { font = NSFont.systemFont(ofSize: font.pointSize * room / width, weight: .heavy) }
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.white]
            )
            return true
        }
        brandTiles[key] = image
        return image
    }

    /// `image` without color, for a lesser badge, cached under `key`.
    func grayscale(_ image: NSImage, key: String) -> NSImage? {
        if let image = grayscaleImages[key] { return image }
        guard let data = image.tiffRepresentation, let input = CIImage(data: data) else { return nil }
        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.saturation = 0
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: input.extent)
        else { return nil }
        let gray = NSImage(cgImage: cgImage, size: image.size)
        grayscaleImages[key] = gray
        return gray
    }

    private func load(_ key: String) async {
        guard let data = await AvatarStore.data(for: key), let image = NSImage(data: data) else {
            // Try again later rather than never: the network may be back by then.
            try? await Task.sleep(for: Self.retryDelay)
            loading.remove(key)
            return
        }
        images[key] = image
        loading.remove(key)
        scheduleVersionBump()
    }

    private static let retryDelay: Duration = .seconds(300)
    @ObservationIgnored private var isBumpScheduled = false

    /// A list's worth of avatars arrives at once; everything showing them redraws once per batch
    /// rather than once per image.
    private func scheduleVersionBump() {
        guard !isBumpScheduled else { return }
        isBumpScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            isBumpScheduled = false
            version += 1
        }
    }
}

extension Badge {
    /// The org's brand tile or bundled logo, without color for a secondary badge.
    @MainActor
    var image: NSImage? {
        let cache = AvatarCache.shared
        if let tile = org.brandTile { return cache.brandTile(tile.text, hex: tile.hex) }
        guard let key = org.logoAsset, let image = NSImage(named: key) else { return nil }
        return isSecondary ? cache.grayscale(image, key: key) : image
    }
}
