import CoreGraphics
import DockGuard
import BarSettings
import BarSettings
import Foundation
import SuiteCore

// Explorer's own Dock: the model behind it, with no AppKit. The window lives in the app.

/// An application in the Dock, pinned or running.
public struct BarApp: Codable, Hashable, Sendable {
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
    public func isSameApp(as other: BarApp) -> Bool {
        if let mine = bundleID, let theirs = other.bundleID { return mine == theirs }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: other.path).standardizedFileURL.path
    }
}

/// Apps of the suite that are ordinary apps only for macOS's sake: never shown in the Dock, their windows
/// neither fitted nor watched. Bureau is one, as Finder is, so macOS picks it when an app quits instead
/// of switching Space.
public enum BarHiddenApps {
    public static let bundleIDs: Set<String> = ["local.suite.desktop"]

    public static func contains(_ bundleID: String?) -> Bool { bundleID.map(bundleIDs.contains) ?? false }
}

/// Reads the system Dock's pinned apps (`com.apple.dock` › `persistent-apps`), read only.
public enum DockReader {
    public static let domain = DockManager.dockDomain

    /// The apps the system Dock shows today, in its order.
    public static func currentApps() -> [BarApp] {
        guard let entries = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain as CFString) as? [Any]
        else { return [] }
        return apps(fromPersistentApps: entries)
    }

    /// The apps in a copy of the Dock's preferences file (`com.apple.dock.plist`, XML or binary).
    public static func apps(fromPlist data: Data) throws -> [BarApp] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let entries = (plist as? [String: Any])?["persistent-apps"] as? [Any] else { return [] }
        return apps(fromPersistentApps: entries)
    }

    /// Keeps the application tiles; spacers and anything without a file are left out.
    public static func apps(fromPersistentApps entries: [Any]) -> [BarApp] {
        entries.compactMap { entry in
            guard let tile = entry as? [String: Any],
                  (tile["tile-type"] as? String ?? "file-tile") == "file-tile",
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            let url = URL(string: string).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: string)
            let label = (data["file-label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return BarApp(url: url, bundleID: data["bundle-identifier"] as? String, name: label)
        }
    }
}

/// The pinned apps, in the order the user gave them.
public struct BarPins: Equatable {
    public private(set) var apps: [BarApp]

    public init(_ apps: [BarApp]) {
        var unique: [BarApp] = []
        for app in apps where !unique.contains(where: { $0.isSameApp(as: app) }) { unique.append(app) }
        self.apps = unique
    }

    public func index(of app: BarApp) -> Int? {
        apps.firstIndex { $0.isSameApp(as: app) }
    }

    public func contains(_ app: BarApp) -> Bool { index(of: app) != nil }

    /// Pins at the end, or at `index` (0...count); an app already pinned moves there instead.
    public mutating func pin(_ app: BarApp, at index: Int? = nil) {
        var target = index ?? apps.count
        if let current = self.index(of: app) {
            apps.remove(at: current)
            if index != nil, current < target { target -= 1 }
        }
        apps.insert(app, at: min(max(target, 0), apps.count))
    }

