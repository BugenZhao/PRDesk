import CoreGraphics

/// How the desk is laid out: a pure function of the window (its width and size class) and the
/// viewer's choices, so a window that changes at any time (rotation, multitasking, a resized
/// window) always lands on the layout it calls for, whatever came before.
///
/// The desk is always a split view, laid out as the system lays one out: the list is the
/// detail's sidebar, beside it in a wide window and floating over it in a narrower one, and in a
/// compact window (a phone) a page of its own that the detail is pushed over.
struct DeskLayout: Equatable {
    /// The window's width; zero until it is measured.
    var width: CGFloat
    /// The list's width as laid out, which is the split view's to decide; zero until it is
    /// measured.
    var listWidth: CGFloat
    /// The window's horizontal size class is compact: the split view shows one column.
    var isCompact: Bool
    /// The viewer's choice of rows: two lines each, or one as on the Mac.
    var prefersTwoLines: Bool

    /// From here up the list stands beside the detail (an iPad mini on its side); narrower, the
    /// system floats it over the detail (an iPad mini upright).
    static let wideMinWidth: CGFloat = 900
    /// Keeps whether the sidebar beside the detail is shown.
    static let showsListKey = "showsList"

    var isMeasured: Bool { width > 0 }
    /// The list is a page of its own, and the detail is pushed over it.
    var isListPage: Bool { isCompact }
    /// The list is a sidebar that floats over the detail rather than standing beside it.
    var listFloats: Bool { !isCompact && width < Self.wideMinWidth }

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
