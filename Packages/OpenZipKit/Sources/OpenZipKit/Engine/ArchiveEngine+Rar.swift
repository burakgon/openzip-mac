import Foundation

/// Follows RARLAB's rar through what it prints: "Adding  name   29%", with the percentage
/// printed over itself.
struct RarOutput {
    private(set) var percent: Int?
    private(set) var item = ""
    private(set) var messages: [String] = []
    private var tokenizer = OutputTokenizer()

    private static let verbs = ["Adding", "Updating", "Deleting", "Renaming", "Testing", "Extracting", "Creating", "Repairing", "Copying"]

    mutating func feed(_ data: Data) -> Bool {
        var changed = false
        var tokens: [String] = []
        tokenizer.feed(data) { tokens.append($0) }
        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, token != "OK" else { continue }
            if token.hasSuffix("%"), let value = Int(token.dropLast()), (0...100).contains(value) {
                if percent != value {
                    percent = value
                    changed = true
                }
                continue
            }
            if let verb = Self.verbs.first(where: { token.hasPrefix($0 + " ") }) {
                var name = token.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix(" OK") { name = String(name.dropLast(3)).trimmingCharacters(in: .whitespaces) }
                // rar prints the whole path of what it reads from disk. The name is enough.
                item = (name as NSString).lastPathComponent
                changed = true
                continue
            }
            if token.hasPrefix("Evaluation copy") || token == "Done" || token.hasPrefix("Enter password") || token.hasPrefix("Reenter password") {
                continue
            }
            if messages.count < 100 { messages.append(token) }
        }
        // A percentage that has not been printed over yet.
        let last = tokenizer.unfinished.trimmingCharacters(in: .whitespaces)
        if last.hasSuffix("%"), let value = Int(last.dropLast()), (0...100).contains(value), percent != value {
            percent = value
            changed = true
        }
        return changed
    }
}

/// Creating and changing RAR archives, with RARLAB's own rar. Nothing else can: the
/// format's compression is proprietary, and its license forbids writing another program
/// that produces it. Reading RAR is another matter and needs nothing but 7-Zip.
extension ArchiveEngine {
    private func rar(_ arguments: [String], directory: URL? = nil, password: String? = nil) throws -> ToolCommand {
        guard let executable = tools.rar else { throw ArchiveError.toolMissing("RAR") }
        return ToolCommand(executable: executable, arguments: arguments, directory: directory, input: Self.passwordInput(password))
    }

    /// The switches every run gets: no configuration file of the user's, no banner, and
    /// "yes" to every question, there being nobody at the console to answer.
    private static let rarQuiet = ["-cfg-", "-idc", "-y"]

    @discardableResult
    private func runRar(
        _ arguments: [String], directory: URL? = nil, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws -> OperationReport {
        let output = LockedBox(RarOutput())
        let codes = try await ToolRunner.run(
            [try rar(arguments, directory: directory, password: password)], control: control
        ) { _, data in
            let update: OperationProgress? = output.with { state in
                guard state.feed(data) else { return nil }
                return OperationProgress(fraction: state.percent.map { Double($0) / 100 }, currentItem: state.item)
            }
            if let update { progress?(update) }
        }
        let text = output.current.messages.joined(separator: "\n")
        var report = OperationReport()
        // rar's exit codes say what happened more reliably than its messages.
        switch codes[0] {
        case 0:
            return report
        case 1:
            report.warnings = output.current.messages
            return report
        case 3: throw ArchiveError.damaged(text)
        case 4: throw ArchiveError.locked
        case 5, 9:
            let lower = text.lowercased()
            if lower.contains("no space") { throw ArchiveError.notEnoughSpace }
            if lower.contains("permission denied") || lower.contains("not permitted") { throw ArchiveError.accessDenied("") }
            throw ArchiveError.failed(text.isEmpty ? "The archive could not be written." : text)
        case 8: throw ArchiveError.failed("There is not enough memory for this. A smaller dictionary size needs less.")
        case 10: throw ArchiveError.failed("None of the files could be found.")
        case 11: throw ArchiveError.wrongPassword
        case 12:
            // rar wanted a password and found nobody to ask.
            if text.contains("stdin") { throw ArchiveError.passwordRequired }
            throw ArchiveError.failed(text)
        case 255: throw ArchiveError.cancelled
        default:
            throw ArchiveError.failed(text.isEmpty ? "RAR ended with code \(codes[0])." : text)
        }
    }

    func rarAdd(_ job: CompressionJob, control: OperationControl?, progress: ProgressHandler?) async throws -> OperationReport {
        guard let executable = tools.rar else { throw ArchiveError.toolMissing("RAR") }
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        let options = job.options
        let plan = try Self.plan(job.sources, folder: job.folder, options: options, resolveExclusions: false)
        defer { plan.staging?.remove() }
        try control?.checkCancellation()

        var arguments: [String]
        switch options.updateMode {
        case .addAndReplace: arguments = ["a"]
        case .update: arguments = ["u"]
        case .freshen: arguments = ["f"]
        case .synchronize: arguments = ["a", "-as"]
        }
        arguments += Self.rarQuiet + ["-o+", "-r", "-m\(options.level.rarLevel)"]
        if plan.directory == nil {
            // The sources are named by their full paths: keep only the last part of each.
            arguments.append("-ep1")
            let patterns = (options.excludeMacFiles ? CompressionOptions.macFilePatterns : []) + options.excludePatterns
            for pattern in patterns {
                arguments.append("-x\(pattern)")
                // Without a wildcard rar takes a name for one file at the top. This makes it any.
                if !pattern.contains("*"), !pattern.contains("?") { arguments.append("-x*/\(pattern)") }
            }
        }
        if let dictionary = options.dictionarySize, dictionary >= 1 << 20 { arguments.append("-md\(dictionary >> 20)m") }
        if options.solid == true { arguments.append("-s") }
        if let threads = options.threads, threads > 0 { arguments.append("-mt\(threads)") }
        if options.recoveryPercent > 0 { arguments.append("-rr\(options.recoveryPercent)p") }
        if let volume = options.volumeSize, volume > 0 { arguments.append("-v\(volume)b") }
        if options.storeSymbolicLinks { arguments.append("-ol") }
        if options.lock { arguments.append("-k") }
        if options.selfExtracting {
            // rar looks for its module in /usr/local/etc. It is next to the program.
            let module = executable.deletingLastPathComponent().appending(path: "default.sfx")
            arguments.append(FileManager.default.fileExists(atPath: module.path) ? "-sfx\(module.path)" : "-sfx")
        }
        if !options.comment.isEmpty {
            let file = scratch.url.appending(path: "comment.txt")
            try Data(options.comment.utf8).write(to: file)
            arguments += ["-z\(file.path)", "-scfc"]
        }
        let hasPassword = job.password?.isEmpty == false
        if hasPassword { arguments.append(options.encryptFileNames ? "-hp" : "-p") }

        let list = try Self.writeList(plan.names, in: scratch.url)
        arguments += ["-scfl", "--", job.archive.path, "@\(list.path)"]
        return try await runRar(arguments, directory: plan.directory, password: job.password, control: control, progress: progress)
    }

    func rarDelete(
        _ paths: [String], from archive: URL, password: String?, control: OperationControl?, progress: ProgressHandler?
    ) async throws {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        let list = try Self.writeList(paths, in: scratch.url)
        var arguments = ["d"] + Self.rarQuiet + ["-scfl"]
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path, "@\(list.path)"]
        try await runRar(arguments, password: password, control: control, progress: progress)
    }

