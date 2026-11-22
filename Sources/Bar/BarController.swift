import AppKit
import SuiteCore
import ApplicationServices
import DockGuard
import BarCore
import BarSettings

/// Explorer's own Dock, in place of the system one: shown at the bottom of the main screen while
/// Explorer manages files and the option is on, with the system Dock (and Finder's icon in it) hidden.
/// It stays on screen, windows kept above it, or slides away until the pointer reaches the bottom edge.
final class BarController {
    static let shared = BarController()

    private var panel: BarPanel?
    private let hider = BarController.makeHider()
    private let fitter = WindowFitter()
    private var observers: [NSObjectProtocol] = []

    // Automatic hiding.
    private var mouseMonitors: [Any] = []
    private var isRevealed = true
    private var pending: DispatchWorkItem?
    /// Mission Control shows the Dock, so ours slides in for it, over the hidden mini system Dock.
    private var missionControlTimer: Timer?
    private var inMissionControl = false
    private var bundleIDs: [pid_t: String] = [:]
    /// Where the hidden system Dock wakes up: its edge, and the stretch along it.
    private var systemDockEdge: ScreenEdge = .bottom
    private var systemDockSpan: ClosedRange<CGFloat>?

    /// A full-screen Space in front, where the Dock does as Settings › Dock says for full screen.
    private var inFullScreen = false
    private let edgeProbe = BarEdgeProbe()

    private var options: BarSettings { BarSettings.current }
    /// Whether the Dock hides automatically now: by default, or as the app in front and full screen say.
    private var autohides: Bool {
        options.hides(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, inFullScreen: inFullScreen)
    }
    /// What `autohides` was last applied as.
    private var appliedAutohides: Bool?
    /// Shown while it is turned on and Explorer manages files (Explorer's switch, not Finder).
    private var isActive: Bool { options.isShown && Self.explorerManagesFiles }

