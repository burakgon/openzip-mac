import AppKit
import OpenZipKit
import UniformTypeIdentifiers

/// What the menus, the welcome window, the Dock icon and the Finder all lead to.
enum AppActions {
    /// Asks for an archive and opens it.
    static func openArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose an archive to open."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { AppModel.shared.openArchive($0) }
    }

    /// Asks for files and opens the window that packs them.
    static func newArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the files and folders to put into a new archive."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        AppModel.shared.newArchive(from: panel.urls)
    }

    /// Asks for archives and extracts them where they are.
    static func extractArchives() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Extract"
        panel.message = "Choose the archives to extract. Each is extracted next to itself."
        guard panel.runModal() == .OK else { return }
        QuickActions.extract(panel.urls, mode: .here)
    }

    /// Takes whatever was dropped or opened: archives are opened, anything else is packed.
    static func open(_ urls: [URL], forceBrowse: Bool = false) {
        let archives = urls.filter(isArchive)
        let others = urls.filter { !isArchive($0) }
        if !archives.isEmpty {
            if forceBrowse || AppModel.shared.settings.openAction == .browse {
                archives.forEach { AppModel.shared.openArchive($0) }
            } else {
                QuickActions.extract(archives, mode: .here)
            }
        }
        if !others.isEmpty {
            AppModel.shared.newArchive(from: others)
        }
    }

    /// Whether a file is an archive, judged by its name: what decides between opening a
    /// file and offering to pack it.
    static func isArchive(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let name = url.lastPathComponent
        if FileIcons.isArchive(name: name) { return true }
        // Volumes of a split archive: name.7z.002, name.part2.rar, name.r01, name.z01.
        let lower = name.lowercased()
        if lower.range(of: #"\.(\d{3}|[r-z]\d\d)$"#, options: .regularExpression) != nil { return true }
        let ext = url.pathExtension.lowercased()
        return ["dmg", "pkg", "msi", "chm", "udf", "img", "vdi", "qcow2", "esd", "swm", "ar", "nsis"].contains(ext)
    }
}

/// How the Finder's "Extract" entries differ.
enum ExtractMode: String {
    /// Next to the archive, in a folder of its own if it holds several items.
    case here
    /// Next to the archive, always in a folder named after it.
    case folder
    /// Wherever the user says.
    case ask
}

/// Operations that need no window: they run in the background and show in the activity window.
enum QuickActions {
    static func extract(_ archives: [URL], mode: ExtractMode) {
        var destination: URL?
        if mode == .ask {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Extract"
            panel.message = archives.count == 1
                ? "Choose where to extract “\(archives[0].lastPathComponent)”."
                : "Choose where to extract \(archives.count) archives."
            NSApp.activate()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            destination = chosen
        }
        // Every piece of a split archive leads to the same archive: once is enough.
        var seen = Set<URL>()
        for archive in archives.map({ FileNaming.firstVolume(of: $0.standardizedFileURL) }) where seen.insert(archive).inserted {
            extract(archive, to: destination, folderChoice: mode == .folder ? .always : AppModel.shared.settings.folderChoice)
        }
    }

