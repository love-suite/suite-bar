import AppKit
import SuiteCore
import BarCore
import BarSettings

/// A folder of the Dock, opened: a fan, a grid or a list, as the system Dock offers (the folder's
/// "View content as" option). Closes with a click elsewhere, on its Dock icon, or once an item is opened.
protocol BarStackPresenter: AnyObject {
    var onClose: (() -> Void)? { get set }
    func show()
    func close()
}

enum BarStacks {
    /// The presenter for `item`, opened from `tile` (in `view`'s coordinates) of a Dock along `edge`;
    /// `show()` it once kept. The fan rises from a Dock at the bottom only, as in the system Dock: on the
    /// sides a fan opens as a grid.
    static func presenter(for item: BarItem, tile: NSRect, edge: ScreenEdge,
                          in view: NSView) -> BarStackPresenter? {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let urls = BarStackOrder.contents(of: item.url, sortedBy: item.sort)
        let anchor = window.convertToScreen(view.convert(tile, to: nil))
        let room = screen.visibleFrame.maxY - anchor.maxY - 24
        let capacity = edge == .bottom ? BarFan.capacity(height: room, step: BarFanPanel.step) : 0
        switch item.view.resolved(itemCount: urls.count, fanCapacity: capacity) {
        case .fan where edge == .bottom:
            return BarFanPanel(item: item, urls: urls, anchor: NSPoint(x: anchor.midX, y: anchor.maxY + 2),
                                capacity: capacity)
        case .list:
            return BarStackList(item: item, urls: urls, tile: tile, edge: edge, view: view)
        default:
            return BarStackPopover(item: item, tile: tile, edge: edge, view: view)
        }
    }

    /// Folders open in Explorer, anything else as Explorer opens it (as the system does without Explorer).
    static func open(_ url: URL) {
        if isBrowsableFolder(url) {
            ExplorerLink.open([url])
        } else {
            ExplorerLink.openFiles([url])
        }
    }
}

/// A folder, as opposed to a package or a file: stacks open these inside themselves.
private func isBrowsableFolder(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return values?.isDirectory == true && values?.isPackage != true
}

/// The items' icons, replaced by Quick Look thumbnails as they come.
final class BarStackIcons {
    private(set) var images: [URL: NSImage] = [:]
    var onChange: (() -> Void)?

    init(_ urls: [URL], side: CGFloat) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for url in urls {
            images[url] = NSWorkspace.shared.icon(forFile: url.path)
            guard BarFiles.showsThumbnails, BarFiles.hasThumbnail(url) else { continue }
            BarFiles.thumbnail(for: url, side: side, scale: scale) { [weak self] image in
                self?.images[url] = image
                self?.onChange?()
            }
        }
    }

    subscript(url: URL) -> NSImage? { images[url] }
}

/// Starts dragging a stack's item out, to copy or move it elsewhere.
private func beginDrag(_ url: URL, image: NSImage?, frame: NSRect, event: NSEvent,
                       source: NSView & NSDraggingSource) {
    let item = NSDraggingItem(pasteboardWriter: url as NSURL)
    item.setDraggingFrame(frame, contents: image)
    source.beginDraggingSession(with: [item], event: event, source: source)
}

/// Clicks reach it even though Explorer isn't the active app.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Grid

/// The grid: a bubble above the Dock icon with the items, newest first by default. A folder opens inside
/// it, with a back button, as in the system Dock; "Open in Explorer" shows the folder.
final class BarStackPopover: NSObject, BarStackPresenter, NSPopoverDelegate {
    var onClose: (() -> Void)?
    private let popover = NSPopover()
    private let tile: NSRect
    private weak var view: NSView?
    private var monitor: Any?
    private let edge: ScreenEdge

