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
    @Test func startsFromTheSystemDockWithExplorerFirstAndNoFinder() {
        let store = BarStore(defaults: freshDefaults(), systemApps: { [finder, mail, explorer, safari] },
                              explorer: explorer)
        #expect(store.pins.apps == [mail, explorer, safari])
        let fresh = BarStore(defaults: freshDefaults(), systemApps: { [finder, mail] }, explorer: explorer)
        #expect(fresh.pins.apps == [explorer, mail])
    }

    @Test func changesAreSavedAndOutliveTheSystemDock() {
        let defaults = freshDefaults()
        var system = [mail, safari]
        let store = BarStore(defaults: defaults, systemApps: { system }, explorer: nil)
        store.move(from: 1, to: 0)
        store.pin(notes)
        store.unpin(mail)
        system = []
        #expect(store.pins.apps == [safari, notes])
        let reopened = BarStore(defaults: defaults, systemApps: { [] }, explorer: nil)
        #expect(reopened.pins.apps == [safari, notes])
        #expect(reopened.isPinned(notes))
    }

    @Test func pinsSavedBeforeExplorerCouldMoveGetItFirst() throws {
        let defaults = freshDefaults()
        defaults.set(try JSONEncoder().encode([mail, safari]), forKey: "BarPinnedApps")
        let store = BarStore(defaults: defaults, systemApps: { [] }, explorer: explorer)
        #expect(store.pins.apps == [explorer, mail, safari])
    }

    @Test func explorerCanBeUnpinnedAndMoved() {
        let defaults = freshDefaults()
        let store = BarStore(defaults: defaults, systemApps: { [mail, safari] }, explorer: explorer)
        store.move(from: 0, to: 3)
        #expect(store.pins.apps == [mail, safari, explorer])
        store.unpin(explorer)
        #expect(store.pins.apps == [mail, safari])
        #expect(BarStore(defaults: defaults, systemApps: { [] }, explorer: explorer).pins.apps == [mail, safari])
        store.pin(explorer, at: 1)
        #expect(store.pins.apps == [mail, explorer, safari])
    }

    @Test func finderCantBePinned() {
        let store = BarStore(defaults: freshDefaults(), systemApps: { [] }, explorer: nil)
        store.pin(finder)
        #expect(store.pins.apps.isEmpty)
    }

    @Test func emptyingTheDockIsKept() {
        let defaults = freshDefaults()
        let store = BarStore(defaults: defaults, systemApps: { [mail] }, explorer: explorer)
        store.unpin(mail)
        store.unpin(explorer)
        #expect(BarStore(defaults: defaults, systemApps: { [mail] }, explorer: explorer).pins.apps.isEmpty)
    }
}

@Suite struct BarLayoutTests {
    let downloads = BarItem.downloads(URL(fileURLWithPath: "/Users/me/Downloads"))

