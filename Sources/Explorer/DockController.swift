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
    private let agent = DockController.makeAgent()
    private let fitter = WindowFitter()
    private var observers: [NSObjectProtocol] = []

    // Automatic hiding.
    private var mouseMonitors: [Any] = []
    private var isRevealed = true
    private var pending: DispatchWorkItem?
    /// Where the hidden system Dock wakes up: its edge, and the stretch along it.
    private var systemDockEdge: ScreenEdge = .left
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
        AppSwitcher.shared.isEnabled = false
        Self.restore(hider: hider, agent: agent)
    }

    /// For `--restore-finder`, after a forced quit.
    static func restoreSystemDock() {
        restore(hider: makeHider(), agent: makeAgent())
    }

    /// Its settings first, so that a stopped Dock starts again as the user had it.
    private static func restore(hider: SystemDockHider, agent: SystemDockAgent) {
        hider.restore()
        agent.start()
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
            // Hidden either way, should it be started again by something else (a log out, say).
            hider.hide()
            if options.stopsSystemDock { agent.stop() } else { agent.start() }
            // What stopped with the system Dock, Explorer does instead.
            AppSwitcher.shared.isEnabled = agent.isStopped
        } else {
            setAutohides(false)
            setWatchingPointer(false)
            panel?.orderOut(nil)
            fitter.reserved = 0
            AppSwitcher.shared.isEnabled = false
            Self.restore(hider: hider, agent: agent)
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

    // MARK: The pointer at the system Dock's edge

    /// Watches the pointer everywhere (no permission needed for mouse events), to keep it off the hidden
    /// system Dock's edge and to slide our Dock in when it hides automatically.
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

    /// macOS 27 ignores the long `autohide-delay`: on the outermost pixels of its edge the hidden system
    /// Dock wakes up and shows its icons' names. Along its short stretch of that edge (the middle of the left
    /// edge), the pointer is put back a few points in, too little to be noticed; a screen beyond is reached.
    private func keepOffSystemDockEdge(_ point: NSPoint, screen: NSScreen) {
        // A stopped Dock can't wake up: its edge is free.
        guard !agent.isStopped else { return }
        let others = NSScreen.screens.dropFirst().map(\.frame)
        let whole = systemDockEdge == .bottom ? screen.frame.minX...screen.frame.maxX
                                              : screen.frame.minY...screen.frame.maxY
        guard let target = EdgeGuard.guarded(point, screen: screen.frame, edge: systemDockEdge,
                                             span: systemDockSpan ?? whole, others: others)
        else { return }
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: screen.frame.maxY - target.y))
        // Without this, the pointer would freeze for a moment after being moved.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The edge the hidden system Dock is on and the stretch of it it covers: its icon list's frame through
    /// Accessibility when allowed, otherwise an estimate from its preferences. A few points spare each end.
    private func measureSystemDock() {
        guard isActive, let screen else { return }
        let preferences = AppPreferenceDomain(SystemDockReader.domain)
        systemDockEdge = (preferences.value(forKey: "orientation") as? String).flatMap(ScreenEdge.init) ?? .bottom
        let measured = SystemDockMeasure.iconListSpan(edge: systemDockEdge)
        let estimated: ClosedRange<CGFloat> = {
            let pinned = DockPins(SystemDockReader.currentApps())
            let running = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular && app.bundleIdentifier != FinderDesktop.bundleID
            }
            let unpinned = running.filter { app in
                !pinned.contains(DockApp(url: app.bundleURL ?? URL(fileURLWithPath: "/"),
                                         bundleID: app.bundleIdentifier))
            }
            let count = SystemDockSpan.itemCount(preferences: preferences, running: running.count,
                                                 unpinnedRunning: unpinned.count)
            let tileSize = (preferences.value(forKey: "tilesize") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 16
            return SystemDockSpan.estimate(itemCount: count, tileSize: tileSize, screen: screen.frame,
                                           edge: systemDockEdge)
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
        keepOffSystemDockEdge(point, screen: screen)
        guard options.autohides else { return }
        if !isRevealed {
            let atEdge = point.y <= screen.frame.minY + 2
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

    private static func makeAgent() -> SystemDockAgent {
        SystemDockAgent(
            isDockRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty
            },
            launchctl: { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return -1
                }
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
    /// Along `edge`: x for the bottom, y (bottom-left origin) for the sides.
    static func iconListSpan(edge: ScreenEdge) -> ClosedRange<CGFloat>? {
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
                  size.width > 0, size.height > 0 else { continue }
            if edge == .bottom {
                guard size.width > size.height else { continue }
                return position.x...(position.x + size.width)
            }
            guard size.height > size.width, let mainHeight = NSScreen.screens.first?.frame.height else { continue }
            return (mainHeight - position.y - size.height)...(mainHeight - position.y)
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
