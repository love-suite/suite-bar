import CoreGraphics
import Foundation
import Testing
@testable import ExplorerCore

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
                <key>bundle-identifier</key><string>local.explorer.Explorer</string>
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

private let mail = DockApp(bundleID: "com.apple.mail", path: "/System/Applications/Mail.app", name: "Mail")
private let safari = DockApp(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
private let notes = DockApp(bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app", name: "Notes")
private let finder = DockApp(bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app",
                             name: "Finder")
private let explorer = DockApp(bundleID: "local.explorer.Explorer", path: "/Users/me/Applications/Explorer.app",
                               name: "Explorer")

private func freshDefaults() -> UserDefaults {
    let name = "DockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct SystemDockReaderTests {
    @Test func readsAppsFromThePersistentAppsPlist() throws {
        let apps = try SystemDockReader.apps(fromPlist: Data(dockPlistFixture.utf8))
        #expect(apps.map(\.bundleID) == ["local.explorer.Explorer", "com.apple.mail", "org.mozilla.firefox"])
        #expect(apps[1].path == "/System/Applications/Mail.app")
        #expect(apps[1].name == "Mail")
    }

    @Test func nameFallsBackToTheBundleNameAndPathsAreDecoded() throws {
        let firefox = try SystemDockReader.apps(fromPlist: Data(dockPlistFixture.utf8))[2]
        #expect(firefox.path == "/Applications/Firefox Nightly.app")
        #expect(firefox.name == "Firefox Nightly")
    }

    @Test func aPlistWithoutAppsGivesNone() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["autohide": true], format: .xml, options: 0)
        #expect(try SystemDockReader.apps(fromPlist: data).isEmpty)
    }
}

@Suite struct DockPinsTests {
    @Test func sameAppByBundleIDOrByPath() {
        let moved = DockApp(bundleID: "com.apple.mail", path: "/Elsewhere/Mail.app", name: "Mail")
        #expect(mail.isSameApp(as: moved))
        let a = DockApp(bundleID: nil, path: "/Applications/Tool.app", name: "Tool")
        let b = DockApp(bundleID: nil, path: "/Applications/Tool.app/", name: "Tool")
        #expect(a.isSameApp(as: b))
        #expect(!a.isSameApp(as: mail))
    }

    @Test func duplicatesAreDropped() {
        #expect(DockPins([mail, safari, mail]).apps == [mail, safari])
    }

    @Test func pinAddsAtTheEndOrAtAnIndex() {
        var pins = DockPins([mail])
        pins.pin(safari)
        pins.pin(notes, at: 0)
        #expect(pins.apps == [notes, mail, safari])
    }

    @Test func pinningAPinnedAppMovesIt() {
        var pins = DockPins([mail, safari, notes])
        pins.pin(mail, at: 3)
        #expect(pins.apps == [safari, notes, mail])
        pins.pin(notes)
        #expect(pins.apps == [safari, mail, notes])
    }

    @Test func unpinRemoves() {
        var pins = DockPins([mail, safari])
        pins.unpin(mail)
        #expect(pins.apps == [safari])
        #expect(!pins.contains(mail))
    }

