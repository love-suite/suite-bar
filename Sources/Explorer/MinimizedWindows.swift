import AppKit
import ApplicationServices
import ExplorerCore

/// Other apps' minimized windows, for our Dock: the system Dock that would show them is hidden. Found and
/// brought back through the Accessibility API (the user's permission, as for keeping windows above the
/// Dock); without it, the Dock shows none.
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
        let element: AXUIElement
        let pid: pid_t
    }

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

    // MARK: Watching apps

    private func start() {
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
        retry?.invalidate()
        retry = nil
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notifications.removeAll()
        for pid in Array(observers.keys) { unwatch(pid) }
        entries = []
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
            entries.removeAll { CFEqual($0.element, element) }
        }
    }

    private func add(_ element: AXUIElement, pid: pid_t) {
        guard !entries.contains(where: { CFEqual($0.element, element) }),
              let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return }
        AXUIElementSetMessagingTimeout(element, 0.3)
        let title = Self.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.localizedName ?? url.deletingPathExtension().lastPathComponent
        let window = DockWindow(id: nextID, title: title,
                                app: DockApp(url: url, bundleID: app.bundleIdentifier, name: app.localizedName))
        nextID += 1
        entries.append(Entry(window: window, element: element, pid: pid))
    }

    // MARK: Bringing back

    func restore(_ id: Int) {
        guard let entry = entries.first(where: { $0.window.id == id }) else { return }
        entries.removeAll { $0.window.id == id }
        AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
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

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
