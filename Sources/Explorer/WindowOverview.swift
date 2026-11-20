import AppKit
import ApplicationServices
import ExplorerCore
import ScreenCaptureKit

/// Mission Control's overview while the system Dock is stopped: every window side by side over the
/// dimmed screen (or only the front app's, as App Exposé). A click or Return brings the window forward;
/// Esc, a click outside or the same key again closes it. ⌃↑, ⌃↓ and the Mission Control key open it,
/// read by the ⌘Tab event tap. Pictures of the windows need the Screen Recording permission; without it
/// each window shows as its app's icon.
final class WindowOverview {
    static let shared = WindowOverview()

    private var panel: NSPanel?
    private var view: WindowOverviewView?
    private(set) var isShown = false

    static var canTakePictures: Bool { CGPreflightScreenCaptureAccess() }

    static func askForPictures() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Opening and closing

    /// `onlyApp` limits it to one app's windows (⌃↓).
    func toggle(onlyApp pid: pid_t? = nil) {
        isShown ? close() : open(onlyApp: pid)
    }

    private func open(onlyApp pid: pid_t?) {
        guard let screen = NSScreen.screens.first else { return }
        let windows = Self.windows(onlyApp: pid)
        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: false)
        guard let view else { return }
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.show(windows)
        isShown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        takePictures(of: windows)
    }

    func close() {
        guard isShown, let panel else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isShown == false { panel.orderOut(nil) }
        })
    }

    /// Keys while the overview is open; true when the key was used.
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard isShown, let view else { return false }
        switch keyCode {
        case 53: close()                                            // Esc
        case 36, 76: view.chooseSelection()                         // Return, Enter
        case 123: view.move(.left)
        case 124: view.move(.right)
        case 125: view.move(.down)
        case 126: view.move(.up)
        default: return false
        }
        return true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        let view = WindowOverviewView { [weak self] window in
            self?.close()
            if let window { Self.bringForward(window) }
        }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }

    // MARK: The windows

    private static func windows(onlyApp pid: pid_t?) -> [OverviewWindow] {
        let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var titles: [Int32: [(CGRect, String)]] = [:]
        return list.compactMap { info -> OverviewWindow? in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let owner = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == nil || owner == pid,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  OverviewWindow.isShown(layer: info[kCGWindowLayer as String] as? Int ?? -1,
                                         alpha: info[kCGWindowAlpha as String] as? Double ?? 0,
                                         frame: bounds, screens: screens)
            else { return nil }
            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            // Window names need Screen Recording; Accessibility gives them too.
            var title = info[kCGWindowName as String] as? String ?? ""
            if title.isEmpty {
                if titles[owner] == nil { titles[owner] = accessibilityWindows(of: owner).map { ($0.frame, $0.title) } }
                let candidates = titles[owner] ?? []
                if let index = WindowMatch.index(of: bounds, in: candidates.map(\.0)) { title = candidates[index].1 }
            }
            return OverviewWindow(id: id, pid: owner, frame: bounds, title: title.isEmpty ? appName : title,
                                  appName: appName)
        }
    }

    private static func accessibilityWindows(of pid: pid_t) -> [(element: AXUIElement, frame: CGRect, title: String)] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var position: CFTypeRef?, size: CFTypeRef?, title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            var origin = CGPoint.zero, extent = CGSize.zero
            guard let position, let size,
                  AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return (window, CGRect(origin: origin, size: extent), title as? String ?? "")
        }
    }

    /// The chosen window to the front: raised through Accessibility, its app activated.
    static func bringForward(_ window: OverviewWindow) {
        if window.pid == getpid() {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.window(withWindowNumber: Int(window.id))?.makeKeyAndOrderFront(nil)
            return
        }
        let candidates = accessibilityWindows(of: window.pid)
        if let index = WindowMatch.index(of: window.frame, in: candidates.map(\.frame)) {
            AXUIElementPerformAction(candidates[index].element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(candidates[index].element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if let app = NSRunningApplication(processIdentifier: window.pid) { AppSwitcher.bringForward(app) }
    }

    // MARK: Pictures

    private func takePictures(of windows: [OverviewWindow]) {
        guard Self.canTakePictures, #available(macOS 14, *) else { return }
        let wanted = Set(windows.map(\.id))
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            else { return }
            for window in content.windows where wanted.contains(window.windowID) {
                let configuration = SCStreamConfiguration()
                let scale = min(1, 900 / max(window.frame.width, 1))
                configuration.width = Int(window.frame.width * scale * 2)
                configuration.height = Int(window.frame.height * scale * 2)
                configuration.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                else { continue }
                let picture = NSImage(cgImage: image, size: window.frame.size)
                self?.view?.setPicture(picture, for: window.windowID)
            }
        }
    }
}

/// The dimmed screen with the windows laid out on it.
final class WindowOverviewView: NSView {
    private var windows: [OverviewWindow] = []
    private var frames: [CGRect] = []
    private var pictures: [UInt32: NSImage] = [:]
    private var icons: [Int32: NSImage] = [:]
    private var selection: Int?
    private let choose: (OverviewWindow?) -> Void

    init(choose: @escaping (OverviewWindow?) -> Void) {
        self.choose = choose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ windows: [OverviewWindow]) {
        self.windows = windows
        pictures = [:]
        icons = Dictionary(windows.map { ($0.pid, NSRunningApplication(processIdentifier: $0.pid)?.icon ?? NSImage()) },
                           uniquingKeysWith: { first, _ in first })
        frames = OverviewLayout.frames(for: windows.map(\.frame.size), in: bounds.insetBy(dx: 40, dy: 50))
        selection = windows.isEmpty ? nil : 0
        needsDisplay = true
    }

    func setPicture(_ picture: NSImage, for id: UInt32) {
        pictures[id] = picture
        needsDisplay = true
    }

    func move(_ direction: OverviewLayout.Direction) {
        guard let selection else { return }
        self.selection = OverviewLayout.neighbour(of: selection, count: windows.count, frames: frames,
                                                  direction: direction)
        needsDisplay = true
    }

    func chooseSelection() {
        choose(selection.map { windows[$0] })
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        if windows.isEmpty {
            let text = NSAttributedString(string: "No windows", attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
            text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - 12))
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        for (index, window) in windows.enumerated() {
            let frame = frames[index]
            let card = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            card.addClip()
            if let picture = pictures[window.id] {
                picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                             hints: nil)
            } else {
                NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
                frame.fill()
                let side = min(frame.width, frame.height, 128) * 0.6
                icons[window.pid]?.draw(in: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                                                   width: side, height: side),
                                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                        hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            if index == selection {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -4, dy: -4), xRadius: 13, yRadius: 13)
                ring.lineWidth = 4
                ring.stroke()
            }
            // App icon on the window's bottom edge (the card already shows it without a picture), and its
            // title below.
            let badge: CGFloat = min(48, frame.width / 3)
            if pictures[window.id] != nil { icons[window.pid]?.draw(in: NSRect(x: frame.midX - badge / 2, y: frame.maxY - badge * 0.6,
                                               width: badge, height: badge),
                                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            let title = NSAttributedString(string: window.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: index == selection ? .semibold : .regular),
                .foregroundColor: NSColor.white, .paragraphStyle: style,
                .shadow: { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; return shadow }()])
            title.draw(in: NSRect(x: frame.minX - 20, y: frame.maxY + badge * 0.45, width: frame.width + 40, height: 20))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.insetBy(dx: -6, dy: -6).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = index(at: event), index != selection {
            selection = index
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        choose(index(at: event).map { windows[$0] })
    }
}
