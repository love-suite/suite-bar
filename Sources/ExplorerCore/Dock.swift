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

/// A minimized window, shown in the Dock until it is brought back.
public struct DockWindow: Hashable {
    /// Ours, given when the window is first seen minimized.
    public let id: Int
    public var title: String
    public var app: DockApp

    public init(id: Int, title: String, app: DockApp) {
        self.id = id
        self.title = title
        self.app = app
    }
}

/// One place in the Dock, left to right.
public enum DockTile: Hashable {
    /// Explorer, always first, where the system Dock has Finder.
    case explorer
    case app(DockApp, isPinned: Bool, isRunning: Bool)
    case separator
    case downloads
    case window(DockWindow)
    case trash

    public var app: DockApp? {
        if case .app(let app, _, _) = self { return app }
        return nil
    }
}

public enum DockLayout {
    /// Explorer, the pinned apps, a separator and the running apps that aren't pinned, then a separator,
    /// Downloads, the minimized windows and the Trash. Finder never appears.
    public static func tiles(pinned: [DockApp], running: [DockApp], minimized: [DockWindow] = []) -> [DockTile] {
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
        tiles += [.separator, .downloads]
        tiles += minimized.map { .window($0) }
        tiles.append(.trash)
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
    /// Explorer's Dock in place of the system one, which is then hidden (with Finder's icon in it).
    public var isShown = false
    public var iconSize: CGFloat = 48
    /// Slides away until the pointer reaches the bottom of the screen, as the system Dock can.
    public var autohides = false
    /// Experimental: the system Dock stopped altogether (⌘Tab, Mission Control, Spaces and full screen
    /// stop with it), rather than hidden.
    public var stopsSystemDock = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case isShown, iconSize, autohides, stopsSystemDock }

    /// Options saved by an older version, without the newer keys, keep what they had.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isShown = try values.decodeIfPresent(Bool.self, forKey: .isShown) ?? false
        iconSize = try values.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48
        autohides = try values.decodeIfPresent(Bool.self, forKey: .autohides) ?? false
        stopsSystemDock = try values.decodeIfPresent(Bool.self, forKey: .stopsSystemDock) ?? false
    }

    public var geometry: DockGeometry { DockGeometry(iconSize: iconSize) }
}

/// Keeps windows clear of the Dock, as macOS does for its own Dock: a window reaching into the Dock's
/// strip at the bottom of the screen is shortened to end above it. Frames are in screen coordinates,
/// origin bottom left.
public enum WindowFit {
    /// The frame `window` should take, or nil when it can stay as it is. `reserved` is the height kept
    /// for the Dock above `screen`'s bottom; `visibleTop` the top of the usable area (below the menu bar).
    /// With `onlyIfFilling`, only windows filling the height (maximized) change: a window the user moved
    /// down on purpose stays put.
    public static func fitted(_ window: CGRect, screen: CGRect, reserved: CGFloat, visibleTop: CGFloat,
                              onlyIfFilling: Bool = false, minimumHeight: CGFloat = 120) -> CGRect? {
        let limit = screen.minY + reserved
        guard reserved > 0,
              screen.contains(CGPoint(x: window.midX, y: min(max(window.midY, screen.minY), screen.maxY - 1))),
              window.minY < limit - 0.5,
              // A window pushed below the screen's edge was moved there by the user.
              window.minY >= screen.minY - 1,
              window.maxY - limit >= minimumHeight
        else { return nil }
        if onlyIfFilling, window.maxY < visibleTop - 2 { return nil }
        return CGRect(x: window.minX, y: limit, width: window.width, height: window.maxY - limit)
    }

