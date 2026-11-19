import AppKit
import ApplicationServices
import ExplorerCore

/// ⌘Tab while the system Dock is stopped (it is the Dock that draws the system's switcher). Hold ⌘ and
/// press Tab to go through the apps, most recently used first; ⇧ or the arrows go back, Esc cancels,
/// letting go of ⌘ brings the chosen app forward; the pointer can choose too. The keys are read by an
/// event tap, which needs the Accessibility permission.
final class AppSwitcher {
    static let shared = AppSwitcher()

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retry: Timer?
    private var recent = RecentApps()
    private var state: AppSwitcherState?
    private var shown: [NSRunningApplication] = []
    private lazy var panel = AppSwitcherPanel(onPoint: { [weak self] index in self?.pointed(at: index) },
                                              commit: { [weak self] in self?.commit() })

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                              queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.activated(app.processIdentifier)
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                              queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.terminated(app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication { recent.activated(front.processIdentifier) }
    }

    // MARK: The key tap

    private func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Waits for the permission, given in Settings › Dock.
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                self?.retry?.invalidate()
                self?.retry = nil
                self?.start()
            }
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<AppSwitcher>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        retry?.invalidate()
        retry = nil
        close()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let shift = flags.contains(.maskShift)
            if state == nil, Self.isMinimizeKey(event) {
                // ⌘M does nothing without the system Dock; Explorer minimizes instead.
                MinimizedWindows.shared.parkFrontWindow()
                return nil
            }
            if state == nil {
                guard keyCode == AppSwitcherKey.tab, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return pass }
                open(backwards: shift)
                return nil
            }
            switch AppSwitcherKey(keyCode: keyCode, shift: shift) {
            case .next: state?.next(); show()
            case .previous: state?.previous(); show()
            case .cancel: close()
            case .ignore: break
            }
            return nil
        case .keyUp:
            return state == nil ? pass : nil
        case .flagsChanged:
            if state != nil, !event.flags.contains(.maskCommand) { commit() }
            return pass
        default:
            return pass
        }
    }

    /// ⌘M alone, whatever the keyboard layout (the character typed, not the key's place).
    private static func isMinimizeKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand), !flags.contains(.maskShift), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return false }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: length).lowercased() == "m"
    }

    // MARK: The switcher

    private func open(backwards: Bool) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let order = recent.ordered(apps.map(\.processIdentifier))
        shown = order.compactMap { byPID[$0] }
        guard !shown.isEmpty else { return }
        state = AppSwitcherState(apps: order, backwards: backwards)
        show()
    }

    private func show() {
        guard let state else { return }
        panel.show(apps: shown, selection: state.selection)
    }

    private func pointed(at index: Int) {
        state?.select(index)
        show()
    }

    private func commit() {
        guard let pid = state?.selected,
              let app = shown.first(where: { $0.processIdentifier == pid }) else { return close() }
        close()
        Self.bringForward(app)
    }

    private func close() {
        state = nil
        shown = []
        panel.orderOut(nil)
    }

    /// Activation from an app in the background may be refused; reopening the app, as a Dock click does,
    /// is the fallback.
    static func bringForward(_ app: NSRunningApplication) {
        if app.processIdentifier == getpid() {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication != app, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}

/// The row of app icons in the middle of the screen, as macOS draws its switcher.
final class AppSwitcherPanel: NSPanel {
    private let content: AppSwitcherView

    init(onPoint: @escaping (Int) -> Void, commit: @escaping () -> Void) {
        content = AppSwitcherView(onPoint: onPoint, commit: commit)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 22
        material.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]
        material.addSubview(content)
        contentView = material
    }

    override var canBecomeKey: Bool { false }

    func show(apps: [NSRunningApplication], selection: Int) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        content.apps = apps
        content.selection = selection
        let size = content.size(fitting: screen.visibleFrame.width - 80)
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        if self.frame != frame {
            setFrame(frame, display: false)
            content.frame = NSRect(origin: .zero, size: size)
        }
        content.needsDisplay = true
        orderFrontRegardless()
    }
}

final class AppSwitcherView: NSView {
    var apps: [NSRunningApplication] = []
    var selection = 0
    private var iconSize: CGFloat = 96
    private let onPoint: (Int) -> Void
    private let commit: () -> Void
    private let padding: CGFloat = 18
    private let labelHeight: CGFloat = 26

    init(onPoint: @escaping (Int) -> Void, commit: @escaping () -> Void) {
        self.onPoint = onPoint
        self.commit = commit
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cell: CGFloat { iconSize + 24 }

    /// Icons shrink when there are too many apps for the screen's width.
    func size(fitting width: CGFloat) -> NSSize {
        let count = CGFloat(max(apps.count, 1))
        iconSize = min(96, max(32, (width - 2 * padding) / count - 24)).rounded()
        return NSSize(width: count * cell + 2 * padding, height: cell + labelHeight + 2 * padding - 6)
    }

    private func frame(of index: Int) -> NSRect {
        NSRect(x: padding + CGFloat(index) * cell, y: padding + labelHeight - 6, width: cell, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, app) in apps.enumerated() {
            let tile = frame(of: index)
            if index == selection {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: tile, xRadius: 14, yRadius: 14).fill()
            }
            app.icon?.draw(in: tile.insetBy(dx: 12, dy: 12), from: .zero, operation: .sourceOver, fraction: 1)
        }
        guard apps.indices.contains(selection) else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: apps[selection].localizedName ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white,
            .paragraphStyle: style])
        let tile = frame(of: selection)
        let width = max(tile.width + 60, name.size().width + 8)
        let x = min(max(tile.midX - width / 2, 4), bounds.width - width - 4)
        name.draw(in: NSRect(x: x, y: padding - 8, width: width, height: labelHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect],
                                       owner: self))
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return apps.indices.first { frame(of: $0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = index(at: event), index != selection { onPoint(index) }
    }

    override func mouseUp(with event: NSEvent) {
        if let index = index(at: event) {
            onPoint(index)
            commit()
        }
    }
}