    @Test func moveDropsBeforeTheDestination() {
        var pins = DockPins([mail, safari, notes])
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

@Suite struct DockStoreTests {
    @Test func startsFromTheSystemDockWithoutFinderOrExplorer() {
        let store = DockStore(defaults: freshDefaults(), systemApps: { [explorer, finder, mail, safari] })
        #expect(store.pins.apps == [mail, safari])
    }

    @Test func changesAreSavedAndOutliveTheSystemDock() {
        let defaults = freshDefaults()
        var system = [mail, safari]
        let store = DockStore(defaults: defaults, systemApps: { system })
        store.move(from: 1, to: 0)
        store.pin(notes)
        store.unpin(mail)
        system = []
        #expect(store.pins.apps == [safari, notes])
        let reopened = DockStore(defaults: defaults, systemApps: { [] })
        #expect(reopened.pins.apps == [safari, notes])
        #expect(reopened.isPinned(notes))
    }

    @Test func finderAndExplorerCantBePinned() {
        let store = DockStore(defaults: freshDefaults(), systemApps: { [] })
        store.pin(finder)
        store.pin(explorer)
        #expect(store.pins.apps.isEmpty)
    }

    @Test func emptyingTheDockIsKept() {
        let defaults = freshDefaults()
        let store = DockStore(defaults: defaults, systemApps: { [mail] })
        store.unpin(mail)
        #expect(DockStore(defaults: defaults, systemApps: { [mail] }).pins.apps.isEmpty)
    }
}

@Suite struct DockLayoutTests {
    @Test func explorerFirstThenPinnedThenRunningThenStacks() {
        let tiles = DockLayout.tiles(pinned: [mail, safari], running: [safari, notes, finder])
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
        let tiles = DockLayout.tiles(pinned: [mail], running: [mail, explorer, finder])
        #expect(tiles == [.explorer, .app(mail, isPinned: true, isRunning: true), .separator, .downloads, .trash])
    }

    @Test func finderNeverShowsEvenIfPinned() {
        let tiles = DockLayout.tiles(pinned: [finder, mail], running: [])
        #expect(!tiles.contains { $0.app?.bundleID == "com.apple.finder" })
    }
}

@Suite struct DockGeometryTests {
    @Test func iconSizeIsClamped() {
        #expect(DockGeometry(iconSize: 4).iconSize == 32)
        #expect(DockGeometry(iconSize: 500).iconSize == 96)
    }

    @Test func tilesSitSideBySideWithNarrowSeparators() {
        let geometry = DockGeometry(iconSize: 48)
        let tiles: [DockTile] = [.explorer, .app(mail, isPinned: true, isRunning: false), .separator, .trash]
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
        let geometry = DockGeometry(iconSize: 48)
        let tiles: [DockTile] = [.explorer, .separator, .trash]
        let frames = geometry.frames(for: tiles)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[0].midX, y: 10), tiles: tiles) == 0)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[1].midX, y: 10), tiles: tiles) == nil)
        #expect(geometry.tileIndex(at: CGPoint(x: frames[2].midX, y: 10), tiles: tiles) == 2)
        #expect(geometry.tileIndex(at: CGPoint(x: -5, y: 10), tiles: tiles) == nil)
    }

    @Test func insertionIndexCountsIconsOnTheLeft() {
        let frames = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 50, y: 0, width: 50, height: 50)]
        #expect(DockGeometry.insertionIndex(forX: 10, pinnedFrames: frames) == 0)
        #expect(DockGeometry.insertionIndex(forX: 30, pinnedFrames: frames) == 1)
        #expect(DockGeometry.insertionIndex(forX: 99, pinnedFrames: frames) == 2)
    }

    @Test func optionsAreSavedAsJSON() throws {
        var options = DockOptions()
        #expect(!options.isShown)
        #expect(!options.autohides)
        options.iconSize = 64
        options.autohides = true
        let decoded = try JSONDecoder().decode(DockOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }

    @Test func optionsFromTheFirstVersionKeepTheDockShown() throws {
        let old = Data(#"{"isShown":true,"iconSize":56,"hidesSystemDock":true}"#.utf8)
        let options = try JSONDecoder().decode(DockOptions.self, from: old)
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
        // 10 tiles of 24, two separators of 16, two ends of 24: 320 long.
        #expect(SystemDockSpan.estimate(itemCount: 10, tileSize: 16, screen: screen)
                == CGFloat(575)...CGFloat(895))
        #expect(SystemDockSpan.estimate(itemCount: 10, tileSize: 16, screen: screen, edge: .left)
                == CGFloat(318)...CGFloat(638))
        #expect(SystemDockSpan.estimate(itemCount: 500, tileSize: 16, screen: screen) == 0...1470)
        let dock = FakeDock(["persistent-apps": [1, 2, 3], "persistent-others": [1], "recent-apps": [1, 2]])
        #expect(SystemDockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 4) == 2 + 3 + 1 + 2 + 4)
        dock.values["show-recents"] = false
        #expect(SystemDockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 0) == 6)
        dock.values["static-only"] = true
        #expect(SystemDockSpan.itemCount(preferences: dock, running: 6, unpinnedRunning: 0) == 8)
    }
}

@Suite struct DockStackOrderTests {
    @Test func newestFirstThenByName() {
        let now = Date()
        let order = DockStackOrder.sorted([
            (URL(fileURLWithPath: "/d/old.zip"), now.addingTimeInterval(-100)),
            (URL(fileURLWithPath: "/d/b.pdf"), nil),
            (URL(fileURLWithPath: "/d/new.dmg"), now),
            (URL(fileURLWithPath: "/d/a.pdf"), nil),
        ])
        #expect(order.map(\.lastPathComponent) == ["new.dmg", "old.zip", "a.pdf", "b.pdf"])
    }

    @Test func listsAFolderWithoutHiddenFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DockStack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }  // a scratch folder of the test's own
        try Data().write(to: folder.appendingPathComponent("file.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden"))
        #expect(DockStackOrder.contents(of: folder).map(\.lastPathComponent) == ["file.txt"])
    }
}

/// A Dock preferences domain in memory: the real Dock is never touched by tests.
private final class FakeDock: PreferenceDomain {
    var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(forKey key: String) -> Any? { values[key] }
    func setValue(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite struct SystemDockHiderTests {
    @Test func hidingSetsALongDelayAndSlowAnimationAndRestartsTheDock() {
        let dock = FakeDock(["autohide": false])
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 })
        hider.hide()
        #expect(dock.values["autohide"] as? Bool == true)
        #expect(dock.values["autohide-delay"] as? Double == 1000)
        #expect(dock.values["autohide-time-modifier"] as? Double == 1000)
        #expect(dock.values["tilesize"] as? Double == 16)
        #expect(dock.values["orientation"] as? String == "left")
        #expect(dock.values["static-only"] as? Bool == true)
        #expect(restarts == 1)
        #expect(hider.isHiding)
    }

