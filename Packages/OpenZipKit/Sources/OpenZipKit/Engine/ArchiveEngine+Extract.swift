import Foundation

/// Whether extracted items get a folder of their own.
public enum FolderPolicy: Sendable, Equatable {
    /// Straight into the destination.
    case none
    /// Always into a new folder with this name.
    case always(String)
    /// Into a folder with this name, unless the archive has a single item at its top: then
    /// that item goes straight into the destination. This is what the Finder does, and it
    /// never leaves a hundred files loose in Downloads or a folder inside a folder.
    case automatic(String)
}

/// What to extract, and where to.
public struct ExtractionJob: Sendable {
    public var archive: URL
    /// What the archive holds, if it was listed already. Used to check the free space, to
    /// see whether it is a compressed tar and to bring the resource forks of a selection along.
    public var listing: ArchiveListing?
    /// The entries to extract. nil for everything.
    public var items: [Item]?
    /// The folder to extract into. It is created if it does not exist.
    public var destination: URL
    public var password: String?
    public var folderPolicy: FolderPolicy = .none
    public var conflictPolicy: ConflictPolicy = .ask
    /// Fold resource forks and extended attributes that the archive keeps beside the
    /// files (see `AppleDouble`) back into them.
    public var restoreMacMetadata = true
    /// Pass the quarantine of the archive on to what comes out of it.
    public var keepQuarantine = true
    /// Put every file directly into the destination, without the folders of the archive.
    public var flatten = false
    /// Keep files that failed their check instead of removing them.
    public var keepBrokenFiles = false

    public struct Item: Sendable, Hashable {
        /// The path as the archive stores it.
        public var path: String

        public init(path: String) {
            self.path = path
        }
    }

    public init(archive: URL, destination: URL, listing: ArchiveListing? = nil, items: [Item]? = nil, password: String? = nil) {
        self.archive = archive
        self.destination = destination
        self.listing = listing
        self.items = items
        self.password = password
    }
}

public struct ExtractionResult: Sendable {
    /// What was put in place: the items at the top, not everything inside them.
    public var items: [URL]
    /// The folder they are in: the destination, or the folder that was made in it.
    public var container: URL
    public var report: OperationReport
    /// How many items were left out because one of the same name existed.
    public var skipped: Int
}

