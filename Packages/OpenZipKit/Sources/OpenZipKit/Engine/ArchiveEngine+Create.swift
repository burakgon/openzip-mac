import Foundation

/// What to pack, and into which archive.
public struct CompressionJob: Sendable {
    /// The files and folders to add. Each goes in under its own name.
    public var sources: [URL]
    /// The archive to create, or to add to if it exists.
    public var archive: URL
    /// The folder of the archive the items go into. Empty for its top level.
    public var folder: String
    public var options: CompressionOptions
    public var password: String?

    public init(sources: [URL], archive: URL, folder: String = "", options: CompressionOptions = CompressionOptions(), password: String? = nil) {
        self.sources = sources
        self.archive = archive
        self.folder = folder
        self.options = options
        self.password = password
    }
}

public struct CompressionResult: Sendable {
    /// The archive that was written. For a split archive, its first volume.
    public var output: URL
    public var report: OperationReport
}

/// What a look through the items to pack found.
public struct SourceScan: Sendable, Equatable {
    public var fileCount = 0
    public var folderCount = 0
    public var totalSize: UInt64 = 0
    /// The items the exclusion patterns leave out, as paths in the archive.
    public var excluded: [String] = []

    public init() {}
}

extension ArchiveEngine {
    /// Creates an archive, or adds to an existing one.
    public func compress(
        _ job: CompressionJob,
        control: OperationControl? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> CompressionResult {
        guard !job.sources.isEmpty else { throw ArchiveError.failed("There is nothing to add.") }
        progress?(OperationProgress(phase: .preparing))
        let format = job.options.format
        let files = FileManager.default
        try files.createDirectory(at: job.archive.deletingLastPathComponent(), withIntermediateDirectories: true)

        if format.isSingleFile {
            var isDirectory: ObjCBool = false
            guard job.sources.count == 1, files.fileExists(atPath: job.sources[0].path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ArchiveError.unsupported("\(format.displayName) compresses a single file. For several files or a folder, choose TAR.\(format.fileExtension.uppercased()).")
            }
        }

        let report: OperationReport
        if format.needsRar {
            report = try await rarAdd(job, control: control, progress: progress)
        } else if let compressor = format.compressor {
            if files.fileExists(atPath: job.archive.path) {
                report = try await modifyCompressedTar(job.archive, compression: compressor, control: control, progress: progress) { tar in
                    var inner = job
                    inner.archive = tar
                    inner.options.format = .tar
                    return try await add(inner, control: control, progress: progress)
                }
            } else {
                report = try await createCompressedTar(job, compressor: compressor, control: control, progress: progress)
            }
        } else {
            report = try await add(job, control: control, progress: progress)
        }
        return CompressionResult(output: Self.output(of: job), report: report)
    }

    /// The file a job leaves behind: the archive, or the first of its volumes.
    static func output(of job: CompressionJob) -> URL {
        guard job.options.volumeSize != nil, job.options.format.supportsVolumes else { return job.archive }
        let files = FileManager.default
        if job.options.format == .rar {
            // "name.part1.rar", or with more digits when there are ten volumes or more.
            let base = job.archive.deletingPathExtension()
            for digits in 1...5 {
                let first = base.appendingPathExtension("part" + String(repeating: "0", count: digits - 1) + "1").appendingPathExtension("rar")
                if files.fileExists(atPath: first.path) { return first }
            }
            return job.archive
        }
        let first = URL(filePath: job.archive.path + ".001")
        return files.fileExists(atPath: first.path) ? first : job.archive
    }

    // MARK: 7-Zip

    func add(_ job: CompressionJob, control: OperationControl?, progress: ProgressHandler?) async throws -> OperationReport {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        let options = job.options
        let plan = try Self.plan(job.sources, folder: job.folder, options: options)
        defer { plan.staging?.remove() }
        try control?.checkCancellation()

        let hasPassword = job.password?.isEmpty == false
        if let problem = options.format.problem(withPassword: job.password) {
            throw ArchiveError.unsupported(problem)
        }
        var arguments = Self.updateCommand(options.updateMode)
        arguments += compressionSwitches(options, encrypt: hasPassword)
        if options.storeSymbolicLinks { arguments.append("-snl") }
        // -spd: every name is a name, not a pattern. Which also means the patterns to leave
        // out cannot be handed to 7-Zip as patterns: `plan` has resolved them to paths.
        arguments += ["-y", "-bb1", "-bsp1", "-sccUTF-8", "-scsUTF-8", "-spd"]
        if hasPassword { arguments.append("-p") }
        if !plan.excluded.isEmpty {
            let list = try Self.writeList(plan.excluded, in: scratch.url, name: "excluded.txt")
            arguments.append("-x@\(list.path)")
        }
        let list = try Self.writeList(plan.names, in: scratch.url)
        arguments += ["-i@\(list.path)", "--", job.archive.path]

        let output = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run(
            [sevenZip(arguments, directory: plan.directory, input: Self.passwordInput(job.password))],
            control: control
        ) { _, data in
            let update: OperationProgress? = output.with { state in
                guard state.feed(data) else { return nil }
                return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
            }
            if let update { progress?(update) }
        }
        return try Self.evaluate(codes, output.current, hadPassword: hasPassword, partial: false)
    }

    private func createCompressedTar(
        _ job: CompressionJob, compressor: String, control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        let options = job.options
        let plan = try Self.plan(job.sources, folder: job.folder, options: options)
        defer { plan.staging?.remove() }
        try control?.checkCancellation()

        // The tar is written to a pipe and compressed from there: it never exists on disk.
        var tar = ["a", "-ttar", "-an", "-so", "-bso2", "-bse2", "-bsp2", "-bb1", "-y", "-sccUTF-8", "-scsUTF-8", "-spd"]
        if options.storeSymbolicLinks { tar.append("-snl") }
        if !plan.excluded.isEmpty {
            let list = try Self.writeList(plan.excluded, in: scratch.url, name: "excluded.txt")
            tar.append("-x@\(list.path)")
        }
        let list = try Self.writeList(plan.names, in: scratch.url)
        tar.append("-i@\(list.path)")

        // The name of the tar inside: "backup.tar" for "backup.tar.gz" and for "backup.tgz".
        let inner = FileNaming.archiveBaseName(job.archive.lastPathComponent) + ".tar"
        var pack = ["a", "-t\(compressor)", "-mx=\(options.level.rawValue)", "-si\(inner)", "-y", "-bso0", "-bsp0"]
        if let threads = options.threads, threads > 0 { pack.append("-mmt=\(threads)") }
        if compressor == "xz", let dictionary = options.dictionarySize { pack.append("-md=\(dictionary)b") }
        pack += ["--", job.archive.path]

        let output = LockedBox(OperationOutput())
        let packing = LockedBox(OperationOutput())
        do {
            let codes = try await ToolRunner.run([
                sevenZip(tar, directory: plan.directory),
                sevenZip(pack),
            ], control: control) { index, data in
                guard index == 0 else {
                    packing.with { _ = $0.feed(data) }
                    return
                }
                let update: OperationProgress? = output.with { state in
                    guard state.feed(data) else { return nil }
                    return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
                }
                if let update { progress?(update) }
            }
            if codes[1] >= 2 {
                throw Self.classify(Self.diagnosis(packing.current.messages), exitCode: codes[1])
            }
            return try Self.evaluate([codes[0]], output.current, hadPassword: false, partial: false)
        } catch {
            // Half an archive is worse than none.
            try? FileManager.default.removeItem(at: job.archive)
            throw error
        }
    }

    /// "a" for adding, "u" for the modes that compare what is in the archive with what
    /// is on disk. The letters after -u are 7-Zip's: q is "in the archive but not on
    /// disk", r "on disk but not in the archive", and 0 means "leave it out".
    private static func updateCommand(_ mode: UpdateMode) -> [String] {
        switch mode {
        case .addAndReplace: ["a"]
        case .update: ["u"]
        case .freshen: ["u", "-ur0"]
        case .synchronize: ["u", "-uq0"]
        }
    }

    func compressionSwitches(_ options: CompressionOptions, encrypt: Bool) -> [String] {
        let format = options.format
        var result = ["-t\(format.sevenZipType)"]
        if format.supportsLevels { result.append("-mx=\(options.level.rawValue)") }
        if let threads = options.threads, threads > 0 { result.append("-mmt=\(threads)") }

        switch format {
        case .sevenZip:
            if options.level != .store {
                // Naming a method turns off 7-Zip's own choice of filters for programs, so
                // the default is left unnamed.
                switch options.method {
                case nil, "LZMA2":
                    if let dictionary = options.dictionarySize { result.append("-md=\(dictionary)b") }
                case "PPMd":
                    result.append("-m0=PPMd" + (options.dictionarySize.map { ":mem=\($0)b" } ?? ""))
                case "LZMA":
                    result.append("-m0=LZMA" + (options.dictionarySize.map { ":d=\($0)b" } ?? ""))
                case let method?:
                    result.append("-m0=\(method)")
                }
            }
            if let solid = options.solid { result.append(solid ? "-ms=on" : "-ms=off") }
            if encrypt, options.encryptFileNames { result.append("-mhe=on") }
            if options.selfExtracting, let module = tools.sfxModule { result.append("-sfx\(module.path)") }
        case .zip:
            if options.level != .store, let method = options.method, method != "Deflate" {
                result.append("-mm=\(method)")
                if let dictionary = options.dictionarySize {
                    result.append(method == "PPMd" ? "-mmem=\(dictionary)b" : "-md=\(dictionary)b")
                }
            }
            if encrypt { result.append("-mem=\(options.zipEncryption.rawValue)") }
            // Names that are not ASCII are written as UTF-8, which every current program reads.
            result.append("-mcu=on")
        case .xz:
            if let dictionary = options.dictionarySize { result.append("-md=\(dictionary)b") }
        default:
            break
        }
        if let volume = options.volumeSize, volume > 0, format.supportsVolumes {
            result.append("-v\(volume)b")
        }
        return result
    }

    // MARK: Sources

    /// How the items to add are named for 7-Zip.
    struct SourcePlan {
        /// The folder 7-Zip runs in, when the names are relative to one.
        var directory: URL?
        var names: [String]
        var excluded: [String]
        var staging: WorkDirectory?
    }

    /// Works out how to give the sources to 7-Zip so that they end up under the right
    /// names in the archive.
    ///
    /// 7-Zip stores an item under the last part of the path it is given. That is right
    /// for the usual case, files added at the top of an archive. For a folder inside the
    /// archive, or two items of the same name, the layout is built on disk first.
    static func plan(
        _ sources: [URL], folder: String, options: CompressionOptions, resolveExclusions: Bool = true
    ) throws -> SourcePlan {
        let folder = folder.split(separator: "/").joined(separator: "/")
        let patterns = (options.excludeMacFiles ? CompressionOptions.macFilePatterns : []) + options.excludePatterns
        let names = sources.map(\.lastPathComponent)

        if folder.isEmpty, Set(names).count == names.count {
            var excluded: [String] = []
            if resolveExclusions, !patterns.isEmpty {
                for source in sources {
                    var scan = SourceScan()
                    Self.scan(source, storedAs: source.lastPathComponent, patterns: patterns, into: &scan)
                    excluded += scan.excluded
                }
            }
            return SourcePlan(directory: nil, names: sources.map(\.path), excluded: excluded, staging: nil)
        }

        let staging = try WorkDirectory.make(near: sources[0])
        do {
            let base = folder.isEmpty ? staging.url : staging.url.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var used = Set<String>()
            var staged: [String] = []
            for source in sources {
                // Two items of the same name from different folders: the second becomes "name 2".
                let name = FileNaming.uniqueURL(for: base.appending(path: source.lastPathComponent)) { used.contains($0.lastPathComponent) }.lastPathComponent
                used.insert(name)
                try Staging.stage(source, at: base.appending(path: name), followLinks: !options.storeSymbolicLinks, excluding: patterns)
                staged.append(folder.isEmpty ? name : "\(folder)/\(name)")
            }
            return SourcePlan(directory: staging.url, names: staged, excluded: [], staging: staging)
        } catch {
            staging.remove()
            throw error
        }
    }

    /// Counts what is in the items, and finds what the patterns leave out.
    public static func scan(_ sources: [URL], options: CompressionOptions) -> SourceScan {
        let patterns = (options.excludeMacFiles ? CompressionOptions.macFilePatterns : []) + options.excludePatterns
        var result = SourceScan()
        for source in sources {
            scan(source, storedAs: source.lastPathComponent, patterns: patterns, into: &result)
        }
        return result
    }

    /// Walks one item. The patterns apply to what is inside a folder, never to the item
    /// itself: what was chosen by hand is wanted.
    static func scan(_ source: URL, storedAs name: String, patterns: [String], into result: inout SourceScan) {
        guard let root = strdup(source.path) else { return }
        defer { free(root) }
        var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let stream = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(stream) }
        let prefix = strlen(root)

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT else { continue }
            if entry.pointee.fts_level > 0 {
                let itemName = withUnsafePointer(to: &entry.pointee.fts_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if Wildcard.matches(itemName, anyOf: patterns) {
                    let relative = String(cString: entry.pointee.fts_path + prefix)
                    result.excluded.append(name + relative)
                    if info == FTS_D { fts_set(stream, entry, FTS_SKIP) }
                    continue
                }
            }
            if info == FTS_D {
                result.folderCount += 1
            } else {
                result.fileCount += 1
                if info == FTS_F, let stats = entry.pointee.fts_statp {
                    result.totalSize += UInt64(max(0, stats.pointee.st_size))
                }
            }
        }
    }