    private static func extract(_ archive: URL, to destination: URL?, folderChoice: FolderChoice) {
        let app = AppModel.shared
        let settings = app.settings
        let name = archive.lastPathComponent
        app.operations.start("Extracting \(name)", symbol: "square.and.arrow.down") { operation, progress in
            let engine = app.engine
            let result = try await withPassword(for: archive) { password in
                let listing = try await engine.list(archive, password: password, control: operation.control, progress: progress)
                var job = ExtractionJob(
                    archive: archive, destination: destination ?? archive.deletingLastPathComponent(),
                    listing: listing, password: password
                )
                job.folderPolicy = folderChoice.policy(named: FileNaming.archiveBaseName(name))
                // Nobody is asked from here: what exists stays, the new gets a number.
                job.conflictPolicy = .keepBoth
                job.restoreMacMetadata = settings.restoreMacMetadata
                job.keepQuarantine = settings.keepQuarantine
                return try await engine.extract(job, control: operation.control, progress: progress)
            }
            if !result.report.failures.isEmpty {
                let first = result.report.failures[0]
                throw ArchiveError.damaged("\(Formatting.count(result.report.failures.count, "file")) could not be extracted (\(first.path): \(first.reason))")
            }
            if settings.trashArchiveAfterExtracting {
                try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            }
            if settings.revealAfterExtracting, !result.items.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(result.items)
            }
            return OperationOutcome(
                message: "\(Formatting.count(result.items.count, "item")) in \(Formatting.folder(result.container))",
                results: result.items
            )
        }
    }

    /// Packs files into an archive next to them, with the settings of the last archive
    /// but in the given format.
    static func compress(_ sources: [URL], format: ArchiveFormat) {
        guard !sources.isEmpty else { return }
        var options = AppModel.shared.settings.lastOptions
        options.format = format
        // What was special about the last archive is not wanted in a quick one.
        options.volumeSize = nil
        options.selfExtracting = false
        options.comment = ""
        options.updateMode = .addAndReplace
        if !format.methods.contains(options.method ?? "") { options.method = nil }
        options.dictionarySize = nil
        let archive = CompressPlan.suggestedArchive(for: sources, format: format)
        CompressRunner.start(CompressPlan(sources: sources, archive: archive, options: options))
    }

    static func test(_ archives: [URL]) {
        let app = AppModel.shared
        for archive in archives {
            app.operations.start("Testing \(archive.lastPathComponent)", symbol: "checkmark.shield") { operation, progress in
                let report = try await withPassword(for: archive) { password in
                    try await app.engine.test(archive, password: password, control: operation.control, progress: progress)
                }
                if let first = report.failures.first {
                    throw ArchiveError.damaged("\(Formatting.count(report.failures.count, "file")) damaged (\(first.path): \(first.reason))")
                }
                return OperationOutcome(message: "No errors found" + (report.fileCount.map { " in \(Formatting.count($0, "file"))" } ?? ""))
            }
        }
    }

    /// Runs something that may need the password of an archive, asking for it as often
    /// as it takes.
    static func withPassword<Result>(for archive: URL, _ work: (String?) async throws -> Result) async throws -> Result {
        let app = AppModel.shared
        var password = app.password(for: archive)
        while true {
            do {
                let result = try await work(password)
                app.remember(password, for: archive)
                return result
            } catch ArchiveError.passwordRequired {
                guard let entered = PasswordAlert.ask(for: archive.lastPathComponent, wrong: false) else { throw ArchiveError.cancelled }
                password = entered
            } catch ArchiveError.wrongPassword {
                guard let entered = PasswordAlert.ask(for: archive.lastPathComponent, wrong: password != nil) else { throw ArchiveError.cancelled }
                password = entered
            }
        }
    }
}

/// The question for a password, when there is no window to ask it in.
enum PasswordAlert {
    static func ask(for archive: String, wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = "“\(archive)” is protected with a password"
        alert.informativeText = wrong ? "That password is not correct. Try again." : "Enter the password to go on."
        alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
}

/// Everything about one "create an archive".
struct CompressPlan {
    var sources: [URL]
    var archive: URL
    var options: CompressionOptions
    var password: String?
    /// One archive per item, each named after its item, in the folder of `archive`.
    var separate = false
    var trashOriginals = false
    var testAfterwards = false
    /// An archive to repack: its content is what goes in, instead of `sources`.
    var converting: URL?
    var convertingPassword: String?

    /// Where the Finder would put the archive of these items, and under what name: next
    /// to them, named after the item if there is one and "Archive" if there are several.
    static func suggestedArchive(for sources: [URL], format: ArchiveFormat) -> URL {
        guard let first = sources.first else {
            return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Archive.\(format.fileExtension)")
        }
        let folder = first.deletingLastPathComponent()
        let base = suggestedName(for: sources)
        return FileNaming.uniqueURL(for: folder.appending(path: "\(base).\(format.fileExtension)"))
    }

    static func suggestedName(for sources: [URL]) -> String {
        guard sources.count == 1, let only = sources.first else { return "Archive" }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: only.path, isDirectory: &isDirectory)
        // "Report.pdf" becomes "Report.zip"; a folder keeps its dots.
        return isDirectory.boolValue ? only.lastPathComponent : FileNaming.split(only.lastPathComponent).base
    }
}

