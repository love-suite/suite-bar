import AppKit
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
        apply()
    }

    /// Explorer quits: the system Dock comes back as it was.
    func stop() {
        panel?.orderOut(nil)
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
            panel?.dockView.geometry = options.geometry
            setAutohides(options.autohides)
            place()
            hider.hide()
        } else {
            setAutohides(false)
            panel?.orderOut(nil)
            fitter.reserved = 0
            hider.restore()
        }
        // The screen's visible area follows the system Dock once it has restarted.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
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

    // MARK: Automatic hiding

    private func setAutohides(_ autohides: Bool) {
        if autohides, mouseMonitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                self?.pointerMoved()
            }) { mouseMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                self?.pointerMoved()
                return event
            }) { mouseMonitors.append(local) }
            conceal()
        } else if !autohides, !mouseMonitors.isEmpty {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors.removeAll()
            pending?.cancel()
            isRevealed = true
        }
    }

    private func pointerMoved() {
        guard let panel, let shown = shownFrame, let screen else { return }
        let point = NSEvent.mouseLocation
        if !isRevealed {
            let atEdge = point.y <= screen.frame.minY + 1 && point.x >= shown.minX - 20 && point.x <= shown.maxX + 20
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
