import CoreGraphics
import Foundation
import BarSettings

// Folders and files kept on the Dock's right side (Downloads, by default), as the system Dock's
// `persistent-others`, with the options its right-click menu offers.

/// How a folder's items are ordered. Raw values are the system Dock's `arrangement`.
public enum BarStackSort: Int, Codable, CaseIterable, Sendable {
    case name = 1, dateAdded = 2, dateModified = 3, dateCreated = 4, kind = 5

    public var title: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .kind: return "Kind"
        }
    }
}

/// What the folder's Dock icon shows. Raw values are the system Dock's `displayas`.
public enum BarStackDisplay: Int, Codable, CaseIterable, Sendable {
    /// Its first items piled up.
    case stack = 0
    /// The folder's own icon.
    case folder = 1

    public var title: String { self == .stack ? "Stack" : "Folder" }
}

/// How the folder opens. Raw values are the system Dock's `showas`.
public enum BarStackView: Int, Codable, CaseIterable, Sendable {
    case automatic = 0, fan = 1, grid = 2, list = 3

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .fan: return "Fan"
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    /// The view actually used: Automatic is a fan when every item fits in one, a grid otherwise.
    public func resolved(itemCount: Int, fanCapacity: Int) -> BarStackView {
        self == .automatic ? (itemCount <= fanCapacity ? .fan : .grid) : self
    }

    /// The menu's order, as the system Dock lists them.
    public static let menuOrder: [BarStackView] = [.fan, .grid, .list, .automatic]
}

/// A folder or file kept in the Dock, right of the apps.
public struct BarItem: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var isFolder: Bool
    public var sort: BarStackSort
    public var display: BarStackDisplay
    public var view: BarStackView

    public init(path: String, name: String? = nil, isFolder: Bool, sort: BarStackSort = .dateAdded,
                display: BarStackDisplay = .stack, view: BarStackView = .automatic) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        self.path = url.path
        self.name = name ?? url.lastPathComponent
        self.isFolder = isFolder
        self.sort = sort
        self.display = display
        self.view = view
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }

    public func isSameItem(as other: BarItem) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: other.path).standardizedFileURL.path
    }

    /// The Downloads folder as the system Dock first shows it.
    public static func downloads(_ url: URL, name: String? = nil) -> BarItem {
        BarItem(path: url.path, name: name, isFolder: true, sort: .dateAdded, display: .stack, view: .automatic)
    }
}

extension DockReader {
    /// The folders and files the system Dock keeps right of its apps, in its order.
    public static func currentOthers() -> [BarItem]? {
        guard let entries = CFPreferencesCopyAppValue("persistent-others" as CFString, domain as CFString) as? [Any]
        else { return nil }
        return others(fromPersistentOthers: entries)
    }

    /// Folders (`directory-tile`) and files (`file-tile`); anything else (recent items, spacers) is left out.
    public static func others(fromPersistentOthers entries: [Any]) -> [BarItem] {
        entries.compactMap { entry in
            guard let tile = entry as? [String: Any],
                  let type = tile["tile-type"] as? String, type == "directory-tile" || type == "file-tile",
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            let url = URL(string: string).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: string)
            let label = (data["file-label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let isFolder = type == "directory-tile" || (data["file-type"] as? Int) == 2
            let int = { (key: String) in (data[key] as? NSNumber)?.intValue }
            return BarItem(path: url.path, name: label, isFolder: isFolder,
                            sort: int("arrangement").flatMap(BarStackSort.init(rawValue:)) ?? .dateAdded,
                            display: int("displayas").flatMap(BarStackDisplay.init(rawValue:)) ?? .stack,
                            view: int("showas").flatMap(BarStackView.init(rawValue:)) ?? .automatic)
        }
    }
}

/// The Dock's folders and files, saved. Until the user changes them, they are the system Dock's, or
/// Downloads when the system Dock has none to tell.
public final class BarItemStore {
    public static let shared = BarItemStore()
    public static let didChange = Notification.Name("DockItemStoreDidChange")
    private static let key = "BarOtherItems"

    private let defaults: UserDefaults
    private let systemItems: () -> [BarItem]?
    private let downloads: URL

    public init(defaults: UserDefaults = BarSettings.defaults,
                systemItems: @escaping () -> [BarItem]? = DockReader.currentOthers,
                downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) {
        self.defaults = defaults
        self.systemItems = systemItems
        self.downloads = downloads
    }