/// Creates archives in the background.
enum CompressRunner {
    @discardableResult
    static func start(_ plan: CompressPlan) -> BackgroundOperation {
        let app = AppModel.shared
        let title = plan.converting.map { "Converting \($0.lastPathComponent)" } ?? "Creating \(plan.archive.lastPathComponent)"
        return app.operations.start(title, symbol: "doc.zipper") { operation, progress in
            let engine = app.engine
            let outputs: [URL]
            if let source = plan.converting {
                outputs = [try await convert(source, plan: plan, engine: engine, operation: operation, progress: progress)]
            } else if plan.separate, plan.sources.count > 1 {
                var made: [URL] = []
                let folder = plan.archive.deletingLastPathComponent()
                for (index, source) in plan.sources.enumerated() {
                    try operation.control.checkCancellation()
                    let name = CompressPlan.suggestedName(for: [source])
                    let archive = FileNaming.uniqueURL(for: folder.appending(path: "\(name).\(plan.options.format.fileExtension)"))
                    let job = CompressionJob(sources: [source], archive: archive, options: plan.options, password: plan.password)
                    // Each archive is a share of the whole.
                    let count = Double(plan.sources.count)
                    let result = try await engine.compress(job, control: operation.control) { update in
                        var update = update
                        update.fraction = (Double(index) + (update.fraction ?? 0)) / count
                        progress(update)
                    }
                    made.append(result.output)
                }
                outputs = made
            } else {
                let job = CompressionJob(sources: plan.sources, archive: plan.archive, options: plan.options, password: plan.password)
                outputs = [try await engine.compress(job, control: operation.control, progress: progress).output]
            }

            if plan.testAfterwards {
                for output in outputs {
                    let report = try await engine.test(output, password: plan.password, control: operation.control, progress: progress)
                    if let failure = report.failures.first {
                        throw ArchiveError.damaged("The new archive did not pass its test (\(failure.path): \(failure.reason)). The original files were not touched.")
                    }
                }
            }
            // Only once the archive is known to be good.
            if plan.trashOriginals {
                for source in plan.sources {
                    try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
                }
            }
            app.settings.lastOptions = plan.options
            switch app.settings.afterCompressing {
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting(outputs)
            case .open: outputs.forEach { app.openArchive($0) }
            case .nothing: break
            }
            let size = outputs.reduce(UInt64(0)) { $0 + (UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            return OperationOutcome(
                message: outputs.count == 1 ? "\(outputs[0].lastPathComponent) — \(Formatting.bytes(size))" : "\(outputs.count) archives — \(Formatting.bytes(size))",
                results: outputs
            )
        }
    }

    /// Repacks an archive: everything is extracted to a folder next to the new archive,
    /// packed from there, and the folder removed. Half of the progress is for each.
    private static func convert(
        _ source: URL, plan: CompressPlan, engine: ArchiveEngine, operation: BackgroundOperation, progress: @escaping ProgressHandler
    ) async throws -> URL {
        let work = try WorkDirectory.make(near: plan.archive)
        defer { work.remove() }
        var job = ExtractionJob(archive: source, destination: work.url)
        job.listing = try await engine.list(source, password: plan.convertingPassword, control: operation.control)
        job.password = plan.convertingPassword
        job.conflictPolicy = .replace
        // The copy is not a download; what it holds is what the archive held.
        job.keepQuarantine = false
        let extracted = try await engine.extract(job, control: operation.control, progress: { update in
            var update = update
            update.fraction = (update.fraction ?? 0) / 2
            progress(update)
        })
        guard !extracted.items.isEmpty else { throw ArchiveError.failed("There is nothing in the archive to convert.") }
        let pack = CompressionJob(sources: extracted.items, archive: plan.archive, options: plan.options, password: plan.password)
        let result = try await engine.compress(pack, control: operation.control) { update in
            var update = update
            update.fraction = 0.5 + (update.fraction ?? 0) / 2
            progress(update)
        }
        return result.output
    }
}

/// Requests that reach the app from outside: files that are opened with it, and the
/// commands its Finder extension sends as openzip: URLs.
enum ExternalActions {
    static func handle(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            AppActions.open(files)
        }
        for url in urls where url.scheme == "openzip" {
            handle(command: url)
        }
    }

    /// openzip://extract?mode=here&path=/a.zip&path=/b.7z
    private static func handle(command url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let paths = (components.queryItems ?? []).filter { $0.name == "path" }.compactMap(\.value).map { URL(filePath: $0) }
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value }

        // Opening an archive in a window harms nothing. Everything else writes to the
        // disk, and a link on a web page must not be able to ask for that.
        if components.host == "open" {
            paths.forEach { AppModel.shared.openArchive($0) }
            return
        }
        guard isFromOwnExtension() else { return }

        switch components.host {
        case "extract":
            QuickActions.extract(paths, mode: ExtractMode(rawValue: value("mode") ?? "") ?? .here)
        case "compress":
            if let format = value("format").flatMap(ArchiveFormat.init(rawValue:)) {
                QuickActions.compress(paths, format: format)
            } else {
                AppModel.shared.newArchive(from: paths)
            }
        case "test":
            QuickActions.test(paths)
        default:
            break
        }
    }

    /// Whether the URL being handled was sent by the Finder extension inside this app.
    private static func isFromOwnExtension() -> Bool {
        if Demo.isEnabled { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              let sender = NSRunningApplication(processIdentifier: pid),
              let location = sender.bundleURL?.standardizedFileURL.path
        else { return false }
        let plugIns = Bundle.main.bundleURL.appending(path: "Contents/PlugIns").standardizedFileURL.path
        return location.hasPrefix(plugIns + "/") || sender.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
