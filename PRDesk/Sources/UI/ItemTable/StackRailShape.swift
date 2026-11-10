import CoreGraphics

/// How a stack rail is drawn in a row, shared by the list's cells and the detail's stack panel: a
/// lane per branch of the tree, lines between rows, a node per PR.
enum StackRailShape {
    /// Room for two lanes; more lanes squeeze closer.
    static let width: CGFloat = 16
    static let nodeSize: CGFloat = 7
    private static let laneSpacing: CGFloat = 7
    static let lineWidth: CGFloat = 1.5
    static let dash: [CGFloat] = [2.5, 2]

    struct Line {
        var path: CGPath
        var isDashed: Bool
    }

    /// The lines through a row spanning `rect` (top to bottom, y growing downward) and the
    /// node's frame, with lanes from `rect.minX`.
    static func layout(_ rail: StackRail, in rect: CGRect) -> (lines: [Line], node: CGRect) {
        let spacing = rail.laneCount > 1 ? min(laneSpacing, (width - nodeSize) / CGFloat(rail.laneCount - 1)) : 0
        func x(_ lane: Int) -> CGFloat { rect.minX + nodeSize / 2 + CGFloat(lane) * spacing }
        let mid = rect.midY
        let radius = nodeSize / 2
        let node = CGRect(x: x(rail.lane) - radius, y: mid - radius, width: nodeSize, height: nodeSize)
        // Lines stop at the node, so a hollow one stays clear on any background.
        let lines = rail.segments.map { segment -> Line in
            let path = CGMutablePath()
            let link: StackRail.Link
            switch segment {
            case let .up(lane, l):
                link = l
                path.move(to: CGPoint(x: x(lane), y: rect.minY))
                path.addLine(to: CGPoint(x: x(lane), y: mid - radius))
            case let .down(lane, l):
                link = l
                path.move(to: CGPoint(x: x(lane), y: mid + radius))
                path.addLine(to: CGPoint(x: x(lane), y: rect.maxY))
            case let .through(lane, l):
                link = l
                path.move(to: CGPoint(x: x(lane), y: rect.minY))
                path.addLine(to: CGPoint(x: x(lane), y: rect.maxY))
            case let .fork(lane, l):
                link = l
                path.move(to: CGPoint(x: x(rail.lane) + radius, y: mid))
                path.addQuadCurve(to: CGPoint(x: x(lane), y: rect.maxY), control: CGPoint(x: x(lane), y: mid))
            }
            return Line(path: path, isDashed: link == .branch)
        }
        return (lines, node)
    }
}
