import CoreGraphics
import Foundation

/// What the Dock does while an app is in full screen.
public enum BarFullScreenMode: String, Codable, CaseIterable, Sendable {
    /// Hides and slides in at the bottom edge, as the system Dock does.
    case hides
    /// Stays on screen, over the bottom of the app.
    case stays
    /// As for the app in front: the default and the lists of apps.
    case asForTheApp
}

/// The Dock's settings, in Bar.app's defaults: Bar.app reads them, Suite Settings writes them.
/// `BarSettings.current` loads and saves them; setting it tells the Dock in this app (`didChange`).
public struct BarSettings: Codable, Equatable {
    /// Our Dock in place of the system one, which is then hidden (with Finder's icon in it).
    public var isShown = false
    public var iconSize: CGFloat = 48
    /// The sizes the Dock's icons can take.
    public static let iconSizes: ClosedRange<CGFloat> = 32...96
    /// By default, slides away until the pointer reaches the bottom of the screen, as the system Dock can.
    public var autohides = false
    /// Bundle identifiers of the apps with which the Dock hides automatically, though by default it stays.
    public var hidingApps: [String] = []
    /// Bundle identifiers of the apps with which the Dock stays on screen, though by default it hides.
    public var stayingApps: [String] = []
    public var fullScreen: BarFullScreenMode = .hides

    public init() {}

    private enum CodingKeys: String, CodingKey { case isShown, iconSize, autohides, hidingApps, stayingApps, fullScreen }

    /// Options saved by an older version, without the newer keys, keep what they had.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isShown = try values.decodeIfPresent(Bool.self, forKey: .isShown) ?? false
        iconSize = try values.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48
        autohides = try values.decodeIfPresent(Bool.self, forKey: .autohides) ?? false
        hidingApps = try values.decodeIfPresent([String].self, forKey: .hidingApps) ?? []
        stayingApps = try values.decodeIfPresent([String].self, forKey: .stayingApps) ?? []
        fullScreen = (try? values.decodeIfPresent(BarFullScreenMode.self, forKey: .fullScreen)) ?? .hides
    }

    /// The apps that make an exception to the default: those with which the Dock stays while it hides by
    /// default, those with which it hides while it stays by default.
    public var exceptions: [String] {
        get { autohides ? stayingApps : hidingApps }
        set { if autohides { stayingApps = newValue } else { hidingApps = newValue } }
    }

    /// Whether the Dock hides automatically with `frontmost` (a bundle identifier) in front, in full
    /// screen or not: the full-screen choice first, unless it defers to the app, then the app's list, then
    /// the default.
    public func hides(frontmost: String?, inFullScreen: Bool) -> Bool {
        if inFullScreen {
            switch fullScreen {
            case .hides: return true
            case .stays: return false
            case .asForTheApp: break
            }
        }
        guard let frontmost else { return autohides }
        return autohides ? !stayingApps.contains(frontmost) : hidingApps.contains(frontmost)
    }
}

extension BarSettings {
    /// Bar.app's defaults domain.
    public static let domain = "local.suite.bar"
    public static let didChange = Notification.Name("BarSettingsDidChange")
    /// The key they are saved under (the name they had in Explorer's defaults, where they lived before).
    static let key = "BarSettings"

    /// Bar.app's defaults, read and written from whichever app (Suite Settings writes them).
    public static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain) ?? .standard
    }

    /// The settings as saved; setting them saves them and posts `didChange` in this app.
    public static var current: BarSettings {
        get {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BarSettings.self, from: $0) }
                ?? BarSettings()
        }
        set {
            guard newValue != current else { return }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Written by another app (Suite Settings, a profile): read them again and apply them as a change.
    public static func reloadFromDefaults() {
        CFPreferencesAppSynchronize(domain as CFString)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
