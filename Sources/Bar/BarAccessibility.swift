import AppKit
import ApplicationServices
import BarCore

/// Apps' badges (unread counts and the like), read from the hidden system Dock through Accessibility:
/// it still shows the running apps, each with its badge as `AXStatusLabel`. Without the permission, no badges.
final class BarBadges {
    static let shared = BarBadges()
    static let didChange = Notification.Name("DockBadgesDidChange")

    /// By the app bundle's standardized path.
    private(set) var labels: [String: String] = [:]
    private var timer: Timer?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            timer?.invalidate()
            timer = nil
            if isEnabled {
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
                refresh()
            } else if !labels.isEmpty {
                labels = [:]
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    func label(for appURL: URL) -> String? {
        labels[appURL.standardizedFileURL.path]
    }

    private func refresh() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var found: [String: String] = [:]
        for list in AX.children(of: app) where AX.string(list, kAXRoleAttribute) == kAXListRole {
            for item in AX.children(of: list) {
                guard let label = AX.string(item, "AXStatusLabel"), !label.isEmpty,
                      let url = AX.url(item, kAXURLAttribute) else { continue }
                found[url.standardizedFileURL.path] = label
            }
        }
        guard found != labels else { return }
        labels = found
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// An app's windows, for its Dock menu: their titles, whether minimized, and bringing one forward.
struct AppWindow {
    let title: String
    let isMinimized: Bool
    fileprivate let element: AXUIElement?
    fileprivate let own: NSWindow?

    /// Explorer's own windows directly; another app's through Accessibility (none without the permission).
    static func windows(of app: NSRunningApplication) -> [AppWindow] {
        if app.processIdentifier == getpid() {
            return NSApp.windows.filter { window in
                (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled)
                    && !(window is NSPanel) && !window.title.isEmpty
            }.map { AppWindow(title: $0.title, isMinimized: $0.isMiniaturized, element: nil, own: $0) }
        }
        guard AXIsProcessTrusted() else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            guard AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  let title = AX.string(window, kAXTitleAttribute), !title.isEmpty else { return nil }
            return AppWindow(title: title, isMinimized: AX.bool(window, kAXMinimizedAttribute), element: window,
                             own: nil)
        }
    }

    func bringForward(of app: NSRunningApplication) {
        if let own {
            NSApp.activate(ignoringOtherApps: true)
            if own.isMiniaturized { own.deminiaturize(nil) }
            own.makeKeyAndOrderFront(nil)
            return
        }
        guard let element else { return }
        if isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
    }

    /// Whether the app shows any window on screen: from the window list, which needs no permission.
    static func hasWindowOnScreen(_ app: NSRunningApplication) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { info in
            info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
                && info[kCGWindowLayer as String] as? Int == 0
        }
    }
}

/// Small Accessibility readers.
enum AX {
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! CFURL) as URL
    }
}

/// Other apps opened at login ("Open at Login" in their Dock menu), kept by System Events through
/// Apple Events. The first change asks the user to let Explorer control System Events; until one has
/// worked, the list isn't read, so that merely opening a menu never asks.
enum LoginItems {
    private static let allowedKey = "BarLoginItemsAllowed"

    static func contains(_ app: URL) -> Bool {
        guard UserDefaults.standard.bool(forKey: allowedKey),
              let list = try? run("tell application \"System Events\" to get the path of every login item")
        else { return false }
        let path = app.standardizedFileURL.path
        let paths = (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.stringValue }
        return paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
    }

    static func set(_ app: URL, opensAtLogin: Bool) {
        let path = app.standardizedFileURL.path
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = opensAtLogin
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false}"
            : "tell application \"System Events\" to delete (every login item whose path is \"\(path)\")"
        do {
            _ = try run(script)
            UserDefaults.standard.set(true, forKey: allowedKey)
        } catch let error as NSError where error.code == -1743 {
            BarFiles.showError(T("Explorer isn't allowed to control System Events. Allow it in System Settings › Privacy & Security › Automation."))
        } catch {
            BarFiles.showError(error.localizedDescription)
        }
    }

    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
            throw NSError(domain: "LoginItems", code: (error?[NSAppleScript.errorNumber] as? Int) ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: (error?[NSAppleScript.errorMessage] as? String)
                              ?? "System Events didn't answer."])
        }
        return result
    }
}

/// "Show All Windows": the app's windows side by side, as Mission Control's App Exposé shows them.
enum AppExpose {
    static func show(_ app: NSRunningApplication) {
        app.activate(options: [])
        // Once the app is in front, App Exposé shows its windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !postShortcut() { launchMissionControl() }
        }
    }

    /// The App Exposé shortcut set in System Settings › Keyboard › Shortcuts (⌃↓ by default), when one
    /// is on and Explorer may post keys.
    private static func postShortcut() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var keyCode: CGKeyCode = 125
        var flags: CGEventFlags = .maskControl
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        if let entry = hotkeys?["33"] as? [String: Any] {
            guard (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = (value["parameters"] as? [NSNumber])?.map(\.intValue), parameters.count == 3,
                  parameters[1] != 65535
            else { return false }
            keyCode = CGKeyCode(parameters[1])
            flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        }
        // Arrow keys come with these, as from a keyboard.
        if (123...126).contains(keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Mission Control opened on the app's windows.
    private static func launchMissionControl() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        process.arguments = ["2"]
        try? process.run()
    }
}
