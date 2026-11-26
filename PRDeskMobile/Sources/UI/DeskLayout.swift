import CoreGraphics

/// How the desk is laid out: a pure function of the window's width and the viewer's choices, so
/// a window that changes size at any time (rotation, multitasking, a resized window) always lands
/// on the layout its new size calls for, whatever came before.
///
/// The list is either a page of its own, the whole window wide, which an item's detail is pushed
/// over; or the sidebar of the detail: beside it in a wide window, floating over it in a narrower
/// one, and put away at will. The choice is kept for wide and for narrower windows apart, since
/// what suits an iPad on its side (list and detail) isn't what suits it upright (the list).
struct DeskLayout: Equatable {
    /// The window's width; zero until it is measured.
    var width: CGFloat
    /// The list's width as laid out, which as a sidebar is the split view's to decide; zero
    /// until it is measured.
    var listWidth: CGFloat
    /// The viewer's choice for this width: the list as a page of its own.
    var prefersListPage: Bool
    /// The viewer's choice of rows: two lines each, or one as on the Mac.
    var prefersTwoLines: Bool

    /// From here up the list fits beside the detail (an iPad mini on its side).
    static let wideMinWidth: CGFloat = 900
    /// Below this there is only the list as a page (any iPhone upright): no room for a sidebar
    /// over the detail.
    static let sidebarMinWidth: CGFloat = 560

    /// Keep the choice of `prefersListPage`, for wide windows and for narrower ones.
    static let listPageWideKey = "listPage.wide"
    static let listPageNarrowKey = "listPage.narrow"
    /// Keeps whether the sidebar beside the detail is shown.
    static let showsListKey = "showsList"

    var isMeasured: Bool { width > 0 }
    var isWide: Bool { width >= Self.wideMinWidth }
    /// There is a choice: the list can be the detail's sidebar.
    var canBeSidebar: Bool { width >= Self.sidebarMinWidth }
    /// The list is a page of its own, and the detail is pushed over it.
    var isListPage: Bool { !canBeSidebar || prefersListPage }
    /// The list is a sidebar that floats over the detail rather than standing beside it.
    var listFloats: Bool { !isListPage && !isWide }

    var density: RowDensity {
        RowDensity(listWidth: listWidth > 0 ? listWidth : (isListPage ? width : 460), prefersTwoLines: prefersTwoLines)
    }
}

/// Which of the Mac's columns a list this wide has room for, the title keeping the most of it:
/// the columns looked at least give way first, as the Mac's do when its window narrows.
struct RowDensity: Equatable {
    var listWidth: CGFloat
    var prefersTwoLines: Bool

    /// The title on its own line, the rest beneath it: by choice, and on a phone always, where
    /// one line has no room for both.
    var usesTwoLines: Bool { prefersTwoLines || !canUseOneLine }
    /// One line is there to choose.
    var canUseOneLine: Bool { listWidth >= 450 }
    var showsNumber: Bool { listWidth >= 640 }
    var showsSize: Bool { listWidth >= 720 }
    /// The author's login and marks beside the picture.
    var showsAuthorName: Bool { listWidth >= 960 }
    /// The board's Comment and the latest event in the title's column, where they fit.
    var showsNotes: Bool { listWidth >= 640 }
    /// Tags in full ("[Rust Frontend]" rather than "[RF]").
    var showsFullTags: Bool { listWidth >= 640 }
}
