import CoreGraphics
import DockGuard
@testable import BarCore
import BarSettings
import Foundation
import Testing

/// A trimmed copy of a real `com.apple.dock.plist`: Explorer, Finder-less apps, a spacer, a stack.
private let dockPlistFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>autohide</key><false/>
    <key>tilesize</key><integer>36</integer>
    <key>persistent-apps</key>
    <array>
        <dict>
            <key>tile-data</key>
            <dict>
                <key>bundle-identifier</key><string>local.suite.explorer</string>
                <key>file-data</key>
                <dict>
                    <key>_CFURLString</key><string>file:///Users/me/Applications/Explorer.app/</string>
                    <key>_CFURLStringType</key><integer>15</integer>
                </dict>
                <key>file-label</key><string>Explorer</string>
            </dict>
            <key>tile-type</key><string>file-tile</string>
        </dict>
        <dict>
            <key>tile-data</key>
            <dict>
                <key>bundle-identifier</key><string>com.apple.mail</string>
                <key>file-data</key>
                <dict>
                    <key>_CFURLString</key><string>file:///System/Applications/Mail.app/</string>
                    <key>_CFURLStringType</key><integer>15</integer>
                </dict>
                <key>file-label</key><string>Mail</string>
            </dict>
            <key>tile-type</key><string>file-tile</string>
        </dict>
        <dict>
            <key>tile-data</key><dict/>
            <key>tile-type</key><string>spacer-tile</string>
        </dict>
        <dict>
            <key>tile-data</key>
            <dict>
                <key>bundle-identifier</key><string>org.mozilla.firefox</string>
                <key>file-data</key>
                <dict>
                    <key>_CFURLString</key><string>file:///Applications/Firefox%20Nightly.app/</string>
                    <key>_CFURLStringType</key><integer>15</integer>
                </dict>
            </dict>
            <key>tile-type</key><string>file-tile</string>
        </dict>
    </array>
    <key>persistent-others</key>
    <array>
        <dict>
            <key>tile-data</key>
            <dict>
                <key>file-data</key>
                <dict><key>_CFURLString</key><string>file:///Users/me/Downloads/</string></dict>
            </dict>
            <key>tile-type</key><string>directory-tile</string>
        </dict>
    </array>
