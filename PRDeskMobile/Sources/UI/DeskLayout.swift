import CoreGraphics

/// How the desk is laid out: a pure function of the window (its width and size class) and the
/// viewer's choices, so a window that changes at any time (rotation, multitasking, a resized
/// window) always lands on the layout it calls for, whatever came before.
///
/// The desk is always a split view, laid out as the system lays one out: the list is the
/// detail's sidebar, beside it in a wide window and floating over it in a narrower one, and in a
/// compact window (a phone) a page of its own that the detail is pushed over.
///
/// On an iPad the list can also be asked for as a table: the same one column a phone has, the
/// whole window wide, with a line a row and every column there is room for. The split view is
/// told its width is compact for that, so it is the system's own collapsed form, and the choice
/// is kept for wide and for narrower windows apart.
struct DeskLayout: Equatable {
    /// The window's width; zero until it is measured.
    var width: CGFloat
    /// The list's width as laid out, which is the split view's to decide; zero until it is
    /// measured.
    var listWidth: CGFloat
    /// The window's horizontal size class is compact: the split view shows one column whatever
    /// is asked for.
    var isCompact: Bool
    /// The viewer's choice for this width: the list as a table the whole window wide.
    var prefersTable: Bool
    /// The viewer's choice of rows: two lines each, or one as on the Mac.
    var prefersTwoLines: Bool

    /// From here up the list stands beside the detail (an iPad mini on its side); narrower, the
    /// system floats it over the detail (an iPad mini upright).
    static let wideMinWidth: CGFloat = 900
    /// Keeps whether the sidebar beside the detail is shown.
    static let showsListKey = "showsList"
    /// Keep the choice of `prefersTable`, for wide windows and for narrower ones.
    static let tableWideKey = "table.wide"
    static let tableNarrowKey = "table.narrow"

    var isMeasured: Bool { width > 0 }
    var isWide: Bool { width >= Self.wideMinWidth }
    /// The list is a table the whole window wide (there is a choice only where the window isn't
    /// compact already).
    var isTable: Bool { !isCompact && prefersTable }
    /// The list is a page of its own, and the detail is pushed over it.
    var isListPage: Bool { isCompact || isTable }
    /// The list is a sidebar that floats over the detail rather than standing beside it.
    var listFloats: Bool { !isListPage && !isWide }

    /// A table's rows are a line each: that is what it is asked for.
    var density: RowDensity {
        RowDensity(listWidth: listWidth > 0 ? listWidth : (isListPage ? width : 460), prefersTwoLines: prefersTwoLines && !isTable)
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
    /// Tags in full ("[Rust Frontend]" rather than "[RF]"): only where the author's name fits
    /// too (an iPad on its side, as a table). Narrower, the title needs the room more, an iPad
    /// mini's upright table included.
    var showsFullTags: Bool { showsAuthorName }
}
