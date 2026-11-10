import Foundation

/// Where the command-line programs are.
public struct Tools: Sendable, Equatable {
    /// 7-Zip's console program, which the app carries inside its bundle.
    public var sevenZip: URL
    /// RARLAB's `rar`, if it is installed. RAR archives can be read without it; creating
    /// and changing them is something only RARLAB's own program does.
    public var rar: URL?
    /// The program 7-Zip puts in front of a 7z archive to make it extract itself.
    public var sfxModule: URL?

    public init(sevenZip: URL, rar: URL? = nil, sfxModule: URL? = nil) {
        self.sevenZip = sevenZip
        self.rar = rar
        self.sfxModule = sfxModule
    }

    /// Where OpenZip keeps the `rar` it downloaded on request.
    public static var managedRarFolder: URL {
        URL.applicationSupportDirectory.appending(path: "OpenZip/RAR", directoryHint: .isDirectory)
    }

    /// Looks for `rar` where it usually is: OpenZip's own copy, Homebrew, /usr/local.
    public static func findRar() -> URL? {
        let candidates = [
            managedRarFolder.appending(path: "rar"),
            URL(filePath: "/opt/homebrew/bin/rar"),
            URL(filePath: "/usr/local/bin/rar"),
            URL(filePath: "/Applications/rar/rar"),
            URL.homeDirectory.appending(path: "bin/rar"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Whether an archive can be changed, and with what.
public enum Editability: Sendable, Equatable {
    case editable
    /// A RAR archive: it can be changed once RARLAB's `rar` is installed.
    case needsRar
    case readOnly(String)

    public var canEdit: Bool { self == .editable }
}

/// Reads, extracts, creates and changes archives by running 7-Zip (and for writing RAR,
/// RARLAB's rar) as separate processes.
///
/// A separate process has a price, a few milliseconds per operation, and buys a lot: a
/// damaged or hostile archive can at worst crash the helper, never the app; an operation
/// is stopped by ending a process; and the memory a compression needs is gone the moment
/// it is done.
public struct ArchiveEngine: Sendable {
    public var tools: Tools

    public init(tools: Tools) {
        self.tools = tools
    }

    // MARK: Commands

    func sevenZip(_ arguments: [String], directory: URL? = nil, input: Data? = nil) -> ToolCommand {
        ToolCommand(executable: tools.sevenZip, arguments: arguments, directory: directory, input: input)
    }

    /// The password as the tools read it from their standard input. Twice, because a tool
    /// that sets a password may ask for it again to be sure.
    static func passwordInput(_ password: String?) -> Data? {
        guard let password, !password.isEmpty else { return nil }
        return Data("\(password)\n\(password)\n".utf8)
    }

    /// Writes names to a file for 7-Zip to read. A selection can be hundreds of thousands
    /// of names, far more than fits on a command line, and a name in a file cannot be
    /// mistaken for a switch.
    static func writeList(_ names: [String], in folder: URL, name: String = "names.txt") throws -> URL {
        let url = folder.appending(path: name)
        // A name with a line break cannot be written this way. Such entries are left out.
        let text = names.filter { !$0.contains("\n") && !$0.isEmpty }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Listing

    /// Reads what is in an archive.
    ///
    /// Throws `ArchiveError.passwordRequired` when even the names are encrypted and no
    /// password was given. A damaged archive that can still be listed is returned, with
    /// what is wrong in `info.errors`.
    public func list(
        _ archive: URL,
        password: String? = nil,
        control: OperationControl? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> ArchiveListing {
        let parser = LockedBox(ListingParser())
        let codes = try await ToolRunner.run(
            [sevenZip(["l", "-slt", "-sccUTF-8", "-bsp0", "--", archive.path], input: Self.passwordInput(password))],
            control: control
        ) { _, data in
            parser.with { $0.feed(data) }
        }
        var parsed = parser.current
        parsed.finish()
        var listing = try Self.listing(from: parsed, exitCode: codes[0], hadPassword: password?.isEmpty == false)
        if listing.info.physicalSize == nil {
            listing.info.physicalSize = Self.fileSize(archive)
        }
        // Formats that only compress hold one file and no name for it. It is called what
        // the archive is called, less its extension.
        for index in listing.entries.indices where listing.entries[index].path.isEmpty {
            listing.entries[index].path = Self.innerName(of: archive)
        }

        // A .tar.gz is a gzip file that holds one file, a tar. What people want to see is
        // what is in the tar.
        if let layer = Self.compressedTarLayer(of: listing) {
            var inner = try await listTar(inside: archive, control: control, progress: progress)
            inner.info.compression = layer
            inner.info.type = "tar"
            inner.info.physicalSize = listing.info.physicalSize
            inner.info.warnings = listing.info.warnings + inner.info.warnings
            inner.info.errors = listing.info.errors + inner.info.errors
            listing = inner
        }
        return listing
    }

    /// The formats that compress one stream of data and know nothing of files.
    static let streamTypes: Set<String> = ["gzip", "bzip2", "xz", "zstd", "z", "lzma", "lzma86"]

    /// Whether the archive is one compressed file rather than a collection of files.
    static func isSingleStream(_ info: ArchiveInfo) -> Bool {
        info.compression.isEmpty && streamTypes.contains(info.type.lowercased())
    }

    /// The name of the file inside an archive that only compresses: "backup.tar" for
    /// "backup.tar.xz" and for "backup.txz", "notes.txt" for "notes.txt.gz".
    static func innerName(of archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        for short in [".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".taz"] where lower.hasSuffix(short) {
            return String(name.dropLast(short.count)) + ".tar"
        }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// The compression around a tar, if this listing is that of a compressed tar.
    static func compressedTarLayer(of listing: ArchiveListing) -> String? {
        let type = listing.info.type.lowercased()
        guard streamTypes.contains(type),
              listing.entries.count == 1,
              listing.entries[0].path.lowercased().hasSuffix(".tar")
        else { return nil }
        return type
    }

    private func listTar(inside archive: URL, control: OperationControl?, progress: ProgressHandler?) async throws -> ArchiveListing {
        let parser = LockedBox(ListingParser())
        let unpacking = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run([
            sevenZip(["x", "-so", "-bso2", "-bse2", "-bsp2", "--", archive.path]),
            sevenZip(["l", "-si", "-ttar", "-slt", "-sccUTF-8", "-bsp0"]),
        ], control: control) { index, data in
            if index == 1 {
                parser.with { $0.feed(data) }
            } else {
                let percent: Int? = unpacking.with { $0.feed(data) ? $0.percent : nil }
                if let percent { progress?(OperationProgress(fraction: Double(percent) / 100)) }
            }
        }
        var parsed = parser.current
        parsed.finish()
        var listing = try Self.listing(from: parsed, exitCode: codes[1], hadPassword: false)
        if codes[0] >= 2 {
            let reason = Self.classify(unpacking.current.diagnosis, exitCode: codes[0])
            if listing.entries.isEmpty { throw reason }
            listing.info.errors.append(reason.localizedDescription)
        }
        return listing
    }

    private static func listing(from parsed: ListingParser, exitCode: Int32, hadPassword: Bool) throws -> ArchiveListing {
        let text = diagnosis(parsed.messages)
        guard parsed.foundArchive else {
            if parsed.sawPasswordPrompt || text.contains("Cannot open encrypted archive") || text.contains("Wrong password") {
                throw hadPassword ? ArchiveError.wrongPassword : ArchiveError.passwordRequired
            }
            throw classify(text, exitCode: exitCode)
        }
        var info = parsed.info
        // 7-Zip asked for the password before it could list anything.
        if parsed.sawPasswordPrompt { info.hasEncryptedHeaders = true }
        if exitCode >= 2, info.errors.isEmpty {
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Errors:") && !$0.hasPrefix("Warnings:") }
            info.errors = lines.isEmpty ? ["The archive could not be read completely."] : lines
        }
        return ArchiveListing(info: info, entries: parsed.entries)
    }

    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    // MARK: Results

    /// What 7-Zip printed, without the lines it prints every time.
    static func diagnosis(_ messages: [String]) -> String {
        let routine = [
            "7-Zip", "64-bit", "32-bit", "Scanning the drive", "Listing archive", "Extracting archive",
            "Testing archive", "Open archive", "Creating archive", "Updating archive", "Path = ", "Type = ",
            "Physical Size = ", "Everything is Ok",
        ]
        return messages.filter { line in
            if routine.contains(where: { line.hasPrefix($0) }) { return false }
            // "1 file, 3014553 bytes (2944 KiB)"
            if line.first?.isNumber == true, line.contains(" bytes") { return false }
            return true
        }.joined(separator: "\n")
    }

    /// Turns the end of a run into a report or an error.
    ///
    /// With `partial`, single files that failed do not fail the whole run: they are listed
    /// in the report, which is what extracting and testing a damaged archive should do.
    static func evaluate(
        _ codes: [Int32], _ output: OperationOutput, hadPassword: Bool, partial: Bool
    ) throws -> OperationReport {
        var report = OperationReport()
        report.fileCount = output.fileCount
        let worst = codes.max() ?? 0
        let text = diagnosis(output.messages)

        if worst <= 1 {
            // 1 is 7-Zip's code for "done, but": for example a file that could not be read.
            if worst == 1 || !output.failures.isEmpty {
                report.warnings = text.isEmpty ? [] : text.split(separator: "\n").map(String.init)
            }
            report.failures = output.failures
            return report
        }
        if output.sawPasswordPrompt, !hadPassword {
            throw ArchiveError.passwordRequired
        }
        // A wrong password shows as a failure of every encrypted file. A link among them
        // fails a second time, as a link whose target could not be read.
        let passwordFailures = output.failures.filter { $0.reason.contains("Wrong password") }
        let otherFailures = output.failures.filter { !$0.reason.contains("Wrong password") && !$0.reason.contains("reparse") }
        if text.contains("Cannot open encrypted archive") || (!passwordFailures.isEmpty && otherFailures.isEmpty) {
            throw hadPassword ? ArchiveError.wrongPassword : ArchiveError.passwordRequired
        }
        if partial, !output.failures.isEmpty {
            report.failures = output.failures
            return report
        }
        throw classify(text, exitCode: worst)
    }

    static func classify(_ text: String, exitCode: Int32) -> ArchiveError {
        let lower = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        if has("wrong password") { return .wrongPassword }
        if has("cannot open the file as archive", "can not open the file as archive", "is not archive") { return .notAnArchive }
        if has("no space left", "errno=28", "not enough space") { return .notEnoughSpace }
        if has("errno=13", "permission denied", "operation not permitted", "errno=1 :") {
            // The line after the message names the file.
            let lines = text.split(separator: "\n").map(String.init)
            let path = lines.first { $0.hasPrefix("/") } ?? ""
            return .accessDenied(path)
        }
        if has("locked archive") { return .locked }
        if has("unsupported method") {
            return .unsupported("The archive uses a compression method that is not supported.")
        }
        if has("data error", "crc failed", "unexpected end", "headers error", "unavailable data", "checksum error", "corrupt") {
            let lines = text.split(separator: "\n").map(String.init)
            let detail = lines.first { !$0.uppercased().hasSuffix("ERRORS:") && !$0.hasPrefix("ERROR:") } ?? lines.first ?? ""
            return .damaged(detail.replacingOccurrences(of: "ERROR: ", with: ""))
        }
        if has("can't allocate required memory") || exitCode == 8 {
            return .failed("There is not enough memory for this. A smaller dictionary size or fewer threads need less.")
        }
        if has("duplicate filename") {
            return .failed("Two of the items would get the same name in the archive.")
        }
        if has("errno=2 :", "no such file or directory", "cannot find archive", "no more files") {
            return .failed("The file could not be found. It may have been moved or deleted.")
        }
        if exitCode == 255 { return .cancelled }
        return .failed(text.isEmpty ? "The operation ended with code \(exitCode)." : text)
    }

    // MARK: Changing

    /// Whether the archive can be changed in place: files added, deleted, renamed.
    public func editability(of info: ArchiveInfo, at url: URL) -> Editability {
        if info.isMultiVolume {
            return .readOnly("An archive that is split into volumes cannot be changed.")
        }
        if info.isSelfExtracting {
            return .readOnly("A self-extracting archive cannot be changed.")
        }
        let type = info.type.lowercased()
        let reason: Editability?
        switch type {
        case "zip", "7z", "wim":
            reason = nil
        case "tar":
            if ["", "gzip", "bzip2", "xz"].contains(info.compression.lowercased()) {
                reason = nil
            } else {
                reason = .readOnly("\(info.displayType) archives can be read, but not written.")
            }
        case "rar", "rar5":
            if info.isLocked {
                reason = .readOnly("This archive is locked against changes.")
            } else {
                reason = tools.rar == nil ? .needsRar : nil
            }
        default:
            reason = .readOnly("\(info.displayType) archives can be read, but not changed.")
        }
        if let reason { return reason }
        if !FileManager.default.isWritableFile(atPath: url.path)
            || !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
            return .readOnly("The archive is in a place that cannot be written to.")
        }
        return .editable
    }
}
