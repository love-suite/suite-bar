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

/// The side of the screen the Dock sits on (the system Dock's `orientation`).
public enum BarPosition: String, Codable, CaseIterable, Sendable {
    case left, bottom, right
}

/// The screen the Dock shows on.
public enum BarDisplay: String, Codable, CaseIterable, Sendable {
    /// The main screen only (the one with the menu bar, in System Settings › Displays).
    case main
    /// As the system Dock: it moves to another screen when the pointer pushes against that screen's
    /// edge where the Dock goes.
    case withPointer
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
    /// A dot under running apps.
    public var showsIndicators = true
    /// Minimized windows go into their app's icon (listed in its menu) instead of a tile of their own.
    public var minimizesIntoApp = false
    /// Apps bounce while they open.
    public var animatesLaunch = true
    /// Apps recently used and not kept in the Dock stay there, after a separator.
    public var showsRecents = true
    /// Icons grow under the pointer, up to `magnifiedSize`.
    public var magnifies = false
    public var magnifiedSize: CGFloat = 96
    /// The sizes magnified icons can grow to.
    public static let magnifiedSizes: ClosedRange<CGFloat> = 32...128
    public var position: BarPosition = .bottom
    public var display: BarDisplay = .withPointer

    public init() {}

    /// Where decoding finds the values for keys an older version didn't save (the system Dock's own).
    public static let fallbackKey = CodingUserInfoKey(rawValue: "BarSettingsFallback")!

    private enum CodingKeys: String, CodingKey {
        case isShown, iconSize, autohides, hidingApps, stayingApps, fullScreen
        case showsIndicators, minimizesIntoApp, animatesLaunch, showsRecents
        case magnifies, magnifiedSize, position, display
    }

    /// Options saved by an older version, without the newer keys, keep what they had, and take the
    /// fallback's (the system Dock's) for the rest.
    public init(from decoder: Decoder) throws {
        let fallback = decoder.userInfo[Self.fallbackKey] as? BarSettings ?? BarSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isShown = try values.decodeIfPresent(Bool.self, forKey: .isShown) ?? false
        iconSize = try values.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48
        autohides = try values.decodeIfPresent(Bool.self, forKey: .autohides) ?? false
        hidingApps = try values.decodeIfPresent([String].self, forKey: .hidingApps) ?? []
        stayingApps = try values.decodeIfPresent([String].self, forKey: .stayingApps) ?? []
        fullScreen = (try? values.decodeIfPresent(BarFullScreenMode.self, forKey: .fullScreen)) ?? .hides
        showsIndicators = try values.decodeIfPresent(Bool.self, forKey: .showsIndicators) ?? fallback.showsIndicators
        minimizesIntoApp = try values.decodeIfPresent(Bool.self, forKey: .minimizesIntoApp)
            ?? fallback.minimizesIntoApp
        animatesLaunch = try values.decodeIfPresent(Bool.self, forKey: .animatesLaunch) ?? fallback.animatesLaunch
        showsRecents = try values.decodeIfPresent(Bool.self, forKey: .showsRecents) ?? fallback.showsRecents
        magnifies = try values.decodeIfPresent(Bool.self, forKey: .magnifies) ?? fallback.magnifies
        magnifiedSize = try values.decodeIfPresent(CGFloat.self, forKey: .magnifiedSize) ?? fallback.magnifiedSize
        position = (try? values.decodeIfPresent(BarPosition.self, forKey: .position)) ?? fallback.position
        display = (try? values.decodeIfPresent(BarDisplay.self, forKey: .display)) ?? .withPointer
    }

    /// The size magnified icons reach: never smaller than the icons themselves.
    public var magnifiedIconSize: CGFloat {
        max(min(magnifiedSize, Self.magnifiedSizes.upperBound), iconSize)
    }

    /// Starts with the system Dock's own options, read by `value` (a key of `com.apple.dock`).
    public init(system value: (String) -> Any?) {
        self.init()
        func bool(_ key: String) -> Bool? { (value(key) as? NSNumber)?.boolValue }
        showsIndicators = bool("show-process-indicators") ?? true
        minimizesIntoApp = bool("minimize-to-application") ?? false
        animatesLaunch = bool("launchanim") ?? true
        showsRecents = bool("show-recents") ?? true
        magnifies = bool("magnification") ?? false
        if let size = (value("largesize") as? NSNumber).map({ CGFloat($0.doubleValue) }) {
            magnifiedSize = min(max(size, Self.magnifiedSizes.lowerBound), Self.magnifiedSizes.upperBound)
        }
        // The system Dock's side, as long as Explorer hasn't hidden it (it is then kept at the bottom).
        if let side = value("orientation") as? String, let position = BarPosition(rawValue: side) {
            self.position = position
        }
    }

    /// The system Dock's options as it has them now (read only).
    public static var system: BarSettings {
        BarSettings { CFPreferencesCopyAppValue($0 as CFString, "com.apple.dock" as CFString) }
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
            // The system Dock's own options fill in whatever wasn't saved yet (indicators, minimizing).
            let system = BarSettings.system
            let decoder = JSONDecoder()
            decoder.userInfo[BarSettings.fallbackKey] = system
            return defaults.data(forKey: key).flatMap { try? decoder.decode(BarSettings.self, from: $0) } ?? system
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