    init(item: BarItem, tile: NSRect, edge: ScreenEdge, view: NSView) {
        self.tile = tile
        self.edge = edge
        self.view = view
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = BarStackGridController(root: item.url, sort: item.sort,
                                                 maxHeight: (view.window?.screen?.visibleFrame.height ?? 800) - 160)
        controller.done = { [weak self] in self?.close() }
        controller.resized = { [weak self] size in self?.popover.contentSize = size }
        popover.contentViewController = controller
    }

    func show() {
        guard let view else { return }
        popover.show(relativeTo: tile, of: view, preferredEdge: edge == .bottom ? .maxY : edge == .left ? .maxX : .minX)
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

final class BarStackGridController: NSViewController {
    var done: (() -> Void)?
    var resized: ((NSSize) -> Void)?
    private let root: URL
    private let sort: BarStackSort
    private let maxHeight: CGFloat
    private var path: [URL]
    private let content = NSView()

    init(root: URL, sort: BarStackSort, maxHeight: CGFloat) {
        self.root = root
        self.sort = sort
        self.maxHeight = max(maxHeight, 240)
        path = [root]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = content
        build()
    }

    private var folder: URL { path.last ?? root }

    /// Lays out the current folder: header (inside a subfolder), grid, footer.
    private func build() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let urls = Array(BarStackOrder.contents(of: folder, sortedBy: path.count == 1 ? sort : .name)
            .prefix(BarStackGrid.limit))
        let grid = BarStackGrid(items: urls, maxHeight: maxHeight) { [weak self] url in self?.opened(url) }
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: grid.visibleSize))
        scroll.documentView = grid
        scroll.hasVerticalScroller = grid.frame.height > grid.visibleSize.height
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.scroll(to: .zero)

        let inset: CGFloat = 14
        let footerHeight: CGFloat = 34
        let headerHeight: CGFloat = path.count > 1 ? 34 : 0
        let width = max(grid.visibleSize.width, 300) + 2 * inset
        let height = headerHeight + grid.visibleSize.height + footerHeight + inset + 6
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scroll.frame = NSRect(x: (width - grid.visibleSize.width) / 2, y: footerHeight,
                              width: grid.visibleSize.width, height: grid.visibleSize.height)
        content.addSubview(scroll)

        if path.count > 1 {
            let parent = path[path.count - 2]
            let back = FirstClickButton(title: " " + FileManager.default.displayName(atPath: parent.path),
                                        image: NSImage(systemSymbolName: "chevron.left",
                                                       accessibilityDescription: T("Back"))!,
                                        target: self, action: #selector(goBack))
            back.isBordered = false
            back.imagePosition = .imageLeading
            back.contentTintColor = .controlAccentColor
            back.font = .systemFont(ofSize: 13)
            back.sizeToFit()
            back.frame.origin = NSPoint(x: inset - 2, y: height - headerHeight + (headerHeight - back.frame.height) / 2)
            let title = NSTextField(labelWithString: FileManager.default.displayName(atPath: folder.path))
            title.font = .boldSystemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingMiddle
            title.alignment = .center
            let titleWidth = width - 2 * (back.frame.maxX + 8)
            title.frame = NSRect(x: (width - titleWidth) / 2, y: back.frame.minY, width: max(titleWidth, 60),
                                 height: back.frame.height)
            content.addSubview(back)
            content.addSubview(title)
        }

        let open = FirstClickButton(title: T("Open in Explorer"),
                                    image: NSImage(systemSymbolName: "arrow.forward.circle.fill",
                                                   accessibilityDescription: nil)!,
                                    target: self, action: #selector(openFolder))
        open.isBordered = false
        open.imagePosition = .imageTrailing
        open.contentTintColor = .secondaryLabelColor
        open.font = .systemFont(ofSize: 13)
        open.sizeToFit()
        open.frame.origin = NSPoint(x: width - inset - open.frame.width, y: (footerHeight - open.frame.height) / 2 + 2)
        content.addSubview(open)

        let count = NSTextField(labelWithString: urls.count == 1 ? T("1 item") : String(format: T("%d items"), urls.count))
        count.font = .systemFont(ofSize: 12)
        count.textColor = .tertiaryLabelColor
        count.sizeToFit()
        count.frame.origin = NSPoint(x: inset, y: (footerHeight - count.frame.height) / 2 + 2)
        content.addSubview(count)

        preferredContentSize = content.frame.size
        resized?(content.frame.size)
    }

    private func opened(_ url: URL) {
        if isBrowsableFolder(url) {
            path.append(url)
            build()
        } else {
            ExplorerLink.openFiles([url])
            done?()
        }
    }

    @objc private func goBack() {
        guard path.count > 1 else { return }
        path.removeLast()
        build()
    }

    @objc private func openFolder() {
        ExplorerLink.open([folder])
        done?()
    }
}

/// The grid's items: icon (or thumbnail) and name, as the system Dock's grid.
final class BarStackGrid: NSView, NSDraggingSource {
    static let limit = 120
    private static let cell = NSSize(width: 96, height: 104)
    private static let iconSide: CGFloat = 64