    public mutating func unpin(_ app: BarApp) {
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

/// Saves the pinned apps. Until the user changes them, they are the system Dock's, with Explorer first,
/// where the system Dock has Finder; Explorer can then be unpinned and moved like any app.
public final class BarStore {
    public static let shared = BarStore()
    public static let didChange = Notification.Name("BarStoreDidChange")
    private static let key = "BarPinnedApps"
    /// Set once the saved list says itself whether Explorer is pinned: before, Explorer was always first
    /// and never saved.
    private static let holdsExplorerKey = "BarPinsHoldExplorer"
    public static let explorerBundleID = "local.suite.explorer"
    /// Finder never shows in our Dock: Explorer takes its place.
    public static let excludedBundleIDs: Set<String> = ["com.apple.finder"]

    private let defaults: UserDefaults
    private let systemApps: () -> [BarApp]
    /// Explorer itself, pinned first until the user says otherwise.
    public let explorer: BarApp?

    public init(defaults: UserDefaults = BarSettings.defaults,
                systemApps: @escaping () -> [BarApp] = DockReader.currentApps,
                explorer: BarApp? = BarApp(url: Bundle.main.bundleURL, bundleID: BarStore.explorerBundleID,
                                             name: "Explorer")) {
        self.defaults = defaults
        self.systemApps = systemApps
        self.explorer = explorer
    }

    public var pins: BarPins {
        get {
            var apps: [BarApp]
            if let data = defaults.data(forKey: Self.key),
               let saved = try? JSONDecoder().decode([BarApp].self, from: data) {
                apps = saved
            } else {
                apps = systemApps()
            }
            apps = apps.filter { !Self.isExcluded($0) }
            if let explorer, !defaults.bool(forKey: Self.holdsExplorerKey),
               !apps.contains(where: { $0.isSameApp(as: explorer) }) {
                apps.insert(explorer, at: 0)
            }
            return BarPins(apps)
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue.apps), forKey: Self.key)
            defaults.set(true, forKey: Self.holdsExplorerKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    public static func isExplorer(_ app: BarApp) -> Bool { app.bundleID == explorerBundleID }

    public static func isExcluded(_ app: BarApp) -> Bool {
        app.bundleID.map(excludedBundleIDs.contains) ?? false
    }

    public func isPinned(_ app: BarApp) -> Bool { pins.contains(app) }

    public func pin(_ app: BarApp, at index: Int? = nil) {
        guard !Self.isExcluded(app) else { return }
        var pins = self.pins
        pins.pin(app, at: index)
        self.pins = pins
    }

    public func unpin(_ app: BarApp) {
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
public struct BarWindow: Hashable {
    /// Ours, given when the window is first seen minimized.
    public let id: Int
    public var title: String
    public var app: BarApp

    public init(id: Int, title: String, app: BarApp) {
        self.id = id
        self.title = title
        self.app = app
    }
}

/// One place in the Dock, left to right.
public enum BarTile: Hashable {
    case app(BarApp, isPinned: Bool, isRunning: Bool)
    case separator
    /// A folder or file kept in the Dock (Downloads by default).
    case item(BarItem)
    case window(BarWindow)
    case trash

    public var app: BarApp? {
        if case .app(let app, _, _) = self { return app }
        return nil
    }
}

public enum BarLayout {
    /// The pinned apps (Explorer first by default), then the running apps that aren't pinned (with the
    /// recently used ones after a separator when `recents` are shown, as the system Dock does), then a
    /// separator, the folders and files, the minimized windows and the Trash. Finder never appears.
    /// `explorer`, the app drawing the Dock, always counts as running.
    public static func tiles(pinned: [BarApp], running: [BarApp], minimized: [BarWindow] = [],
                             items: [BarItem] = [], recents: [BarApp]? = nil,
                             explorer: BarApp? = nil) -> [BarTile] {
        var running = running
        if let explorer, !running.contains(where: { $0.isSameApp(as: explorer) }) {
            running.insert(explorer, at: 0)
        }
        let pinned = BarPins(pinned.filter { !BarStore.isExcluded($0) }).apps
        let others = BarPins(running.filter { app in
            !BarStore.isExcluded(app) && !pinned.contains { $0.isSameApp(as: app) }
        }).apps
        var tiles: [BarTile] = pinned.map { app in
            .app(app, isPinned: true, isRunning: running.contains { $0.isSameApp(as: app) })
        }
        if let recents {
            let quit = BarPins(recents.filter { app in
                !BarStore.isExcluded(app) && !pinned.contains { $0.isSameApp(as: app) }
                    && !others.contains { $0.isSameApp(as: app) }
            }).apps
            if !others.isEmpty || !quit.isEmpty {
                tiles.append(.separator)
                tiles += others.map { .app($0, isPinned: false, isRunning: true) }
                tiles += quit.map { .app($0, isPinned: false, isRunning: false) }
            }
        } else {
            tiles += others.map { .app($0, isPinned: false, isRunning: true) }
        }
        tiles.append(.separator)
        tiles += items.map { .item($0) }
        tiles += minimized.map { .window($0) }
        tiles.append(.trash)
        return tiles
    }
}

/// Where the tiles go in the Dock's bar, whose origin is its bottom left corner.
public struct BarGeometry: Equatable {
    public static let sizes = BarSettings.iconSizes

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

    public func frames(for tiles: [BarTile], magnification: BarMagnification? = nil) -> [CGRect] {
        var x = margin
        let rest = tiles.map { tile in
            let width = tile == .separator ? separatorWidth : tileWidth
            defer { x += width }
            return CGRect(x: x, y: 0, width: width, height: barHeight)
        }
        guard let magnification, magnification.amount > 0, magnification.size > iconSize else { return rest }
        return magnified(rest, tiles: tiles, by: magnification)
    }

    /// Tiles near the pointer grow, the nearest most, pushing the others aside; the point under the
    /// pointer stays under it, as in the system Dock.
    private func magnified(_ rest: [CGRect], tiles: [BarTile], by magnification: BarMagnification) -> [CGRect] {
        let reach = BarMagnification.reach * tileWidth
        let growth = (magnification.size / iconSize - 1) * magnification.amount
        let scales = rest.map { frame -> CGFloat in
            let distance = abs(frame.midX - magnification.pointer) / reach
            return distance < 1 ? 1 + growth * (cos(distance * .pi) + 1) / 2 : 1
        }
        var x = margin
        var frames = zip(rest, scales).map { frame, scale -> CGRect in
            defer { x += frame.width * scale }
            return CGRect(x: x, y: 0, width: frame.width * scale, height: barHeight + iconSize * (scale - 1))
        }
        // The tile under the pointer (or the nearest end) keeps the pointer at the same place in it.
        let pointer = magnification.pointer
        let anchor = rest.lastIndex { $0.minX <= pointer } ?? 0
        let fraction = min(max((pointer - rest[anchor].minX) / rest[anchor].width, 0), 1)
        let shift = (rest[anchor].minX + fraction * rest[anchor].width)
            - (frames[anchor].minX + fraction * frames[anchor].width)
        for index in frames.indices { frames[index].origin.x += shift }
        return frames
    }

    public func barSize(for tiles: [BarTile]) -> CGSize {
        let last = frames(for: tiles).last?.maxX ?? margin
        return CGSize(width: last + margin, height: barHeight)
    }

    /// How far magnified icons can push the bar's ends out, on either side.
    public func magnificationReach(size: CGFloat) -> CGFloat {
        guard size > iconSize else { return 0 }
        return ((size / iconSize - 1) * BarMagnification.reach * tileWidth).rounded(.up)
    }

    /// The icon's square inside its tile, magnified with it.
    public func iconFrame(in tile: CGRect) -> CGRect {
        let side = tile.width * iconSize / tileWidth
        return CGRect(x: tile.midX - side / 2, y: dotArea + tilePadding, width: side, height: side)
    }

    /// The tile under `point`, separators excluded.
    public func tileIndex(at point: CGPoint, tiles: [BarTile]) -> Int? {
        let frames = frames(for: tiles)
        return frames.indices.first { frames[$0].contains(point) && tiles[$0] != .separator }
    }

    /// Where an app dropped at `x` joins the pinned apps: the number of pinned icons left of it.
    /// `pinnedFrames` are the pinned tiles' frames, in order.
    public static func insertionIndex(forX x: CGFloat, pinnedFrames: [CGRect]) -> Int {
        pinnedFrames.filter { $0.midX < x }.count
    }
}

/// Icons growing under the pointer.
public struct BarMagnification: Equatable {
    /// The size the icon right under the pointer reaches.
    public var size: CGFloat
    /// The pointer along the bar, in the bar's coordinates.
    public var pointer: CGFloat
    /// From 0 (at rest) to 1 (fully grown), for growing and shrinking smoothly.
    public var amount: CGFloat

    /// How many tiles away from the pointer icons still grow.
    public static let reach: CGFloat = 3

    public init(size: CGFloat, pointer: CGFloat, amount: CGFloat = 1) {
        self.size = size
        self.pointer = pointer
        self.amount = min(max(amount, 0), 1)
    }
}

extension BarSettings {
    public var geometry: BarGeometry { BarGeometry(iconSize: iconSize) }
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
        fitted(window, screen: screen, edge: .bottom, reserved: reserved, visible: CGRect(
            x: screen.minX, y: screen.minY, width: screen.width, height: visibleTop - screen.minY),
               onlyIfFilling: onlyIfFilling, minimumLength: minimumHeight)
    }

    /// The same for a Dock on any side: a window reaching into the Dock's strip along `edge` ends before
    /// it. `visible` is the screen's usable area, by which a maximized window is told: one filling it
    /// across the Dock's strip.
    public static func fitted(_ window: CGRect, screen: CGRect, edge: ScreenEdge, reserved: CGFloat,
                              visible: CGRect, onlyIfFilling: Bool = false,
                              minimumLength: CGFloat = 120) -> CGRect? {
        // On this screen (at the bottom, a window may reach below it).
        let middle = edge == .bottom
            ? CGPoint(x: window.midX, y: min(max(window.midY, screen.minY), screen.maxY - 1))
            : CGPoint(x: window.midX, y: window.midY)
        guard reserved > 0, screen.contains(middle) else { return nil }
        switch edge {
        case .bottom:
            let limit = screen.minY + reserved
            // A window pushed past the screen's edge was moved there by the user.
            guard window.minY < limit - 0.5, window.minY >= screen.minY - 1, window.maxY - limit >= minimumLength
            else { return nil }
            if onlyIfFilling, window.maxY < visible.maxY - 2 { return nil }
            return CGRect(x: window.minX, y: limit, width: window.width, height: window.maxY - limit)
        case .left:
            let limit = screen.minX + reserved
            guard window.minX < limit - 0.5, window.minX >= screen.minX - 1, window.maxX - limit >= minimumLength
            else { return nil }
            if onlyIfFilling, window.maxX < visible.maxX - 2 { return nil }
            return CGRect(x: limit, y: window.minY, width: window.maxX - limit, height: window.height)
        case .right:
            let limit = screen.maxX - reserved
            guard window.maxX > limit + 0.5, window.maxX <= screen.maxX + 1, limit - window.minX >= minimumLength
            else { return nil }
            if onlyIfFilling, window.minX > visible.minX + 2 { return nil }
            return CGRect(x: window.minX, y: window.minY, width: limit - window.minX, height: window.height)
        }
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
public enum DockSpan {
    /// The smallest icons the system Dock shows when it does come up: its preferences take 1 point
    /// (how Bar hides it), but over a full-screen app it comes up at System Settings' smallest size, 16
    /// points, much longer along the edge.
    public static let smallestShownTile: CGFloat = 16

    /// `itemCount` counts every tile: Finder, apps, folders, the Trash. The range runs along the edge:
    /// x for the bottom, y for the sides.
    public static func estimate(itemCount: Int, tileSize: CGFloat, screen: CGRect,
                                edge: ScreenEdge = .bottom) -> ClosedRange<CGFloat> {
        // Each tile is a little longer than its icon, then two separators and the ends: with one-point
        // icons and five tiles that is 32 points, against 26 on a screenshot of the user's.
        let length = CGFloat(itemCount) * (tileSize * 1.2 + 3) + 2 * (tileSize * 0.3 + 3) + 2 * (tileSize * 0.2 + 2)
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
public enum BarStackOrder {
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

// MARK: Full screen

/// A full-screen Space in front, noticed from the windows on screen: the app in front has a normal window
/// (layer 0) covering the whole screen, menu bar included, which only full screen allows. There the
/// system Dock hides and slides in at the bottom edge, and so does ours.
/// The apps the Dock asked to quit: one still running after that is offered Force Quit in place of Quit
/// (as is any app while Option is held, as in the system Dock).
public struct QuitRequests: Equatable, Sendable {
    private var asked: Set<Int32> = []

    public init() {}

    public mutating func asked(_ pid: Int32) { asked.insert(pid) }

    /// Forgets the apps that have quit, whose process numbers may be given to others.
    public mutating func keep(running pids: Set<Int32>) { asked.formIntersection(pids) }

    public func offersForceQuit(_ pid: Int32, optionHeld: Bool = false) -> Bool {
        optionHeld || asked.contains(pid)
    }
}

public enum FullScreenSpace {
    public struct Window: Equatable {
        public let ownerPID: Int32
        public let layer: Int
        /// In window-server coordinates: origin at the top left of the main screen.
        public let bounds: CGRect

        public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// `screen`: the main screen's size; `frontmost`: the process of the app in front.
    public static func isActive(windows: [Window], screen: CGSize, frontmost: Int32?) -> Bool {
        guard let frontmost else { return false }
        return windows.contains { window in
            window.ownerPID == frontmost && window.layer == 0
                && abs(window.bounds.minX) <= 1 && abs(window.bounds.minY) <= 1
                && window.bounds.width >= screen.width - 1 && window.bounds.height >= screen.height - 1
        }
    }
}

// MARK: Mission Control

/// Mission Control, noticed from the windows on screen: while it is open, macOS's WindowManager shows its
/// Spaces bar (a strip as wide as the screen at the top, layer 14) and a shield over the whole screen
/// (layer 19). Seen on macOS 27 with the user; no public notification exists.
public enum MissionControl {
    public static let windowManager = "com.apple.WindowManager"

    public struct Window: Equatable {
        public let owner: String
        public let layer: Int
        public let size: CGSize

        public init(owner: String, layer: Int, size: CGSize) {
            self.owner = owner
            self.layer = layer
            self.size = size
        }
    }

    /// `owner` is the bundle identifier of each window's app.
    public static func isOpen(windows: [Window], screen: CGSize) -> Bool {
        windows.contains { window in
            guard window.owner == windowManager else { return false }
            let spacesBar = window.layer == 14 && window.size.width >= screen.width - 1
                && window.size.height < screen.height / 2
            let shield = window.layer == 19 && window.size.width >= screen.width - 1
                && window.size.height >= screen.height - 1
            return spacesBar || shield
        }
    }
}
