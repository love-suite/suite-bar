import Foundation

/// What Suite Settings and Bar.app say to each other, as distributed notifications.
public enum BarMessage: String, CaseIterable, Sendable {
    /// To the Dock: settings were written (the Dock tab, a profile); read them again.
    case applySettings
    /// To the Dock: ask for Accessibility, which fitting windows above the Dock and minimized windows need.
    case allowWindowFitting
    /// To the Dock: write down its status (`StatusKey`) and say so.
    case reportStatus
    /// To Suite Settings: the Dock's status changed.
    case statusDidChange
    /// To Suite Settings: show the Dock tab.
    case showSettings

    public var name: Notification.Name { Notification.Name("local.suite.bar." + rawValue) }

    /// Delivered at once, even to an app in the background, which both often are.
    public func post(_ userInfo: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: userInfo,
                                                                     deliverImmediately: true)
    }

    @discardableResult
    public func observe(_ handler: @escaping (Notification) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main, using: handler)
    }

    /// What the Dock writes in its defaults for the Dock tab to show.
    public enum StatusKey {
        public static let windowFittingAllowed = "StatusWindowFittingAllowed"
    }

    /// Whether the Dock may fit other apps' windows above it (Accessibility), as it last said.
    public static var windowFittingAllowed: Bool {
        CFPreferencesAppSynchronize(BarSettings.domain as CFString)
        return BarSettings.defaults.bool(forKey: StatusKey.windowFittingAllowed)
    }
}
