import Foundation

/// Lists folders the way the file system has them.
///
/// FileManager does not: every way it has of listing a folder leaves out the names that
/// start with "._", whether or not they are the AppleDouble files it takes them for. An
/// archive tool that lists folders with it loses those files without a word, when adding
/// them and when moving what was extracted into place.
public enum Directory {
    /// The names in a folder: all of them, except "." and "..".
    public static func names(in folder: URL) throws -> [String] {
        guard let stream = opendir(folder.path) else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSFilePathErrorKey: folder.path,
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
            ])
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    /// Everything under a folder, at any depth, as paths relative to it. A folder comes
    /// before what is in it. Links are listed and not followed.
    public static func walk(_ root: URL) -> [String] {
        var result: [String] = []
        var pending = [""]
        while let relative = pending.popLast() {
            let folder = relative.isEmpty ? root : root.appending(path: relative)
            guard let names = try? names(in: folder) else { continue }
            for name in names.sorted() {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                result.append(path)
                var info = stat()
                if lstat(root.appending(path: path).path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    pending.append(path)
                }
            }
        }
        return result
    }
}