    /// Converts between Accessibility's coordinates (origin top left of the main screen) and AppKit's.
    public static func flipped(_ rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A side of the screen, where the system Dock sits (its `orientation` setting).
public enum ScreenEdge: String, Equatable {
    case bottom, left, right
}

/// Keeps the pointer off the screen's outermost row or column of pixels where the hidden system Dock sits,
/// since that is where it wakes up. Points in screen coordinates, origin bottom left.
public enum EdgeGuard {
    /// How far from the edge the pointer is put back.
    public static let gap: CGFloat = 3

    /// Where the pointer goes instead of `point`, or nil when it can stay: away from the edge, outside the
    /// stretch `span` (along the edge) where the hidden system Dock wakes up, so it still slides along the
    /// rest of the edge and reaches the corners, or going on to another screen placed against that edge.
    public static func guarded(_ point: CGPoint, screen: CGRect, edge: ScreenEdge, span: ClosedRange<CGFloat>,
                               others: [CGRect]) -> CGPoint? {
        // AppKit puts the outermost row or column at the edge or a point in, depending on rounding.
        switch edge {
        case .bottom:
            guard span.contains(point.x), point.x >= screen.minX, point.x < screen.maxX,
                  point.y < screen.minY + 1.5, point.y >= screen.minY - 1 else { return nil }
            let beyond = others.contains {
                abs($0.maxY - screen.minY) <= 1 && point.x >= $0.minX && point.x < $0.maxX
            }
            return beyond ? nil : CGPoint(x: point.x, y: screen.minY + gap)
        case .left:
            guard span.contains(point.y), point.y >= screen.minY, point.y < screen.maxY,
                  point.x < screen.minX + 1.5, point.x >= screen.minX - 1 else { return nil }
            let beyond = others.contains {
                abs($0.maxX - screen.minX) <= 1 && point.y >= $0.minY && point.y < $0.maxY
            }
            return beyond ? nil : CGPoint(x: screen.minX + gap, y: point.y)
        case .right:
            guard span.contains(point.y), point.y >= screen.minY, point.y < screen.maxY,
                  point.x > screen.maxX - 2.5, point.x <= screen.maxX + 1 else { return nil }
            let beyond = others.contains {
                abs($0.minX - screen.maxX) <= 1 && point.y >= $0.minY && point.y < $0.maxY
            }
            return beyond ? nil : CGPoint(x: screen.maxX - 1 - gap, y: point.y)
        }
    }
}

/// Where the hidden system Dock sits along its edge, when Accessibility can't say: centred, as long as
/// its icons.
public enum SystemDockSpan {
    /// `itemCount` counts every tile: Finder, apps, folders, the Trash. The range runs along the edge:
    /// x for the bottom, y for the sides.
    public static func estimate(itemCount: Int, tileSize: CGFloat, screen: CGRect,
                                edge: ScreenEdge = .bottom) -> ClosedRange<CGFloat> {
        // Each tile is a little longer than its icon; two separators; generous ends.
        let length = CGFloat(itemCount) * (tileSize + 8) + 2 * 16 + 2 * 24
        let (middle, available) = edge == .bottom ? (screen.midX, screen.width) : (screen.midY, screen.height)
        let half = min(length, available) / 2
        return (middle - half)...(middle + half)
    }

    /// The tiles the system Dock shows, from its preferences: Finder and the Trash, then with `static-only`
    /// the running apps alone, otherwise pinned apps and folders, recent apps if shown and the running apps
    /// that aren't pinned. `running` counts the running apps, `unpinnedRunning` those not pinned.
    public static func itemCount(preferences: PreferenceDomain, running: Int, unpinnedRunning: Int) -> Int {
        if (preferences.value(forKey: "static-only") as? Bool) == true { return 2 + running }
        let pinned = (preferences.value(forKey: "persistent-apps") as? [Any])?.count ?? 0
        let others = (preferences.value(forKey: "persistent-others") as? [Any])?.count ?? 0
        let showsRecents = (preferences.value(forKey: "show-recents") as? Bool) ?? true
        let recents = showsRecents ? ((preferences.value(forKey: "recent-apps") as? [Any])?.count ?? 0) : 0
        return 2 + pinned + others + recents + unpinnedRunning
    }
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

/// Hides the system Dock with public settings only: automatic hiding with a delay so long it doesn't come
/// back, and an animation so slow that it wouldn't be seen if it did, then a Dock restart. The values
/// found before are kept in our own preferences, so they can be put back even after a crash.
public final class SystemDockHider {
    /// What the Dock is set to while hidden.
    public static let hiddenSettings: [(key: String, value: Any)] = [
        ("autohide", true),
        // Seconds before the hidden Dock would show: longer than anyone hovers.
        ("autohide-delay", 1000.0),
        // Seconds the sliding in would take, should the Dock still decide to show (pushing at the edge).
        ("autohide-time-modifier", 1000.0),
        // At the bottom, where windows minimize to (the animation follows the hidden Dock), with the
        // running apps only and icons of a single point (the preferences take 1, below System Settings'
        // 16: tested on macOS 27), so it is a sliver even in Mission Control and the stretch of the bottom
        // edge where it wakes up is as short as can be.
        ("tilesize", 1.0),
        ("orientation", "bottom"),
        ("static-only", true),
    ]
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
        Self.hiddenSettings.allSatisfy { key, value in
            (dock.value(forKey: key) as? NSObject)?.isEqual(value) == true
        }
    }

    /// Hides the system Dock; does nothing (no restart) if it already is.
    public func hide() {
        var saved = memory.dictionary(forKey: Self.savedKey) ?? [:]
        var missing = !isHiding
        // Each key saved is marked, so a key added by a later version is saved once, before it changes.
        // The first version saved two keys without marks.
        if isHiding, !saved.keys.contains(where: { $0.hasPrefix("~") }) {
            saved["~autohide"] = true
            saved["~autohide-delay"] = true
        }
        for (key, _) in Self.hiddenSettings where saved["~" + key] == nil {
            if let value = dock.value(forKey: key) { saved[key] = value }
            saved["~" + key] = true
            missing = true
        }
        if missing { memory.set(saved, forKey: Self.savedKey) }
        guard !isHiddenNow else { return }
        for (key, value) in Self.hiddenSettings { dock.setValue(value, forKey: key) }
        restartDock()
    }

    /// Puts back the settings found before hiding; does nothing if we didn't hide it.
    public func restore() {
        guard let saved = memory.dictionary(forKey: Self.savedKey) else { return }
        for (key, _) in Self.hiddenSettings {
            dock.setValue(saved[key], forKey: key)
        }
        memory.removeObject(forKey: Self.savedKey)
        restartDock()
    }
}

// MARK: Stopping the system Dock (experimental)

/// Stops and restarts the system Dock's launchd job for this login session only (`launchctl bootout`,
/// then `bootstrap` and `kickstart`): nothing is written to the system, and logging out brings it back
/// anyway. Remembered in our preferences, so a crash can be undone at the next launch.
public final class SystemDockAgent {
    public static let label = "com.apple.Dock.agent"
    public static let plist = "/System/Library/LaunchAgents/com.apple.Dock.plist"
    private static let stoppedKey = "SystemDockStopped"

    private let domain: String
    private let memory: UserDefaults
    private let isDockRunning: () -> Bool
    /// Runs `launchctl` with these arguments and returns its exit status.
    private let launchctl: ([String]) -> Int32

    public init(uid: uid_t = getuid(), memory: UserDefaults = .standard,
                isDockRunning: @escaping () -> Bool, launchctl: @escaping ([String]) -> Int32) {
        domain = "gui/\(uid)"
        self.memory = memory
        self.isDockRunning = isDockRunning
        self.launchctl = launchctl
    }

    /// True once we have stopped the Dock, until we start it again.
    public var isStopped: Bool { memory.bool(forKey: Self.stoppedKey) }

    /// Stops the Dock if it runs (after a log out it runs again, even if we had stopped it).
    public func stop() {
        if isDockRunning() {
            guard launchctl(["bootout", "\(domain)/\(Self.label)"]) == 0 else { return }
        }
        memory.set(true, forKey: Self.stoppedKey)
    }

    /// Starts the Dock again if we stopped it: loading the job doesn't start it, so it is kicked too.
    public func start() {
        guard isStopped else { return }
        if !isDockRunning() {
            _ = launchctl(["bootstrap", domain, Self.plist])
            _ = launchctl(["kickstart", "\(domain)/\(Self.label)"])
        }
        memory.removeObject(forKey: Self.stoppedKey)
    }
}
