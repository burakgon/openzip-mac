import Foundation

/// The mark macOS puts on files that came from somewhere else, such as a download. A file
/// that carries it is checked by Gatekeeper before it runs.
public enum Quarantine {
    private static let attribute = "com.apple.quarantine"

    /// The mark of a file, if it has one.
    public static func mark(of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read > 0 ? data.prefix(read) : nil
        }
    }

    /// Puts a mark on a file, or on a folder and everything in it.
    ///
    /// What comes out of a downloaded archive is as much a download as the archive was.
    /// Without this an app could be smuggled past Gatekeeper by zipping it.
    public static func apply(_ mark: Data, to url: URL) {
        set(mark, on: url)
        for relative in Directory.walk(url) {
            set(mark, on: url.appending(path: relative))
        }
    }

    private static func set(_ mark: Data, on url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            mark.withUnsafeBytes { bytes in
                _ = setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
    }
}

/// AppleDouble files: where everything about a Mac file that a foreign format cannot hold
/// goes. A zip made by the Finder keeps them in a "__MACOSX" folder next to the files, tar
/// puts a "._name" beside each "name". They carry extended attributes, Finder tags and
/// resource forks.
public enum AppleDouble {
    /// Folds the AppleDouble files in `root` back into the files they belong to and removes
    /// them, the way the Finder's own unarchiver does. Returns how many were applied.
    @discardableResult
    public static func merge(in root: URL) -> Int {
        let files = FileManager.default
        var merged = 0

        // The Finder's way: a parallel tree under __MACOSX.
        let shadow = root.appending(path: "__MACOSX", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: shadow.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for relative in Directory.walk(shadow) {
                let name = (relative as NSString).lastPathComponent
                guard name.hasPrefix("._"), name.utf8.count > 2 else { continue }
                let folder = (relative as NSString).deletingLastPathComponent
                let target = root.appending(path: folder).appending(path: String(name.dropFirst(2)))
                if apply(shadow.appending(path: relative), to: target) { merged += 1 }
            }
            try? files.removeItem(at: shadow)
        }

        // tar's way: "._name" next to "name".
        let sidecars = Directory.walk(root).filter { ($0 as NSString).lastPathComponent.hasPrefix("._") }
        for relative in sidecars {
            let sidecar = root.appending(path: relative)
            let name = sidecar.lastPathComponent
            guard name.utf8.count > 2 else { continue }
            let target = sidecar.deletingLastPathComponent().appending(path: String(name.dropFirst(2)))
            // A "._name" that is not AppleDouble, or has no file to belong to, is somebody's file.
            guard exists(target), isAppleDouble(sidecar) else { continue }
            if apply(sidecar, to: target) { merged += 1 }
            try? files.removeItem(at: sidecar)
        }
        return merged
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// AppleDouble files start with the magic number 0x00051607.
    static func isAppleDouble(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return false }
        return magic.elementsEqual([0x00, 0x05, 0x16, 0x07])
    }

    private static func apply(_ sidecar: URL, to target: URL) -> Bool {
        guard exists(target), isAppleDouble(sidecar) else { return false }
        let flags = copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_NOFOLLOW | COPYFILE_ACL | COPYFILE_XATTR)
        return copyfile(sidecar.path, target.path, nil, flags) == 0
    }

    /// The AppleDouble companions an archive has for the given entries: when only some
    /// files are extracted, theirs have to come along to be folded in.
    static func companions(of paths: [String], in existing: Set<String>) -> [String] {
        var result: [String] = []
        for path in paths {
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let sidecar = folder.isEmpty ? "._\(name)" : "\(folder)/._\(name)"
            for candidate in ["__MACOSX/\(sidecar)", sidecar, "__MACOSX/\(path)"] where existing.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }
}

/// Makes files appear in a second place without copying their data, to give 7-Zip a
/// folder that looks the way the archive should.
///
/// 7-Zip stores a file under the path it was given, relative to the folder it runs in.
/// There is no switch for "put this file into that folder of the archive", so the folder
/// is built on disk first: as clones on APFS, which take no time and no space, as hard
/// links elsewhere, and as copies only where neither exists.
enum Staging {
    /// - Parameters:
    ///   - followLinks: Put what a symbolic link points to in its place, for archives that
    ///     are to hold the files and not the links.
    ///   - patterns: Names to leave out inside folders.
    static func stage(
        _ source: URL, at destination: URL, followLinks: Bool = false, excluding patterns: [String] = [], depth: Int = 0
    ) throws {
        var info = stat()
        let found = followLinks ? stat(source.path, &info) : lstat(source.path, &info)
        guard found == 0 else {
            // A link that points nowhere has nothing to put in its place.
            if followLinks, depth > 0 { return }
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let files = FileManager.default
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // Links can lead in circles once they are followed.
            guard depth < 64 else { return }
            try files.createDirectory(at: destination, withIntermediateDirectories: false)
            for name in try Directory.names(in: source) where !Wildcard.matches(name, anyOf: patterns) {
                try stage(
                    source.appending(path: name), at: destination.appending(path: name),
                    followLinks: followLinks, excluding: patterns, depth: depth + 1
                )
            }
            // The folder's own dates and permissions, once nothing more is written into it.
            _ = copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_STAT))
        case S_IFLNK:
            let target = try files.destinationOfSymbolicLink(atPath: source.path)
            try files.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        case S_IFREG:
            if clonefile(source.path, destination.path, 0) == 0 { return }
            if link(source.path, destination.path) == 0 { return }
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        default:
            // Sockets, pipes and devices do not belong in an archive.
            break
        }
    }
}