    @Test func restoringPutsBackTheValuesFoundBefore() {
        let dock = FakeDock(["autohide": false, "autohide-time-modifier": 0.2, "tilesize": 36,
                             "orientation": "bottom"])
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 })
        hider.hide()
        hider.restore()
        #expect(dock.values["autohide"] as? Bool == false)
        #expect(dock.values["autohide-time-modifier"] as? Double == 0.2)
        #expect(dock.values["tilesize"] as? Int == 36)
        #expect(dock.values["orientation"] as? String == "bottom")
        #expect(dock.values["static-only"] == nil)
        // The delay wasn't set before, so it is removed rather than set to a value of ours.
        #expect(dock.values["autohide-delay"] == nil)
        #expect(!hider.isHiding)
        #expect(restarts == 2)
    }

    @Test func hidingTwiceKeepsTheFirstValuesAndDoesntRestartAgain() {
        let dock = FakeDock(["autohide": true, "autohide-delay": 0.5])
        let memory = freshDefaults()
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: memory, restartDock: { restarts += 1 })
        hider.hide()
        hider.hide()
        #expect(restarts == 1)
        // Another launch after a crash: the saved values are still the user's.
        SystemDockHider(dock: dock, memory: memory, restartDock: { restarts += 1 }).restore()
        #expect(dock.values["autohide"] as? Bool == true)
        #expect(dock.values["autohide-delay"] as? Double == 0.5)
        #expect(dock.values["autohide-time-modifier"] == nil)
    }

    @Test func valuesSavedByTheFirstVersionAreKept() {
        // The first version hid with two keys and saved them without marks.
        let dock = FakeDock(["autohide": true, "autohide-delay": 1000.0])
        let memory = freshDefaults()
        memory.set(["autohide": false], forKey: "SystemDockSettingsBeforeHiding")
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: memory, restartDock: { restarts += 1 })
        hider.hide()
        #expect(dock.values["autohide-time-modifier"] as? Double == 1000)
        #expect(restarts == 1)
        hider.restore()
        #expect(dock.values["autohide"] as? Bool == false)
        #expect(dock.values["autohide-delay"] == nil)
        #expect(dock.values["autohide-time-modifier"] == nil)
    }

    @Test func restoringWithoutHidingDoesNothing() {
        let dock = FakeDock(["autohide": true])
        var restarts = 0
        SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 }).restore()
        #expect(dock.values["autohide"] as? Bool == true)
        #expect(restarts == 0)
    }
}

/// launchctl is never run by tests: the commands are only recorded.
@Suite struct SystemDockAgentTests {
    final class Fake {
        var running = true
        var commands: [[String]] = []
        var status: Int32 = 0
    }

    func agent(_ fake: Fake, memory: UserDefaults) -> SystemDockAgent {
        SystemDockAgent(uid: 501, memory: memory, isDockRunning: { fake.running }, launchctl: { arguments in
            fake.commands.append(arguments)
            if fake.status == 0 { fake.running = arguments[0] != "bootout" ? true : false }
            return fake.status
        })
    }

    @Test func stoppingBootsTheJobOutForThisSession() {
        let fake = Fake()
        let dock = agent(fake, memory: freshDefaults())
        dock.stop()
        #expect(fake.commands == [["bootout", "gui/501/com.apple.Dock.agent"]])
        #expect(dock.isStopped)
        #expect(!fake.running)
    }

    @Test func startingLoadsAndKicksTheJob() {
        let fake = Fake()
        let dock = agent(fake, memory: freshDefaults())
        dock.stop()
        dock.start()
        #expect(fake.commands.dropFirst().map { $0 } == [
            ["bootstrap", "gui/501", "/System/Library/LaunchAgents/com.apple.Dock.plist"],
            ["kickstart", "gui/501/com.apple.Dock.agent"],
        ])
        #expect(!dock.isStopped)
        #expect(fake.running)
    }

    @Test func aDockWeDidntStopIsLeftAlone() {
        let fake = Fake()
        agent(fake, memory: freshDefaults()).start()
        #expect(fake.commands.isEmpty)
    }

    @Test func aRefusedStopIsntRemembered() {
        let fake = Fake()
        fake.status = 150
        let dock = agent(fake, memory: freshDefaults())
        dock.stop()
        #expect(!dock.isStopped)
    }

    @Test func afterALogOutTheDockIsStoppedAgain() {
        let fake = Fake()
        let memory = freshDefaults()
        agent(fake, memory: memory).stop()
        fake.running = true
        agent(fake, memory: memory).stop()
        #expect(fake.commands.count == 2)
        // Already stopped (crash, then a new launch): nothing to do.
        agent(fake, memory: memory).stop()
        #expect(fake.commands.count == 2)
    }
}
