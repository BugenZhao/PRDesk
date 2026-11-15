import SwiftUI

#if os(macOS)
    import AppKit

    /// The platform's image type: what `AvatarCache` and `Badge.image` hand out.
    typealias PlatformImage = NSImage

    extension Image {
        init(platformImage: NSImage) { self.init(nsImage: platformImage) }
    }
#else
    import UIKit

    typealias PlatformImage = UIImage

    extension Image {
        init(platformImage: UIImage) { self.init(uiImage: platformImage) }
    }
#endif
