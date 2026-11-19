import CoreGraphics
import Foundation

// Explorer's own Dock: the model behind it, with no AppKit. The window lives in the app.

/// An application in the Dock, pinned or running.
public struct DockApp: Codable, Hashable, Sendable {
    public var bundleID: String?
    /// The application bundle's path, used when the bundle identifier can't find it.
    public var path: String
    public var name: String

    public init(bundleID: String?, path: String, name: String) {
        self.bundleID = bundleID
        self.path = path
        self.name = name
    }

    public init(url: URL, bundleID: String?, name: String? = nil) {
        self.init(bundleID: bundleID, path: url.standardizedFileURL.path,
                  name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Same application: the same bundle identifier when both have one, otherwise the same bundle.
    public func isSameApp(as other: DockApp) -> Bool {
        if let mine = bundleID, let theirs = other.bundleID { return mine == theirs }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: other.path).standardizedFileURL.path
    }
}

/// Reads the system Dock's pinned apps (`com.apple.dock` › `persistent-apps`), read only.
public enum SystemDockReader {
    public static let domain = "com.apple.dock"

    /// The apps the system Dock shows today, in its order.
    public static func currentApps() -> [DockApp] {
        guard let entries = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain as CFString) as? [Any]
        else { return [] }
        return apps(fromPersistentApps: entries)
    }

    /// The apps in a copy of the Dock's preferences file (`com.apple.dock.plist`, XML or binary).
    public static func apps(fromPlist data: Data) throws -> [DockApp] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let entries = (plist as? [String: Any])?["persistent-apps"] as? [Any] else { return [] }
        return apps(fromPersistentApps: entries)
    }

    /// Keeps the application tiles; spacers and anything without a file are left out.
    public static func apps(fromPersistentApps entries: [Any]) -> [DockApp] {
        entries.compactMap { entry in
            guard let tile = entry as? [String: Any],
                  (tile["tile-type"] as? String ?? "file-tile") == "file-tile",
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            let url = URL(string: string).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: string)
            let label = (data["file-label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DockApp(url: url, bundleID: data["bundle-identifier"] as? String, name: label)
        }
    }
}

/// The pinned apps, in the order the user gave them.
public struct DockPins: Equatable {
    public private(set) var apps: [DockApp]

    public init(_ apps: [DockApp]) {
        var unique: [DockApp] = []
        for app in apps where !unique.contains(where: { $0.isSameApp(as: app) }) { unique.append(app) }
        self.apps = unique
    }

    public func index(of app: DockApp) -> Int? {
        apps.firstIndex { $0.isSameApp(as: app) }
    }

    public func contains(_ app: DockApp) -> Bool { index(of: app) != nil }

    /// Pins at the end, or at `index` (0...count); an app already pinned moves there instead.
    public mutating func pin(_ app: DockApp, at index: Int? = nil) {
        var target = index ?? apps.count
        if let current = self.index(of: app) {
            apps.remove(at: current)
            if index != nil, current < target { target -= 1 }
        }
        apps.insert(app, at: min(max(target, 0), apps.count))
    }

    public mutating func unpin(_ app: DockApp) {
        apps.removeAll { $0.isSameApp(as: app) }
    }

    /// Moves the app at `source` so that it lands before the app that was at `destination`
    /// (`destination` may be `count`: the end), as when dropping between two icons.
    public mutating func move(from source: Int, to destination: Int) {
        guard apps.indices.contains(source) else { return }
        let app = apps.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        apps.insert(app, at: min(max(target, 0), apps.count))
    }
}

/// Saves the pinned apps. Until the user changes them, they are the system Dock's.
public final class DockStore {
    public static let shared = DockStore()
    public static let didChange = Notification.Name("DockStoreDidChange")
    private static let key = "DockPinnedApps"
    /// Finder never shows in our Dock, and Explorer has its own fixed place, first.
    public static let excludedBundleIDs: Set<String> = ["com.apple.finder", "local.explorer.Explorer"]

    private let defaults: UserDefaults
    private let systemApps: () -> [DockApp]

    public init(defaults: UserDefaults = .standard, systemApps: @escaping () -> [DockApp] = SystemDockReader.currentApps) {
        self.defaults = defaults
        self.systemApps = systemApps
    }