    func rarRename(
        _ changes: [(from: String, to: String)], in archive: URL, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws {
        var batch: [String] = []
        var size = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            var arguments = ["rn"] + Self.rarQuiet
            if password?.isEmpty == false { arguments.append("-p") }
            arguments += ["--", archive.path] + batch
            try await runRar(arguments, password: password, control: control, progress: progress)
            batch = []
            size = 0
        }
        for change in changes {
            batch += [change.from, change.to]
            size += change.from.utf8.count + change.to.utf8.count + 2
            if size > 120_000 { try await flush() }
        }
        try await flush()
    }

    /// Adds what is at `path` under `staging`, with that path.
    func rarAddStaged(
        _ path: String, from staging: URL, to archive: URL, password: String?,
        control: OperationControl?, progress: ProgressHandler?
    ) async throws {
        var arguments = ["a"] + Self.rarQuiet + ["-r"]
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path, path]
        try await runRar(arguments, directory: staging, password: password, control: control, progress: progress)
    }

    func rarSetComment(_ comment: String, of archive: URL, password: String?, control: OperationControl?) async throws {
        let scratch = try WorkDirectory.makeTemporary()
        defer { scratch.remove() }
        // An empty file takes the comment away.
        let file = scratch.url.appending(path: "comment.txt")
        try Data(comment.utf8).write(to: file)
        var arguments = ["c"] + Self.rarQuiet + ["-z\(file.path)", "-scfc"]
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        try await runRar(arguments, password: password, control: control, progress: nil)
    }

    // MARK: What only RAR has

    /// Locks a RAR archive: it can still be read, and never changed again.
    public func lock(_ archive: URL, password: String? = nil, control: OperationControl? = nil) async throws {
        var arguments = ["k"] + Self.rarQuiet
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        try await runRar(arguments, password: password, control: control, progress: nil)
    }

    /// Adds a recovery record: extra data with which the archive can repair itself if
    /// part of it gets damaged. `percent` is its size relative to the archive.
    public func addRecoveryRecord(
        to archive: URL, percent: Int, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws {
        var arguments = ["rr\(max(1, min(percent, 100)))p"] + Self.rarQuiet
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        try await runRar(arguments, password: password, control: control, progress: progress)
    }

    /// Repairs a damaged RAR archive, with its recovery record if it has one. The repaired
    /// copy is written next to it; the damaged original is left alone. Returns the copy.
    public func repairRar(
        _ archive: URL, password: String? = nil,
        control: OperationControl? = nil, progress: ProgressHandler? = nil
    ) async throws -> URL {
        let folder = archive.deletingLastPathComponent()
        let before = Set((try? Directory.names(in: folder)) ?? [])
        var arguments = ["r"] + Self.rarQuiet
        if password?.isEmpty == false { arguments.append("-p") }
        arguments += ["--", archive.path]
        try await runRar(arguments, directory: folder, password: password, control: control, progress: progress)
        // rar names the result "fixed.name.rar" or "rebuilt.name.rar", depending on how it got there.
        let after = (try? Directory.names(in: folder)) ?? []
        guard let created = after.first(where: { !before.contains($0) && ($0.hasPrefix("fixed.") || $0.hasPrefix("rebuilt.")) }) else {
            throw ArchiveError.failed("RAR found nothing it could repair.")
        }
        return folder.appending(path: created)
    }
}
