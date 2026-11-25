import AppKit
import BarCore
import BarSettings
import SuiteCore
import SuiteFilesCore
import SuiteFilesUI

/// The Dock's icons: Explorer, the pinned apps, the running ones, Downloads and the Trash. Click to open,
/// drag a pinned app to reorder it (or up and away to remove it), drop files to open, move or trash them.
final class BarView: NSView {
    var geometry = BarSettings().geometry {
        didSet { if geometry != oldValue { icons.removeAll(); reload() } }
    }
    /// Called when the bar changes width, so the panel can follow.
    var onSizeChange: (() -> Void)?
    var barSize: NSSize { geometry.barSize(for: tiles) }

    private(set) var tiles: [BarTile] = []
    /// A stack is open, an icon is being dragged or a drop is on its way: the Dock mustn't slide away.
    var isBusy: Bool { stack != nil || pressed != nil || reorder != nil || dropTarget != nil || isDropping }
    private var isDropping = false
    private var running: [String: NSRunningApplication] = [:]
    private var quitRequests = QuitRequests()
    private var icons: [String: NSImage] = [:]
    private var downloadsIcon: NSImage?
    private var trashIsFull = false
    private var watchers: [DirectoryWatcher] = []
    private var observers: [NSObjectProtocol] = []

    private let store: BarStore
    private let label = BarLabel()
    private var stack: BarStackPopover?

    // Mouse state.
    private var pressed: Int?
    private var pressLocation: NSPoint = .zero
    private var reorder: (from: Int, x: CGFloat, removing: Bool)?
    private var dropTarget: Int?
    private var acceptsDrop: [String: Bool] = [:]

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(store: BarStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
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
        for folder in [Self.downloads, BarFiles.trash] {
            let watcher = DirectoryWatcher(url: folder) { [weak self] in
                DispatchQueue.main.async { self?.refreshFolders() }
            }
            watcher.start()
            watchers.append(watcher)
        }
        refreshFolders()
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
        let old = barSize
        tiles = BarLayout.tiles(pinned: store.pins.apps, running: runningApps,
                                 minimized: MinimizedWindows.shared.windows)
        needsDisplay = true
        if barSize != old { onSizeChange?() }
    }

    private func refreshFolders() {
        let recent = BarStackOrder.contents(of: Self.downloads)
        downloadsIcon = recent.isEmpty
            ? NSWorkspace.shared.icon(forFile: Self.downloads.path)
            : StackIcon.image(for: recent, side: geometry.iconSize, expanded: false)
        // Listing the Trash needs Full Disk Access; without it the Trash shows empty.
        // All its folders count: what was deleted from iCloud Drive or a disk fills it too.
        trashIsFull = !BarFiles.trashContents().isEmpty
        needsDisplay = true
    }

    private func key(_ app: BarApp) -> String { app.bundleID ?? app.path }

