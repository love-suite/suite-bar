import AppKit
import SuiteCore
import SuiteFilesCore

/// Files dropped on the Downloads stack, as Explorer handles a drop: moved from the same disk, copied from
/// another (Option copies); a name already taken asks whether to replace (the old item goes to the
/// Trash), skip or keep both, for all the items if wanted.
enum BarDrop {
    enum Choice { case replace, skip, keepBoth }

    static func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Windows' rule: on the same volume a drop moves, onto another volume it copies.
    private static func moves(_ urls: [URL], into folder: URL, info: NSDraggingInfo) -> Bool {
        let mask = info.draggingSourceOperationMask
        guard mask.contains(.move) || mask.contains(.generic) else { return false }
        let target = volume(of: folder)
        return target != nil && urls.allSatisfy { volume(of: $0)?.isEqual(target) == true }
    }

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// The operation to show while hovering; none if the drop would change nothing.
    static func dragOperation(for info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let urls = fileURLs(in: info)
        guard !urls.isEmpty else { return [] }
        if moves(urls, into: folder, info: info) {
            let folderPath = folder.standardizedFileURL.path
            if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }) { return [] }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .generic
        }
        return .copy
    }

    /// Moves or copies the dropped files into `folder`; returns their new locations.
    @discardableResult
    static func perform(_ info: NSDraggingInfo, into folder: URL) -> [URL] {
        let urls = fileURLs(in: info)
        let move = moves(urls, into: folder, info: info)
        let folderPath = folder.standardizedFileURL.path
        var choiceForAll: Choice?
        var done: [URL] = []
        for url in urls {
            let sourcePath = url.standardizedFileURL.path
            if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") { continue }
            let sameFolder = url.deletingLastPathComponent().standardizedFileURL.path == folderPath
            if move && sameFolder { continue }
            var target = folder.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    let choice: Choice
                    if sameFolder {
                        choice = .keepBoth
                    } else if let choiceForAll {
                        choice = choiceForAll
                    } else {
                        let (asked, forAll) = askAboutConflict(existing: target, remaining: urls.count > 1)
                        if forAll { choiceForAll = asked }
                        choice = asked
                    }
                    switch choice {
                    case .skip: continue
                    case .replace: _ = try SuiteTrash.moveToTrash(target)
                    case .keepBoth: target = uniqueDestination(named: url.lastPathComponent, in: folder)
                    }
                }
                if move { try FileManager.default.moveItem(at: url, to: target) }
                else { try FileManager.default.copyItem(at: url, to: target) }
                done.append(target)
            } catch {
                BarFiles.showError(error.localizedDescription)
                break
            }
        }
        return done
    }

    private static func askAboutConflict(existing: URL, remaining: Bool) -> (Choice, Bool) {
        let alert = NSAlert()
        alert.messageText = String(format: T("The destination already has an item named \u{201C}%@\u{201D}."),
                                   existing.lastPathComponent)
        alert.informativeText = T("Replace it (the old one goes to the Trash), skip this item, or keep both?")
        alert.addButton(withTitle: T("Replace"))
        alert.addButton(withTitle: T("Skip"))
        alert.addButton(withTitle: T("Keep Both"))
        if remaining {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = T("Do this for all conflicts")
        }
        NSApp.activate(ignoringOtherApps: true)
        let choice: Choice
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .replace
        case .alertSecondButtonReturn: choice = .skip
        default: choice = .keepBoth
        }
        return (choice, alert.suppressionButton?.state == .on)
    }
}

extension BarDrop {
    /// `name` in `folder`, or "name (2)", "name (3)" and so on, as Explorer names a kept copy.
    static func uniqueDestination(named name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
