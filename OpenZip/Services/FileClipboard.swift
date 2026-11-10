import AppKit

/// Files of an archive on the clipboard.
///
/// The clipboard holds files only as the places where they are, so what is copied out of
/// an archive is extracted first, into a folder of its own in the temporary directory.
/// That folder stays until something else is copied out of an archive, and after the app
/// has quit for as long as the clipboard still points to it: what was copied can be
/// pasted then too.
///
/// What is on the clipboard is only ever read when the user pastes. macOS asks the user
/// for permission when an app reads the clipboard on its own, and rightly so; whether
/// the clipboard has moved on is told from its count of changes, which says nothing
/// about what is on it.
enum FileClipboard {
    /// The clipboard. The demo can use one of its own instead, so that trying this from a
    /// script does not replace what its user has copied: --pasteboard name.
    static let pasteboard: NSPasteboard = {
        if Demo.isEnabled, let name = Demo.value("--pasteboard") {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }()

    private static let prefix = "OpenZip-Clipboard-"
    /// The folder with the files that are on the clipboard now.
    private static var current: URL?
    /// Where the name of that folder and the clipboard's count of changes are kept from
    /// one start of the app to the next. The count starts over when the Mac does.
    private static var folderKey: String { "clipboardFolder" + keySuffix }
    private static var countKey: String { "clipboardChangeCount" + keySuffix }
    /// The demo's own clipboard is remembered apart from the real one.
    private static var keySuffix: String {
        pasteboard === NSPasteboard.general ? "" : "." + pasteboard.name.rawValue
    }

    /// A new folder to extract into.
    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Puts names on the clipboard, one per line. Returns the clipboard's count of changes,
    /// by which a later moment can tell whether anything else has been copied since.
    @discardableResult
    static func write(names: [String]) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }

    /// Whether the clipboard still holds what it held at that count.
    static func isUnchanged(since changeCount: Int) -> Bool {
        pasteboard.changeCount == changeCount
    }

    /// Puts files on the clipboard. Each is there as a file, for the Finder and for other
    /// archives, and as its name, for wherever text is pasted.
    static func write(files: [URL], in folder: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { file in
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setString(file.lastPathComponent, forType: .string)
            return item
        })
        if let current, current != folder { try? FileManager.default.removeItem(at: current) }
        current = folder
        UserDefaults.standard.set(folder.lastPathComponent, forKey: folderKey)
        UserDefaults.standard.set(pasteboard.changeCount, forKey: countKey)
    }

    /// The files on the clipboard that exist. This reads the clipboard: it is for the
    /// moment the user pastes, and for that moment only.
    static var files: [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether there are files to paste, told from the kinds of things on the clipboard
    /// without reading them.
    static var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Removes the folders that earlier copies left behind, except the one that is still
    /// on the clipboard: the one written last, if nothing has been copied since. Called
    /// when the app starts.
    static func removeLeftovers() {
        let defaults = UserDefaults.standard
        var kept: String?
        if let name = defaults.string(forKey: folderKey), defaults.integer(forKey: countKey) == pasteboard.changeCount {
            kept = name
        } else {
            defaults.removeObject(forKey: folderKey)
            defaults.removeObject(forKey: countKey)
        }
        let temporary = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix(prefix) {
            let folder = temporary.appending(path: name, directoryHint: .isDirectory)
            if name == kept {
                current = folder
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
