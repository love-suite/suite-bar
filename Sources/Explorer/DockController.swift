import AppKit
import ApplicationServices
import ExplorerCore

/// Explorer's own Dock, in place of the system one: shown at the bottom of the main screen while
/// Explorer manages files and the option is on, with the system Dock (and Finder's icon in it) hidden.
/// It stays on screen, windows kept above it, or slides away until the pointer reaches the bottom edge.
final class DockController {
    static let shared = DockController()

    private var panel: DockPanel?
    private let hider = DockController.makeHider()
    private let fitter = WindowFitter()
    private var observers: [NSObjectProtocol] = []

    // Automatic hiding.
    private var mouseMonitors: [Any] = []
    private var isRevealed = true
    private var pending: DispatchWorkItem?
    /// Where the hidden system Dock wakes up along the bottom edge.
    private var systemDockSpan: ClosedRange<CGFloat>?

    private var options: DockOptions { DockSettings.shared.options }
    private var isActive: Bool { options.isShown && FinderReplacement.shared.usesExplorer }

    func start() {
        let center = NotificationCenter.default
        for name in [DockSettings.didChange, FinderReplacement.didChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.apply()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.place() })
        // The system Dock grows and shrinks with the running apps.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.measureSystemDock() }
            })
        }
        apply()
    }

    /// Explorer quits: the system Dock comes back as it was.
    func stop() {
        panel?.orderOut(nil)
        setWatchingPointer(false)
        fitter.reserved = 0
        hider.restore()
    }

    /// For `--restore-finder`, after a forced quit.
    static func restoreSystemDock() {
        makeHider().restore()
    }

    private func apply() {
        if isActive {
            if panel == nil {
                let panel = DockPanel()
                panel.dockView.onSizeChange = { [weak self] in self?.place() }
                self.panel = panel
            }
            setWatchingPointer(true)
            panel?.dockView.geometry = options.geometry
            setAutohides(options.autohides)
            place()
            hider.hide()
        } else {
            setAutohides(false)
            setWatchingPointer(false)
            panel?.orderOut(nil)
            fitter.reserved = 0
            hider.restore()
        }
        // The screen's visible area and the system Dock's size follow once it has restarted.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.place()
                self?.measureSystemDock()
            }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    /// Centred at the bottom of the main screen, above the system Dock should that one show.
    private var shownFrame: NSRect? {
        guard let panel, let screen else { return nil }
        let size = panel.dockView.barSize
        let bottom = max(screen.visibleFrame.minY, screen.frame.minY) + 4
        return NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: bottom,
                      width: size.width, height: size.height)
    }

    /// Just below the screen's bottom edge.
    private var hiddenFrame: NSRect? {
        guard let shown = shownFrame, let screen else { return nil }
        return shown.offsetBy(dx: 0, dy: screen.frame.minY - shown.maxY - 2)
    }

    private func place() {
        guard isActive, let panel, let shown = shownFrame, let screen else { return }
        if isRevealed {
            if panel.frame != shown { panel.setFrame(shown, display: true) }
            panel.orderFrontRegardless()
        }
        // Windows are kept above the Dock only while it stays on screen, as with the system Dock.
        fitter.reserved = options.autohides ? 0 : shown.maxY + 2 - screen.frame.minY
    }

    // MARK: The pointer at the bottom edge

    /// Watches the pointer everywhere (no permission needed for mouse events), to keep it off the bottom
    /// edge and to slide the Dock in when it hides automatically.
    private func setWatchingPointer(_ watching: Bool) {
        if watching, mouseMonitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                self?.pointerMoved()
            }) { mouseMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                self?.pointerMoved()
                return event
            }) { mouseMonitors.append(local) }
        } else if !watching, !mouseMonitors.isEmpty {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors.removeAll()
        }
    }

    /// macOS 27 ignores the long `autohide-delay`: on the main screen's last row of pixels the hidden system
    /// Dock wakes up and shows its icons' names. The pointer is put back a few points higher, too little to
    /// be noticed; a screen below the main one is still reached.
    private func keepOffBottomEdge(_ point: NSPoint, screen: NSScreen) {
        let others = NSScreen.screens.dropFirst().map(\.frame)
        let span = systemDockSpan ?? screen.frame.minX...screen.frame.maxX
        guard let target = BottomEdge.guarded(point, screen: screen.frame, span: span, others: others)
        else { return }
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: screen.frame.maxY - target.y))
        // Without this, the pointer would freeze for a moment after being moved.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The stretch of the bottom edge the hidden system Dock covers: its icon list's frame through
    /// Accessibility when allowed, otherwise an estimate from its preferences. A few points spare each side.
    private func measureSystemDock() {
        guard isActive, let screen else { return }
        let measured = SystemDockMeasure.iconListSpan()
        let estimated: ClosedRange<CGFloat> = {
            let pinned = DockPins(SystemDockReader.currentApps())
            let unpinned = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular && app.bundleIdentifier != FinderDesktop.bundleID
                    && !pinned.contains(DockApp(url: app.bundleURL ?? URL(fileURLWithPath: "/"),
                                                bundleID: app.bundleIdentifier))
            }.count
            let count = SystemDockSpan.itemCount(preferences: AppPreferenceDomain(SystemDockReader.domain),
                                                 unpinnedRunning: unpinned)
            let tileSize = (AppPreferenceDomain(SystemDockReader.domain).value(forKey: "tilesize") as? NSNumber)
                .map { CGFloat($0.doubleValue) } ?? 16
            return SystemDockSpan.estimate(itemCount: count, tileSize: tileSize, screen: screen.frame)
        }()
        let span = measured ?? estimated
        systemDockSpan = (span.lowerBound - 12)...(span.upperBound + 12)
    }

    // MARK: Automatic hiding

    private func setAutohides(_ autohides: Bool) {
        if autohides, isRevealed {
            conceal()
        } else if !autohides {
            cancelPending()
            isRevealed = true
        }
    }

    private func pointerMoved() {
        guard let panel, let shown = shownFrame, let screen else { return }
        let point = NSEvent.mouseLocation
        keepOffBottomEdge(point, screen: screen)
        guard options.autohides else { return }
        if !isRevealed {
            let atEdge = point.y <= screen.frame.minY + BottomEdge.gap + 1
                && point.x >= shown.minX - 20 && point.x <= shown.maxX + 20
            atEdge ? schedule(0.12) { [weak self] in self?.reveal() } : cancelPending()
        } else {
            let near = shown.insetBy(dx: -8, dy: -8).union(NSRect(x: shown.minX, y: screen.frame.minY,
                                                                  width: shown.width, height: 1)).contains(point)
            near || panel.dockView.isBusy ? cancelPending() : schedule(0.35) { [weak self] in self?.conceal() }
        }
    }

    private func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            action()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func reveal() {
        guard let panel, let shown = shownFrame, let hidden = hiddenFrame, !isRevealed else { return }
        isRevealed = true
        panel.setFrame(hidden, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(shown, display: true)
        }
    }

    private func conceal() {
        guard let panel, let hidden = hiddenFrame else { return }
        guard !panel.dockView.isBusy else { return }
        isRevealed = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(hidden, display: true)
        }, completionHandler: { [weak self] in
            if self?.isRevealed == false { panel.orderOut(nil) }
        })
    }

    private static func makeHider() -> SystemDockHider {
        SystemDockHider(restartDock: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Dock"]
            try? process.run()
            process.waitUntilExit()
        })
    }
}

/// Asks the system Dock (through Accessibility, when allowed) where its icons are.
enum SystemDockMeasure {
    static func iconListSpan() -> ClosedRange<CGFloat>? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }
        for element in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole as String,
                  let position: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint),
                  let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize),
                  size.width > 0, size.width > size.height else { continue }
            return position.x...(position.x + size.width)
        }
        return nil
    }

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(value as! AXValue, type, pointer) ? pointer.pointee : nil
    }
}

/// A borderless panel at the Dock's level that never takes the focus from the app in front.
final class DockPanel: NSPanel {
    let dockView = DockView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        contentView = DockBackground(dock: dockView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The Dock's translucent rounded bar, with the icons on top.
final class DockBackground: NSView {
    private let material = NSVisualEffectView()

    init(dock: DockView) {
        super.init(frame: .zero)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        dock.autoresizingMask = [.width, .height]
        addSubview(material)
        addSubview(dock)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        material.frame = bounds
        subviews.last?.frame = bounds
        let radius = min(bounds.height * 0.3, 18)
        material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}
