import AppKit
import QuickLookThumbnailing
import SuiteCore
import SuiteFilesCore
import SuiteFilesUI

/// What the Dock does with files, without Explorer's code: opening, the Trash, thumbnails in stacks.
/// Folders open in Explorer (`ExplorerLink`); files the way the system opens them.
enum BarFiles {
    /// The Trash's folders: the home `.Trash`, iCloud Drive's, the disks' (`TrashLocations`).
    static var trash: URL { TrashLocations.url }

    /// What the Trash holds, in all its folders.
    static func trashContents() -> [URL] {
        TrashLocations.all.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
        }
    }

    /// True for an item in one of the Trash's folders.
    static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return TrashLocations.all.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Moves to the Trash with the record Explorer's Restore reads, tells Explorer (its Undo history gets
    /// it), and plays Finder's sound.
    static func moveToTrash(_ urls: [URL]) {
        var originals: [URL] = [], trashed: [URL] = []
        do {
            for url in urls {
                trashed.append(try SuiteTrash.moveToTrash(url))
                originals.append(url)
            }
        } catch {
            showError(error.localizedDescription)
        }
        if !trashed.isEmpty {
            SuiteTrash.announce(originals: originals, trashed: trashed)
            FinderSounds.play(.moveToTrash)
        }
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Explorer's setting: thumbnails in place of icons.
    static var showsThumbnails: Bool {
        SuiteDefaults.explorer.object(forKey: "ShowThumbnails") as? Bool ?? true
    }

    /// Files whose thumbnail is worth making: not folders, packages or aliases.
    static func hasThumbnail(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey, .isPackageKey])
        return values?.isDirectory != true && values?.isAliasFile != true && values?.isPackage != true
    }

    /// Makes the thumbnail in the background; `completion` runs on the main thread, only if there is one.
    static func thumbnail(for url: URL, side: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        // Drawn like an icon: a border for pictures, a page for documents.
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

/// A string of the Dock's catalog (Resources/Localizable.xcstrings).
func T(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
