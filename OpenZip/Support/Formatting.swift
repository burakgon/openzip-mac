import AppKit
import OpenZipKit
import UniformTypeIdentifiers

enum Formatting {
    /// The language of the app with the conventions of the user's region: where the Mac
    /// is set to Turkish, English month names, with the 24-hour clock, the decimal comma
    /// and the percent sign in front that the region is used to. This is what macOS itself
    /// shows when its language is English and its region is not. Numbers and dates in the
    /// Mac's own language next to English words would read like a mistake.
    static let locale = Locale(identifier: Demo.value("--locale") ?? "en_\(Locale.current.region?.identifier ?? "US")")

    static func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted(.number.locale(locale))) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A date the way the Finder's list shows it: "Today at 14:32", "Yesterday at 09:10",
    /// then "12 Mar 2026 at 18:00".
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))) at \(time)"
    }

    /// How much smaller the packed data is than the original: "62%" saved.
    static func saving(packed: UInt64, size: UInt64) -> String? {
        guard size > 0, packed > 0, packed < size else { return nil }
        return percent(1 - Double(packed) / Double(size))
    }

    /// The packed size as a share of the original, as WinRAR's "Ratio" column has it.
    static func ratio(packed: UInt64, size: UInt64) -> String {
        guard size > 0, packed > 0 else { return "—" }
        return percent(Double(packed) / Double(size))
    }

    /// "2 folders, 14 files": what a folder or a selection holds.
    static func contents(files: Int, folders: Int) -> String {
        switch (files, folders) {
        case (0, 0): "Empty"
        case (_, 0): count(files, "file")
        case (0, _): count(folders, "folder")
        default: "\(count(folders, "folder")), \(count(files, "file"))"
        }
    }

    /// "about 2 minutes left", for the time an operation still needs.
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int(seconds / 5) * 5) seconds left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(count(minutes, "minute")) left" }
        let hours = minutes / 60
        return "about \(count(hours, "hour")) \(count(minutes % 60, "minute")) left"
    }

    /// A location for people: "Downloads", "Desktop — Projects" with the home folder cut off.
    static func folder(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "Home" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

/// Icons and descriptions for files that exist only as names in an archive: both come
/// from the extension, and are looked up once per extension.
enum FileIcons {
    private static var icons: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]
    private static var archiveCache: [String: Bool] = [:]

    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let document = NSWorkspace.shared.icon(for: .data)

    static func icon(for name: String, isDirectory: Bool) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            // An app or another package is a folder in the archive and has its own icon.
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .package) else { return folder }
            return cached(ext) { NSWorkspace.shared.icon(for: type) }
        }
        guard !ext.isEmpty else { return document }
        return cached(ext) { UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? document }
    }

    private static func cached(_ key: String, make: () -> NSImage) -> NSImage {
        if let icon = icons[key] { return icon }
        let icon = make()
        icons[key] = icon
        return icon
    }

    static func kind(for name: String, isDirectory: Bool, isLink: Bool = false) -> String {
        if isLink { return "Alias" }
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .package) else { return "Folder" }
            return type.localizedDescription ?? "Package"
        }
        guard !ext.isEmpty else { return "Document" }
        if let kind = kinds[ext] { return kind }
        let type = UTType(filenameExtension: ext)
        // The Finder's own words first; then the type's; and a type nobody has heard of is
        // described by its extension, as the Finder does.
        let kind = finderKinds.kind(forExtension: ext)
            ?? type.flatMap { $0.identifier.hasPrefix("dyn.") ? nil : $0.localizedDescription }
            ?? "\(ext.uppercased()) file"
        kinds[ext] = kind
        return kind
    }

    private static let finderKinds: KindLookup = LaunchServicesKinds()

    /// Whether a name looks like an archive that can be opened in a window of its own.
    static func isArchive(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".tar.zst") { return true }
        let ext = (lower as NSString).pathExtension
        return archiveExtensions.contains(ext)
    }

    static let archiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "z", "cab", "iso", "wim", "arj", "lzh", "lha", "cpio", "rpm", "deb", "xar", "jar", "war",
        "001", "cbz", "cbr", "cb7", "apk", "ipa", "xpi", "whl", "nupkg", "squashfs", "vhd", "vhdx", "vmdk",
    ]
}

/// What the Finder calls files of an extension: "Plain Text Document", where the type
/// itself only says "text".
private protocol KindLookup {
    func kind(forExtension ext: String) -> String?
}

/// Launch Services still has the words; the function that hands them out has been
/// deprecated for years without a replacement that works for a file that does not exist.
/// It is reached through the protocol so that the one deprecation does not show up as a
/// warning in every build.
private struct LaunchServicesKinds: KindLookup {
    @available(macOS, deprecated: 10.10)
    func kind(forExtension ext: String) -> String? {
        var kind: Unmanaged<CFString>?
        guard LSCopyKindStringForTypeInfo(OSType(kLSUnknownType), OSType(kLSUnknownCreator), ext as CFString, &kind) == noErr else { return nil }
        let text = kind?.takeRetainedValue() as String?
        return text?.isEmpty == false ? text : nil
    }
}