    /// Where the app is now: its running copy, its saved place, or wherever Launch Services finds it.
    private func location(of app: BarApp) -> URL? {
        if let url = running[key(app)]?.bundleURL { return url }
        if FileManager.default.fileExists(atPath: app.path) { return app.url }
        return app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private func icon(for tile: BarTile) -> NSImage? {
        switch tile {
        case .explorer:
            return NSApp.applicationIconImage
        case .app(let app, _, _):
            if let cached = icons[key(app)] { return cached }
            let image = running[key(app)]?.icon
                ?? location(of: app).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
            icons[key(app)] = image
            return image
        case .downloads:
            return downloadsIcon
        case .window(let window):
            let appIcon = icon(for: .app(window.app, isPinned: false, isRunning: true))
            return Self.minimizedIcon(badge: appIcon)
        case .trash:
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName)
        case .separator:
            return nil
        }
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
        case .explorer: return "Explorer"
        case .app(let app, _, _): return running[key(app)]?.localizedName ?? app.name
        case .downloads: return NSLocalizedString("Downloads", comment: "")
        case .window(let window): return window.title
        case .trash: return NSLocalizedString("Trash", comment: "")
        case .separator: return ""
        }
    }

    // MARK: Drawing

    /// The tiles' frames as drawn: while a pinned app is dragged, the others make room where it would land.
    private var drawnFrames: [CGRect] {
        var frames = geometry.frames(for: tiles)
        guard let reorder, !reorder.removing else { return frames }
        let pinned = pinnedRange
        let slots = pinned.map { frames[$0] }
        let others = pinned.filter { $0 != reorder.from }
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

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.height * 0.3, 18)
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
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
                NSRect(x: frame.midX.rounded() - 0.5, y: frame.height * 0.18, width: 1, height: frame.height * 0.64).fill()
                continue
            }
            let iconFrame = geometry.iconFrame(in: frame)
            if dropTarget == index {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: iconFrame.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
            }
            icon(for: tile)?.draw(in: iconFrame, from: .zero, operation: .sourceOver,
                                  fraction: isMissing(tile) ? 0.4 : 1)
            if pressed == index, reorder == nil {
                NSColor.black.withAlphaComponent(0.35).setFill()
                iconFrame.fill(using: .sourceAtop)
            }
            if isRunning(tile) {
                let side = max(4, (geometry.iconSize * 0.08).rounded())
                NSColor.labelColor.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: (geometry.dotArea - side) / 2 + 1,
                                            width: side, height: side)).fill()
            }
        }
    }

    private func isRunning(_ tile: BarTile) -> Bool {
        switch tile {
        case .explorer: return true
        case .app(_, _, let isRunning): return isRunning
        default: return false
        }
    }

    private func isMissing(_ tile: BarTile) -> Bool {
        guard let app = tile.app else { return false }
        return location(of: app) == nil
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
        let point = convert(event.locationInWindow, from: nil)
        if let index = geometry.tileIndex(at: point, tiles: tiles), stack == nil {
            showLabel(name(of: tiles[index]), over: geometry.frames(for: tiles)[index])
        } else {
            label.hide()
        }
    }

    override func mouseExited(with event: NSEvent) {
        label.hide()
    }

    private func showLabel(_ text: String, over frame: CGRect) {
        guard let window else { return }
        let rect = window.convertToScreen(convert(frame, to: nil))
        label.show(text, above: NSPoint(x: rect.midX, y: window.frame.maxY + 6), parent: window)
    }

    // MARK: Clicks and reordering

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        pressLocation = convert(event.locationInWindow, from: nil)
        pressed = geometry.tileIndex(at: pressLocation, tiles: tiles)
        label.hide()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, case .app(_, true, _) = tiles[pressed] else { return }
        let point = convert(event.locationInWindow, from: nil)
        if reorder == nil, hypot(point.x - pressLocation.x, point.y - pressLocation.y) < 5 { return }
        // Dragged well above the Dock, the app is removed on release, as in the system Dock.
        let removing = point.y > bounds.maxY + geometry.iconSize
        let pinned = pinnedRange.map { geometry.frames(for: tiles)[$0] }
        let x = min(max(point.x, (pinned.first?.minX ?? 0)), (pinned.last?.maxX ?? bounds.maxX))
        reorder = (pressed, x, removing)
        if removing {
            showLabel(NSLocalizedString("Remove", comment: ""), over: geometry.frames(for: tiles)[pressed].offsetBy(dx: point.x - pressLocation.x, dy: 0))
        } else {
            label.hide()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            reorder = nil
            label.hide()
            needsDisplay = true
        }
        if let reorder, let app = tiles[reorder.from].app {
            if reorder.removing {
                store.unpin(app)
                FinderSounds.play(.poof)
            } else {
                let frames = geometry.frames(for: tiles)
                let others = pinnedRange.filter { $0 != reorder.from }
                var pins = store.pins
                pins.unpin(app)
                pins.pin(app, at: BarGeometry.insertionIndex(forX: reorder.x, pinnedFrames: others.map { frames[$0] }))
                if pins != store.pins { store.pins = pins }
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, geometry.tileIndex(at: point, tiles: tiles) == pressed else { return }
        open(tiles[pressed], at: pressed)
    }

    private func open(_ tile: BarTile, at index: Int) {
        switch tile {
        case .explorer:
            ExplorerLink.activate()
            NSApp.activate(ignoringOtherApps: true)
        case .app(let app, let isPinned, _):
            guard let url = location(of: app) else {
                askToRemoveMissing(app, isPinned: isPinned)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { BarFiles.showError(error.localizedDescription) } }
            }
        case .downloads:
            showStack(at: index)
        case .window(let window):
            MinimizedWindows.shared.restore(window.id)
        case .trash:
            ExplorerLink.open([BarFiles.trash])
        case .separator:
            break
        }
    }

    private func askToRemoveMissing(_ app: BarApp, isPinned: Bool) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("\u{201C}%@\u{201D} can't be found.", comment: ""), app.name)
        alert.informativeText = NSLocalizedString("It may have been moved or uninstalled.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Remove from Dock", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.unpin(app) }
    }

    private func showStack(at index: Int) {
        if let stack {
            stack.close()
            return
        }
        label.hide()
        let popover = BarStackPopover(folder: Self.downloads)
        popover.onClose = { [weak self] in self?.stack = nil }
        stack = popover
        popover.show(relativeTo: geometry.frames(for: tiles)[index], of: self)
    }

    // MARK: Right-click menus

    override func rightMouseDown(with event: NSEvent) {
        label.hide()
        let point = convert(event.locationInWindow, from: nil)
        let index = geometry.tileIndex(at: point, tiles: tiles)
        NSMenu.popUpContextMenu(menu(for: index.map { tiles[$0] }), with: event, for: self)
    }

    private func menu(for tile: BarTile?) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(BarMenuItem(title: title, action: action))
        }
        switch tile {
        case .explorer:
            add(NSLocalizedString("New Explorer Window", comment: "")) {
                ExplorerLink.open([FileManager.default.homeDirectoryForCurrentUser])
            }
            menu.addItem(.separator())
            add(NSLocalizedString("Bar Settings", comment: "")) { SuiteSettingsApp.show(tab: "Bar") }
        case .app(let app, let isPinned, _)?:
            if isPinned {
                add(NSLocalizedString("Remove from Dock", comment: "")) { [store] in store.unpin(app) }
            } else {
                add(NSLocalizedString("Keep in Dock", comment: "")) { [store] in store.pin(app) }
            }
            if let url = location(of: app) {
                add(NSLocalizedString("Show in Explorer", comment: "")) { ExplorerLink.reveal([url]) }
            }
            if let runningApp = running[key(app)] {
                menu.addItem(.separator())
                addQuit(runningApp, title: NSLocalizedString("Quit", comment: ""), to: menu)
            }
        case .downloads?:
            add(NSLocalizedString("Open in Explorer", comment: "")) { ExplorerLink.open([Self.downloads]) }
        case .window(let window)?:
            add(NSLocalizedString("Bring Back", comment: "")) { MinimizedWindows.shared.restore(window.id) }
            if let app = MinimizedWindows.shared.app(of: window.id) {
                menu.addItem(.separator())
                addQuit(app, title: String(format: NSLocalizedString("Quit %@", comment: ""),
                                           app.localizedName ?? window.app.name), to: menu)
            }
        case .trash?:
            add(NSLocalizedString("Open", comment: "")) { ExplorerLink.open([BarFiles.trash]) }
            menu.addItem(.separator())
            add(NSLocalizedString("Empty Trash", comment: "")) {
                NSApp.activate(ignoringOtherApps: true)
                ExplorerLink.send(.emptyTrash)
            }
        case .separator?, nil:
            add(NSLocalizedString("Bar Settings", comment: "")) { SuiteSettingsApp.show(tab: "Bar") }
        }
        return menu
    }

    /// Quit, or Force Quit for an app that didn't quit when asked (or with Option held).
    private func addQuit(_ app: NSRunningApplication, title: String, to menu: NSMenu) {
        let pid = app.processIdentifier
        quitRequests.keep(running: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
        if quitRequests.offersForceQuit(pid, optionHeld: NSEvent.modifierFlags.contains(.option)) {
            let name = title == "Quit" ? "Force Quit" : "Force " + title
            menu.addItem(BarMenuItem(title: name) { app.forceTerminate() })
        } else {
            menu.addItem(BarMenuItem(title: title) { [weak self] in
                self?.quitRequests.asked(pid)
                app.terminate()
            })
        }
    }

    // MARK: Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrop = [:]
        isDropping = true
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = BarDrop.fileURLs(in: sender)
        let point = convert(sender.draggingLocation, from: nil)
        let (target, operation) = dropOperation(for: urls, at: point, info: sender)
        if target != dropTarget {
            dropTarget = target
            needsDisplay = true
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropping = false
        dropTarget = nil
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropping = false
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            isDropping = false
            dropTarget = nil
            needsDisplay = true
        }
        let urls = BarDrop.fileURLs(in: sender)
        let point = convert(sender.draggingLocation, from: nil)
        guard !urls.isEmpty, dropOperation(for: urls, at: point, info: sender).1 != [] else { return false }
        guard let index = geometry.tileIndex(at: point, tiles: tiles) else {
            // Applications dropped between icons are pinned there.
            let frames = geometry.frames(for: tiles)
            var at = BarGeometry.insertionIndex(forX: point.x, pinnedFrames: pinnedRange.map { frames[$0] })
            for url in urls {
                store.pin(BarApp(url: url, bundleID: Bundle(url: url)?.bundleIdentifier), at: at)
                at += 1
            }
            return true
        }
        switch tiles[index] {
        case .explorer:
            ExplorerLink.open(urls)
        case .app(let app, _, _):
            guard let appURL = location(of: app) else { return false }
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        case .downloads:
            _ = BarDrop.perform(sender, into: Self.downloads)
        case .trash:
            BarFiles.moveToTrash(urls)
        case .separator, .window:
            return false
        }
        return true
    }

    /// The tile a drop at `point` goes to (highlighted), and what it does.
    private func dropOperation(for urls: [URL], at point: NSPoint, info: NSDraggingInfo) -> (Int?, NSDragOperation) {
        guard !urls.isEmpty else { return (nil, []) }
        guard let index = geometry.tileIndex(at: point, tiles: tiles) else {
            let allApps = urls.allSatisfy { $0.pathExtension == "app" }
            return (nil, allApps ? .generic : [])
        }
        switch tiles[index] {
        case .explorer:
            return (index, .generic)
        case .app(let app, _, _):
            guard let appURL = location(of: app), canOpen(urls, with: appURL) else { return (nil, []) }
            return (index, .generic)
        case .downloads:
            return (index, BarDrop.dragOperation(for: info, into: Self.downloads))
        case .trash:
            if urls.contains(where: { BarFiles.isInTrash($0) }) { return (nil, []) }
            let mask = info.draggingSourceOperationMask
            // Folders dragged out of the sidebar can only be copied: they never go to the Trash this way.
            if mask.isDisjoint(with: [.delete, .move, .generic]) { return (nil, []) }
            return (index, mask.contains(.delete) ? .delete : mask.contains(.move) ? .move : .generic)
        case .separator, .window:
            return (nil, [])
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

    func show(_ text: String, above point: NSPoint, parent: NSWindow) {
        let panel = self.panel ?? makePanel()
        field.stringValue = text
        field.sizeToFit()
        let size = NSSize(width: field.frame.width + 20, height: field.frame.height + 8)
        field.frame.origin = NSPoint(x: 10, y: 4)
        panel.setFrame(NSRect(x: (point.x - size.width / 2).rounded(), y: point.y, width: size.width,
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
