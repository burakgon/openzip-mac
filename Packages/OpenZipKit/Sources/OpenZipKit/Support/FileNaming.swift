import Foundation

/// Names of files and archives: what to call the folder an archive is extracted to, and
/// how to find a name that is still free.
public enum FileNaming {
    /// Extensions made of two parts, which must be taken off and put back as one.
    private static let doubleExtensions = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.lz4", ".tar.z", ".tar.br",
    ]

    /// The extensions that mean "archive", for naming the folder an archive goes into.
    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "z", "taz", "cab", "iso", "dmg", "wim", "arj", "lzh", "lha", "cpio", "rpm", "deb", "xar",
        "pkg", "jar", "war", "ear", "apk", "ipa", "xpi", "epub", "cbz", "cbr", "cb7", "img", "vhd", "vhdx",
        "vmdk", "vdi", "qcow2", "squashfs", "chm", "msi", "nsis", "exe", "udf", "001", "esd", "swm",
    ]

    /// Splits a file name into its base and its extension, with the dot. ".tar.gz" counts
    /// as one extension. A name without one, or a hidden file such as ".zshrc", has none.
    public static func split(_ name: String) -> (base: String, extension: String) {
        let lower = name.lowercased()
        for double in doubleExtensions where lower.hasSuffix(double) && lower.count > double.count {
            return (String(name.dropLast(double.count)), String(name.suffix(double.count)))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        let ext = name[dot...]
        // "Version 1.2 notes" has a dot, and no extension.
        guard !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    /// The name of an archive without what makes it an archive: "Photos.zip" and
    /// "Photos.part1.rar" and "Photos.7z.001" are all "Photos".
    public static func archiveBaseName(_ name: String) -> String {
        let (first, ext) = split(name)
        let lower = ext.lowercased()
        guard !ext.isEmpty,
              archiveExtensions.contains(String(lower.dropFirst())) || lower.hasPrefix(".tar.") || isVolumeNumber(lower)
        else { return name }
        // The pieces of a split archive have a second extension: ".7z.001", ".part1.rar".
        var base = first
        while true {
            let (inner, innerExtension) = split(base)
            let innerLower = innerExtension.lowercased()
            guard !innerExtension.isEmpty, !inner.isEmpty,
                  archiveExtensions.contains(String(innerLower.dropFirst())) || isPartNumber(innerLower)
            else { break }
            base = inner
        }
        return base.isEmpty ? name : base
    }

    /// ".001", ".002"…
    private static func isVolumeNumber(_ ext: String) -> Bool {
        let digits = ext.dropFirst()
        return digits.count == 3 && digits.allSatisfy(\.isNumber)
    }

    /// ".part1", ".part01"…
    private static func isPartNumber(_ ext: String) -> Bool {
        guard ext.hasPrefix(".part") else { return false }
        let digits = ext.dropFirst(5)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// A location with this name that is free: the one given, or "Name 2", "Name 3"… the
    /// way the Finder counts.
    public static func uniqueURL(for url: URL, isTaken: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard isTaken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let (base, ext) = split(url.lastPathComponent)
        var number = 2
        while true {
            let candidate = folder.appending(path: "\(base) \(number)\(ext)")
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// The first piece of a split archive, given any of its pieces: it is the one that
    /// has to be opened. Returns the URL itself for everything else.
    public static func firstVolume(of url: URL) -> URL {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let lower = name.lowercased()
        let candidate: String?

        if let match = lower.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
            // "name.part03.rar": the same number of digits, counting from one.
            let digits = lower[match].dropFirst(5).dropLast(4)
            let first = String(repeating: "0", count: digits.count - 1) + "1"
            candidate = String(name[..<match.lowerBound]) + ".part" + first + ".rar"
        } else if lower.range(of: #"\.z\d\d$"#, options: .regularExpression) != nil {
            // A zip in pieces ends in "name.zip", after "name.z01", "name.z02"…
            candidate = String(name.dropLast(4)) + ".zip"
        } else if lower.range(of: #"\.[r-y]\d\d$"#, options: .regularExpression) != nil {
            // The old RAR naming: "name.rar", then "name.r00", "name.r01"…
            candidate = String(name.dropLast(4)) + ".rar"
        } else if lower.range(of: #"\.\d\d\d$"#, options: .regularExpression) != nil {
            candidate = String(name.dropLast(4)) + ".001"
        } else {
            candidate = nil
        }

        guard let candidate, candidate != name else { return url }
        let first = folder.appending(path: candidate)
        return FileManager.default.fileExists(atPath: first.path) ? first : url
    }

    /// Whether a name is one of the files macOS leaves around, which nobody packs on purpose.
    public static func isMacMetadata(name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }
}

/// A new, empty folder for work in progress.
public struct WorkDirectory: Sendable {
    public let url: URL

    /// Makes one on the volume of `url`, so that moving what was made into place is a
    /// rename and not a copy.
    public static func make(near url: URL) throws -> WorkDirectory {
        let files = FileManager.default
        var anchor = url.standardizedFileURL
        while !files.fileExists(atPath: anchor.path), anchor.path != "/" {
            anchor.deleteLastPathComponent()
        }
        if let folder = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor, create: true) {
            return WorkDirectory(url: folder)
        }
        // Volumes that have no place for temporary items: a hidden folder next to the target.
        var isDirectory: ObjCBool = false
        files.fileExists(atPath: anchor.path, isDirectory: &isDirectory)
        let parent = isDirectory.boolValue ? anchor : anchor.deletingLastPathComponent()
        let folder = parent.appending(path: ".OpenZip-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        return WorkDirectory(url: folder)
    }

    /// One in the system's temporary folder, for work that ends up nowhere in particular.
    public static func makeTemporary() throws -> WorkDirectory {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "OpenZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WorkDirectory(url: folder)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
