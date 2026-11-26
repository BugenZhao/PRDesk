import CoreGraphics

/// How the desk is laid out: a pure function of the window's width and one preference, so a
/// window that changes size at any time (rotation, multitasking, a resized window) always lands
/// on the layout its new size calls for, whatever came before.
struct DeskLayout: Equatable {
    /// The window's width; zero until it is measured.
    var width: CGFloat
    /// The viewer's choice where there is room for both: the list beside the detail, or put away
    /// like a sidebar, the detail having the window.
    var showsList: Bool
    /// The viewer's choice of rows: two lines each, or one as on the Mac.
    var prefersTwoLines: Bool

    /// Below this the list and the detail don't fit side by side (an iPad mini in portrait, any
    /// iPhone): the list fills the window and an item's detail is pushed over it.
    static let splitMinWidth: CGFloat = 900
    /// Keeps the choice of `showsList`.
    static let showsListKey = "showsList"

    var isMeasured: Bool { width > 0 }
    /// The detail has a pane of its own, beside the list.
    var isSplit: Bool { width >= Self.splitMinWidth }
    /// The list is put away. Only beside the detail: alone in the window it is all there is.
    var isListHidden: Bool { isSplit && !showsList }

    /// The bar over the list has room for the filter's button beside the lists and the menu. A
    /// phone's hasn't: there the system keeps the filter at the window's foot.
    var showsFilterInBar: Bool { width >= 560 }

    /// Two fifths of the window beside the detail, within what the columns need and what the
    /// detail can spare.
    var listWidth: CGFloat {
        isSplit ? min(480, max(400, (width * 0.4).rounded())) : width
    }

    var density: RowDensity { RowDensity(listWidth: listWidth, prefersTwoLines: prefersTwoLines) }
}

/// Which of the Mac's columns a list this wide has room for, the title keeping the most of it:
/// the columns looked at least give way first, as the Mac's do when its window narrows.
struct RowDensity: Equatable {
    var listWidth: CGFloat
    var prefersTwoLines: Bool

    /// The title on its own line, the rest beneath it: by choice, and on a phone always, where
    /// one line has no room for both.
    var usesTwoLines: Bool { prefersTwoLines || listWidth < 450 }
    var showsNumber: Bool { listWidth >= 640 }
    var showsSize: Bool { listWidth >= 720 }
    /// The author's login and marks beside the picture.
    var showsAuthorName: Bool { listWidth >= 960 }
    /// The board's Comment and the latest event in the title's column, where they fit.
    var showsNotes: Bool { listWidth >= 640 }
    /// Tags in full ("[Rust Frontend]" rather than "[RF]").
    var showsFullTags: Bool { listWidth >= 640 }
}