    public var items: [BarItem] {
        get {
            if let data = defaults.data(forKey: Self.key),
               let items = try? JSONDecoder().decode([BarItem].self, from: data) {
                return items
            }
            return systemItems() ?? [.downloads(downloads)]
        }
        set {
            var unique: [BarItem] = []
            for item in newValue where !unique.contains(where: { $0.isSameItem(as: item) }) { unique.append(item) }
            defaults.set(try? JSONEncoder().encode(unique), forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Adds at the end, or at `index`; an item already there moves instead.
    public func add(_ item: BarItem, at index: Int? = nil) {
        var items = self.items
        var target = index ?? items.count
        if let current = items.firstIndex(where: { $0.isSameItem(as: item) }) {
            items.remove(at: current)
            if index != nil, current < target { target -= 1 }
        }
        items.insert(item, at: min(max(target, 0), items.count))
        self.items = items
    }

    public func remove(_ item: BarItem) {
        items = items.filter { !$0.isSameItem(as: item) }
    }

    /// Saves a changed option (sort, display, view) of an item already there.
    public func update(_ item: BarItem) {
        items = items.map { $0.isSameItem(as: item) ? item : $0 }
    }
}

/// A stack's items with what sorting needs.
public struct BarStackEntry: Sendable {
    public var url: URL
    public var added: Date?
    public var modified: Date?
    public var created: Date?
    public var kind: String?

    public init(url: URL, added: Date? = nil, modified: Date? = nil, created: Date? = nil, kind: String? = nil) {
        self.url = url
        self.added = added
        self.modified = modified
        self.created = created
        self.kind = kind
    }
}

extension BarStackOrder {
    /// Ordered as the Dock does: dates newest first, names and kinds alphabetically, then by name.
    public static func sorted(_ entries: [BarStackEntry], by sort: BarStackSort) -> [URL] {
        func byName(_ a: BarStackEntry, _ b: BarStackEntry) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        func byDate(_ key: KeyPath<BarStackEntry, Date?>) -> (BarStackEntry, BarStackEntry) -> Bool {
            { a, b in
                switch (a[keyPath: key], b[keyPath: key]) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            }
        }
        let order: (BarStackEntry, BarStackEntry) -> Bool
        switch sort {
        case .name: order = byName
        case .dateAdded: order = byDate(\.added)
        case .dateModified: order = byDate(\.modified)
        case .dateCreated: order = byDate(\.created)
        case .kind:
            order = { a, b in
                let x = a.kind ?? "", y = b.kind ?? ""
                if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
                return byName(a, b)
            }
        }
        return entries.sorted(by: order).map(\.url)
    }

    /// The folder's visible items, in the item's order.
    public static func contents(of folder: URL, sortedBy sort: BarStackSort,
                                fileManager: FileManager = .default) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .creationDateKey,
                                      .localizedTypeDescriptionKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        return sorted(urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return BarStackEntry(url: url, added: values?.addedToDirectoryDate ?? values?.creationDate,
                                  modified: values?.contentModificationDate, created: values?.creationDate,
                                  kind: values?.localizedTypeDescription)
        }, by: sort)
    }
}

/// The fan a stack opens into: its items rising from the Dock icon in a curve bending right, the first
/// (newest) at the bottom, as the system Dock draws it.
public enum BarFan {
    public struct Place: Equatable {
        /// The item's icon centre, relative to the top centre of the Dock icon (y up).
        public var center: CGPoint
        /// Clockwise tilt, in degrees.
        public var angle: CGFloat
    }

    /// How many items fit between the Dock's top and the top of the screen.
    public static func capacity(height: CGFloat, step: CGFloat, maximum: Int = 15) -> Int {
        // One step is kept for the "Open in Explorer" button at the top.
        max(min(Int(height / step) - 1, maximum), 1)
    }

    /// Places for `count` items `step` points apart; the curve bends right by `bend` points at the top.
    public static func places(count: Int, step: CGFloat, bend: CGFloat = 60) -> [Place] {
        guard count > 0 else { return [] }
        let span = CGFloat(max(count, 6))
        return (0..<count).map { index in
            let t = CGFloat(index + 1) / span
            let x = bend * t * t
            // The slope of the curve, as a tilt.
            let slope = 2 * bend * t / (span * step)
            return Place(center: CGPoint(x: x, y: step * (CGFloat(index) + 0.5)),
                         angle: atan(slope) * 180 / .pi)
        }
    }
}

/// Apps recently used and not kept in the Dock, most recent first, as the system Dock's recent apps.
public struct BarRecents: Codable, Equatable {
    public static let limit = 3
    public private(set) var apps: [BarApp] = []

    public init(_ apps: [BarApp] = []) {
        self.apps = BarPins(apps).apps.prefix(Self.limit).map { $0 }
    }

    public mutating func used(_ app: BarApp) {
        // Explorer is always running, so never a recent app.
        guard !BarStore.isExcluded(app), !BarStore.isExplorer(app) else { return }
        apps.removeAll { $0.isSameApp(as: app) }
        apps.insert(app, at: 0)
        apps = Array(apps.prefix(Self.limit))
    }

    public mutating func forget(_ app: BarApp) {
        apps.removeAll { $0.isSameApp(as: app) }
    }
}
