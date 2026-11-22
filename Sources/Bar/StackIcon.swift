import AppKit
import SuiteFilesUI

extension StackIcon {
    /// The same pile from pictures already made (thumbnails, say), first on top.
    static func image(icons: [NSImage], side: CGFloat) -> NSImage {
        let icons = Array(icons.prefix(3))
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            for (depth, icon) in icons.enumerated().reversed() {
                let d = CGFloat(depth)
                let size = rect.width * 0.84 * (1 - d * 0.08)
                let frame = NSRect(x: (rect.width - size) / 2, y: d * rect.height * 0.07, width: size, height: size)
                let angle: CGFloat = depth == 0 ? 0 : (depth == 1 ? -7 : 6)
                NSGraphicsContext.saveGraphicsState()
                let turn = NSAffineTransform()
                turn.translateX(by: frame.midX, yBy: frame.midY)
                turn.rotate(byDegrees: angle)
                turn.translateX(by: -frame.midX, yBy: -frame.midY)
                turn.concat()
                icon.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}