extension ArchiveEngine {
    /// Extracts from an archive.
    ///
    /// Everything is extracted into a work folder on the destination's volume first and
    /// moved into place when it is complete. A wrong password or a cancelled operation
    /// leaves nothing behind.
    public func extract(
        _ job: ExtractionJob,
        control: OperationControl? = nil,
        resolver: ConflictResolver? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> ExtractionResult {
        let files = FileManager.default
        progress?(OperationProgress(phase: .preparing))
        try files.createDirectory(at: job.destination, withIntermediateDirectories: true)

        // An archive that only compresses holds one file, under a name of 7-Zip's making:
        // there is nothing to choose from, and asking for it by name could miss.
        let isStream = job.listing.map { Self.isSingleStream($0.info) } ?? false
        var paths = isStream ? nil : job.items.map { $0.map(\.path) }
        if let listing = job.listing {
            try Self.checkSpace(for: paths, of: listing, at: job.destination)
            if job.restoreMacMetadata, let selected = paths {
                paths = selected + AppleDouble.companions(of: selected, in: Set(listing.entries.map(\.path)))
            }
        }

        let work = try WorkDirectory.make(near: job.destination)
        defer { work.remove() }

        let report = try await extractRaw(
            archive: job.archive,
            compression: job.listing?.info.compression ?? "",
            paths: paths,
            flatten: job.flatten,
            into: work.url,
            password: job.password,
            control: control,
            progress: progress
        )
        try control?.checkCancellation()
        progress?(OperationProgress(fraction: 1, phase: .finishing))

        if !job.keepBrokenFiles {
            // A file that failed its check is not the file that was packed.
            for failure in report.failures {
                try? files.removeItem(at: Self.location(of: failure.path, in: work.url))
            }
        }
        if job.restoreMacMetadata {
            AppleDouble.merge(in: work.url)
        }
        if job.keepQuarantine, let mark = Quarantine.mark(of: job.archive) {
            for name in (try? Directory.names(in: work.url)) ?? [] {
                Quarantine.apply(mark, to: work.url.appending(path: name))
            }
        }

        // What goes where. A selection is extracted relative to itself: choosing
        // "docs/manual" gives "manual" at the destination, not "docs/manual".
        var moves: [(source: URL, name: String)] = []
        if let items = job.items, !job.flatten, !isStream {
            var seen = Set<String>()
            for item in items where seen.insert(item.path).inserted {
                let source = Self.location(of: item.path, in: work.url)
                guard Placer.exists(source) else { continue }
                moves.append((source, source.lastPathComponent))
            }
        } else {
            for name in try Directory.names(in: work.url).sorted() {
                moves.append((work.url.appending(path: name), name))
            }
        }

        var container = job.destination
        func folder(_ name: String) -> URL {
            let url = job.destination.appending(path: name)
            // "Keep both" for a folder means a second folder, not a mix of old and new files.
            return job.conflictPolicy == .keepBoth ? FileNaming.uniqueURL(for: url, isTaken: Placer.exists) : url
        }
        switch job.folderPolicy {
        case .none:
            break
        case .always(let name):
            container = folder(name)
        case .automatic(let name):
            if moves.count != 1 { container = folder(name) }
        }
        if !moves.isEmpty {
            try files.createDirectory(at: container, withIntermediateDirectories: true)
        }

        var placer = Placer(policy: job.conflictPolicy, resolver: resolver)
        for move in moves {
            try control?.checkCancellation()
            try await placer.place(move.source, at: container.appending(path: move.name))
        }
        return ExtractionResult(items: placer.placed, container: container, report: report, skipped: placer.skipped)
    }

    /// Where 7-Zip puts an entry inside the folder it extracts to. It leaves out what
    /// could lead outside of that folder: a slash at the start, "." and "..".
    static func location(of path: String, in folder: URL) -> URL {
        var url = folder
        for part in path.split(separator: "/") where part != "." && part != ".." {
            url.append(path: String(part))
        }
        return url
    }

    private static func checkSpace(for paths: [String]?, of listing: ArchiveListing, at destination: URL) throws {
        let needed: UInt64
        if let paths {
            let selected = Set(paths)
            needed = listing.entries.reduce(0) { total, entry in
                // An entry counts if it is selected or lies in a selected folder.
                var path = Substring(entry.path)
                while true {
                    if selected.contains(String(path)) { return total.addingSaturated(entry.size) }
                    guard let slash = path.lastIndex(of: "/") else { return total }
                    path = path[..<slash]
                }
            }
        } else {
            needed = listing.entries.reduce(0) { $0.addingSaturated($1.size) }
        }
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0, needed > UInt64(available) {
            throw ArchiveError.notEnoughSpace
        }
    }

    /// Runs 7-Zip to extract into a folder, with the paths of the archive.
    func extractRaw(
        archive: URL, compression: String, paths: [String]?, flatten: Bool, into directory: URL,
        password: String?, control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }

        // -spod: the path after -o is a path. Without it 7-Zip replaces every * in it with
        // the name of the archive.
        var switches = ["-y", "-aoa", "-bb1", "-bsp1", "-sccUTF-8", "-scsUTF-8", "-spod", "-o\(directory.path)"]
        if let paths {
            // -spd: the names are names, not patterns. A file called "what?.txt" is one file.
            let list = try Self.writeList(paths, in: scratch.url)
            switches += ["-spd", "-i@\(list.path)"]
        }
        let verb = flatten ? "e" : "x"
        let output = LockedBox(OperationOutput())

        if compression.isEmpty {
            let codes = try await ToolRunner.run(
                [sevenZip([verb] + switches + ["--", archive.path], input: Self.passwordInput(password))],
                control: control
            ) { _, data in
                let update: OperationProgress? = output.with { state in
                    guard state.feed(data) else { return nil }
                    return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
                }
                if let update { progress?(update) }
            }
            return try Self.evaluate(codes, output.current, hadPassword: password?.isEmpty == false, partial: true)
        }

        // A compressed tar: one 7-Zip unpacks the compression and hands the tar to a
        // second one, so the tar never has to be written to disk. The first knows how far
        // along it is, the second which file it is at.
        let unpacking = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run([
            sevenZip(["x", "-so", "-bso2", "-bse2", "-bsp2", "--", archive.path]),
            sevenZip([verb, "-si", "-ttar"] + switches),
        ], control: control) { index, data in
            // Each side reads the other's state before locking its own: taking both locks
            // in opposite orders on two threads is how a deadlock is made.
            let update: OperationProgress?
            if index == 0 {
                let item = output.with { $0.item }
                update = unpacking.with { state in
                    guard state.feed(data), let percent = state.percent else { return nil }
                    return OperationProgress(fraction: Double(percent) / 100, currentItem: item)
                }
            } else {
                let percent = unpacking.with { $0.percent }
                update = output.with { state in
                    guard state.feed(data), !state.item.isEmpty else { return nil }
                    return OperationProgress(fraction: percent.map { Double($0) / 100 }, currentItem: state.item)
                }
            }
            if let update { progress?(update) }
        }
        if codes[0] >= 2, output.current.failures.isEmpty {
            throw Self.classify(Self.diagnosis(unpacking.current.messages), exitCode: codes[0])
        }
        return try Self.evaluate([codes[1]], output.current, hadPassword: false, partial: true)
    }

