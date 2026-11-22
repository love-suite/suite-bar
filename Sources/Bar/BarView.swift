import AppKit
import BarCore
import BarSettings
import SuiteCore
import SuiteFilesCore
import SuiteFilesUI

/// The Dock's icons: Explorer, the pinned apps, the running and recent ones, the folders and files kept
/// in it (Downloads), the minimized windows and the Trash, as the system Dock. Click to open, drag a pinned
/// app or a folder to reorder it (or up and away to remove it), drop files to open, move or trash them,
/// drag the separator up or down to resize.
final class BarView: NSView {
    var options = BarSettings() {
        didSet {
            guard options != oldValue else { return }
            if options.iconSize != oldValue.iconSize {
                icons.removeAll()
                refreshItems()
            }
            if !options.magnifies { stopMagnifying() }
            reload()
            // Its side, its magnification or its size changed the panel's.
            onSizeChange?()
        }
    }
    /// The room along the screen's edge: icons shrink, as in the system Dock, when they wouldn't fit.
    var fittingLength: CGFloat = .infinity {
        didSet { if fittingLength != oldValue { reload() } }
    }
    var geometry: BarGeometry {
        let chosen = options.geometry
        let length = chosen.barSize(for: tiles).width + 2 * reach(for: chosen)
        guard length > fittingLength else { return chosen }
        return BarGeometry(iconSize: (chosen.iconSize * fittingLength / length).rounded(.down))
    }
    /// The side of the screen the Dock is on. The view lays itself out in the Dock's own coordinates, as
    /// at the bottom (x along the bar, y away from the screen's edge), turned to that side by `toView`.
    var edge: ScreenEdge { ScreenEdge(options.position) }
    /// Called when the bar changes size, so the panel can follow.
    var onSizeChange: (() -> Void)?
    /// Called when the bar as drawn changes (icons magnified), so its background can follow.
    var onBarChange: (() -> Void)?
    /// The bar at rest, in the Dock's coordinates.
    var barSize: NSSize { geometry.barSize(for: tiles) }
    /// Room above the bar, where icons bounce while their app opens and grow under the pointer.
    var headroom: CGFloat {
        max(bounceHeight, options.magnifies ? options.magnifiedIconSize - geometry.iconSize + 8 : 0)
    }
    private var bounceHeight: CGFloat { (geometry.iconSize * 0.6).rounded() }
    /// How far magnified icons may push the bar's ends out, kept clear on each side of it.
    private var reach: CGFloat { reach(for: geometry) }
    private func reach(for geometry: BarGeometry) -> CGFloat {
        options.magnifies ? geometry.magnificationReach(size: options.magnifiedIconSize) : 0
    }
    /// The view's length along the edge, and its thickness.
    private var length: CGFloat { barSize.width + 2 * reach }
    private var thickness: CGFloat { barSize.height + headroom }
    var panelSize: NSSize {
        edge == .bottom ? NSSize(width: length, height: thickness) : NSSize(width: thickness, height: length)
    }
    /// The bar at rest, in the view's coordinates: where the panel is placed, windows and the pointer kept.
    var restBarRect: NSRect { toView(NSRect(x: reach, y: 0, width: barSize.width, height: barSize.height)) }
    /// The bar as drawn, magnified icons pushing its ends out, in the view's coordinates.
    var drawnBarRect: NSRect { toView(barRect) }

    private(set) var tiles: [BarTile] = []
    /// A stack is open, an icon is being dragged or a drop is on its way: the Dock mustn't slide away.
    var isBusy: Bool {
        stack != nil || pressed != nil || reorder != nil || dropTarget != nil || isDropping || resizing != nil
    }
    private var isDropping = false
    private var running: [String: NSRunningApplication] = [:]
    private var quitRequests = QuitRequests()
    private var icons: [String: NSImage] = [:]
    private var itemIcons: [String: NSImage] = [:]
    private var trashIsFull = false
    private var trashWatcher: DirectoryWatcher?
    private var itemWatchers: [String: DirectoryWatcher] = [:]
    private var observers: [NSObjectProtocol] = []
    private var recents: BarRecents

    private let store: BarStore
    private let itemStore: BarItemStore
    private let label = BarLabel()
    private var stack: BarStackPresenter?
    private var stackTile: Int?

    // Mouse state.
    private var pressed: Int?
    private var pressLocation: NSPoint = .zero
    private var reorder: (from: Int, x: CGFloat, removing: Bool)?
    private var resizing: (y: CGFloat, size: CGFloat)?
    private var dropTarget: Int?
    private var draggingVolumes = false
    private var acceptsDrop: [String: Bool] = [:]

    // Icons growing under the pointer.
    private var magnification: BarMagnification?
    private var magnifyTarget: CGFloat = 0
    private var magnifyTimer: Timer?

    // Apps opening: their icons bounce.
    private var bouncing: [String: Date] = [:]
    private var bounceTimer: Timer?
    private static let bouncePeriod: TimeInterval = 0.7

    private static let recentsKey = "BarRecentApps"

