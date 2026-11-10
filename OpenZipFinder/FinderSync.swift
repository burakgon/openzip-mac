import Cocoa
import FinderSync

/// The "OpenZip" entries in the Finder's context menu.
///
/// The extension does no work itself. It tells the app which files were chosen and what
/// to do with them, as an openzip: URL, and the app does it. That keeps the extension as
/// small as macOS wants extensions to be, and all the code that touches archives in one place.
///
/// The Finder reaches an extension over XPC, on a queue of its own and not on the main
/// thread. Menus are an AppKit matter and are built on the main thread, which the
/// extension has and does nothing else with.
nonisolated final class FinderSync: FIFinderSync {
    private enum Command: Int {
        case extractHere = 1, extractToFolder, extractTo, open, test
        case compressZip = 10, compress7z, compressWith
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "z", "cab", "iso", "wim", "arj", "lzh", "lha", "cpio", "rpm", "deb", "xar", "jar", "war",
        "001", "cbz", "cbr", "cb7", "apk", "ipa", "xpi", "dmg", "pkg", "msi",
    ]

    override init() {
        super.init()
        // Everywhere: the menu is wanted wherever files are.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty
        else { return nil }
        return Self.onMain { Unchecked(Self.makeMenu(for: urls)) }.value
    }

    /// Runs a piece of main-actor code from the queue the Finder calls on, and waits for it.
    private static func onMain<Result: Sendable>(_ work: @MainActor () -> Result) -> Result {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    @MainActor private static func makeMenu(for urls: [URL]) -> NSMenu {

        let submenu = NSMenu(title: "OpenZip")
        func add(_ title: String, _ symbol: String, _ command: Command) {
            let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
            item.tag = command.rawValue
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            submenu.addItem(item)
        }

        // The entries for archives, when everything chosen is one.
        if urls.allSatisfy(isArchive) {
            let name = baseName(of: urls[0])
            add("Extract Here", "square.and.arrow.down", .extractHere)
            add(urls.count == 1 ? "Extract to “\(name)”" : "Extract Each to Its Own Folder", "folder.badge.plus", .extractToFolder)
            add("Extract to…", "folder", .extractTo)
            add("Open in OpenZip", "macwindow", .open)
            add("Test", "checkmark.shield", .test)
            submenu.addItem(.separator())
        }
        let name = urls.count == 1 ? baseName(of: urls[0], keepingFolderDots: true) : "Archive"
        add("Compress to “\(name).zip”", "doc.zipper", .compressZip)
        add("Compress to “\(name).7z”", "doc.zipper", .compress7z)
        add("Compress…", "slider.horizontal.3", .compressWith)

        let menu = NSMenu(title: "")
        let root = NSMenuItem(title: "OpenZip", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        let item = Unchecked(sender)
        let tag = Self.onMain { item.value.tag }
        guard let command = Command(rawValue: tag),
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty
        else { return }

        var components = URLComponents()
        components.scheme = "openzip"
        var items = urls.map { URLQueryItem(name: "path", value: $0.path) }
        switch command {
        case .extractHere:
            components.host = "extract"
            items.append(URLQueryItem(name: "mode", value: "here"))
        case .extractToFolder:
            components.host = "extract"
            items.append(URLQueryItem(name: "mode", value: "folder"))
        case .extractTo:
            components.host = "extract"
            items.append(URLQueryItem(name: "mode", value: "ask"))
        case .open:
            components.host = "open"
        case .test:
            components.host = "test"
        case .compressZip:
            components.host = "compress"
            items.append(URLQueryItem(name: "format", value: "zip"))
        case .compress7z:
            components.host = "compress"
            items.append(URLQueryItem(name: "format", value: "7z"))
        case .compressWith:
            components.host = "compress"
        }
        components.queryItems = items
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if archiveExtensions.contains((name as NSString).pathExtension) { return true }
        return name.range(of: #"\.(part\d+\.rar|[r-z]\d\d)$"#, options: .regularExpression) != nil
    }

    /// The name without its extension: what the folder or the archive would be called.
    private static func baseName(of url: URL, keepingFolderDots: Bool = false) -> String {
        if keepingFolderDots, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return url.lastPathComponent
        }
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? url.lastPathComponent : name
    }
}

/// Carries a value out of a main-actor block that the compiler cannot see is safe to carry.
private nonisolated struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