    /// Extracts one file to a place of its own, for looking at it or opening it in another
    /// app. Returns where it is.
    public func extractFile(
        _ path: String, from archive: URL, listing: ArchiveListing?, password: String?, into folder: URL,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws -> URL {
        let work = try WorkDirectory.makeTemporary()
        defer { work.remove() }
        let isStream = listing.map { Self.isSingleStream($0.info) } ?? false
        var paths = [path]
        if let listing {
            paths += AppleDouble.companions(of: paths, in: Set(listing.entries.map(\.path)))
        }
        let report = try await extractRaw(
            archive: archive, compression: listing?.info.compression ?? "", paths: isStream ? nil : paths, flatten: false,
            into: work.url, password: password, control: control, progress: progress
        )
        if let failure = report.failures.first {
            throw ArchiveError.damaged("\(failure.reason): \(failure.path)")
        }
        AppleDouble.merge(in: work.url)
        var source = Self.location(of: path, in: work.url)
        if isStream, let only = try? Directory.names(in: work.url).first {
            source = work.url.appending(path: only)
        }
        guard Placer.exists(source) else {
            throw ArchiveError.failed("“\((path as NSString).lastPathComponent)” could not be extracted.")
        }
        if let mark = Quarantine.mark(of: archive) {
            Quarantine.apply(mark, to: source)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Checks every file of the archive against its checksum, without writing anything.
    /// The files that fail are in the report.
    public func test(
        _ archive: URL, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws -> OperationReport {
        let output = LockedBox(OperationOutput())
        let codes = try await ToolRunner.run(
            [sevenZip(["t", "-y", "-bb1", "-bsp1", "-sccUTF-8", "--", archive.path], input: Self.passwordInput(password))],
            control: control
        ) { _, data in
            let update: OperationProgress? = output.with { state in
                guard state.feed(data) else { return nil }
                return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
            }
            if let update { progress?(update) }
        }
        return try Self.evaluate(codes, output.current, hadPassword: password?.isEmpty == false, partial: true)
    }
}
