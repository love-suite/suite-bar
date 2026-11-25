import AppKit
import SuiteCore
import ApplicationServices
import BarCore

/// Keeps windows above Explorer's Dock, as macOS keeps them above its own: maximized windows (and windows
/// resized into the Dock's strip) are shortened to end where the Dock starts. Other apps' windows are
/// reached through the Accessibility API, which needs the user's permission (Privacy & Security ›
/// Accessibility); Explorer's own windows don't.
final class WindowFitter {
    /// Posted when the Accessibility permission is given or taken away.
    static let permissionDidChange = Notification.Name("WindowFitterPermissionDidChange")

    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Height kept for the Dock above the main screen's bottom; 0 turns fitting off.
    var reserved: CGFloat = 0 {
        didSet {
            guard reserved != oldValue else { return }
            reserved > 0 ? start() : stop()
            if reserved > 0 { fitAll() }
        }
    }

    private var observers: [pid_t: AXObserver] = [:]
    private var notifications: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var wasPermitted = WindowFitter.isPermitted
    /// When each window was last changed, so a window refusing its new size isn't tried over and over.
    private var lastFitted: [CFHashCode: Date] = [:]
    /// Windows being resized: each is looked at once it has stopped changing, not at every step.
    private var waiting: [CFHashCode: DispatchWorkItem] = [:]

    /// Shows macOS's request for the permission, then the pane where it is given.
    static func askForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Watching windows

    private func start() {
        guard notifications.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication).map { self?.watch($0) }
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
        })
        // An app brought forward may have been maximized while the Dock wasn't there.
        notifications.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.fitWindows(of: app)
        })
        // Explorer's own windows: no Accessibility needed (and asking ourselves through it would block).
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                        queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, !window.inLiveResize else { return }
                DispatchQueue.main.async { self?.fit(window, onlyIfFilling: false) }
            })
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkPermission()
        }
        watchRunningApps()
    }

    private func stop() {
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        permissionTimer?.invalidate()
        permissionTimer = nil
        for pid in Array(observers.keys) { unwatch(pid) }
    }

    private func checkPermission() {
        let permitted = Self.isPermitted
        guard permitted != wasPermitted else { return }
        wasPermitted = permitted
        NotificationCenter.default.post(name: Self.permissionDidChange, object: nil)
        if permitted {
            watchRunningApps()
            fitAll()
        }
    }

    private func watchRunningApps() {
        guard Self.isPermitted else { return }
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !BarHiddenApps.contains($0.bundleIdentifier) }.forEach(watch)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard Self.isPermitted, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowFitter>.fromOpaque(refcon).takeUnretainedValue().fitSoon(element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        // A busy app mustn't hold Explorer up.
        AXUIElementSetMessagingTimeout(element, 0.3)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowResizedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: Fitting

    /// Maximized windows of every app (when the Dock appears or changes size).
    private func fitAll() {
        NSApp.windows.forEach { fit($0, onlyIfFilling: true) }
        guard Self.isPermitted else { return }
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !BarHiddenApps.contains($0.bundleIdentifier) }.forEach(fitWindows)
    }

    private func fitWindows(of app: NSRunningApplication) {
        guard reserved > 0 else { return }
        if app.processIdentifier == getpid() {
            NSApp.windows.forEach { fit($0, onlyIfFilling: true) }
            return
        }
        guard Self.isPermitted else { return }
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        windows.forEach { fit($0, onlyIfFilling: true) }
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    private func target(for frame: CGRect, onlyIfFilling: Bool) -> CGRect? {
        guard reserved > 0, let screen else { return nil }
        return WindowFit.fitted(frame, screen: screen.frame, reserved: reserved,
                                visibleTop: screen.visibleFrame.maxY, onlyIfFilling: onlyIfFilling)
    }

    private func fit(_ window: NSWindow, onlyIfFilling: Bool) {
        guard window.styleMask.contains(.titled), window.isVisible, !window.styleMask.contains(.fullScreen),
              let frame = target(for: window.frame, onlyIfFilling: onlyIfFilling) else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    private func fitSoon(_ element: AXUIElement) {
        let key = CFHash(element)
        waiting[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.waiting[key] = nil
            self?.fit(element, onlyIfFilling: false)
        }
        waiting[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func fit(_ element: AXUIElement, onlyIfFilling: Bool) {
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard reserved > 0, let height = NSScreen.screens.first?.frame.height,
              role(of: element) == kAXWindowRole as String,
              let position: CGPoint = value(of: element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = value(of: element, kAXSizeAttribute, .cgSize) else { return }
        let frame = WindowFit.flipped(CGRect(origin: position, size: size), mainScreenHeight: height)
        guard let fitted = target(for: frame, onlyIfFilling: onlyIfFilling) else { return }
        let key = CFHash(element)
        if let last = lastFitted[key], Date().timeIntervalSince(last) < 1 { return }
        lastFitted[key] = Date()
        // The top stays where it is, so only the height changes.
        var newSize = fitted.size
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    private func value<T>(of element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(value as! AXValue, type, pointer) ? pointer.pointee : nil
    }
}
