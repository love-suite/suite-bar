import Foundation

// ⌘Tab without the system Dock: the order of the apps and the selection, with no AppKit.

/// Apps in the order they were last used, most recent first, as ⌘Tab lists them.
public struct RecentApps: Equatable {
    public private(set) var order: [Int32] = []

    public init(_ order: [Int32] = []) { self.order = order }

    /// `pid` came to the front.
    public mutating func activated(_ pid: Int32) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    public mutating func terminated(_ pid: Int32) {
        order.removeAll { $0 == pid }
    }

    /// The running apps, most recent first; apps never seen in front follow, in the order given.
    public func ordered(_ running: [Int32]) -> [Int32] {
        let known = order.filter(running.contains)
        return known + running.filter { !known.contains($0) }
    }
}

/// The switcher on screen: the apps it shows and the one ⌘ will go to when it is let go.
public struct AppSwitcherState: Equatable {
    public let apps: [Int32]
    public private(set) var selection: Int

    /// Opens on the app used before the one in front (or the last one, going backwards), as ⌘Tab does.
    public init(apps: [Int32], backwards: Bool = false) {
        self.apps = apps
        selection = apps.count > 1 ? (backwards ? apps.count - 1 : 1) : 0
    }

    public var selected: Int32? { apps.indices.contains(selection) ? apps[selection] : nil }

    public mutating func next() { move(by: 1) }
    public mutating func previous() { move(by: -1) }

    public mutating func select(_ index: Int) {
        if apps.indices.contains(index) { selection = index }
    }

    private mutating func move(by step: Int) {
        guard !apps.isEmpty else { return }
        selection = ((selection + step) % apps.count + apps.count) % apps.count
    }
}

/// What a key does while ⌘ is held. Key codes are positions on the keyboard, the same in every layout.
public enum AppSwitcherKey: Equatable {
    case next, previous, cancel, ignore

    public static let tab: UInt16 = 48
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    /// The key left of 1 (` on US keyboards): ⌘⇧ with it goes backwards, as on macOS.
    public static let grave: UInt16 = 50

    public init(keyCode: UInt16, shift: Bool) {
        switch keyCode {
        case Self.tab: self = shift ? .previous : .next
        case Self.grave: self = .previous
        case Self.rightArrow: self = .next
        case Self.leftArrow: self = .previous
        case Self.escape: self = .cancel
        default: self = .ignore
        }
    }
}