    public var pins: DockPins {
        get {
            if let data = defaults.data(forKey: Self.key),
               let apps = try? JSONDecoder().decode([DockApp].self, from: data) {
                return DockPins(apps)
            }
            return DockPins(systemApps().filter { !Self.isExcluded($0) })
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue.apps), forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    public static func isExcluded(_ app: DockApp) -> Bool {
        app.bundleID.map(excludedBundleIDs.contains) ?? false
    }

    public func isPinned(_ app: DockApp) -> Bool { pins.contains(app) }

    public func pin(_ app: DockApp, at index: Int? = nil) {
        guard !Self.isExcluded(app) else { return }
        var pins = self.pins
        pins.pin(app, at: index)
        self.pins = pins
    }

    public func unpin(_ app: DockApp) {
        var pins = self.pins
        pins.unpin(app)
        self.pins = pins
    }

    public func move(from source: Int, to destination: Int) {
        var pins = self.pins
        pins.move(from: source, to: destination)
        self.pins = pins
    }
}

/// One place in the Dock, left to right.
public enum DockTile: Hashable {
    /// Explorer, always first, where the system Dock has Finder.
    case explorer
    case app(DockApp, isPinned: Bool, isRunning: Bool)
    case separator
    case downloads
    case trash

    public var app: DockApp? {
        if case .app(let app, _, _) = self { return app }
        return nil
    }
}

public enum DockLayout {
    /// Explorer, the pinned apps, a separator and the running apps that aren't pinned, then a separator,
    /// Downloads and the Trash. Finder never appears.
    public static func tiles(pinned: [DockApp], running: [DockApp]) -> [DockTile] {
        let pinned = DockPins(pinned.filter { !DockStore.isExcluded($0) }).apps
        let others = DockPins(running.filter { app in
            !DockStore.isExcluded(app) && !pinned.contains { $0.isSameApp(as: app) }
        }).apps
        var tiles: [DockTile] = [.explorer]
        tiles += pinned.map { app in
            .app(app, isPinned: true, isRunning: running.contains { $0.isSameApp(as: app) })
        }
        if !others.isEmpty {
            tiles.append(.separator)
            tiles += others.map { .app($0, isPinned: false, isRunning: true) }
        }
        tiles += [.separator, .downloads, .trash]
        return tiles
    }
}

/// Where the tiles go in the Dock's bar, whose origin is its bottom left corner.
public struct DockGeometry: Equatable {
    public static let sizes: ClosedRange<CGFloat> = 32...96

    public let iconSize: CGFloat