</dict>
</plist>
"""

private let mail = BarApp(bundleID: "com.apple.mail", path: "/System/Applications/Mail.app", name: "Mail")
private let safari = BarApp(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
private let notes = BarApp(bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app", name: "Notes")
private let finder = BarApp(bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app",
                             name: "Finder")
private let explorer = BarApp(bundleID: "local.suite.explorer", path: "/Users/me/Applications/Explorer.app",
                               name: "Explorer")

private func freshDefaults() -> UserDefaults {
    let name = "BarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct DockReaderTests {
    @Test func readsAppsFromThePersistentAppsPlist() throws {
        let apps = try DockReader.apps(fromPlist: Data(dockPlistFixture.utf8))
        #expect(apps.map(\.bundleID) == ["local.suite.explorer", "com.apple.mail", "org.mozilla.firefox"])
        #expect(apps[1].path == "/System/Applications/Mail.app")
        #expect(apps[1].name == "Mail")
    }

    @Test func nameFallsBackToTheBundleNameAndPathsAreDecoded() throws {
        let firefox = try DockReader.apps(fromPlist: Data(dockPlistFixture.utf8))[2]
        #expect(firefox.path == "/Applications/Firefox Nightly.app")
        #expect(firefox.name == "Firefox Nightly")
    }

    @Test func aPlistWithoutAppsGivesNone() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["autohide": true], format: .xml, options: 0)
        #expect(try DockReader.apps(fromPlist: data).isEmpty)
    }
}

@Suite struct BarPinsTests {
    @Test func sameAppByBundleIDOrByPath() {
        let moved = BarApp(bundleID: "com.apple.mail", path: "/Elsewhere/Mail.app", name: "Mail")
        #expect(mail.isSameApp(as: moved))
        let a = BarApp(bundleID: nil, path: "/Applications/Tool.app", name: "Tool")
        let b = BarApp(bundleID: nil, path: "/Applications/Tool.app/", name: "Tool")
        #expect(a.isSameApp(as: b))
        #expect(!a.isSameApp(as: mail))
    }

    @Test func duplicatesAreDropped() {
        #expect(BarPins([mail, safari, mail]).apps == [mail, safari])
    }

    @Test func pinAddsAtTheEndOrAtAnIndex() {
        var pins = BarPins([mail])
        pins.pin(safari)
        pins.pin(notes, at: 0)
        #expect(pins.apps == [notes, mail, safari])
    }

    @Test func pinningAPinnedAppMovesIt() {
        var pins = BarPins([mail, safari, notes])
        pins.pin(mail, at: 3)
        #expect(pins.apps == [safari, notes, mail])
        pins.pin(notes)
        #expect(pins.apps == [safari, mail, notes])
    }

    @Test func unpinRemoves() {
        var pins = BarPins([mail, safari])
        pins.unpin(mail)
        #expect(pins.apps == [safari])
        #expect(!pins.contains(mail))
    }

    @Test func moveDropsBeforeTheDestination() {
        var pins = BarPins([mail, safari, notes])
        pins.move(from: 0, to: 2)
        #expect(pins.apps == [safari, mail, notes])
        pins.move(from: 2, to: 0)
        #expect(pins.apps == [notes, safari, mail])
        pins.move(from: 0, to: 3)
        #expect(pins.apps == [safari, mail, notes])
        pins.move(from: 1, to: 1)
        #expect(pins.apps == [safari, mail, notes])
        pins.move(from: 9, to: 0)
        #expect(pins.apps == [safari, mail, notes])
    }
}

@Suite struct BarStoreTests {
    @Test func startsFromTheSystemDockWithoutFinderOrExplorer() {
        let store = BarStore(defaults: freshDefaults(), systemApps: { [explorer, finder, mail, safari] })
        #expect(store.pins.apps == [mail, safari])
    }

    @Test func changesAreSavedAndOutliveTheSystemDock() {
        let defaults = freshDefaults()
        var system = [mail, safari]
        let store = BarStore(defaults: defaults, systemApps: { system })
        store.move(from: 1, to: 0)
        store.pin(notes)
        store.unpin(mail)
        system = []
        #expect(store.pins.apps == [safari, notes])
        let reopened = BarStore(defaults: defaults, systemApps: { [] })
        #expect(reopened.pins.apps == [safari, notes])
        #expect(reopened.isPinned(notes))
    }

    @Test func finderAndExplorerCantBePinned() {
        let store = BarStore(defaults: freshDefaults(), systemApps: { [] })
        store.pin(finder)
        store.pin(explorer)
        #expect(store.pins.apps.isEmpty)
    }

    @Test func emptyingTheDockIsKept() {
        let defaults = freshDefaults()
        let store = BarStore(defaults: defaults, systemApps: { [mail] })
        store.unpin(mail)
        #expect(BarStore(defaults: defaults, systemApps: { [mail] }).pins.apps.isEmpty)
    }
}

@Suite struct BarLayoutTests {
    @Test func explorerFirstThenPinnedThenRunningThenStacks() {
        let tiles = BarLayout.tiles(pinned: [mail, safari], running: [safari, notes, finder])
        #expect(tiles == [
            .explorer,
            .app(mail, isPinned: true, isRunning: false),
            .app(safari, isPinned: true, isRunning: true),
            .separator,
            .app(notes, isPinned: false, isRunning: true),
            .separator, .downloads, .trash,
        ])
    }

    @Test func noRunningSectionWhenEverythingIsPinned() {
        let tiles = BarLayout.tiles(pinned: [mail], running: [mail, explorer, finder])
        #expect(tiles == [.explorer, .app(mail, isPinned: true, isRunning: true), .separator, .downloads, .trash])
    }

    @Test func minimizedWindowsComeBeforeTheTrash() {
        let window = BarWindow(id: 1, title: "Inbox", app: mail)
        let tiles = BarLayout.tiles(pinned: [mail], running: [mail], minimized: [window])
        #expect(Array(tiles.suffix(3)) == [.downloads, .window(window), .trash])
    }

    @Test func finderNeverShowsEvenIfPinned() {
        let tiles = BarLayout.tiles(pinned: [finder, mail], running: [])
        #expect(!tiles.contains { $0.app?.bundleID == "com.apple.finder" })
    }
}

@Suite struct BarGeometryTests {
    @Test func iconSizeIsClamped() {
        #expect(BarGeometry(iconSize: 4).iconSize == 32)
        #expect(BarGeometry(iconSize: 500).iconSize == 96)
    }

    @Test func tilesSitSideBySideWithNarrowSeparators() {
        let geometry = BarGeometry(iconSize: 48)
        let tiles: [BarTile] = [.explorer, .app(mail, isPinned: true, isRunning: false), .separator, .trash]
        let frames = geometry.frames(for: tiles)
        #expect(frames[0].minX == geometry.margin)
        #expect(frames[1].minX == frames[0].maxX)
        #expect(frames[2].width == geometry.separatorWidth)
        #expect(frames[2].width < frames[1].width)
        #expect(geometry.barSize(for: tiles).width == frames[3].maxX + geometry.margin)
        #expect(geometry.iconFrame(in: frames[1]).width == 48)
        #expect(geometry.iconFrame(in: frames[1]).maxY <= geometry.barHeight)
    }

    @Test func hitTestingSkipsSeparators() {
        let geometry = BarGeometry(iconSize: 48)
        let tiles: [BarTile] = [.explorer, .separator, .trash]
        let frames = geometry.frames(for: tiles)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[0].midX, y: 10), tiles: tiles) == 0)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[1].midX, y: 10), tiles: tiles) == nil)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[2].midX, y: 10), tiles: tiles) == 2)
        #expect(geometry.tileIndex(at: CGPoint(x: -5, y: 10), tiles: tiles) == nil)
    }

    @Test func insertionIndexCountsIconsOnTheLeft() {
        let frames = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 50, y: 0, width: 50, height: 50)]
        #expect(BarGeometry.insertionIndex(forX: 10, pinnedFrames: frames) == 0)
        #expect(BarGeometry.insertionIndex(forX: 30, pinnedFrames: frames) == 1)
        #expect(BarGeometry.insertionIndex(forX: 99, pinnedFrames: frames) == 2)
    }

    @Test func optionsAreSavedAsJSON() throws {
        var options = BarSettings()
        #expect(!options.isShown)
        #expect(!options.autohides)
        options.iconSize = 64
        options.autohides = true
        let decoded = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }

    @Test func optionsFromTheFirstVersionKeepTheDockShown() throws {
        let old = Data(#"{"isShown":true,"iconSize":56,"hidesSystemDock":true}"#.utf8)
        let options = try JSONDecoder().decode(BarSettings.self, from: old)
        #expect(options.isShown)
        #expect(options.iconSize == 56)
        #expect(!options.autohides)
    }
}

@Suite struct WindowFitTests {
    // A 1512 × 982 screen, menu bar 33 high, Dock strip 70 high.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let top: CGFloat = 949

    @Test func aMaximizedWindowEndsAboveTheDock() {
        let window = CGRect(x: 0, y: 4, width: 1512, height: 945)
        #expect(WindowFit.fitted(window, screen: screen, reserved: 70, visibleTop: top)
                == CGRect(x: 0, y: 70, width: 1512, height: 879))
        #expect(WindowFit.fitted(window, screen: screen, reserved: 70, visibleTop: top, onlyIfFilling: true) != nil)
    }

    @Test func windowsClearOfTheDockStay() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(WindowFit.fitted(window, screen: screen, reserved: 70, visibleTop: top) == nil)
    }

    @Test func aWindowLowerDownButNotFillingStaysWhenOnlyMaximizedOnesChange() {
        let window = CGRect(x: 100, y: 20, width: 800, height: 600)
        #expect(WindowFit.fitted(window, screen: screen, reserved: 70, visibleTop: top, onlyIfFilling: true) == nil)
        #expect(WindowFit.fitted(window, screen: screen, reserved: 70, visibleTop: top)?.minY == 70)
    }

    @Test func windowsPushedOffTheScreenOrTooShortOrElsewhereStay() {
        #expect(WindowFit.fitted(CGRect(x: 100, y: -200, width: 800, height: 600), screen: screen,
                                 reserved: 70, visibleTop: top) == nil)
        #expect(WindowFit.fitted(CGRect(x: 100, y: 10, width: 800, height: 150), screen: screen,
                                 reserved: 70, visibleTop: top) == nil)
        #expect(WindowFit.fitted(CGRect(x: 2000, y: 4, width: 800, height: 900), screen: screen,
                                 reserved: 70, visibleTop: top) == nil)
        #expect(WindowFit.fitted(CGRect(x: 0, y: 4, width: 800, height: 900), screen: screen,
                                 reserved: 0, visibleTop: top) == nil)
    }

    @Test func accessibilityFramesFlipAroundTheMainScreen() {
        let ax = CGRect(x: 10, y: 33, width: 500, height: 400)
        let flipped = WindowFit.flipped(ax, mainScreenHeight: 982)
        #expect(flipped == CGRect(x: 10, y: 549, width: 500, height: 400))
        #expect(WindowFit.flipped(flipped, mainScreenHeight: 982) == ax)
    }
}

@Suite struct EdgeGuardTests {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let span: ClosedRange<CGFloat> = 600...870

    @Test func theLastRowUnderTheSystemDockSendsThePointerBackUp() {
        #expect(EdgeGuard.guarded(CGPoint(x: 700, y: 0), screen: screen, edge: .bottom, span: span, others: [])
                == CGPoint(x: 700, y: EdgeGuard.gap))
        #expect(EdgeGuard.guarded(CGPoint(x: 700, y: 1), screen: screen, edge: .bottom, span: span, others: [])
                != nil)
        #expect(EdgeGuard.guarded(CGPoint(x: 700, y: 3), screen: screen, edge: .bottom, span: span, others: [])
                == nil)
        #expect(EdgeGuard.guarded(CGPoint(x: 100, y: 0), screen: screen, edge: .bottom, span: span, others: [])
                == nil)
    }

    @Test func onTheLeftOnlyTheMiddleOfTheLeftEdgeIsKept() {
        let span: ClosedRange<CGFloat> = 300...650
        #expect(EdgeGuard.guarded(CGPoint(x: 0, y: 400), screen: screen, edge: .left, span: span, others: [])
                == CGPoint(x: EdgeGuard.gap, y: 400))
        #expect(EdgeGuard.guarded(CGPoint(x: 0, y: 100), screen: screen, edge: .left, span: span, others: [])
                == nil)
        #expect(EdgeGuard.guarded(CGPoint(x: 5, y: 400), screen: screen, edge: .left, span: span, others: [])
                == nil)
        // The bottom edge is free when the Dock is on the left.
        #expect(EdgeGuard.guarded(CGPoint(x: 700, y: 0), screen: screen, edge: .left, span: span, others: [])
                == nil)
    }

    @Test func onTheRightTheLastColumnIsKept() {
        let span: ClosedRange<CGFloat> = 300...650
        #expect(EdgeGuard.guarded(CGPoint(x: 1469, y: 400), screen: screen, edge: .right, span: span, others: [])
                == CGPoint(x: 1469 - EdgeGuard.gap, y: 400))
        #expect(EdgeGuard.guarded(CGPoint(x: 1400, y: 400), screen: screen, edge: .right, span: span, others: [])
                == nil)
    }

    @Test func aScreenBeyondTheEdgeIsStillReached() {
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(EdgeGuard.guarded(CGPoint(x: 700, y: 0), screen: screen, edge: .bottom, span: span,
                                  others: [below]) == nil)
        let leftOf = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(EdgeGuard.guarded(CGPoint(x: 0, y: 400), screen: screen, edge: .left, span: 300...650,
                                  others: [leftOf]) == nil)
        #expect(EdgeGuard.guarded(CGPoint(x: 0, y: 400), screen: screen, edge: .left, span: 300...650,
                                  others: [below]) != nil)
    }

    @Test func theSystemDockSpanIsCentredAndCounted() {
        // 10 tiles of 22.2, two separators of 7.8, two ends of 5.2: 248 long.
        #expect(DockSpan.estimate(itemCount: 10, tileSize: 16, screen: screen)
                == CGFloat(611)...CGFloat(859))
        #expect(DockSpan.estimate(itemCount: 10, tileSize: 16, screen: screen, edge: .left)
                == CGFloat(354)...CGFloat(602))
        // The hidden mini Dock: one-point icons, five tiles.
        #expect(DockSpan.estimate(itemCount: 5, tileSize: 1, screen: screen) == CGFloat(719)...CGFloat(751))
        #expect(DockSpan.estimate(itemCount: 500, tileSize: 16, screen: screen) == 0...1470)
        let dock = FakeDock(["persistent-apps": [1, 2, 3], "persistent-others": [1], "recent-apps": [1, 2]])
        #expect(DockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 4) == 2 + 3 + 1 + 2 + 4)
        dock.values["show-recents"] = false
        #expect(DockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 0) == 6)
        dock.values["static-only"] = true
        #expect(DockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 0) == 8)
    }
}

@Suite struct BarStackOrderTests {
    @Test func newestFirstThenByName() {
        let now = Date()
        let order = BarStackOrder.sorted([
            (URL(fileURLWithPath: "/d/old.zip"), now.addingTimeInterval(-100)),
            (URL(fileURLWithPath: "/d/b.pdf"), nil),
            (URL(fileURLWithPath: "/d/new.dmg"), now),
            (URL(fileURLWithPath: "/d/a.pdf"), nil),
        ])
        #expect(order.map(\.lastPathComponent) == ["new.dmg", "old.zip", "a.pdf", "b.pdf"])
    }

    @Test func listsAFolderWithoutHiddenFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BarStack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }  // a scratch folder of the test's own
        try Data().write(to: folder.appendingPathComponent("file.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden"))
        #expect(BarStackOrder.contents(of: folder).map(\.lastPathComponent) == ["file.txt"])
    }
}

/// A Dock preferences domain in memory: the real Dock is never touched by tests.
private final class FakeDock: PreferenceDomain {
    var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(forKey key: String) -> Any? { values[key] }
    func setValue(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite struct MissionControlTests {
    let screen = CGSize(width: 1470, height: 956)
    let wm = MissionControl.windowManager

    @Test func theSpacesBarOrTheShieldMeanItIsOpen() {
        #expect(MissionControl.isOpen(windows: [.init(owner: wm, layer: 14, size: CGSize(width: 1470, height: 220))],
                                      screen: screen))
        #expect(MissionControl.isOpen(windows: [.init(owner: wm, layer: 19, size: CGSize(width: 1470, height: 956))],
                                      screen: screen))
    }

    @Test func theDesktopAloneMeansItIsClosed() {
        let desktop: [MissionControl.Window] = [
            .init(owner: wm, layer: -2147483624, size: CGSize(width: 1470, height: 956)),
            .init(owner: "com.apple.dock", layer: 20, size: CGSize(width: 1470, height: 956)),
            .init(owner: wm, layer: 15, size: CGSize(width: 169, height: 129)),
            .init(owner: "org.mozilla.firefox", layer: 14, size: CGSize(width: 1470, height: 220)),
        ]
        #expect(!MissionControl.isOpen(windows: desktop, screen: screen))
    }
}

@Suite struct FullScreenSpaceTests {
    let screen = CGSize(width: 1470, height: 956)

    @Test func theAppInFrontCoveringTheWholeScreenIsFullScreen() {
        let windows: [FullScreenSpace.Window] = [
            .init(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956)),
        ]
        #expect(FullScreenSpace.isActive(windows: windows, screen: screen, frontmost: 42))
    }

    @Test func aMaximizedWindowStopsAtTheMenuBar() {
        let windows: [FullScreenSpace.Window] = [
            .init(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1470, height: 923)),
        ]
        #expect(!FullScreenSpace.isActive(windows: windows, screen: screen, frontmost: 42))
    }

    @Test func anotherAppsWindowOrTheDesktopDoesNotCount() {
        let windows: [FullScreenSpace.Window] = [
            .init(ownerPID: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956)),
            .init(ownerPID: 42, layer: -2147483623, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956)),
        ]
        #expect(!FullScreenSpace.isActive(windows: windows, screen: screen, frontmost: 42))
        #expect(!FullScreenSpace.isActive(windows: windows, screen: screen, frontmost: nil))
    }
}

@Suite struct BarHidingRulesTests {
    @Test func theDefaultHoldsForAppsInNeitherList() {
        var options = BarSettings()
        #expect(!options.hides(frontmost: "com.apple.Safari", inFullScreen: false))
        options.autohides = true
        #expect(options.hides(frontmost: "com.apple.Safari", inFullScreen: false))
        #expect(options.hides(frontmost: nil, inFullScreen: false))
    }

    @Test func eachListMakesExceptionsToItsDefault() {
        var options = BarSettings()
        options.hidingApps = ["com.apple.Safari"]
        options.stayingApps = ["com.apple.mail"]
        // Stays by default: hides with Safari; Mail's list doesn't apply.
        #expect(options.hides(frontmost: "com.apple.Safari", inFullScreen: false))
        #expect(!options.hides(frontmost: "com.apple.mail", inFullScreen: false))
        // Hides by default: stays with Mail; Safari's list doesn't apply.
        options.autohides = true
        #expect(!options.hides(frontmost: "com.apple.mail", inFullScreen: false))
        #expect(options.hides(frontmost: "com.apple.Safari", inFullScreen: false))
    }

    @Test func fullScreenHasItsOwnChoice() {
        var options = BarSettings()
        options.stayingApps = ["com.apple.mail"]
        options.autohides = true
        #expect(options.hides(frontmost: "com.apple.mail", inFullScreen: true))
        options.fullScreen = .stays
        #expect(!options.hides(frontmost: "com.apple.Safari", inFullScreen: true))
        options.fullScreen = .asForTheApp
        #expect(!options.hides(frontmost: "com.apple.mail", inFullScreen: true))
        #expect(options.hides(frontmost: "com.apple.Safari", inFullScreen: true))
    }

    @Test func exceptionsAreTheListTheDefaultUses() {
        var options = BarSettings()
        options.exceptions = ["a"]
        #expect(options.hidingApps == ["a"])
        options.autohides = true
        #expect(options.exceptions.isEmpty)
        options.exceptions = ["b"]
        #expect(options.stayingApps == ["b"] && options.hidingApps == ["a"])
    }

    @Test func olderOptionsKeepTheirSettings() throws {
        let old = Data(#"{"isShown":true,"iconSize":40,"autohides":true}"#.utf8)
        let options = try JSONDecoder().decode(BarSettings.self, from: old)
        #expect(options.autohides && options.isShown && options.fullScreen == .hides && options.stayingApps.isEmpty)
    }
}

@Suite struct QuitRequestsTests {
    @Test func forceQuitOnceAskedOrWithOption() {
        var requests = QuitRequests()
        #expect(!requests.offersForceQuit(42))
        #expect(requests.offersForceQuit(42, optionHeld: true))
        requests.asked(42)
        #expect(requests.offersForceQuit(42))
        #expect(!requests.offersForceQuit(43))
        requests.keep(running: [43])
        #expect(!requests.offersForceQuit(42))
    }
}

@Suite struct LauncherTileTests {
    @Test func theLauncherTileFollowsExplorersWhenShown() {
        let app = BarApp(url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari")
        #expect(!BarLayout.tiles(pinned: [app], running: []).contains(.launcher))
        let tiles = BarLayout.tiles(pinned: [app], running: [], showsLauncher: true)
        #expect(Array(tiles.prefix(2)) == [.explorer, .launcher])
    }
}
