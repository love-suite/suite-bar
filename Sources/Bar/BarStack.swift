import AppKit
import SuiteCore
import BarCore
import BarSettings

/// A folder's stack opened from the Dock (Downloads): a grid of its items, newest first, as the system
/// Dock's grid. One click opens an item, items can be dragged out, and "Open in Explorer" shows the folder.
final class BarStackPopover: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    private let popover = NSPopover()
    private let folder: URL
    private var monitor: Any?

    init(folder: URL) {
        self.folder = folder
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = BarStackViewController(folder: folder) { [weak self] in self?.close() }
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        // Explorer isn't the active app, so transient popovers wouldn't see clicks in other apps.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onClose?()
    }
}

final class BarStackViewController: NSViewController {
    private let folder: URL
    private let done: () -> Void

    init(folder: URL, done: @escaping () -> Void) {
        self.folder = folder
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let items = Array(BarStackOrder.contents(of: folder).prefix(BarStackGrid.limit))
        let grid = BarStackGrid(items: items) { [weak self] url in
            ExplorerLink.openFiles([url])
            self?.done()
        }
        let visible = grid.visibleSize
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: visible))
        scroll.documentView = grid
        scroll.hasVerticalScroller = grid.frame.height > visible.height
        scroll.drawsBackground = false
        grid.scroll(NSPoint(x: 0, y: grid.frame.height))

        let title = NSTextField(labelWithString: FileManager.default.displayName(atPath: folder.path))
        title.font = .boldSystemFont(ofSize: 15)
        let open = FirstClickButton(title: "Open in Explorer", target: self, action: #selector(openFolder))
        open.bezelStyle = .rounded

        let footer = NSStackView(views: [NSView(), open])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [title, scroll, footer])
        stack.alignment = .leading
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        scroll.widthAnchor.constraint(equalToConstant: visible.width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: visible.height).isActive = true
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        view = stack
    }

    @objc private func openFolder() {
        ExplorerLink.open([folder])
        done()
    }
}

/// Clicks reach it even though Explorer isn't the active app.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The stack's items in a grid: icon (or thumbnail) and name.
final class BarStackGrid: NSView, NSDraggingSource {
    static let limit = 60
    private static let cell = NSSize(width: 88, height: 90)
    private static let columns = 5
    private static let visibleRows = 4

    private let items: [URL]
    private let onOpen: (URL) -> Void
    private var images: [URL: NSImage] = [:]
    private var hovered: Int?
    private var pressed: (index: Int, at: NSPoint)?

    init(items: [URL], onOpen: @escaping (URL) -> Void) {
        self.items = items
        self.onOpen = onOpen
        let columns = min(max(items.count, 1), Self.columns)
        let rows = max((items.count + columns - 1) / columns, 1)
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * Self.cell.width,
                                 height: CGFloat(rows) * Self.cell.height))
        for url in items {
            images[url] = NSWorkspace.shared.icon(forFile: url.path)
            guard BarFiles.showsThumbnails, BarFiles.hasThumbnail(url) else { continue }
            BarFiles.thumbnail(for: url, side: 56, scale: NSScreen.main?.backingScaleFactor ?? 2) { [weak self] image in
                self?.images[url] = image
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var visibleSize: NSSize {
        NSSize(width: frame.width, height: min(frame.height, CGFloat(Self.visibleRows) * Self.cell.height))
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func frame(of index: Int) -> NSRect {
        let columns = min(max(items.count, 1), Self.columns)
        return NSRect(x: CGFloat(index % columns) * Self.cell.width, y: CGFloat(index / columns) * Self.cell.height,
                      width: Self.cell.width, height: Self.cell.height)
    }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { frame(of: $0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if items.isEmpty {
            let text = NSAttributedString(string: "No items", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: bounds.midY - 8))
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        for (index, url) in items.enumerated() {
            let cell = frame(of: index)
            guard cell.intersects(dirtyRect) else { continue }
            if hovered == index || pressed?.index == index {
                NSColor.labelColor.withAlphaComponent(pressed?.index == index ? 0.18 : 0.1).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8).fill()
            }
            let icon = NSRect(x: cell.midX - 28, y: cell.minY + 6, width: 56, height: 56)
            images[url]?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                              hints: nil)
            let name = NSAttributedString(string: url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            name.draw(with: NSRect(x: cell.minX + 4, y: icon.maxY + 3, width: cell.width - 8, height: 26),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = index(at: point).map { ($0, point) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.at.x, point.y - pressed.at.y) > 4 else { return }
        self.pressed = nil
        let url = items[pressed.index]
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = frame(of: pressed.index).insetBy(dx: 16, dy: 6)
        item.setDraggingFrame(NSRect(x: icon.minX, y: icon.minY, width: 56, height: 56), contents: images[url])
        beginDraggingSession(with: [item], event: event, source: self)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let pressed, index(at: convert(event.locationInWindow, from: nil)) == pressed.index else { return }
        onOpen(items[pressed.index])
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.move, .copy, .generic]
    }
}
