import Foundation

/// Changes to an archive that exists: none of them extracts it. 7-Zip writes a new archive
/// next to the old one, copies what stays as it is, compressed, and swaps the two at the end.
extension ArchiveEngine {
    private enum Backend {
        case sevenZip
        case compressedTar(String)
        case rar
    }

    private func backend(for info: ArchiveInfo, at url: URL) throws -> Backend {
        switch editability(of: info, at: url) {
        case .editable:
            break
        case .needsRar:
            throw ArchiveError.toolMissing("RAR")
        case .readOnly(let reason):
            throw ArchiveError.unsupported(reason)
        }
        let type = info.type.lowercased()
        if type == "rar" || type == "rar5" { return .rar }
        if !info.compression.isEmpty { return .compressedTar(info.compression.lowercased()) }
        return .sevenZip
    }

    /// Removes entries. A folder goes with everything in it.
    public func delete(
        _ paths: [String], from archive: URL, info: ArchiveInfo, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws {
        guard !paths.isEmpty else { return }
        switch try backend(for: info, at: archive) {
        case .rar:
            try await rarDelete(paths, from: archive, password: password, control: control, progress: progress)
        case .compressedTar(let compression):
            _ = try await modifyCompressedTar(archive, compression: compression, control: control, progress: progress) { tar in
                try await sevenZipDelete(paths, from: tar, password: nil, control: control, progress: progress)
            }
        case .sevenZip:
            _ = try await sevenZipDelete(paths, from: archive, password: password, control: control, progress: progress)
        }
    }

    private func sevenZipDelete(
        _ paths: [String], from archive: URL, password: String?, control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        let list = try Self.writeList(paths, in: scratch.url)
        var arguments = ["d", "-y", "-bb1", "-bsp1", "-sccUTF-8", "-scsUTF-8", "-spd", "-i@\(list.path)"]
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        return try await runEdit(arguments, password: password, control: control, progress: progress)
    }

    /// Renames or moves entries: a move is a rename to a path in another folder. A folder
    /// takes everything in it along.
    public func rename(
        _ changes: [(from: String, to: String)], in archive: URL, info: ArchiveInfo, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws {
        let changes = changes.filter { $0.from != $0.to && !$0.from.isEmpty && !$0.to.isEmpty }
        guard !changes.isEmpty else { return }
        switch try backend(for: info, at: archive) {
        case .rar:
            try await rarRename(changes, in: archive, password: password, control: control, progress: progress)
        case .compressedTar(let compression):
            _ = try await modifyCompressedTar(archive, compression: compression, control: control, progress: progress) { tar in
                try await sevenZipRename(changes, in: tar, password: nil, control: control, progress: progress)
            }
        case .sevenZip:
            _ = try await sevenZipRename(changes, in: archive, password: password, control: control, progress: progress)
        }
    }

    private func sevenZipRename(
        _ changes: [(from: String, to: String)], in archive: URL, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        // The pairs have to be arguments, 7-Zip takes them from nowhere else, and a command
        // line has a limit. Many renames are done in several runs.
        var report = OperationReport()
        var batch: [String] = []
        var size = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            var arguments = ["rn", "-y", "-bb1", "-bsp1", "-sccUTF-8", "-spd"]
            if password?.isEmpty == false { arguments.append("-p") }
            arguments += ["--", archive.path] + batch
            report = try await runEdit(arguments, password: password, control: control, progress: progress)
            batch = []
            size = 0
        }
        for change in changes {
            batch += [change.from, change.to]
            size += change.from.utf8.count + change.to.utf8.count + 2
            if size > 120_000 { try await flush() }
        }
        try await flush()
        return report
    }

    /// Adds an empty folder.
    public func createFolder(
        _ path: String, in archive: URL, info: ArchiveInfo, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws {
        let path = path.split(separator: "/").joined(separator: "/")
        guard !path.isEmpty else { return }
        let backend = try backend(for: info, at: archive)

        // An empty folder on disk with the path the one in the archive is to have.
        let staging = try WorkDirectory.makeTemporary()
        defer { staging.remove() }
        try FileManager.default.createDirectory(at: staging.url.appending(path: path, directoryHint: .isDirectory), withIntermediateDirectories: true)

        switch backend {
        case .rar:
            try await rarAddStaged(path, from: staging.url, to: archive, password: password, control: control, progress: progress)
        case .compressedTar(let compression):
            _ = try await modifyCompressedTar(archive, compression: compression, control: control, progress: progress) { tar in
                try await addStaged(path, from: staging.url, to: tar, type: "tar", password: nil, control: control, progress: progress)
            }
        case .sevenZip:
            _ = try await addStaged(path, from: staging.url, to: archive, type: nil, password: password, control: control, progress: progress)
        }
    }

    private func addStaged(
        _ path: String, from staging: URL, to archive: URL, type: String?, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let list = try Self.writeList([path], in: staging, name: ".openzip-names.txt")
        var arguments = ["a", "-y", "-bb1", "-bsp1", "-sccUTF-8", "-scsUTF-8", "-spd", "-i@\(list.path)"]
        if let type { arguments.append("-t\(type)") }
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        return try await runEdit(arguments, directory: staging, password: password, control: control, progress: progress)
    }

    private func runEdit(
        _ arguments: [String], directory: URL? = nil, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let output = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run(
            [sevenZip(arguments, directory: directory, input: Self.passwordInput(password))], control: control
        ) { _, data in
            let update: OperationProgress? = output.with { state in
                guard state.feed(data) else { return nil }
                return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
            }
            if let update { progress?(update) }
        }
        return try Self.evaluate(codes, output.current, hadPassword: password?.isEmpty == false, partial: false)
    }

    /// Sets the comment of an archive. Zip and RAR have one.
    public func setComment(
        _ comment: String, of archive: URL, info: ArchiveInfo, password: String? = nil,
        control: OperationControl? = nil
    ) async throws {
        switch info.type.lowercased() {
        case "zip":
            guard !info.isMultiVolume, !info.isSelfExtracting else {
                throw ArchiveError.unsupported("The comment of this archive cannot be changed.")
            }
            try ZipComment.write(comment, to: archive)
        case "rar", "rar5":
            try await rarSetComment(comment, of: archive, password: password, control: control)
        default:
            throw ArchiveError.unsupported("\(info.displayType) archives have no comment.")
        }
    }
}

/// The comment of a zip archive: text at the very end of the file, after the directory.
/// 7-Zip reads it and has no command to write it, so this does.
enum ZipComment {
    /// A zip ends with a record that starts with these four bytes. Its last field is the
    /// length of the comment, which follows and runs to the end of the file.
    private static let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let recordSize = 22

    static func write(_ comment: String, to archive: URL) throws {
        let text = Data(comment.utf8)
        guard text.count <= 0xFFFF else {
            throw ArchiveError.unsupported("A zip comment can be 65,535 bytes at most.")
        }
        let handle = try FileHandle(forUpdating: archive)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        // The record is searched for from the end, in the last 64 KB plus its own size.
        let window = min(size, UInt64(0xFFFF + recordSize))
        try handle.seek(toOffset: size - window)
        guard let tail = try handle.read(upToCount: Int(window)) else { throw ArchiveError.notAnArchive }
        let bytes = [UInt8](tail)
        var found: Int?
        var index = bytes.count - recordSize
        while index >= 0 {
            if bytes[index] == signature[0], bytes[index + 1] == signature[1], bytes[index + 2] == signature[2], bytes[index + 3] == signature[3] {
                // The real one says exactly how much comment follows it.
                let length = Int(bytes[index + 20]) | Int(bytes[index + 21]) << 8
                if index + recordSize + length == bytes.count {
                    found = index
                    break
                }
            }
            index -= 1
        }
        guard let found else { throw ArchiveError.damaged("The end of the zip archive was not found.") }

        let lengthOffset = size - window + UInt64(found) + 20
        try handle.seek(toOffset: lengthOffset)
        try handle.write(contentsOf: Data([UInt8(text.count & 0xFF), UInt8(text.count >> 8)]) + text)
        try handle.truncate(atOffset: lengthOffset + 2 + UInt64(text.count))
        try handle.synchronize()
    }
}