    public init(iconSize: CGFloat) {
        self.iconSize = min(max(iconSize, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    /// Room around each icon.
    public var tilePadding: CGFloat { (iconSize * 0.08).rounded() }
    public var tileWidth: CGFloat { iconSize + 2 * tilePadding }
    public var separatorWidth: CGFloat { (iconSize * 0.4).rounded() }
    /// Space on each end of the bar.
    public var margin: CGFloat { (iconSize * 0.12).rounded() }
    /// Below the icons: the running dot.
    public var dotArea: CGFloat { max(6, (iconSize * 0.16).rounded()) }
    public var barHeight: CGFloat { iconSize + dotArea + 2 * tilePadding }

    public func frames(for tiles: [DockTile]) -> [CGRect] {
        var x = margin
        return tiles.map { tile in
            let width = tile == .separator ? separatorWidth : tileWidth
            defer { x += width }
            return CGRect(x: x, y: 0, width: width, height: barHeight)
        }
    }

    public func barSize(for tiles: [DockTile]) -> CGSize {
        let last = frames(for: tiles).last?.maxX ?? margin
        return CGSize(width: last + margin, height: barHeight)
    }

    /// The icon's square inside its tile.
    public func iconFrame(in tile: CGRect) -> CGRect {
        CGRect(x: tile.midX - iconSize / 2, y: dotArea + tilePadding, width: iconSize, height: iconSize)
    }

    /// The tile under `point`, separators excluded.
    public func tileIndex(at point: CGPoint, tiles: [DockTile]) -> Int? {
        let frames = frames(for: tiles)
        return frames.indices.first { frames[$0].contains(point) && tiles[$0] != .separator }
    }

    /// Where an app dropped at `x` joins the pinned apps: the number of pinned icons left of it.
    /// `pinnedFrames` are the pinned tiles' frames, in order.
    public static func insertionIndex(forX x: CGFloat, pinnedFrames: [CGRect]) -> Int {
        pinnedFrames.filter { $0.midX < x }.count
    }
}

/// The Dock's options, saved by the app.
public struct DockOptions: Codable, Equatable {
    /// Explorer's Dock at the bottom of the main screen.
    public var isShown = false
    public var iconSize: CGFloat = 48
    /// The system Dock hidden while ours is shown, so Finder's icon is out of sight.
    public var hidesSystemDock = true

    public init() {}

    public var geometry: DockGeometry { DockGeometry(iconSize: iconSize) }
}

/// Orders a stack's items as the Dock does: the most recently added first.
public enum DockStackOrder {
    public static func sorted(_ items: [(url: URL, added: Date?)]) -> [URL] {
        items.sorted { a, b in
            switch (a.added, b.added) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }.map(\.url)
    }

    /// The folder's visible items, newest first.
    public static func contents(of folder: URL, fileManager: FileManager = .default) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return sorted(urls.map { url in
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return (url, values?.addedToDirectoryDate ?? values?.creationDate)
        })
    }
}

// MARK: Hiding the system Dock

/// A preferences domain, such as `com.apple.dock`. Tests use a dictionary instead of the real Dock.
public protocol PreferenceDomain: AnyObject {
    func value(forKey key: String) -> Any?
    /// `nil` removes the key.
    func setValue(_ value: Any?, forKey key: String)
}

/// Another app's preferences, through the public CFPreferences calls `defaults` uses.
public final class AppPreferenceDomain: PreferenceDomain {
    public let identifier: String

    public init(_ identifier: String) { self.identifier = identifier }

    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, identifier as CFString)
    }

    public func setValue(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value.map { $0 as AnyObject }, identifier as CFString)
        CFPreferencesAppSynchronize(identifier as CFString)
    }
}

/// Hides the system Dock with public settings only: automatic hiding with a delay so long it never
/// comes back, then a Dock restart. The values found before are kept in our own preferences, so they
/// can be put back even after a crash.
public final class SystemDockHider {
    public static let autohideKey = "autohide"
    public static let delayKey = "autohide-delay"
    /// Seconds before the hidden Dock would show: longer than anyone hovers.
    public static let hiddenDelay: Double = 1000
    private static let savedKey = "SystemDockSettingsBeforeHiding"

    private let dock: PreferenceDomain
    private let memory: UserDefaults
    private let restartDock: () -> Void

    public init(dock: PreferenceDomain = AppPreferenceDomain(SystemDockReader.domain),
                memory: UserDefaults = .standard, restartDock: @escaping () -> Void) {
        self.dock = dock
        self.memory = memory
        self.restartDock = restartDock
    }

    /// True while the system Dock is hidden by us (and its previous settings are kept).
    public var isHiding: Bool { memory.dictionary(forKey: Self.savedKey) != nil }

    private var isHiddenNow: Bool {
        (dock.value(forKey: Self.autohideKey) as? Bool) == true
            && (dock.value(forKey: Self.delayKey) as? NSNumber)?.doubleValue == Self.hiddenDelay
    }

    /// Hides the system Dock; does nothing (no restart) if it already is.
    public func hide() {
        if !isHiding {
            var saved: [String: Any] = [:]
            for key in [Self.autohideKey, Self.delayKey] {
                if let value = dock.value(forKey: key) { saved[key] = value }
            }
            memory.set(saved, forKey: Self.savedKey)
        }
        guard !isHiddenNow else { return }
        dock.setValue(true, forKey: Self.autohideKey)
        dock.setValue(Self.hiddenDelay, forKey: Self.delayKey)
        restartDock()
    }

    /// Puts back the settings found before hiding; does nothing if we didn't hide it.
    public func restore() {
        guard let saved = memory.dictionary(forKey: Self.savedKey) else { return }
        for key in [Self.autohideKey, Self.delayKey] {
            dock.setValue(saved[key], forKey: key)
        }
        memory.removeObject(forKey: Self.savedKey)
        restartDock()
    }
}