    init(store: BarStore = .shared, itemStore: BarItemStore = .shared) {
        self.store = store
        self.itemStore = itemStore
        recents = UserDefaults.standard.data(forKey: Self.recentsKey)
            .flatMap { try? JSONDecoder().decode(BarRecents.self, from: $0) } ?? BarRecents()
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.reload() })
        observers.append(workspace.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let url = app.bundleURL else { return }
            self?.startBouncing(BarApp(url: url, bundleID: app.bundleIdentifier))
            self?.reload()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.activationPolicy == .regular, let url = app.bundleURL {
                self?.remember(BarApp(url: url, bundleID: app.bundleIdentifier, name: app.localizedName))
            }
            self?.reload()
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        }
        // Clipboard is in the Dock only while its history window is open: it changes its activation
        // policy without launching, and says so. Another process's policy reaches this one a moment later.
        observers.append(ClipboardMessage.dockPresenceDidChange.observe { [weak self] _ in
            for delay in [0.2, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.reload() }
            }
        })
        for name in [BarStore.didChange, MinimizedWindows.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                    queue: .main) { [weak self] _ in self?.reload() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: BarItemStore.didChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            self?.refreshItems()
            self?.reload()
        })
        observers.append(NotificationCenter.default.addObserver(forName: BarBadges.didChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
        let trash = DirectoryWatcher(url: BarFiles.trash) { [weak self] in
            DispatchQueue.main.async { self?.refreshTrash() }
        }
        trash.start()
        trashWatcher = trash
        refreshTrash()
        refreshItems()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Contents

    func reload() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleURL != nil
                && !BarHiddenApps.contains($0.bundleIdentifier)
        }
        running = [:]
        var runningApps: [BarApp] = []
        for app in apps {
            guard let url = app.bundleURL else { continue }
            let barApp = BarApp(url: url, bundleID: app.bundleIdentifier, name: app.localizedName)
            runningApps.append(barApp)
            running[key(barApp)] = app
        }
        let old = panelSize
        tiles = BarLayout.tiles(pinned: store.pins.apps, running: runningApps,
                                 minimized: options.minimizesIntoApp ? [] : MinimizedWindows.shared.windows,
                                 items: itemStore.items, recents: options.showsRecents ? recents.apps : nil,
                                 explorer: store.explorer)
        needsDisplay = true
        if panelSize != old { onSizeChange?() }
    }

    private func remember(_ app: BarApp) {
        guard !store.isPinned(app) else { return }
        recents.used(app)
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: Self.recentsKey)
    }

    private func forget(_ app: BarApp) {
        recents.forget(app)
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: Self.recentsKey)
        reload()
    }

    /// The folders' and files' icons, and a watcher on each folder so its stack follows its contents.
    private func refreshItems() {
        let items = itemStore.items
        let folders = Set(items.filter(\.isFolder).map(\.path))
        for path in itemWatchers.keys where !folders.contains(path) {
            itemWatchers[path]?.stop()
            itemWatchers[path] = nil
        }
        for path in folders where itemWatchers[path] == nil {
            let watcher = DirectoryWatcher(url: URL(fileURLWithPath: path, isDirectory: true)) { [weak self] in
                DispatchQueue.main.async { self?.refreshItem(path) }
            }
            watcher.start()
            itemWatchers[path] = watcher
        }
        items.forEach { refreshIcon(of: $0) }
        needsDisplay = true
    }

    private func refreshItem(_ path: String) {
        guard let item = itemStore.items.first(where: { $0.path == path }) else { return }
        refreshIcon(of: item)
        needsDisplay = true
    }

    /// A folder shows its own icon or its first items piled up (thumbnails once made); a file its icon.
    private func refreshIcon(of item: BarItem) {
        let side = geometry.iconSize
        guard item.isFolder, item.display == .stack else {
            itemIcons[item.path] = NSWorkspace.shared.icon(forFile: item.path)
            return
        }
        let first = Array(BarStackOrder.contents(of: item.url, sortedBy: item.sort).prefix(3))
        guard !first.isEmpty else {
            itemIcons[item.path] = NSWorkspace.shared.icon(forFile: item.path)
            return
        }
        itemIcons[item.path] = StackIcon.image(for: first, side: side, expanded: false)
        guard BarFiles.showsThumbnails else { return }
        var pictures = first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (index, url) in first.enumerated() {
            guard BarFiles.hasThumbnail(url) else { continue }
            BarFiles.thumbnail(for: url, side: side, scale: scale) { [weak self] image in
                pictures[index] = image
                self?.itemIcons[item.path] = StackIcon.image(icons: pictures, side: side)
                self?.needsDisplay = true
            }
        }
    }

    private func refreshTrash() {
        // Listing the Trash needs Full Disk Access; without it the Trash shows empty.
        // All its folders count: what was deleted from iCloud Drive or a disk fills it too.
        trashIsFull = !BarFiles.trashContents().isEmpty
        needsDisplay = true
    }

    private func key(_ app: BarApp) -> String { app.bundleID ?? app.path }

    /// Where the app is now: its running copy, its saved place, or wherever Launch Services finds it.
    private func location(of app: BarApp) -> URL? {
        if BarStore.isExplorer(app) { return Bundle.main.bundleURL }
        if let url = running[key(app)]?.bundleURL { return url }
        if FileManager.default.fileExists(atPath: app.path) { return app.url }
        return app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private func icon(for tile: BarTile) -> NSImage? {
        switch tile {
        case .app(let app, _, _):
            if BarStore.isExplorer(app) { return NSApp.applicationIconImage }
            if let cached = icons[key(app)] { return cached }
            let image = running[key(app)]?.icon
                ?? location(of: app).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
            icons[key(app)] = image
            return image
        case .item(let item):
            return itemIcons[item.path] ?? NSWorkspace.shared.icon(forFile: item.path)
        case .window(let window):
            let appIcon = icon(for: .app(window.app, isPinned: false, isRunning: true))
            return Self.minimizedIcon(badge: appIcon)
        case .trash:
            if draggingVolumes { return Self.ejectIcon }
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName)
        case .separator:
            return nil
        }
    }

    /// The Trash while a disk is dragged over the Dock: dropping it there ejects it.
    private static let ejectIcon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        let circle = rect.insetBy(dx: 6, dy: 6)
        NSColor(white: 0.25, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: T("Eject"))?
            .withSymbolConfiguration(configuration) {
            let frame = NSRect(x: circle.midX - symbol.size.width / 2, y: circle.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: frame)
            NSColor.white.set()
            frame.fill(using: .sourceAtop)
        }
        return true
    }

    /// A minimized window: a small window with its app's icon in the corner, as the system Dock shows one
    /// (its picture would need the Screen Recording permission).
    static func minimizedIcon(badge: NSImage?) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let window = NSRect(x: 4, y: 12, width: 56, height: 44)
            let shape = NSBezierPath(roundedRect: window, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: window.minX, y: window.maxY - 9, width: window.width, height: 9).fill()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: window.minX + 5 + CGFloat(index) * 8, y: window.maxY - 7,
                                            width: 5, height: 5)).fill()
            }
            badge?.draw(in: NSRect(x: rect.maxX - 34, y: 0, width: 34, height: 34))
            return true
        }
    }

    private func name(of tile: BarTile) -> String {
        switch tile {
        case .app(let app, _, _):
            if BarStore.isExplorer(app) { return "Explorer" }
            return running[key(app)]?.localizedName ?? app.name
        case .item(let item): return item.name
        case .window(let window): return window.title
        case .trash: return draggingVolumes ? T("Eject") : T("Trash")
        case .separator: return ""
        }
    }

    // MARK: Layout

    /// The tiles' frames in the Dock's coordinates, magnified under the pointer.
    private var frames: [CGRect] {
        geometry.frames(for: tiles, magnification: magnification).map { $0.offsetBy(dx: reach, dy: 0) }
    }

    /// The tile under `point` (in the Dock's coordinates), separators excluded.
    private func tileIndex(at point: CGPoint) -> Int? {
        let frames = self.frames
        return frames.indices.first { frames[$0].contains(point) && tiles[$0] != .separator }
    }

    /// From the Dock's coordinates to the view's: at the bottom the same; on the sides turned, the first
    /// tile at the top and the bar's bottom against the screen's edge.
    private func toView(_ rect: NSRect) -> NSRect {
        switch edge {
        case .bottom: return rect
        case .left: return NSRect(x: rect.minY, y: length - rect.maxX, width: rect.height, height: rect.width)
        case .right:
            return NSRect(x: thickness - rect.maxY, y: length - rect.maxX, width: rect.height, height: rect.width)
        }
    }

    /// A point of the window, in the Dock's coordinates.
    private func logical(_ windowPoint: NSPoint) -> NSPoint {
        let point = convert(windowPoint, from: nil)
        switch edge {
        case .bottom: return point
        case .left: return NSPoint(x: length - point.y, y: point.x)
        case .right: return NSPoint(x: length - point.y, y: thickness - point.x)
        }
    }

    /// How far a screen point is from the screen's edge the Dock is on, for resizing it by dragging.
    private func outward(_ screenPoint: NSPoint) -> CGFloat {
        switch edge {
        case .bottom: return screenPoint.y
        case .left: return screenPoint.x
        case .right: return -screenPoint.x
        }
    }

    private var resizeCursor: NSCursor { edge == .bottom ? .resizeUpDown : .resizeLeftRight }

    // MARK: Drawing

    /// The tiles' frames as drawn: while a pinned app or a folder is dragged, the others of its group make
    /// room where it would land.
    private var drawnFrames: [CGRect] {
        var frames = self.frames
        guard let reorder, !reorder.removing, let group = reorderGroup(of: reorder.from) else { return frames }
        let slots = group.map { frames[$0] }
        let others = group.filter { $0 != reorder.from }
        let target = BarGeometry.insertionIndex(forX: reorder.x, pinnedFrames: others.map { frames[$0] })
        var order = others
        order.insert(reorder.from, at: target)
        for (slot, index) in zip(slots.indices, order) {
            frames[index] = slots[slot]
        }
        return frames
    }

    private var pinnedRange: [Int] {
        tiles.indices.filter { if case .app(_, true, _) = tiles[$0] { return true } else { return false } }
    }

    private var itemRange: [Int] {
        tiles.indices.filter { if case .item = tiles[$0] { return true } else { return false } }
    }

    /// The tiles a dragged one can be reordered among: the pinned apps, or the folders and files.
    private func reorderGroup(of index: Int) -> [Int]? {
        switch tiles[index] {
        case .app(_, true, _): return pinnedRange
        case .item: return itemRange
        default: return nil
        }
    }

    /// The bar, below the room kept for bouncing and magnified icons, its ends pushed out by magnified
    /// icons, in the Dock's coordinates.
    private var barRect: NSRect {
        let frames = self.frames
        guard let first = frames.first, let last = frames.last else {
            return NSRect(x: reach, y: 0, width: barSize.width, height: geometry.barHeight)
        }
        return NSRect(x: first.minX - geometry.margin, y: 0, width: last.maxX - first.minX + 2 * geometry.margin,
                      height: geometry.barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = toView(barRect)
        let radius = min(geometry.barHeight * 0.3, 18)
        let border = NSBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()

        let frames = drawnFrames
        for (index, tile) in tiles.enumerated() {
            var frame = frames[index]
            if let reorder, reorder.from == index {
                if reorder.removing { continue }
                frame.origin.x = reorder.x - frame.width / 2
            }
            if tile == .separator {
                NSColor.separatorColor.setFill()
                let height = geometry.barHeight
                toView(NSRect(x: frame.midX.rounded() - 0.5, y: height * 0.18, width: 1, height: height * 0.64)).fill()
                continue
            }
            var logicalIcon = geometry.iconFrame(in: frame)
            if let app = tile.app { logicalIcon.origin.y += bounceOffset(for: app) }
            let iconFrame = toView(logicalIcon)
            if dropTarget == index {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: iconFrame.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
            }
            icon(for: tile)?.draw(in: iconFrame, from: .zero, operation: .sourceOver,
                                  fraction: isMissing(tile) ? 0.4 : 1)
            if pressed == index || stackTile == index, reorder == nil {
                NSColor.black.withAlphaComponent(0.35).setFill()
                iconFrame.fill(using: .sourceAtop)
            }
            if options.showsIndicators, isRunning(tile) {
                let side = max(4, (geometry.iconSize * 0.08).rounded())
                NSColor.labelColor.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: toView(NSRect(x: frame.midX - side / 2, y: (geometry.dotArea - side) / 2 + 1,
                                                   width: side, height: side))).fill()
            }
            if case .app(let app, _, true) = tile, let url = running[key(app)]?.bundleURL,
               let badge = BarBadges.shared.label(for: url) {
                drawBadge(badge, on: iconFrame)
            }
        }
    }

    /// An app's badge: a red rounded label at the icon's top right corner.
    private func drawBadge(_ text: String, on icon: NSRect) {
        let height = (icon.height * 0.36).rounded()
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: height * 0.62, weight: .semibold), .foregroundColor: NSColor.white])
        let size = string.size()
        let width = max(height, ceil(size.width) + height * 0.5)
        let frame = NSRect(x: icon.maxX - width * 0.8, y: icon.maxY - height * 0.85, width: width, height: height)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2).fill()
        string.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    private func isRunning(_ tile: BarTile) -> Bool {
        switch tile {
        case .app(_, _, let isRunning): return isRunning
        default: return false
        }
    }

    private func isMissing(_ tile: BarTile) -> Bool {
        if case .item(let item) = tile { return !FileManager.default.fileExists(atPath: item.path) }
        guard let app = tile.app else { return false }
        return location(of: app) == nil
    }

    // MARK: Bouncing

    private func startBouncing(_ app: BarApp) {
        guard options.animatesLaunch, bouncing[key(app)] == nil else { return }
        bouncing[key(app)] = Date()
        guard bounceTimer == nil else { return }
        bounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.bounceStep()
        }
    }

    /// Bounces go on until the app has finished launching, a whole bounce at least, ten seconds at most.
    private func bounceStep() {
        let now = Date()
        for (key, start) in bouncing {
            let elapsed = now.timeIntervalSince(start)
            let phase = elapsed.truncatingRemainder(dividingBy: Self.bouncePeriod)
            let atRest = elapsed >= Self.bouncePeriod && phase < 1.0 / 30
            let launched = running[key]?.isFinishedLaunching ?? false
            if elapsed > 10 || (atRest && launched) { bouncing[key] = nil }
        }
        if bouncing.isEmpty {
            bounceTimer?.invalidate()
            bounceTimer = nil
        }
        needsDisplay = true
    }

    private func bounceOffset(for app: BarApp) -> CGFloat {
        guard let start = bouncing[key(app)] else { return 0 }
        let phase = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: Self.bouncePeriod)
            / Self.bouncePeriod
        return (sin(phase * .pi) * bounceHeight * 0.9).rounded()
    }

    // MARK: Magnification

    /// The pointer anywhere on screen (from the Dock's pointer monitor): icons grow while it is over the
    /// bar, and shrink back once it leaves.
    func pointerMoved(to screenPoint: NSPoint) {
        guard options.magnifies, let window else {
            if magnification != nil { stopMagnifying() }
            return
        }
        // Frozen while a tile is pressed, so the click lands where it began.
        guard pressed == nil else { return }
        let point = logical(window.convertPoint(fromScreen: screenPoint))
        let bar = barRect
        let over = stack == nil && reorder == nil && resizing == nil
            && (NSRect(x: bar.minX, y: -4, width: bar.width, height: bar.height + 4).contains(point)
                || frames.contains { $0.contains(point) })
        if over {
            magnification = BarMagnification(size: options.magnifiedIconSize, pointer: point.x - reach,
                                              amount: magnification?.amount ?? 0)
            needsDisplay = true
            onBarChange?()
        }
        animateMagnification(to: over ? 1 : 0)
    }

    private func animateMagnification(to target: CGFloat) {
        magnifyTarget = target
        guard magnifyTimer == nil, magnification != nil, magnification?.amount != target else { return }
        magnifyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.magnifyStep()
        }
    }

    /// About a tenth of a second to grow or shrink fully.
    private func magnifyStep() {
        guard var current = magnification else { return finishMagnifying() }
        let step: CGFloat = 1.0 / 6
        current.amount = magnifyTarget > current.amount ? min(current.amount + step, magnifyTarget)
                                                        : max(current.amount - step, magnifyTarget)
        magnification = current.amount > 0 ? current : nil
        needsDisplay = true
        onBarChange?()
        if magnification == nil || current.amount == magnifyTarget { finishMagnifying() }
    }

    private func finishMagnifying() {
        magnifyTimer?.invalidate()
        magnifyTimer = nil
    }

    /// Back to rest at once: before a stack opens, a drag starts or the Dock is resized.
    private func stopMagnifying() {
        finishMagnifying()
        guard magnification != nil else { return }
        magnification = nil
        needsDisplay = true
        onBarChange?()
    }

    // MARK: Hover label

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard reorder == nil else { return }
        let point = logical(event.locationInWindow)
        if separatorIndex(at: point) != nil {
            resizeCursor.set()
            label.hide()
            return
        }
        NSCursor.arrow.set()
        if let index = tileIndex(at: point), stack == nil {
            showLabel(name(of: tiles[index]), over: frames[index])
        } else {
            label.hide()
        }
    }

    override func mouseExited(with event: NSEvent) {
        label.hide()
        if resizing == nil { NSCursor.arrow.set() }
    }

    /// The name beside the tile's icon (`frame` in the Dock's coordinates), on the screen's side.
    private func showLabel(_ text: String, over frame: CGRect) {
        guard let window else { return }
        var icon = geometry.iconFrame(in: frame)
        icon.size.height += geometry.tilePadding + 4
        label.show(text, beside: window.convertToScreen(convert(toView(icon), to: nil)), edge: edge, parent: window)
    }

    private func separatorIndex(at point: NSPoint) -> Int? {
        let frames = frames
        return tiles.indices.first { tiles[$0] == .separator && frames[$0].contains(point) }
    }

    // MARK: Clicks, reordering and resizing

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        pressLocation = logical(event.locationInWindow)
        label.hide()
        if separatorIndex(at: pressLocation) != nil {
            resizing = (outward(NSEvent.mouseLocation), geometry.iconSize)
            stopMagnifying()
            return
        }
        pressed = tileIndex(at: pressLocation)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizing {
            // As the system Dock: up makes it bigger, down smaller.
            let size = resizing.size + (outward(NSEvent.mouseLocation) - resizing.y)
            let stepped = (min(max(size, BarGeometry.sizes.lowerBound), BarGeometry.sizes.upperBound) / 4)
                .rounded() * 4
            if stepped != BarSettings.current.iconSize { BarSettings.current.iconSize = stepped }
            resizeCursor.set()
            return
        }
        guard let pressed, let group = reorderGroup(of: pressed) else { return }
        let point = logical(event.locationInWindow)
        if reorder == nil, hypot(point.x - pressLocation.x, point.y - pressLocation.y) < 5 { return }
        if reorder == nil { stopMagnifying() }
        // Dragged well above the Dock, the tile is removed on release, as in the system Dock.
        let removing = point.y > geometry.barHeight + geometry.iconSize
        let frames = frames
        let slots = group.map { frames[$0] }
        let x = min(max(point.x, (slots.first?.minX ?? 0)), (slots.last?.maxX ?? bounds.maxX))
        reorder = (pressed, x, removing)
        if removing {
            showLabel(T("Remove"), over: frames[pressed].offsetBy(dx: point.x - pressLocation.x, dy: 0))
        } else {
            label.hide()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            reorder = nil
            resizing = nil
            label.hide()
            needsDisplay = true
        }
        if resizing != nil { return }
        if let reorder, let group = reorderGroup(of: reorder.from) {
            let frames = frames
            let others = group.filter { $0 != reorder.from }
            let index = BarGeometry.insertionIndex(forX: reorder.x, pinnedFrames: others.map { frames[$0] })
            switch tiles[reorder.from] {
            case .app(let app, _, _):
                if reorder.removing {
                    store.unpin(app)
                    FinderSounds.play(.poof)
                } else {
                    var pins = store.pins
                    pins.unpin(app)
                    pins.pin(app, at: index)
                    if pins != store.pins { store.pins = pins }
                }
            case .item(let item):
                if reorder.removing {
                    itemStore.remove(item)
                    FinderSounds.play(.poof)
                } else {
                    var items = itemStore.items.filter { !$0.isSameItem(as: item) }
                    items.insert(item, at: min(index, items.count))
                    if items != itemStore.items { itemStore.items = items }
                }
            default:
                break
            }
            return
        }
        let point = logical(event.locationInWindow)
        guard let pressed, tileIndex(at: point) == pressed else { return }
        open(tiles[pressed], at: pressed, modifiers: event.modifierFlags)
    }

    private func open(_ tile: BarTile, at index: Int, modifiers: NSEvent.ModifierFlags = []) {
        switch tile {
        case .app(let app, _, _) where BarStore.isExplorer(app):
            ExplorerLink.activate()
            NSApp.activate(ignoringOtherApps: true)
        case .app(let app, let isPinned, _):
            guard let url = location(of: app) else {
                if isPinned { askToRemoveMissing(app) } else { forget(app) }
                return
            }
            // ⌘-click shows the app in Explorer, as the system Dock shows it in Finder.
            if modifiers.contains(.command) {
                ExplorerLink.reveal([url])
                return
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let runningApp = running[key(app)]
            if runningApp == nil { startBouncing(app) }
            if let runningApp, options.minimizesIntoApp, !AppWindow.hasWindowOnScreen(runningApp),
               let window = MinimizedWindows.shared.windows.last(where: { $0.app.isSameApp(as: app) }) {
                // Windows minimized into the icon come back with a click on it.
                MinimizedWindows.shared.restore(window.id)
            } else {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if let error { DispatchQueue.main.async { BarFiles.showError(error.localizedDescription) } }
                }
            }
            // ⌥-click hides the app that was in front.
            if modifiers.contains(.option), let previous, previous != runningApp,
               previous.processIdentifier != getpid() {
                previous.hide()
            }
        case .item(let item):
            if modifiers.contains(.command) {
                ExplorerLink.reveal([item.url])
            } else if !FileManager.default.fileExists(atPath: item.path) {
                askToRemoveMissing(item)
            } else if item.isFolder {
                showStack(item, at: index)
            } else {
                ExplorerLink.openFiles([item.url])
            }
        case .window(let window):
            MinimizedWindows.shared.restore(window.id)
        case .trash:
            ExplorerLink.open([BarFiles.trash])
        case .separator:
            break
        }
    }

    private func askToRemoveMissing(_ app: BarApp) {
        if askToRemove(app.name) { store.unpin(app) }
    }

    private func askToRemoveMissing(_ item: BarItem) {
        if askToRemove(item.name) { itemStore.remove(item) }
    }

    private func askToRemove(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(format: T("\u{201C}%@\u{201D} can't be found."), name)
        alert.informativeText = T("It may have been moved or deleted.")
        alert.addButton(withTitle: T("Remove from Dock"))
        alert.addButton(withTitle: T("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showStack(_ item: BarItem, at index: Int) {
        if let stack {
            stack.close()
            return
        }
        label.hide()
        stopMagnifying()
        guard let presenter = BarStacks.presenter(for: item, tile: toView(frames[index]), edge: edge, in: self)
        else { return }
        presenter.onClose = { [weak self] in
            self?.stack = nil
            self?.stackTile = nil
            self?.needsDisplay = true
        }
        stack = presenter
        stackTile = index
        needsDisplay = true
        presenter.show()
    }

    // MARK: Right-click menus

    override func rightMouseDown(with event: NSEvent) {
        label.hide()
        stack?.close()
        let point = logical(event.locationInWindow)
        let index = tileIndex(at: point)
        NSMenu.popUpContextMenu(menu(for: index.map { tiles[$0] }), with: event, for: self)
    }

    private func menu(for tile: BarTile?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, to menu: NSMenu = menu, _ action: @escaping () -> Void) {
            menu.addItem(BarMenuItem(title: title, action: action))
        }
        switch tile {
        case .app(let app, let isPinned, _)? where BarStore.isExplorer(app):
            addWindows(of: NSRunningApplication.current, to: menu)
            add(T("New Explorer Window")) {
                ExplorerLink.open([FileManager.default.homeDirectoryForCurrentUser])
            }
            menu.addItem(.separator())
            let options = NSMenu()
            let keep = BarMenuItem(title: T("Keep in Dock")) { [store] in
                isPinned ? store.unpin(app) : store.pin(app)
            }
            keep.state = isPinned ? .on : .off
            options.addItem(keep)
            let optionsItem = NSMenuItem(title: T("Options"), action: nil, keyEquivalent: "")
            optionsItem.submenu = options
            menu.addItem(optionsItem)
            add(T("Bar Settings")) { SuiteSettingsApp.show(tab: "Bar") }
            menu.addItem(.separator())
            // Explorer's: quitting it gives Finder its desktop back; restarting doesn't, as for an update.
            add(T("Restart")) { ExplorerLink.send(.relaunch) }
            add(T("Quit")) {
                NSRunningApplication.runningApplications(withBundleIdentifier: SuiteDefaults.explorerDomain)
                    .forEach { $0.terminate() }
            }
        case .app(let app, let isPinned, _)?:
            let runningApp = running[key(app)]
            if let runningApp { addWindows(of: runningApp, to: menu) }
            let options = NSMenu()
            let keep = BarMenuItem(title: T("Keep in Dock")) { [store] in
                isPinned ? store.unpin(app) : store.pin(app)
            }
            keep.state = isPinned ? .on : .off
            options.addItem(keep)
            if !isPinned, runningApp == nil {
                add(T("Remove from Dock"), to: options) { [weak self] in self?.forget(app) }
            }
            if let url = location(of: app) {
                // Read when the menu opens: another app may have changed it.
                let opensAtLogin = LoginItems.contains(url)
                let login = BarMenuItem(title: T("Open at Login")) {
                    LoginItems.set(url, opensAtLogin: !opensAtLogin)
                }
                login.state = opensAtLogin ? .on : .off
                options.addItem(login)
                options.addItem(.separator())
                add(T("Show in Explorer"), to: options) { ExplorerLink.reveal([url]) }
            }
            let optionsItem = NSMenuItem(title: T("Options"), action: nil, keyEquivalent: "")
            optionsItem.submenu = options
            menu.addItem(optionsItem)
            menu.addItem(.separator())
            if let runningApp, AppWindow.hasWindowOnScreen(runningApp) || !AppWindow.windows(of: runningApp).isEmpty {
                add(T("Show All Windows")) { AppExpose.show(runningApp) }
            }
            if let runningApp {
                if runningApp.isHidden {
                    add(T("Show")) { runningApp.unhide() }
                } else {
                    add(T("Hide")) { runningApp.hide() }
                    menu.addItem(alternate(T("Hide Others")) {
                        for other in NSWorkspace.shared.runningApplications
                        where other != runningApp && other.activationPolicy == .regular {
                            other.hide()
                        }
                        runningApp.activate(options: [])
                    })
                }
                addQuit(runningApp, title: T("Quit"), to: menu)
            } else {
                add(T("Open")) { [weak self] in
                    if let index = self?.tiles.firstIndex(of: .app(app, isPinned: isPinned, isRunning: false)) {
                        self?.open(.app(app, isPinned: isPinned, isRunning: false), at: index)
                    }
                }
            }
        case .item(let item)?:
            if item.isFolder {
                addStackOptions(for: item, to: menu)
                menu.addItem(.separator())
            }
            let options = NSMenu()
            add(T("Remove from Dock"), to: options) { [itemStore] in itemStore.remove(item) }
            add(T("Show in Explorer"), to: options) { ExplorerLink.reveal([item.url]) }
            let optionsItem = NSMenuItem(title: T("Options"), action: nil, keyEquivalent: "")
            optionsItem.submenu = options
            menu.addItem(optionsItem)
            if item.isFolder {
                add(String(format: T("Open \u{201C}%@\u{201D}"), item.name)) { ExplorerLink.open([item.url]) }
            } else {
                add(T("Open")) { ExplorerLink.openFiles([item.url]) }
            }
        case .window(let window)?:
            add(T("Bring Back")) { MinimizedWindows.shared.restore(window.id) }
            if let app = MinimizedWindows.shared.app(of: window.id) {
                menu.addItem(.separator())
                addQuit(app, title: String(format: T("Quit %@"),
                                           app.localizedName ?? window.app.name), to: menu)
            }
        case .trash?:
            add(T("Open")) { ExplorerLink.open([BarFiles.trash]) }
            menu.addItem(.separator())
            let empty = BarMenuItem(title: T("Empty Trash")) {
                NSApp.activate(ignoringOtherApps: true)
                ExplorerLink.send(.emptyTrash)
            }
            empty.isEnabled = trashIsFull
            menu.addItem(empty)
        case .separator?, nil:
            let autohides = BarSettings.current.autohides
            add(autohides ? T("Turn Hiding Off") : T("Turn Hiding On")) {
                BarSettings.current.autohides.toggle()
            }
            add(options.magnifies ? T("Turn Magnification Off") : T("Turn Magnification On")) {
                BarSettings.current.magnifies.toggle()
            }
            menu.addItem(.separator())
            let positions = NSMenu()
            for (position, title) in [(BarPosition.left, "Left"), (.bottom, "Bottom"), (.right, "Right")] {
                let item = BarMenuItem(title: T(title)) { BarSettings.current.position = position }
                item.state = options.position == position ? .on : .off
                positions.addItem(item)
            }
            let positionItem = NSMenuItem(title: T("Position on Screen"), action: nil, keyEquivalent: "")
            positionItem.submenu = positions
            menu.addItem(positionItem)
            menu.addItem(.separator())
            add(T("Bar Settings")) { SuiteSettingsApp.show(tab: "Bar") }
        }
        return menu
    }

    /// The app's windows, first in its menu as in the system Dock: a click brings one forward; the
    /// minimized ones carry a diamond.
    private func addWindows(of app: NSRunningApplication, to menu: NSMenu) {
        let windows = AppWindow.windows(of: app)
        guard !windows.isEmpty else { return }
        for window in windows {
            let item = BarMenuItem(title: window.title) { window.bringForward(of: app) }
            if window.isMinimized {
                item.state = .on
                item.onStateImage = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: T("Minimized"))
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// Quit, with Force Quit under it while Option is held; Force Quit alone for an app that didn't quit
    /// when asked.
    private func addQuit(_ app: NSRunningApplication, title: String, to menu: NSMenu) {
        let pid = app.processIdentifier
        quitRequests.keep(running: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
        let force = title == T("Quit") ? T("Force Quit") : String(format: T("Force Quit %@"),
                                                                    app.localizedName ?? "")
        if quitRequests.offersForceQuit(pid, optionHeld: false) {
            menu.addItem(BarMenuItem(title: force) { app.forceTerminate() })
            return
        }
        menu.addItem(BarMenuItem(title: title) { [weak self] in
            self?.quitRequests.asked(pid)
            app.terminate()
        })
        menu.addItem(alternate(force) { app.forceTerminate() })
    }

    /// A menu item shown instead of the one above it while Option is held.
    private func alternate(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = BarMenuItem(title: title, action: action)
        item.keyEquivalentModifierMask = .option
        item.isAlternate = true
        return item
    }

    /// Sort by, Display as and View content as, as the system Dock's folder menu.
    private func addStackOptions(for item: BarItem, to menu: NSMenu) {
        func header(_ title: String) {
            if #available(macOS 14, *) {
                menu.addItem(.sectionHeader(title: title))
            } else {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
        }
        func choice(_ title: String, _ isOn: Bool, _ change: @escaping (inout BarItem) -> Void) {
            let entry = BarMenuItem(title: title) { [itemStore] in
                var changed = item
                change(&changed)
                itemStore.update(changed)
            }
            entry.state = isOn ? .on : .off
            menu.addItem(entry)
        }
        header(T("Sort by"))
        for sort in BarStackSort.allCases {
            choice(T(sort.title), item.sort == sort) { $0.sort = sort }
        }
        menu.addItem(.separator())
        header(T("Display as"))
        for display in [BarStackDisplay.folder, .stack] {
            choice(T(display.title), item.display == display) { $0.display = display }
        }
        menu.addItem(.separator())
        header(T("View content as"))
        for view in BarStackView.menuOrder {
            choice(T(view.title), item.view == view) { $0.view = view }
        }
    }

    // MARK: Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrop = [:]
        isDropping = true
        stack?.close()
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = BarDrop.fileURLs(in: sender)
        let volumes = !urls.isEmpty && urls.allSatisfy(isEjectable)
        if volumes != draggingVolumes {
            draggingVolumes = volumes
            needsDisplay = true
        }
        let point = logical(sender.draggingLocation)
        let (target, operation) = dropOperation(for: urls, at: point, info: sender)
        if target != dropTarget {
            dropTarget = target
            needsDisplay = true
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrop()
    }

    private func endDrop() {
        isDropping = false
        dropTarget = nil
        draggingVolumes = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrop() }
        let urls = BarDrop.fileURLs(in: sender)
        let point = logical(sender.draggingLocation)
        guard !urls.isEmpty, dropOperation(for: urls, at: point, info: sender).1 != [] else { return false }
        let frames = frames
        guard let index = tileIndex(at: point) else {
            if isInItemSection(point) {
                // Folders and files dropped right of the separator are kept there.
                var at = BarGeometry.insertionIndex(forX: point.x, pinnedFrames: itemRange.map { frames[$0] })
                for url in urls {
                    itemStore.add(BarItem(path: url.path, name: FileManager.default.displayName(atPath: url.path),
                                           isFolder: isFolderForDock(url)), at: at)
                    at += 1
                }
                return true
            }
            // Applications dropped between icons are pinned there.
            var at = BarGeometry.insertionIndex(forX: point.x, pinnedFrames: pinnedRange.map { frames[$0] })
            for url in urls {
                store.pin(BarApp(url: url, bundleID: Bundle(url: url)?.bundleIdentifier), at: at)
                at += 1
            }
            return true
        }
        switch tiles[index] {
        case .app(let app, _, _) where BarStore.isExplorer(app):
            ExplorerLink.open(urls)
        case .app(let app, _, _):
            guard let appURL = location(of: app) else { return false }
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        case .item(let item):
            guard item.isFolder else { return false }
            _ = BarDrop.perform(sender, into: item.url)
        case .trash:
            if urls.allSatisfy(isEjectable) {
                for url in urls { eject(url) }
            } else {
                BarFiles.moveToTrash(urls)
            }
        case .separator, .window:
            return false
        }
        return true
    }

    /// The tile a drop at `point` goes to (highlighted), and what it does.
    private func dropOperation(for urls: [URL], at point: NSPoint, info: NSDraggingInfo) -> (Int?, NSDragOperation) {
        guard !urls.isEmpty else { return (nil, []) }
        guard let index = tileIndex(at: point) else {
            if isInItemSection(point) {
                let known = urls.allSatisfy { url in itemStore.items.contains { $0.path == url.standardizedFileURL.path } }
                return (nil, known ? [] : .generic)
            }
            let allApps = urls.allSatisfy { $0.pathExtension == "app" }
            return (nil, allApps ? .generic : [])
        }
        switch tiles[index] {
        case .app(let app, _, _) where BarStore.isExplorer(app):
            return (index, .generic)
        case .app(let app, _, _):
            guard let appURL = location(of: app), canOpen(urls, with: appURL) else { return (nil, []) }
            return (index, .generic)
        case .item(let item):
            guard item.isFolder, !urls.contains(where: { $0.standardizedFileURL.path == item.path }) else {
                return (nil, [])
            }
            return (index, BarDrop.dragOperation(for: info, into: item.url))
        case .trash:
            if urls.allSatisfy(isEjectable) { return (index, .generic) }
            if urls.contains(where: { BarFiles.isInTrash($0) }) { return (nil, []) }
            let mask = info.draggingSourceOperationMask
            // Folders dragged out of the sidebar can only be copied: they never go to the Trash this way.
            if mask.isDisjoint(with: [.delete, .move, .generic]) { return (nil, []) }
            return (index, mask.contains(.delete) ? .delete : mask.contains(.move) ? .move : .generic)
        case .separator, .window:
            return (nil, [])
        }
    }

    /// Right of the separator before the folders: where folders and files are kept.
    private func isInItemSection(_ point: NSPoint) -> Bool {
        guard let separator = tiles.lastIndex(of: .separator) else { return false }
        return point.x > frames[separator].midX
    }

    private func isFolderForDock(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// A disk other than the startup disk: dropped on the Trash, it is ejected.
    private func isEjectable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeIsRootFileSystemKey])
        return values?.isVolume == true && values?.volumeIsRootFileSystem != true
    }

    private func eject(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async {
                    BarFiles.showError("“\(FileManager.default.displayName(atPath: url.path))” couldn't be "
                                          + "ejected: \(error.localizedDescription)")
                }
            }
        }
    }

    /// As in the system Dock, only apps that can open every dropped file light up.
    private func canOpen(_ urls: [URL], with app: URL) -> Bool {
        let cacheKey = app.path + "\n" + urls.map(\.path).joined(separator: "\n")
        if let known = acceptsDrop[cacheKey] { return known }
        let appPath = app.standardizedFileURL.path
        let accepted = urls.allSatisfy { url in
            NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.standardizedFileURL.path == appPath }
        }
        acceptsDrop[cacheKey] = accepted
        return accepted
    }
}