    private let items: [URL]
    private let onOpen: (URL) -> Void
    private let icons: BarStackIcons
    private let columns: Int
    private let visibleRows: Int
    private var hovered: Int?
    private var pressed: (index: Int, at: NSPoint)?

    init(items: [URL], maxHeight: CGFloat, onOpen: @escaping (URL) -> Void) {
        self.items = items
        self.onOpen = onOpen
        icons = BarStackIcons(items, side: Self.iconSide)
        // Wider as items add up, up to seven columns, as the system Dock's grid grows.
        let count = items.count
        columns = count <= 3 ? max(count, 1) : min(7, max(3, Int((Double(count) * 1.6).squareRoot().rounded(.up))))
        let rows = max((count + columns - 1) / columns, 1)
        visibleRows = max(min(rows, Int(maxHeight / Self.cell.height)), 1)
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * Self.cell.width,
                                 height: CGFloat(rows) * Self.cell.height))
        icons.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var visibleSize: NSSize {
        NSSize(width: frame.width, height: CGFloat(visibleRows) * Self.cell.height)
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func frame(of index: Int) -> NSRect {
        NSRect(x: CGFloat(index % columns) * Self.cell.width, y: CGFloat(index / columns) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    private func iconFrame(of index: Int) -> NSRect {
        let cell = frame(of: index)
        return NSRect(x: cell.midX - Self.iconSide / 2, y: cell.minY + 6, width: Self.iconSide, height: Self.iconSide)
    }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { frame(of: $0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if items.isEmpty {
            let text = NSAttributedString(string: T("No items"), attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: bounds.midY - 8))
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        // Two lines, as in the system Dock's grid.
        style.lineBreakMode = .byWordWrapping
        for (index, url) in items.enumerated() {
            let cell = frame(of: index)
            guard cell.intersects(dirtyRect) else { continue }
            let icon = iconFrame(of: index)
            if hovered == index || pressed?.index == index {
                NSColor.labelColor.withAlphaComponent(pressed?.index == index ? 0.2 : 0.1).setFill()
                NSBezierPath(roundedRect: icon.insetBy(dx: -6, dy: -4), xRadius: 8, yRadius: 8).fill()
            }
            icons[url]?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                             hints: nil)
            let name = NSAttributedString(string: FileManager.default.displayName(atPath: url.path), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            name.draw(with: NSRect(x: cell.minX + 4, y: icon.maxY + 3, width: cell.width - 8, height: 30),
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
        beginDrag(url, image: icons[url], frame: iconFrame(of: pressed.index), event: event, source: self)
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

// MARK: - Fan

/// The fan: the items rising from the Dock icon in a curve, each name in a dark label on its left,
/// "Open in Explorer" (or how many more there are) at the top, as the system Dock's fan.
final class BarFanPanel: NSPanel, BarStackPresenter {
    static let step: CGFloat = 56
    static let iconSide: CGFloat = 48
    /// From the item's left edge to its icon's centre: room for the name.
    static let labelRoom: CGFloat = 300

    var onClose: (() -> Void)?
    private let folder: URL
    private let anchor: NSPoint
    private let icons: BarStackIcons
    private var itemViews: [BarFanItemView] = []
    private var monitors: [Any] = []
    private var isClosing = false

    init(item: BarItem, urls: [URL], anchor: NSPoint, capacity: Int) {
        folder = item.url
        self.anchor = anchor
        let shown = Array(urls.prefix(capacity))
        icons = BarStackIcons(shown, side: Self.iconSide)
        let places = BarFan.places(count: shown.count + 1, step: Self.step)
        let bend = places.last?.center.x ?? 0
        let width = Self.labelRoom + bend + Self.iconSide + 40
        let height = Self.step * CGFloat(places.count) + BarFanItemView.height / 2
        let frame = NSRect(x: anchor.x - Self.labelRoom - 10, y: anchor.y, width: width, height: height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        contentView = container
        // The icon centre's x in the panel, at the Dock icon's middle.
        let originX = anchor.x - frame.minX
        for (index, place) in places.enumerated() {
            let isMore = index == shown.count
            let view: BarFanItemView
            if isMore {
                let more = urls.count - shown.count
                view = BarFanItemView(url: nil, title: more > 0 ? String(format: T("%d More in Explorer"), more) : T("Open in Explorer"),
                                       icons: icons, angle: place.angle)
                view.onOpen = { [weak self] in
                    guard let self else { return }
                    ExplorerLink.open([self.folder])
                    self.close()
                }
            } else {
                let url = shown[index]
                view = BarFanItemView(url: url, title: FileManager.default.displayName(atPath: url.path),
                                       icons: icons, angle: place.angle)
                view.onOpen = { [weak self] in
                    BarStacks.open(url)
                    self?.close()
                }
            }
            view.finalOrigin = NSPoint(x: originX + place.center.x - BarFanItemView.iconCenterX,
                                       y: place.center.y - BarFanItemView.height / 2)
            view.setFrameOrigin(NSPoint(x: originX - BarFanItemView.iconCenterX, y: -BarFanItemView.height / 2))
            view.alphaValue = 0
            container.addSubview(view)
            itemViews.append(view)
        }
        icons.onChange = { [weak self] in self?.itemViews.forEach { $0.needsDisplay = true } }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for view in itemViews {
                view.animator().setFrameOrigin(view.finalOrigin)
                view.animator().alphaValue = 1
            }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close() }
            return event
        } as Any)
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let start = NSPoint(x: anchor.x - frame.minX - BarFanItemView.iconCenterX, y: -BarFanItemView.height / 2)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            for view in itemViews {
                view.animator().setFrameOrigin(start)
                view.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onClose?()
        })
    }
}

/// One item of the fan: its name in a dark rounded label, then its icon, tilted along the curve.
final class BarFanItemView: NSView, NSDraggingSource {
    static let iconCenterX: CGFloat = BarFanPanel.labelRoom
    static let height: CGFloat = 160
    var onOpen: (() -> Void)?
    var finalOrigin: NSPoint = .zero
    private let url: URL?
    private let title: String
    private let icons: BarStackIcons
    private let angle: CGFloat
    private var isHovered = false
    private var pressedAt: NSPoint?

    init(url: URL?, title: String, icons: BarStackIcons, angle: CGFloat) {
        self.url = url
        self.title = title
        self.icons = icons
        self.angle = angle
        // Taller than a step: tilted, a long name rises or falls beyond its row.
        super.init(frame: NSRect(x: 0, y: 0, width: BarFanPanel.labelRoom + BarFanPanel.iconSide,
                                 height: Self.height))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var iconFrame: NSRect {
        let side = BarFanPanel.iconSide
        return NSRect(x: Self.iconCenterX - side / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    private var labelText: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
            .paragraphStyle: style])
    }

    private var labelFrame: NSRect {
        let size = labelText.size()
        let width = min(ceil(size.width) + 20, Self.iconCenterX - BarFanPanel.iconSide / 2 - 12)
        let height = ceil(size.height) + 6
        return NSRect(x: iconFrame.minX - 8 - width, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// The label and the icon: what takes clicks.
    private var activeFrame: NSRect { labelFrame.union(iconFrame) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        activeFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: iconFrame.midX, yBy: iconFrame.midY)
        turn.rotate(byDegrees: -angle)
        turn.translateX(by: -iconFrame.midX, yBy: -iconFrame.midY)
        turn.concat()

        let label = labelFrame
        let pill = NSBezierPath(roundedRect: label, xRadius: label.height / 2, yRadius: label.height / 2)
        (isHovered ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.62)).setFill()
        pill.fill()
        labelText.draw(with: label.insetBy(dx: 10, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if let url {
            icons[url]?.draw(in: iconFrame)
        } else {
            let circle = iconFrame.insetBy(dx: 6, dy: 6)
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            if let arrow = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                    arrow.draw(in: rect)
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: circle.midX - arrow.size.width / 2, y: circle.midY - arrow.size.height / 2,
                                       width: arrow.size.width, height: arrow.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: activeFrame, options: [.activeAlways, .mouseEnteredAndExited],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt, let url else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressedAt.x, point.y - pressedAt.y) > 4 else { return }
        self.pressedAt = nil
        beginDrag(url, image: icons[url], frame: iconFrame, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard pressedAt != nil, activeFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.move, .copy, .generic]
    }
}

// MARK: - List

/// The list: a menu of the items with small icons, folders opening as submenus, as the system Dock's list.
final class BarStackList: NSObject, BarStackPresenter, NSMenuDelegate {
    private static let limit = 200
    var onClose: (() -> Void)?
    private let item: BarItem
    private let urls: [URL]
    private let tile: NSRect
    private weak var view: NSView?
    private var menu: NSMenu?

    private let edge: ScreenEdge

    init(item: BarItem, urls: [URL], tile: NSRect, edge: ScreenEdge, view: NSView) {
        self.edge = edge
        self.item = item
        self.urls = urls
        self.tile = tile
        self.view = view
    }

    func show() {
        guard let view else { return }
        let menu = makeMenu(urls, folder: item.url)
        self.menu = menu
        // Runs until the menu closes.
        let point: NSPoint
        switch edge {
        case .bottom: point = NSPoint(x: tile.minX, y: tile.maxY + 6)
        case .left: point = NSPoint(x: tile.maxX + 6, y: tile.maxY)
        case .right: point = NSPoint(x: tile.minX - 6 - menu.size.width, y: tile.maxY)
        }
        menu.popUp(positioning: nil, at: point, in: view)
        self.menu = nil
        onClose?()
    }

    func close() {
        menu?.cancelTracking()
    }

    private func makeMenu(_ urls: [URL], folder: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for url in urls.prefix(Self.limit) {
            let entry = BarMenuItem(title: FileManager.default.displayName(atPath: url.path)) { BarStacks.open(url) }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            if isBrowsableFolder(url) {
                // Filled when it opens.
                let submenu = NSMenu()
                submenu.delegate = self
                submenu.identifier = NSUserInterfaceItemIdentifier(url.path)
                entry.submenu = submenu
            }
            menu.addItem(entry)
        }
        if urls.isEmpty {
            let empty = NSMenuItem(title: T("No items"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(BarMenuItem(title: T("Open in Explorer")) { ExplorerLink.open([folder]) })
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty, let path = menu.identifier?.rawValue else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let filled = makeMenu(BarStackOrder.contents(of: folder, sortedBy: .name), folder: folder)
        let items = filled.items
        filled.removeAllItems()
        items.forEach(menu.addItem)
    }
}
