import AppKit
import ApplicationServices
import ExplorerCore

/// Minimized windows, for our Dock: the system Dock that would show them is hidden. Explorer's own are
/// followed directly; other apps' are found and brought back through the Accessibility API (the user's
/// permission, as for keeping windows above the Dock), without which the Dock shows only Explorer's.
final class MinimizedWindows {
    static let shared = MinimizedWindows()
    static let didChange = Notification.Name("MinimizedWindowsDidChange")

    private(set) var windows: [DockWindow] = []

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private struct Entry {
        let window: DockWindow
        /// Another app's window, or one of Explorer's.
        var element: AXUIElement?
        var own: NSWindow?
        let pid: pid_t
        /// Set for a window we "minimized" ourselves with the system Dock stopped: where it was (in
        /// Accessibility coordinates) before being moved into the screen's corner.
        var parkedFrame: CGRect? = nil
    }

    /// With the system Dock stopped, minimizing does nothing: ⌘M and the yellow button then move the
    /// window out of sight into the bottom right corner of the screen (as AeroSpace hides windows; macOS
    /// keeps a pixel of it on screen) and list it in our Dock.
    var parksWindows = false {
        didSet {
            guard parksWindows != oldValue else { return }
            parksWindows ? watchMinimizeButtons() : unparkAll()
        }
    }
    private var buttonMonitors: [Any] = []