    @Test func pinnedThenRunningThenStacks() {
        let tiles = BarLayout.tiles(pinned: [explorer, mail, safari], running: [safari, notes, finder],
                                     items: [downloads], recents: [], explorer: explorer)
        #expect(tiles == [
            .app(explorer, isPinned: true, isRunning: true),
            .app(mail, isPinned: true, isRunning: false),
            .app(safari, isPinned: true, isRunning: true),
            .separator,
            .app(notes, isPinned: false, isRunning: true),
            .separator, .item(downloads), .trash,
        ])
    }

    @Test func withoutRecentsRunningAppsFollowThePinnedOnes() {
        let tiles = BarLayout.tiles(pinned: [mail], running: [notes], items: [downloads])
        #expect(tiles == [.app(mail, isPinned: true, isRunning: false),
                          .app(notes, isPinned: false, isRunning: true), .separator, .item(downloads), .trash])
    }

    @Test func recentAppsComeAfterTheRunningOnesOnce() {
        let tiles = BarLayout.tiles(pinned: [mail], running: [notes], recents: [notes, safari, mail])
        #expect(tiles == [.app(mail, isPinned: true, isRunning: false), .separator,
                          .app(notes, isPinned: false, isRunning: true),
                          .app(safari, isPinned: false, isRunning: false), .separator, .trash])
    }

    @Test func noRunningSectionWhenEverythingIsPinned() {
        let tiles = BarLayout.tiles(pinned: [explorer, mail], running: [mail, finder], items: [downloads],
                                     recents: [], explorer: explorer)
        #expect(tiles == [.app(explorer, isPinned: true, isRunning: true), .app(mail, isPinned: true, isRunning: true),
                          .separator, .item(downloads), .trash])
    }

    @Test func unpinnedExplorerShowsFirstAmongTheRunningApps() {
        let tiles = BarLayout.tiles(pinned: [mail], running: [notes], recents: [safari], explorer: explorer)
        #expect(tiles == [.app(mail, isPinned: true, isRunning: false), .separator,
                          .app(explorer, isPinned: false, isRunning: true),
                          .app(notes, isPinned: false, isRunning: true),
                          .app(safari, isPinned: false, isRunning: false), .separator, .trash])
    }

    @Test func minimizedWindowsComeBeforeTheTrash() {
        let window = BarWindow(id: 1, title: "Inbox", app: mail)
        let tiles = BarLayout.tiles(pinned: [mail], running: [mail], minimized: [window], items: [downloads])
        #expect(Array(tiles.suffix(3)) == [.item(downloads), .window(window), .trash])
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
        let tiles: [BarTile] = [.app(explorer, isPinned: true, isRunning: true), .app(mail, isPinned: true, isRunning: false), .separator, .trash]
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
        let tiles: [BarTile] = [.app(explorer, isPinned: true, isRunning: true), .separator, .trash]
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

    @Test func optionsSavedBeforeTheNewerKeysTakeTheSystemDocksValues() throws {
        var system = BarSettings()
        system.showsIndicators = false
        system.minimizesIntoApp = true
        let decoder = JSONDecoder()
        decoder.userInfo[BarSettings.fallbackKey] = system
        let options = try decoder.decode(BarSettings.self, from: Data(#"{"isShown":true,"iconSize":56}"#.utf8))
        #expect(options.isShown)
        #expect(!options.showsIndicators)
        #expect(options.minimizesIntoApp)
        #expect(options.animatesLaunch)
    }

    @Test func theSystemDocksOptionsAreRead() {
        let dock: [String: Any] = ["show-process-indicators": false, "minimize-to-application": true,
                                   "launchanim": false, "show-recents": false]
        let options = BarSettings { dock[$0] }
        #expect(!options.showsIndicators)
        #expect(options.minimizesIntoApp)
        #expect(!options.animatesLaunch)
        #expect(!options.showsRecents)
        let defaults = BarSettings { _ in nil }
        #expect(defaults.showsIndicators && !defaults.minimizesIntoApp && defaults.animatesLaunch
                && defaults.showsRecents)
    }
}

@Suite struct BarItemTests {
    /// The system Dock's Downloads, shown as a folder that opens in a fan, sorted by date added.
    let others: [Any] = [
        ["tile-type": "directory-tile",
         "tile-data": ["arrangement": 2, "displayas": 1, "showas": 1, "file-type": 2, "file-label": "Téléchargements",
                       "file-data": ["_CFURLString": "file:///Users/me/Downloads/", "_CFURLStringType": 15]]
                    as [String: Any]],
        ["tile-type": "file-tile",
         "tile-data": ["file-data": ["_CFURLString": "file:///Users/me/Notes.txt"]] as [String: Any]],
        ["tile-type": "recents-tile", "tile-data": [:] as [String: Any]],
    ]

    @Test func readsFoldersAndFilesWithTheirOptions() {
        let items = DockReader.others(fromPersistentOthers: others)
        #expect(items.count == 2)
        #expect(items[0] == BarItem(path: "/Users/me/Downloads", name: "Téléchargements", isFolder: true,
                                     sort: .dateAdded, display: .folder, view: .fan))
        #expect(items[1].name == "Notes.txt")
        #expect(!items[1].isFolder)
        #expect(items[1].view == .automatic)
    }

    @Test func storeStartsFromTheSystemDockOrDownloads() {
        let system = DockReader.others(fromPersistentOthers: others)
        #expect(BarItemStore(defaults: freshDefaults(), systemItems: { system }).items == system)
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let store = BarItemStore(defaults: freshDefaults(), systemItems: { nil }, downloads: downloads)
        #expect(store.items == [.downloads(downloads)])
    }

    @Test func addingRemovingAndChangingAreSaved() {
        let defaults = freshDefaults()
        let store = BarItemStore(defaults: defaults, systemItems: { [] })
        let projects = BarItem(path: "/Users/me/Projects", isFolder: true)
        let notes = BarItem(path: "/Users/me/Notes.txt", isFolder: false)
        store.add(projects)
        store.add(notes, at: 0)
        store.add(projects, at: 0)
        #expect(store.items.map(\.name) == ["Projects", "Notes.txt"])
        var changed = projects
        changed.view = .list
        store.update(changed)
        store.remove(notes)
        #expect(BarItemStore(defaults: defaults, systemItems: { nil }).items == [changed])
    }

    @Test func automaticIsAFanWhenEverythingFits() {
        #expect(BarStackView.automatic.resolved(itemCount: 8, fanCapacity: 12) == .fan)
        #expect(BarStackView.automatic.resolved(itemCount: 20, fanCapacity: 12) == .grid)
        #expect(BarStackView.list.resolved(itemCount: 2, fanCapacity: 12) == .list)
    }

    @Test func eachSortHasItsOrder() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = BarStackEntry(url: URL(fileURLWithPath: "/d/b.zip"), added: base, modified: base + 2 * day,
                               created: base - day, kind: "ZIP archive")
        let b = BarStackEntry(url: URL(fileURLWithPath: "/d/a.pdf"), added: base + day, modified: base,
                               created: base, kind: "PDF document")
        let c = BarStackEntry(url: URL(fileURLWithPath: "/d/c.pdf"), added: nil, modified: base + day,
                               created: nil, kind: "PDF document")
        func names(_ sort: BarStackSort) -> [String] {
            BarStackOrder.sorted([a, b, c], by: sort).map(\.lastPathComponent)
        }
        #expect(names(.name) == ["a.pdf", "b.zip", "c.pdf"])
        #expect(names(.dateAdded) == ["a.pdf", "b.zip", "c.pdf"])
        #expect(names(.dateModified) == ["b.zip", "c.pdf", "a.pdf"])
        #expect(names(.dateCreated) == ["a.pdf", "b.zip", "c.pdf"])
        #expect(names(.kind) == ["a.pdf", "c.pdf", "b.zip"])
    }

    @Test func recentsKeepTheLatestThreeOnce() {
        var recents = BarRecents()
        for app in [mail, safari, notes, mail, finder] { recents.used(app) }
        #expect(recents.apps == [mail, notes, safari])
        recents.used(explorer)
        recents.forget(notes)
        #expect(recents.apps == [mail, safari])
    }

    @Test func theFanRisesAndBendsRight() {
        let places = BarFan.places(count: 10, step: 50)
        #expect(places.count == 10)
        #expect(places[0].center.y == 25)
        for (lower, upper) in zip(places, places.dropFirst()) {
            #expect(upper.center.y == lower.center.y + 50)
            #expect(upper.center.x > lower.center.x)
            #expect(upper.angle > lower.angle)
        }
        #expect(places.last!.center.x <= 60)
        #expect(BarFan.capacity(height: 600, step: 50) == 11)
        #expect(BarFan.capacity(height: 2000, step: 50) == 15)
        #expect(BarFan.capacity(height: 30, step: 50) == 1)
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

@Suite struct BarMagnificationTests {
    let geometry = BarGeometry(iconSize: 48)
    let tiles: [BarTile] = [.app(explorer, isPinned: true, isRunning: true)] + (0..<9).map { _ in BarTile.trash }

    @Test func atRestNothingChanges() {
        let rest = geometry.frames(for: tiles)
        #expect(geometry.frames(for: tiles, magnification: BarMagnification(size: 96, pointer: 100, amount: 0)) == rest)
        #expect(geometry.frames(for: tiles, magnification: BarMagnification(size: 48, pointer: 100)) == rest)
    }

    @Test func theIconUnderThePointerGrowsMostAndStaysUnderIt() {
        let rest = geometry.frames(for: tiles)
        let pointer = rest[5].midX
        let frames = geometry.frames(for: tiles, magnification: BarMagnification(size: 96, pointer: pointer))
        let sides = frames.map { geometry.iconFrame(in: $0).width }
        #expect(abs(sides[5] - 96) < 0.01)
        #expect(sides[4] < sides[5] && sides[6] < sides[5] && sides[4] > 48)
        #expect(abs(sides[0] - 48) < 0.01 && abs(sides[9] - 48) < 0.01)
        #expect(abs(frames[5].midX - pointer) < 0.01)
        // Tiles stay side by side, and the outer ones are pushed out no further than the reach.
        for index in 1..<frames.count { #expect(abs(frames[index].minX - frames[index - 1].maxX) < 0.01) }
        let reach = geometry.magnificationReach(size: 96)
        #expect(frames[0].minX >= rest[0].minX - reach && frames[9].maxX <= rest[9].maxX + reach)
        #expect(frames[0].minX < rest[0].minX && frames[9].maxX > rest[9].maxX)
    }

    @Test func magnifiedIconsRiseFromTheBar() {
        let rest = geometry.frames(for: tiles)
        let frames = geometry.frames(for: tiles, magnification: BarMagnification(size: 96, pointer: rest[2].midX))
        #expect(geometry.iconFrame(in: frames[2]).minY == geometry.iconFrame(in: rest[2]).minY)
        #expect(frames[2].height == geometry.barHeight + 48)
    }

    @Test func windowsEndBeforeADockOnTheSide() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let window = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(WindowFit.fitted(window, screen: screen, edge: .left, reserved: 70, visible: visible)
                == CGRect(x: 70, y: 0, width: 1370, height: 875))
        #expect(WindowFit.fitted(window, screen: screen, edge: .right, reserved: 70, visible: visible)
                == CGRect(x: 0, y: 0, width: 1370, height: 875))
        let narrow = CGRect(x: 0, y: 100, width: 600, height: 500)
        #expect(WindowFit.fitted(narrow, screen: screen, edge: .left, reserved: 70, visible: visible,
                                 onlyIfFilling: true) == nil)
        #expect(WindowFit.fitted(narrow, screen: screen, edge: .left, reserved: 70, visible: visible) != nil)
        #expect(WindowFit.fitted(narrow, screen: screen, edge: .right, reserved: 70, visible: visible) == nil)
        let elsewhere = CGRect(x: 1500, y: 0, width: 800, height: 600)
        #expect(WindowFit.fitted(elsewhere, screen: screen, edge: .left, reserved: 70, visible: visible) == nil)
    }
}

@Suite struct BarPlacementOptionsTests {
    @Test func magnificationAndSideComeFromTheSystemDock() {
        let dock: [String: Any] = ["magnification": true, "largesize": 200, "orientation": "left"]
        let options = BarSettings { dock[$0] }
        #expect(options.magnifies)
        #expect(options.magnifiedSize == BarSettings.magnifiedSizes.upperBound)
        #expect(options.position == .left)
        var small = BarSettings()
        small.iconSize = 64
        small.magnifiedSize = 40
        #expect(small.magnifiedIconSize == 64)
    }

    @Test func olderSavesKeepTheirPlace() throws {
        var system = BarSettings()
        system.position = .right
        let decoder = JSONDecoder()
        decoder.userInfo[BarSettings.fallbackKey] = system
        let options = try decoder.decode(BarSettings.self, from: Data(#"{"isShown":true}"#.utf8))
        #expect(options.position == .right && options.display == .withPointer && !options.magnifies)
        var saved = BarSettings()
        saved.position = .left
        saved.magnifies = true
        saved.display = .main
        let again = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(saved))
        #expect(again == saved)
    }
}
