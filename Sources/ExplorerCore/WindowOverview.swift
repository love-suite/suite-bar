import CoreGraphics
import Foundation

// The overview of the windows that stands in for Mission Control while the system Dock is stopped.

/// A window shown in the overview, as the window server lists it.
public struct OverviewWindow: Equatable {
    public let id: UInt32
    public let pid: Int32
    /// Top-left origin, global coordinates (the window server's and Accessibility's).
    public let frame: CGRect
    public var title: String
    public let appName: String

    public init(id: UInt32, pid: Int32, frame: CGRect, title: String, appName: String) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.title = title
        self.appName = appName
    }

    /// Normal windows only: layer 0, visible, big enough to be a window rather than a palette, and not
    /// parked in the screen's corner by our minimize.
    public static func isShown(layer: Int, alpha: Double, frame: CGRect, screens: CGRect) -> Bool {
        layer == 0 && alpha > 0 && frame.width >= 60 && frame.height >= 40
            && screens.intersection(frame).width >= 20 && screens.intersection(frame).height >= 20
    }
}

public enum OverviewLayout {
    /// Frames for windows of these sizes in `area`, row by row, each scaled down by the same factor as much
    /// as needed (never up), with `spacing` around them: the column count that leaves the windows largest.
    public static func frames(for sizes: [CGSize], in area: CGRect, spacing: CGFloat = 24,
                              captionHeight: CGFloat = 24) -> [CGRect] {
        guard !sizes.isEmpty, area.width > 0, area.height > 0 else { return [] }
        var best: (scale: CGFloat, columns: Int) = (0, 1)
        for columns in 1...sizes.count {
            let rows = (sizes.count + columns - 1) / columns
            let cell = CGSize(width: (area.width - CGFloat(columns + 1) * spacing) / CGFloat(columns),
                              height: (area.height - CGFloat(rows + 1) * spacing) / CGFloat(rows) - captionHeight)
            guard cell.width > 0, cell.height > 0 else { continue }
            let scale = sizes.map { min(cell.width / $0.width, cell.height / $0.height, 1) }.min() ?? 0
            if scale > best.scale { best = (scale, columns) }
        }
        let columns = best.columns
        let rows = (sizes.count + columns - 1) / columns
        let cell = CGSize(width: (area.width - CGFloat(columns + 1) * spacing) / CGFloat(columns),
                          height: (area.height - CGFloat(rows + 1) * spacing) / CGFloat(rows))
        return sizes.enumerated().map { index, size in
            let row = index / columns
            let column = index % columns
            // The last row is centred when it isn't full.
            let inRow = row == rows - 1 ? sizes.count - row * columns : columns
            let rowWidth = CGFloat(inRow) * cell.width + CGFloat(inRow - 1) * spacing
            let left = area.minX + (area.width - rowWidth) / 2
            let slot = CGRect(x: left + CGFloat(column) * (cell.width + spacing),
                              y: area.minY + spacing + CGFloat(row) * (cell.height + spacing),
                              width: cell.width, height: cell.height - captionHeight)
            let scale = min(slot.width / size.width, slot.height / size.height, 1)
            let fitted = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            return CGRect(x: (slot.midX - fitted.width / 2).rounded(), y: (slot.midY - fitted.height / 2).rounded(),
                          width: fitted.width, height: fitted.height)
        }
    }

    /// The item reached from `index` with an arrow key, in reading order.
    public static func neighbour(of index: Int, count: Int, frames: [CGRect], direction: Direction) -> Int {
        guard count > 0, frames.count == count, frames.indices.contains(index) else { return 0 }
        switch direction {
        case .left: return (index - 1 + count) % count
        case .right: return (index + 1) % count
        case .up, .down:
            let here = frames[index]
            // The nearest item in the row above or below (top-left origin: down is +y).
            let candidates = frames.indices.filter {
                direction == .down ? frames[$0].midY > here.maxY : frames[$0].midY < here.minY
            }
            return candidates.min { abs(frames[$0].midX - here.midX) + abs(frames[$0].midY - here.midY)
                < abs(frames[$1].midX - here.midX) + abs(frames[$1].midY - here.midY) } ?? index
        }
    }

    public enum Direction { case left, right, up, down }
}

public enum WindowMatch {
    /// The Accessibility window that is the window server's window: same place and size, to a point or two.
    public static func index(of frame: CGRect, in candidates: [CGRect], tolerance: CGFloat = 2) -> Int? {
        candidates.firstIndex {
            abs($0.minX - frame.minX) <= tolerance && abs($0.minY - frame.minY) <= tolerance
                && abs($0.width - frame.width) <= tolerance && abs($0.height - frame.height) <= tolerance
        }
    }
}
