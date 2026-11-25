import CoreGraphics

/// How the desk is laid out: a pure function of the window's width and one preference, so a
/// window that changes size at any time (rotation, multitasking, a resized window) always lands
/// on the layout its new size calls for, whatever came before.
struct DeskLayout: Equatable {
    /// The window's width; zero until it is measured.
    var width: CGFloat
    /// The viewer's choice where there is room for both: the list beside the detail, or the list
    /// alone at full width with every column.
    var prefersSplit: Bool

    /// Below this the list and the detail don't fit side by side (an iPad mini in portrait, any
    /// iPhone): the list fills the window and an item's detail is pushed over it.
    static let splitMinWidth: CGFloat = 900

    var isMeasured: Bool { width > 0 }
    var canSplit: Bool { width >= Self.splitMinWidth }
    var isSplit: Bool { canSplit && prefersSplit }

    /// Two fifths of the window beside the detail, within what the columns need and what the
    /// detail can spare.
    var listWidth: CGFloat {
        isSplit ? min(480, max(400, (width * 0.4).rounded())) : width
    }

    var density: RowDensity { RowDensity(listWidth: listWidth) }
}

/// Which of the Mac's columns a list this wide has room for, the title keeping the most of it:
/// the columns looked at least give way first, as the Mac's do when its window narrows.
struct RowDensity: Equatable {
    var listWidth: CGFloat

    /// A phone: the title on its own line, the rest beneath it.
    var isCompact: Bool { listWidth < 450 }
    var showsNumber: Bool { listWidth >= 640 }
    var showsSize: Bool { listWidth >= 720 }
    /// The author's login and marks beside the picture.
    var showsAuthorName: Bool { listWidth >= 960 }
    /// The board's Comment and the latest event in the title's column, where they fit.
    var showsNotes: Bool { listWidth >= 640 }
    /// Tags in full ("[Rust Frontend]" rather than "[RF]").
    var showsFullTags: Bool { listWidth >= 640 }
}
