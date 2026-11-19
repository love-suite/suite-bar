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
        #expect(options.hidesSystemDock)
        options.iconSize = 64
        let decoded = try JSONDecoder().decode(DockOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
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
    @Test func hidingSetsALongAutohideDelayAndRestartsTheDock() {
        let dock = FakeDock(["autohide": false])
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 })
        hider.hide()
        #expect(dock.values["autohide"] as? Bool == true)
        #expect((dock.values["autohide-delay"] as? Double) == SystemDockHider.hiddenDelay)
        #expect(restarts == 1)
        #expect(hider.isHiding)
    }

    @Test func restoringPutsBackTheValuesFoundBefore() {
        let dock = FakeDock(["autohide": false])
        var restarts = 0
        let hider = SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 })
        hider.hide()
        hider.restore()
        #expect(dock.values["autohide"] as? Bool == false)
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
    }

    @Test func restoringWithoutHidingDoesNothing() {
        let dock = FakeDock(["autohide": true])
        var restarts = 0
        SystemDockHider(dock: dock, memory: freshDefaults(), restartDock: { restarts += 1 }).restore()
        #expect(dock.values["autohide"] as? Bool == true)
        #expect(restarts == 0)
    }
}