    /// Explorer's Explorer/Finder switch (Settings › Explorer), read from its defaults. Explorer only
    /// writes it once the switch is turned: until then it isn't there, and Explorer manages files.
    static var explorerManagesFiles: Bool {
        CFPreferencesAppSynchronize(SuiteDefaults.explorerDomain as CFString)
        return SuiteDefaults.explorer.object(forKey: "UseExplorer") as? Bool ?? true
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: BarSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        })
        // Explorer says when its settings change, the Explorer/Finder switch among them.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: ExplorerLink.explorerDidChange, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.place() })
        // The system Dock grows and shrinks with the running apps.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.measureSystemDock() }
            })
        }
        // Another app in front may hide or keep the Dock (Settings › Dock). Entering or leaving full screen
        // changes the Space; its windows settle once the animation is over.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                for delay in [0.0, 0.6, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.checkFullScreen() }
                }
            })
        }
        apply()
    }

    /// The Dock quits for an update or a relaunch. The system Dock stays hidden: restarting it (twice, with the next launch) leaves
    /// Spaces, ⌘Tab and Mission Control unusable for a minute or two, which the user can't bear on every
    /// update. Its settings come back on choosing the System Dock or Finder, or with `--restore-finder`.
    func stop() {
        panel?.orderOut(nil)
        setWatchingPointer(false)
        fitter.reserved = 0
    }

    /// For `--restore-finder`, after a forced quit, and when Explorer is quit: the system Dock as it was.
    static func restoreSystemDock() {
        makeHider().restore()
        GuardAgent.update()
    }

    private func apply() {
        if isActive {
            if panel == nil {
                let panel = BarPanel()
                panel.barView.onSizeChange = { [weak self] in self?.place() }
                self.panel = panel
            }
            setWatchingPointer(true)
            panel?.barView.geometry = options.geometry
            panel?.barView.showsLauncher = options.showsLauncher
            updateHiding()
            place()
            MinimizedWindows.shared.isEnabled = true
            hider.hide()
            // The Dock's settings are ours while we show: the system Dock gets our size and automatic
            // hiding when it comes back (within its own range).
            hider.carry(["tilesize": Double(min(max(BarSettings.current.iconSize, 16), 128)),
                         "autohide": BarSettings.current.autohides])
            // While the system Dock is hidden, Dock Guard puts it back should Explorer vanish.
            GuardAgent.update()
        } else {
            setAutohides(false)
            appliedAutohides = nil
            setWatchingPointer(false)
            MinimizedWindows.shared.isEnabled = false
            panel?.orderOut(nil)
            fitter.reserved = 0
            hider.restore()
            GuardAgent.update()
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
        let size = panel.barView.barSize
        // Low enough to cover the hidden mini system Dock (3 to 18 points up), which Mission Control shows.
        let bottom = screen.frame.minY + 2
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
        fitter.reserved = appliedAutohides ?? options.autohides ? 0 : shown.maxY + 2 - screen.frame.minY
    }

    // MARK: The pointer at the system Dock's edge

    /// Watches the pointer everywhere (no permission needed for mouse events), to keep it off the hidden
    /// system Dock's edge and to slide our Dock in when it hides automatically.
    private func setWatchingPointer(_ watching: Bool) {
        if watching, mouseMonitors.isEmpty {
            edgeProbe.start(atEdge: { [weak self] point in
                guard let self, let screen, let shown = shownFrame else { return false }
                return point.y <= screen.frame.minY + EdgeGuard.gap + 1
                    && point.x >= shown.minX - 20 && point.x <= shown.maxX + 20
            }, describe: { [weak self] in
                guard let self else { return "" }
                let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                return "front: \(app), full screen: \(inFullScreen), hides: \(appliedAutohides == true), "
                    + "revealed: \(isRevealed)"
            })
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                self?.edgeProbe.monitorSaw(NSEvent.mouseLocation)
                self?.pointerMoved()
            }) { mouseMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                self?.edgeProbe.monitorSaw(NSEvent.mouseLocation)
                self?.pointerMoved()
                return event
            }) { mouseMonitors.append(local) }
        } else if !watching, !mouseMonitors.isEmpty {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors.removeAll()
        }
    }

    /// macOS 27 ignores the long `autohide-delay`: on the outermost pixels of its edge the hidden system
    /// Dock wakes up and shows its icons' names. Along its short stretch of that edge (the middle of the
    /// bottom edge, with icons of a point), the pointer is put back a few points in, too little to be
    /// noticed; a screen beyond is reached.
    private func keepOffSystemDockEdge(_ point: NSPoint, screen: NSScreen) {
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
        let preferences = AppPreferenceDomain(DockReader.domain)
        systemDockEdge = (preferences.value(forKey: "orientation") as? String).flatMap(ScreenEdge.init) ?? .bottom
        let measured = DockMeasure.iconListSpan(edge: systemDockEdge)
        let estimated: ClosedRange<CGFloat> = {
            let pinned = BarPins(DockReader.currentApps())
            let running = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular && app.bundleIdentifier != "com.apple.finder"
            }
            let unpinned = running.filter { app in
                !pinned.contains(BarApp(url: app.bundleURL ?? URL(fileURLWithPath: "/"),
                                         bundleID: app.bundleIdentifier))
            }
            let count = DockSpan.itemCount(preferences: preferences, running: running.count,
                                                 unpinnedRunning: unpinned.count)
            let tileSize = (preferences.value(forKey: "tilesize") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 16
            return DockSpan.estimate(itemCount: count, tileSize: max(tileSize, DockSpan.smallestShownTile),
                                     screen: screen.frame, edge: systemDockEdge)
        }()
        // The measure is the Dock as it is on the desktop (1-point icons); over a full-screen app it comes up
        // larger: the guarded stretch covers both.
        let span = measured.map { min($0.lowerBound, estimated.lowerBound)...max($0.upperBound, estimated.upperBound) }
            ?? estimated
        systemDockSpan = (span.lowerBound - 12)...(span.upperBound + 12)
    }

    // MARK: Full screen

    private func checkFullScreen() {
        guard isActive, let screen else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> FullScreenSpace.Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return FullScreenSpace.Window(ownerPID: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                          bounds: bounds)
        }
        let full = FullScreenSpace.isActive(windows: windows, screen: screen.frame.size,
                                            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        inFullScreen = full
        updateHiding()
    }

    /// The app in front or full screen changed, or the settings: hides or stays as they now say.
    private func updateHiding() {
        let hides = autohides
        guard hides != appliedAutohides else { return }
        appliedAutohides = hides
        setAutohides(hides)
        place()
    }

    // MARK: Automatic hiding

    private func setAutohides(_ autohides: Bool) {
        if autohides, isRevealed {
            // Not from under the pointer (an app just clicked in the Dock): once it has left.
            pointerMoved()
        } else if !autohides {
            cancelPending()
            isRevealed = true
        }
        watchMissionControl(autohides)
    }

    /// Mission Control has no notification; its Spaces bar is looked for among the windows on screen, five
    /// times a second (a cheap call), only while our Dock hides itself.
    private func watchMissionControl(_ watching: Bool) {
        if watching, missionControlTimer == nil {
            missionControlTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.checkMissionControl()
            }
        } else if !watching {
            missionControlTimer?.invalidate()
            missionControlTimer = nil
            inMissionControl = false
        }
    }

    private func checkMissionControl() {
        guard let screen else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> MissionControl.Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            return MissionControl.Window(owner: bundleIDs[pid] ?? "", layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                         size: bounds.size)
        }
        let open = MissionControl.isOpen(windows: windows, screen: screen.frame.size)
        guard open != inMissionControl else { return }
        inMissionControl = open
        if open {
            cancelPending()
            reveal()
        } else {
            pointerMoved()
        }
    }

    private func pointerMoved() {
        guard let panel, let shown = shownFrame, let screen else { return }
        let point = NSEvent.mouseLocation
        keepOffSystemDockEdge(point, screen: screen)
        guard appliedAutohides == true else { return }
        if !isRevealed {
            // The edge guard may have put the pointer back a few points up.
            let atEdge = point.y <= screen.frame.minY + EdgeGuard.gap + 1
                && point.x >= shown.minX - 20 && point.x <= shown.maxX + 20
            atEdge ? schedule(0.12) { [weak self] in self?.reveal() } : cancelPending()
        } else {
            let near = shown.insetBy(dx: -8, dy: -8).union(NSRect(x: shown.minX, y: screen.frame.minY,
                                                                  width: shown.width, height: 1)).contains(point)
            near || panel.barView.isBusy || inMissionControl
                ? cancelPending() : schedule(0.35) { [weak self] in self?.conceal() }
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
        guard !panel.barView.isBusy, !inMissionControl else { return }
        isRevealed = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(hidden, display: true)
        }, completionHandler: { [weak self] in
            if self?.isRevealed == false { panel.orderOut(nil) }
        })
    }

    private static func makeHider() -> DockManager {
        DockManager(restartDock: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Dock"]
            try? process.run()
            process.waitUntilExit()
        })
    }
}

/// Asks the system Dock (through Accessibility, when allowed) where its icons are.
enum DockMeasure {
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
final class BarPanel: NSPanel {
    let barView = BarView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // A level above the system Dock, so that in Mission Control it covers the hidden mini Dock.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // In full-screen Spaces too, where the system Dock would slide in.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        contentView = BarBackground(bar: barView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The Dock's translucent rounded bar, with the icons on top.
final class BarBackground: NSView {
    private let material = NSVisualEffectView()

    init(bar: BarView) {
        super.init(frame: .zero)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        bar.autoresizingMask = [.width, .height]
        addSubview(material)
        addSubview(bar)
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