    // MARK: Compressed tars

    /// Changes a compressed tar: unpacks the tar next to it, lets `body` change that, and
    /// compresses it again in place of the original. There is no way around the round
    /// trip, a compressed stream cannot be edited in the middle.
    func modifyCompressedTar(
        _ archive: URL, compression: String, control: OperationControl?, progress: ProgressHandler?,
        body: (URL) async throws -> OperationReport
    ) async throws -> OperationReport {
        guard ["gzip", "bzip2", "xz"].contains(compression) else {
            throw ArchiveError.unsupported("Archives compressed with \(compression) can be read, but not written.")
        }
        let work = try WorkDirectory.make(near: archive)
        defer { work.remove() }
        progress?(OperationProgress(phase: .preparing))

        let unpack = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run(
            [sevenZip(["x", "-y", "-aoa", "-bsp1", "-spod", "-o\(work.url.path)", "--", archive.path])], control: control
        ) { _, data in
            unpack.with { _ = $0.feed(data) }
        }
        _ = try Self.evaluate(codes, unpack.current, hadPassword: false, partial: false)
        guard let name = try Directory.names(in: work.url).first else {
            throw ArchiveError.damaged("")
        }
        let tar = work.url.appending(path: name)

        let report = try await body(tar)
        try control?.checkCancellation()
        progress?(OperationProgress(phase: .finishing))

        let packed = work.url.appending(path: "packed-" + archive.lastPathComponent)
        let pack = LockedBox(OperationOutput())
        let packCodes = try await ToolRunner.run(
            [sevenZip(["a", "-t\(compression)", "-mx=5", "-y", "-bsp1", "--", packed.path, tar.path])], control: control
        ) { _, data in
            pack.with { _ = $0.feed(data) }
        }
        _ = try Self.evaluate(packCodes, pack.current, hadPassword: false, partial: false)
        _ = try FileManager.default.replaceItemAt(archive, withItemAt: packed)
        return report
    }
}

/// Patterns with * and ?, as in "*.tmp".
enum Wildcard {
    static func matches(_ name: String, anyOf patterns: [String]) -> Bool {
        patterns.contains { matches(name, pattern: $0) }
    }

    /// Whether the whole name fits the pattern. Upper and lower case are the same.
    static func matches(_ name: String, pattern: String) -> Bool {
        let text = Array(name.lowercased().unicodeScalars)
        let mask = Array(pattern.lowercased().unicodeScalars)
        var textIndex = 0, maskIndex = 0
        var star = -1, mark = 0
        while textIndex < text.count {
            if maskIndex < mask.count, mask[maskIndex] == "?" || mask[maskIndex] == text[textIndex] {
                textIndex += 1
                maskIndex += 1
            } else if maskIndex < mask.count, mask[maskIndex] == "*" {
                star = maskIndex
                mark = textIndex
                maskIndex += 1
            } else if star >= 0 {
                maskIndex = star + 1
                mark += 1
                textIndex = mark
            } else {
                return false
            }
        }
        while maskIndex < mask.count, mask[maskIndex] == "*" { maskIndex += 1 }
        return maskIndex == mask.count
    }
}