    private var entries: [Entry] = [] {
        didSet {
            windows = entries.map(\.window)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    private var nextID = 1
    private var observers: [pid_t: AXObserver] = [:]
    private var notifications: [NSObjectProtocol] = []
    private var retry: Timer?
    private var watchesOwnWindows = false

    // MARK: Watching apps

    private func start() {
        watchOwnWindows()
        guard AXIsProcessTrusted() else {
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                self?.retry?.invalidate()
                self?.retry = nil
                self?.start()
            }
            return
        }
        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Give the app a moment to answer Accessibility.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.watch(app) }
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
        })
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.forEach(watch)
    }

    private func stop() {
        unparkAll()
        retry?.invalidate()
        retry = nil
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        watchesOwnWindows = false
        for pid in Array(observers.keys) { unwatch(pid) }
        entries = []
    }

    private func watchOwnWindows() {
        guard !watchesOwnWindows else { return }
        watchesOwnWindows = true
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil,
                                                queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  !self.entries.contains(where: { $0.own === window }) else { return }
            let me = DockApp(url: Bundle.main.bundleURL, bundleID: Bundle.main.bundleIdentifier, name: "Explorer")
            let title = window.title.isEmpty ? "Explorer" : window.title
            self.entries.append(Entry(window: DockWindow(id: self.nextID, title: title, app: me), element: nil,
                                      own: window, pid: getpid()))
            self.nextID += 1
        })
        notifications.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil,
                                                queue: .main) { [weak self] note in
            self?.entries.removeAll { $0.own === (note.object as? NSWindow) }
        })
        notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                queue: .main) { [weak self] note in
            self?.entries.removeAll { $0.own === (note.object as? NSWindow) }
        })
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isEnabled, AXIsProcessTrusted(), pid != getpid(), observers[pid] == nil else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<MinimizedWindows>.fromOpaque(refcon).takeUnretainedValue()
            me.changed(element, notification: name as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        // Windows minimized before we were watching.
        for window in Self.windows(of: element) where Self.bool(window, kAXMinimizedAttribute) {
            add(window, pid: pid)
        }
    }

    private func unwatch(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        entries.removeAll { $0.pid == pid }
    }

    private func changed(_ element: AXUIElement, notification: String) {
        switch notification {
        case kAXWindowMiniaturizedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            add(element, pid: pid)
        default:
            // Brought back, closed, or its app gone.
            entries.removeAll { $0.element.map { CFEqual($0, element) } ?? false }
        }
    }

    private func add(_ element: AXUIElement, pid: pid_t) {
        guard !entries.contains(where: { $0.element.map { CFEqual($0, element) } ?? false }),
              let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return }
        AXUIElementSetMessagingTimeout(element, 0.3)
        let title = Self.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.localizedName ?? url.deletingPathExtension().lastPathComponent
        let window = DockWindow(id: nextID, title: title,
                                app: DockApp(url: url, bundleID: app.bundleIdentifier, name: app.localizedName))
        nextID += 1
        entries.append(Entry(window: window, element: element, own: nil, pid: pid))
    }

    // MARK: Bringing back

    func restore(_ id: Int) {
        guard let entry = entries.first(where: { $0.window.id == id }) else { return }
        entries.removeAll { $0.window.id == id }
        if entry.parkedFrame != nil {
            unpark(entry, activating: true)
            return
        }
        if let own = entry.own {
            NSApp.activate(ignoringOtherApps: true)
            own.deminiaturize(nil)
            return
        }
        guard let element = entry.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return }
        app.activate(options: [])
        // Activation from an app in the background may be refused; reopening the app is the fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard NSWorkspace.shared.frontmostApplication != app, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    // MARK: Minimizing without the system Dock

    /// ⌘M: the front window of the app in front.
    func parkFrontWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.processIdentifier == getpid() {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow { park(own: window) }
            return
        }
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        park(value as! AXUIElement, pid: front.processIdentifier)
    }

    private func park(own window: NSWindow) {
        guard window.styleMask.contains(.miniaturizable), !entries.contains(where: { $0.own === window }) else { return }
        let me = DockApp(url: Bundle.main.bundleURL, bundleID: Bundle.main.bundleIdentifier, name: "Explorer")
        let title = window.title.isEmpty ? "Explorer" : window.title
        entries.append(Entry(window: DockWindow(id: nextID, title: title, app: me), element: nil, own: window,
                             pid: getpid(), parkedFrame: window.frame))
        nextID += 1
        window.orderOut(nil)
    }

    private func park(_ element: AXUIElement, pid: pid_t) {
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard Self.string(element, kAXRoleAttribute) == kAXWindowRole as String,
              !entries.contains(where: { $0.element.map { CFEqual($0, element) } ?? false }),
              let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL,
              let position: CGPoint = Self.value(element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = Self.value(element, kAXSizeAttribute, .cgSize),
              let screen = NSScreen.screens.first?.frame else { return }
        let title = Self.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.localizedName ?? url.deletingPathExtension().lastPathComponent
        entries.append(Entry(window: DockWindow(id: nextID, title: title,
                                                app: DockApp(url: url, bundleID: app.bundleIdentifier,
                                                             name: app.localizedName)),
                             element: element, own: nil, pid: pid,
                             parkedFrame: CGRect(origin: position, size: size)))
        nextID += 1
        var corner = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        if let value = AXValueCreate(.cgPoint, &corner) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        // The next window of the app comes forward, as after a real minimize.
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        if let next = Self.windows(of: appElement).first(where: { !CFEqual($0, element) }) {
            AXUIElementPerformAction(next, kAXRaiseAction as CFString)
        }
    }

    private func unpark(_ entry: Entry, activating: Bool) {
        if let own = entry.own {
            if activating { NSApp.activate(ignoringOtherApps: true) }
            own.makeKeyAndOrderFront(nil)
            return
        }
        guard let element = entry.element, var origin = entry.parkedFrame?.origin else { return }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard activating, let app = NSRunningApplication(processIdentifier: entry.pid) else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard NSWorkspace.shared.frontmostApplication != app, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// Every window we moved away goes back where it was: the system Dock is back, or Explorer quits.
    func unparkAll() {
        buttonMonitors.forEach(NSEvent.removeMonitor)
        buttonMonitors.removeAll()
        let parked = entries.filter { $0.parkedFrame != nil }
        entries.removeAll { $0.parkedFrame != nil }
        parked.forEach { unpark($0, activating: false) }
    }

    /// The yellow button does nothing without the system Dock: a click on it parks its window instead.
    private func watchMinimizeButtons() {
        guard buttonMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.clickedOtherApp(at: NSEvent.mouseLocation)
        }) { buttonMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            if let window = event.window, let button = window.standardWindowButton(.miniaturizeButton),
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                DispatchQueue.main.async { self?.park(own: window) }
            }
            return event
        }) { buttonMonitors.append(local) }
    }

    private func clickedOtherApp(at point: NSPoint) {
        guard AXIsProcessTrusted(), let height = NSScreen.screens.first?.frame.height else { return }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(height - point.y), &hit) == .success,
              let hit, Self.string(hit, kAXSubroleAttribute) == kAXMinimizeButtonSubrole as String else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != getpid() else { return }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
        park(window as! AXUIElement, pid: pid)
    }

    func app(of id: Int) -> NSRunningApplication? {
        entries.first { $0.window.id == id }.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
    }

    // MARK: Accessibility helpers

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(value as! AXValue, type, pointer) ? pointer.pointee : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
