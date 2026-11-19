import AppKit
import ExplorerCore

/// Explorer's own Dock: shown at the bottom of the main screen while Explorer manages files and the
/// option is on, with the system Dock (and Finder's icon in it) hidden if the user wants.
final class DockController {
    static let shared = DockController()

    private var panel: DockPanel?
    private let hider = DockController.makeHider()
    private var observers: [NSObjectProtocol] = []

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
            place()
            panel?.orderFrontRegardless()
            if options.hidesSystemDock { hider.hide() } else { hider.restore() }
        } else {
            panel?.orderOut(nil)
            hider.restore()
        }
        // The screen's visible area follows the system Dock once it has restarted.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
        }
    }

    /// Centred at the bottom of the main screen, above the system Dock when that one shows.
    private func place() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let size = panel.dockView.barSize
        let bottom = max(screen.visibleFrame.minY, screen.frame.minY) + 4
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: bottom,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
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