/// A menu item that runs a closure.
final class BarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The name shown above the icon under the pointer, as the system Dock does.
final class BarLabel {
    private var panel: NSPanel?
    private let field = NSTextField(labelWithString: "")

    /// Above the icon (`rect`, on screen) of a Dock at the bottom, beside it on the sides.
    func show(_ text: String, beside rect: NSRect, edge: ScreenEdge, parent: NSWindow) {
        let panel = self.panel ?? makePanel()
        field.stringValue = text
        field.sizeToFit()
        let size = NSSize(width: field.frame.width + 20, height: field.frame.height + 8)
        field.frame.origin = NSPoint(x: 10, y: 4)
        let origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 2)
        case .left: origin = NSPoint(x: rect.maxX + 2, y: rect.midY - size.height / 2)
        case .right: origin = NSPoint(x: rect.minX - 2 - size.width, y: rect.midY - size.height / 2)
        }
        panel.setFrame(NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height), display: true)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        field.font = .systemFont(ofSize: 13)
        background.addSubview(field)
        panel.contentView = background
        self.panel = panel
        return panel
    }
}


extension ScreenEdge {
    init(_ position: BarPosition) {
        switch position {
        case .left: self = .left
        case .bottom: self = .bottom
        case .right: self = .right
        }
    }
}
