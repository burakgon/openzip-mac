import AppKit
import Observation
import OpenZipKit

/// What a window is busy with.
@Observable
final class Activity {
    let title: String
    var item = ""
    var fraction: Double?
    var isPaused = false
    let started = Date()
    @ObservationIgnored let control = OperationControl()

    init(_ title: String) {
        self.title = title
    }

    var remaining: String? {
        guard !isPaused, let fraction, fraction > 0.03, fraction < 0.995 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 3 else { return nil }
        return Formatting.remaining(elapsed * (1 - fraction) / fraction)
    }

    func cancel() {
        control.cancel()
    }

    func togglePause() {
        if isPaused { control.resume() } else { control.pause() }
        isPaused.toggle()
    }
}

/// What a window has to say about something that happened in it.
struct Notice: Identifiable, Equatable {
    enum Kind { case success, warning, failure }

    let id = UUID()
    var kind: Kind
    var text: String
    /// More than fits in a line: the files that failed, for example.
    var details: [String] = []
    /// What "Show in Finder" shows.
    var reveal: [URL] = []
}

/// The dialogs of an archive window.
enum SessionSheet: Identifiable {
    case extract(selection: [Int]?)
    case add([URL], folder: Int)
    case newFolder
    case comment
    case recoveryRecord
    case recoveryVolumes
    case details(Notice)

    var id: String {
        switch self {
        case .extract: "extract"
        case .add: "add"
        case .newFolder: "newFolder"
        case .comment: "comment"
        case .recoveryRecord: "recoveryRecord"
        case .recoveryVolumes: "recoveryVolumes"
        case .details: "details"
        }
    }
}

/// A question the window has to ask in the middle of an operation, which waits for the answer.
struct PasswordPrompt: Identifiable {
    let id = UUID()
    var isWrong: Bool
}

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let conflict: FileConflict
}

/// What to extract to where, as chosen in the dialog.
struct ExtractOptions {
    var destination: URL
    var folderChoice: FolderChoice
    var conflictPolicy: ConflictPolicy
    var flatten = false
    var reveal = true
}

/// One archive in one window: what is in it, where the window is looking, what is
/// selected and what is being done with it.
@Observable
final class ArchiveSession: Identifiable {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let id = UUID()
    private(set) var url: URL
    private(set) var phase = Phase.loading
    private(set) var listing = ArchiveListing()
    private(set) var tree = ArchiveTree()
    private(set) var editability = Editability.readOnly("")
    /// The folder the window shows.
    private(set) var folder = ArchiveTree.rootID
    /// The nodes in the list, in the order they are shown.
    private(set) var rows: [Int] = []
    /// Counts up whenever `rows` is replaced, so the table knows to reload.
    private(set) var rowsVersion = 0
    var selection: Set<Int> = []
    var searchText = "" {
        didSet { if searchText != oldValue { refreshRows() } }
    }
    /// Show every file of the folder and the folders in it as one list.
    var isFlat = false {
        didSet { if isFlat != oldValue { refreshRows() } }
    }
    private(set) var activity: Activity?
    var notice: Notice?
    var sheet: SessionSheet?
    var passwordPrompt: PasswordPrompt?
    var conflictPrompt: ConflictPrompt?
    /// The file Quick Look is showing.
    var previewURL: URL?
    /// The nodes waiting for a "delete?" to be answered.
    var pendingDeletion: [Int]?
    /// A file that was opened in another app and changed there.
    var pendingUpdate: EditedFile?
    /// Set to make the list start renaming a row.
    var renameRequest: Int?

    struct EditedFile: Identifiable, Equatable {
        let id = UUID()
        var name: String
        /// The folder of the archive the file belongs to, as shown.
        var folderPath: String
        var url: URL
        var modified: Date
    }

    @ObservationIgnored private var back: [String] = []
    @ObservationIgnored private var forward: [String] = []
    @ObservationIgnored private var password: String?
    /// The password the user typed last, to tell it from one that was only tried.
    @ObservationIgnored private var typedPassword: String?
    /// Whether the password that was typed goes into the keychain once it has opened the archive.
    @ObservationIgnored private var remembersPassword = false
    @ObservationIgnored private var extracted: [String: URL] = [:]
    @ObservationIgnored private var edited: [EditedFile] = []
    @ObservationIgnored private var previewNode: Int?
    // The operations waiting for an answer. Kept apart from the prompts, which SwiftUI
    // clears by itself when a sheet is dismissed with the Escape key.
    @ObservationIgnored private var passwordContinuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?
    @ObservationIgnored private let app = AppModel.shared
    /// Where files extracted for a look are kept until the window closes.
    @ObservationIgnored private lazy var scratch = FileManager.default.temporaryDirectory
        .appending(path: "OpenZip-\(id.uuidString)", directoryHint: .isDirectory)

    init(url: URL) {
        self.url = url
        password = app.password(for: url)
    }

    // MARK: State

    var title: String { url.lastPathComponent }
    var isBusy: Bool { activity != nil }
    var isReady: Bool { phase == .ready }
    var canEdit: Bool { isReady && !isBusy && editability.canEdit }
    var settings: AppSettings { app.settings }
    var currentPath: String { tree.displayPath(of: folder) }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { folder != ArchiveTree.rootID }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The selected nodes, in the order of the list.
    var selectedRows: [Int] {
        rows.filter { selection.contains($0) }
    }

    /// The selection without what is inside a folder that is selected too: deleting or
    /// extracting the folder covers it.
    var selectedRoots: [Int] {
        let chosen = selection
        return selectedRows.filter { id in
            var parent = tree[id].parent
            while parent > 0 {
                if chosen.contains(parent) { return false }
                parent = tree[parent].parent
            }
            return true
        }
    }

    /// Why the archive cannot be changed, if it cannot.
    var readOnlyReason: String? {
        switch editability {
        case .editable: nil
        case .needsRar: "Changing RAR archives needs RARLAB’s RAR. It can be set up in Settings."
        case .readOnly(let reason): reason
        }
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            let listing = try await perform("Opening \(title)") { engine, password, control, progress in
                try await engine.list(self.url, password: password, control: control, progress: progress)
            }
            await apply(listing, keeping: nil)
            phase = .ready
        } catch ArchiveError.cancelled {
            phase = .failed(listing.entries.isEmpty ? "The archive was not opened." : "")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the archive again after it was changed, and stays where the window was.
    func reload() async {
        let path = currentPath
        do {
            let listing = try await app.engine.list(url, password: password)
            await apply(listing, keeping: path)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ listing: ArchiveListing, keeping path: String?) async {
        // Building the tree of a large archive takes a moment that the window should not wait for.
        let entries = listing.entries
        let tree = await Task.detached { ArchiveTree(entries: entries) }.value
        self.listing = listing
        self.tree = tree
        editability = app.engine.editability(of: listing.info, at: url)
        folder = path.flatMap { tree.node(atDisplayPath: $0) } ?? ArchiveTree.rootID
        if !tree[folder].isDirectory { folder = ArchiveTree.rootID }
        selection = []
        extracted.removeAll()
        refreshRows()
    }

    // MARK: The list

    func refreshRows() {
        let showsMacFiles = settings.showsMacFiles
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var ids: [Int]
        if !query.isEmpty {
            ids = tree.search(query, in: folder, includeMacMetadata: showsMacFiles)
        } else if isFlat {
            ids = tree.descendants(of: folder, includeFolders: false)
        } else {
            ids = tree[folder].children
        }
        if !showsMacFiles {
            ids = ids.filter { !isHidden($0) }
        }
        rows = tree.sorted(ids, by: settings.sortKey, ascending: settings.sortAscending, foldersFirst: query.isEmpty && !isFlat)
        selection.formIntersection(rows)
        rowsVersion += 1
    }

    /// Whether a node is, or is inside, what macOS made and nobody packed on purpose.
    private func isHidden(_ id: Int) -> Bool {
        var current = id
        while current > 0 {
            let node = tree[current]
            if node.isMacMetadata { return true }
            current = node.parent
            // Only "__MACOSX" hides what is in it; the other names are files.
            if current > 0, tree[current].name != "__MACOSX" { break }
        }
        return false
    }

    func sort(by key: ArchiveTree.SortKey, ascending: Bool) {
        guard settings.sortKey != key || settings.sortAscending != ascending else { return }
        settings.sortKey = key
        settings.sortAscending = ascending
        refreshRows()
    }

    func selectAll() {
        selection = Set(rows)
    }

    /// The folders in a folder, for the sidebar.
    func folders(in id: Int) -> [Int] {
        let showsMacFiles = settings.showsMacFiles
        let ids = tree[id].children.filter { tree[$0].isDirectory && (showsMacFiles || !tree[$0].isMacMetadata) }
        return tree.sorted(ids, by: .name, ascending: true)
    }

    // MARK: Moving around

    func navigate(to id: Int) {
        guard tree.contains(id), tree[id].isDirectory, id != folder || isSearching else { return }
        if id != folder {
            back.append(currentPath)
            forward.removeAll()
        }
        show(id)
    }

    private func show(_ id: Int) {
        folder = id
        selection = []
        if searchText.isEmpty {
            refreshRows()
        } else {
            searchText = ""
        }
    }

    func goBack() {
        guard let path = back.popLast() else { return }
        forward.append(currentPath)
        show(tree.node(atDisplayPath: path) ?? ArchiveTree.rootID)
    }

    func goForward() {
        guard let path = forward.popLast() else { return }
        back.append(currentPath)
        show(tree.node(atDisplayPath: path) ?? ArchiveTree.rootID)
    }

    func goUp() {
        guard canGoUp else { return }
        let from = folder
        navigate(to: tree[folder].parent)
        // Coming out of a folder leaves it selected, as in the Finder.
        if rows.contains(from) { selection = [from] }
    }

    /// Double click, or Open: a folder is entered, a file is opened.
    func open(_ id: Int) {
        guard tree.contains(id) else { return }
        if tree[id].isDirectory {
            navigate(to: id)
        } else {
            Task { await openFile(id) }
        }
    }

    // MARK: Looking at files

    /// Extracts one file to a temporary place, once, and says where it is.
    private func extractForViewing(_ id: Int) async -> URL? {
        let node = tree[id]
        if let known = extracted[node.path], FileManager.default.fileExists(atPath: known.path) { return known }
        do {
            let target = scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let file = try await perform("Preparing “\(node.name)”") { engine, password, control, progress in
                try await engine.extractFile(
                    node.path, from: self.url, listing: self.listing, password: password, into: target,
                    control: control, progress: progress
                )
            }
            extracted[node.path] = file
            return file
        } catch {
            report(error)
            return nil
        }
    }

    private func openFile(_ id: Int) async {
        let node = tree[id]
        guard let file = await extractForViewing(id) else { return }
        if FileIcons.isArchive(name: node.name) {
            // An archive in an archive opens in a window of its own, with the same password.
            app.remember(password, for: file)
            app.openArchive(file)
            return
        }
        NSWorkspace.shared.open(file)
        watch(file, for: id)
    }

    /// Remembers a file that was handed to another app, to notice when it is saved there.
    func watch(_ file: URL, for id: Int) {
        guard editability.canEdit else { return }
        let node = tree[id]
        let modified = Self.modificationDate(of: file) ?? Date()
        edited.removeAll { $0.url == file }
        edited.append(EditedFile(name: node.name, folderPath: tree.displayPath(of: node.parent), url: file, modified: modified))
    }

    /// Extracts a file for looking at, for the demo's steps.
    func extractForDemo(_ id: Int) async -> URL? {
        await extractForViewing(id)
    }

    /// Space: shows the selected file in Quick Look, or closes it.
    func togglePreview() {
        if previewURL != nil {
            previewURL = nil
            previewNode = nil
        } else {
            Task { await updatePreview(force: true) }
        }
    }

    /// Follows the selection while Quick Look is open.
    func updatePreview(force: Bool = false) async {
        guard force || previewURL != nil else { return }
        guard let id = selectedRows.first(where: { !tree[$0].isDirectory }), id != previewNode || force else { return }
        guard !isBusy else { return }
        previewNode = id
        if let file = await extractForViewing(id), previewNode == id {
            previewURL = file
        }
    }

    /// Looks whether a file that was opened in another app has been saved there since.
    func checkEditedFiles() {
        guard pendingUpdate == nil, !isBusy else { return }
        for (index, file) in edited.enumerated() {
            guard let now = Self.modificationDate(of: file.url) else { continue }
            if now > file.modified.addingTimeInterval(0.5) {
                edited[index].modified = now
                pendingUpdate = edited[index]
                return
            }
        }
    }

    /// When a file was last written. Asked of the file system each time: a URL remembers
    /// what it was told once, and would never notice a change.
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Puts a file that was changed in another app back into the archive.
    func updateArchive(with file: EditedFile) async {
        let target = tree.node(atDisplayPath: file.folderPath) ?? ArchiveTree.rootID
        await add([file.url], into: target, options: nil, password: nil)
    }

    // MARK: Extracting

    func extract(_ ids: [Int]?, options: ExtractOptions) async {
        var job = ExtractionJob(archive: url, destination: options.destination, listing: listing)
        job.items = ids.map { $0.map { ExtractionJob.Item(path: tree[$0].path) } }
        // A whole archive may get a folder of its own. A selection goes where it is sent.
        if ids == nil {
            job.folderPolicy = options.folderChoice.policy(named: FileNaming.archiveBaseName(url.lastPathComponent))
        }
        job.conflictPolicy = options.conflictPolicy
        job.flatten = options.flatten
        job.restoreMacMetadata = settings.restoreMacMetadata
        job.keepQuarantine = settings.keepQuarantine
        let prepared = job

        do {
            let result = try await perform(ids == nil ? "Extracting \(title)" : "Extracting \(Formatting.count(ids?.count ?? 0, "item"))") { engine, password, control, progress in
                var job = prepared
                job.password = password
                return try await engine.extract(job, control: control, resolver: { conflict in
                    await self.ask(about: conflict)
                }, progress: progress)
            }
            settings.noteDestination(options.destination)
            let place = Formatting.folder(result.container)
            if result.report.failures.isEmpty {
                var text = "Extracted \(Formatting.count(result.items.count, "item")) to \(place)"
                if result.skipped > 0 { text += ", skipped \(result.skipped)" }
                notice = Notice(kind: .success, text: text, reveal: result.items)
            } else {
                notice = Notice(
                    kind: .warning,
                    text: "\(Formatting.count(result.report.failures.count, "file")) could not be extracted",
                    details: result.report.failures.map { "\($0.path) — \($0.reason)" },
                    reveal: result.items
                )
            }
            if options.reveal, !result.items.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(result.items)
            }
        } catch {
            report(error)
        }
    }

    /// Extracts for a drag out of the window: into a folder next to where the items are
    /// dropped, from which each is then moved to the name the Finder gave it.
    func extractForDrag(_ ids: [Int], near destination: URL) async throws -> [Int: URL] {
        let work = try WorkDirectory.make(near: destination)
        var job = ExtractionJob(archive: url, destination: work.url, listing: listing)
        job.items = ids.map { ExtractionJob.Item(path: tree[$0].path) }
        job.conflictPolicy = .keepBoth
        job.restoreMacMetadata = settings.restoreMacMetadata
        job.keepQuarantine = settings.keepQuarantine
        let prepared = job
        let result = try await perform("Extracting \(Formatting.count(ids.count, "item"))") { engine, password, control, progress in
            var job = prepared
            job.password = password
            return try await engine.extract(job, control: control, progress: progress)
        }
        var locations: [Int: URL] = [:]
        for id in ids {
            let file = work.url.appending(path: tree[id].name)
            if result.items.contains(where: { $0.lastPathComponent == tree[id].name }) { locations[id] = file }
        }
        return locations
    }

    // MARK: The clipboard

    /// How much Copy extracts without asking first.
    private static let copiedWithoutAsking: UInt64 = 500_000_000

    var canPaste: Bool { canEdit && FileClipboard.hasFiles }

    /// Edit → Copy. The names of what is selected are on the clipboard at once. The files
    /// themselves follow when they have been extracted to a temporary place, which is
    /// where the clipboard can point to; a large selection is asked about first.
    func copySelection(askingAboutSize: Bool = true) async {
        let ids = selectedRoots
        guard isReady, !ids.isEmpty else { return }
        let stamp = FileClipboard.write(names: selectedRows.map { tree[$0].name })
        // While the window is busy with something else, the names are all there is.
        guard !isBusy else { return }
        let size = ids.reduce(UInt64(0)) { $0.addingReportingOverflow(tree[$1].size).partialValue }
        if askingAboutSize, size > Self.copiedWithoutAsking, !Self.confirmCopying(size) { return }

        let folder: URL
        do {
            folder = try FileClipboard.makeFolder()
        } catch {
            report(error)
            return
        }
        var job = ExtractionJob(archive: url, destination: folder, listing: listing)
        job.items = ids.map { ExtractionJob.Item(path: tree[$0].path) }
        job.conflictPolicy = .keepBoth
        job.restoreMacMetadata = settings.restoreMacMetadata
        job.keepQuarantine = settings.keepQuarantine
        let prepared = job
        do {
            let result = try await perform("Copying \(Formatting.count(ids.count, "item"))") { engine, password, control, progress in
                var job = prepared
                job.password = password
                return try await engine.extract(job, control: control, progress: progress)
            }
            // Something else may have been copied while this was at work: that stays.
            guard FileClipboard.isUnchanged(since: stamp), !result.items.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            FileClipboard.write(files: result.items, in: folder)
            if result.report.failures.isEmpty {
                notice = Notice(kind: .success, text: "Copied \(Formatting.count(result.items.count, "item")). Paste in the Finder, or in another archive.")
            } else {
                notice = Notice(
                    kind: .warning,
                    text: "\(Formatting.count(result.report.failures.count, "file")) could not be copied",
                    details: result.report.failures.map { "\($0.path) — \($0.reason)" }
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            report(error)
        }
    }

    private static func confirmCopying(_ size: UInt64) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Copy \(Formatting.bytes(size)) out of the archive?"
        alert.informativeText = "What is copied is extracted to a temporary place first, and pasted from there. The names are on the clipboard already."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Edit → Paste: files from the clipboard go into the folder the window shows. They
    /// are read from the clipboard by whoever was asked to paste, in that very moment.
    func paste(_ files: [URL]) async {
        guard canEdit, !files.isEmpty else { return }
        await add(files, into: nil, options: nil, password: nil)
    }

    // MARK: Changing

    func add(_ urls: [URL], into target: Int?, options: CompressionOptions?, password newPassword: String?) async {
        guard canEdit, !urls.isEmpty, let format = listing.info.format else { return }
        let target = target ?? folder
        var options = options ?? CompressionOptions()
        options.format = format
        options.excludeMacFiles = options.excludeMacFiles && settings.lastOptions.excludeMacFiles
        // What is added to an encrypted archive is encrypted like the rest of it.
        let encrypting = newPassword ?? (listing.hasEncryptedEntries ? password : nil)
        options.encryptFileNames = listing.info.hasEncryptedHeaders
        let targetPath = tree.displayPath(of: target)
        let job = CompressionJob(sources: urls, archive: url, folder: targetPath, options: options, password: encrypting)
        let names = Set(urls.map(\.lastPathComponent))

        do {
            let result = try await perform("Adding \(Formatting.count(urls.count, "item"))") { engine, password, control, progress in
                // The archive may need its own password to be opened for the change.
                var job = job
                if job.password == nil, self.listing.info.hasEncryptedHeaders { job.password = password }
                return try await engine.compress(job, control: control, progress: progress)
            }
            await reload()
            // Show what was added, if the window is looking at where it went.
            if currentPath == targetPath {
                let added = rows.filter { names.contains(tree[$0].name) }
                if !added.isEmpty { selection = Set(added) }
            }
            if result.report.warnings.isEmpty {
                notice = Notice(kind: .success, text: "Added \(Formatting.count(urls.count, "item"))")
            } else {
                notice = Notice(kind: .warning, text: "Added, with warnings", details: result.report.warnings)
            }
        } catch {
            report(error)
        }
    }

    /// Asks before deleting, if the settings say so.
    func requestDeletion(_ ids: [Int]) {
        guard canEdit, !ids.isEmpty else { return }
        if settings.confirmsDeleting {
            pendingDeletion = ids
        } else {
            Task { await delete(ids) }
        }
    }

    func delete(_ ids: [Int]) async {
        guard canEdit, !ids.isEmpty else { return }
        let paths = ids.map { tree[$0].path }
        await change("Deleting \(Formatting.count(ids.count, "item"))") { engine, password, control, progress in
            try await engine.delete(paths, from: self.url, info: self.listing.info, password: password, control: control, progress: progress)
        }
    }

    /// Renames one entry. Returns false if the name cannot be used.
    @discardableResult
    func rename(_ id: Int, to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = tree[id]
        guard canEdit, !name.isEmpty, name != node.name else { return false }
        guard !name.contains("/"), name != ".", name != ".." else {
            notice = Notice(kind: .failure, text: "A name cannot contain a slash.")
            return false
        }
        guard !tree[node.parent].children.contains(where: { $0 != id && tree[$0].name == name }) else {
            notice = Notice(kind: .failure, text: "“\(name)” already exists in this folder.")
            return false
        }
        let parent = (node.path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : "\(parent)/\(name)"
        let changed = await change("Renaming “\(node.name)”") { engine, password, control, progress in
            try await engine.rename([(from: node.path, to: target)], in: self.url, info: self.listing.info, password: password, control: control, progress: progress)
        }
        if changed, let renamed = tree[folder].children.first(where: { tree[$0].name == name }) {
            selection = [renamed]
        }
        return changed
    }

    /// Moves entries into another folder of the archive.
    func move(_ ids: [Int], to target: Int) async {
        guard canEdit, tree.contains(target), tree[target].isDirectory else { return }
        var changes: [(from: String, to: String)] = []
        for id in ids {
            let node = tree[id]
            // Not into itself, not into where it is, and not onto something of its name.
            guard node.parent != target, !tree.isNode(target, inside: id) else { continue }
            guard !tree[target].children.contains(where: { tree[$0].name == node.name }) else {
                notice = Notice(kind: .failure, text: "“\(node.name)” already exists in “\(tree[target].name)”.")
                return
            }
            let base = tree[target].path
            changes.append((node.path, base.isEmpty ? node.name : "\(base)/\(node.name)"))
        }
        guard !changes.isEmpty else { return }
        let prepared = changes
        await change("Moving \(Formatting.count(changes.count, "item"))") { engine, password, control, progress in
            try await engine.rename(prepared, in: self.url, info: self.listing.info, password: password, control: control, progress: progress)
        }
    }

    func newFolder(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !name.isEmpty, !name.contains("/") else { return }
        guard !tree[folder].children.contains(where: { tree[$0].name == name }) else {
            notice = Notice(kind: .failure, text: "“\(name)” already exists in this folder.")
            return
        }
        let path = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        let changed = await change("Creating “\(name)”") { engine, password, control, progress in
            try await engine.createFolder(path, in: self.url, info: self.listing.info, password: password, control: control, progress: progress)
        }
        if changed, let created = tree[folder].children.first(where: { tree[$0].name == name }) {
            selection = [created]
        }
    }

    func setComment(_ comment: String) async {
        await change("Saving the comment") { engine, password, control, _ in
            try await engine.setComment(comment, of: self.url, info: self.listing.info, password: password, control: control)
        }
    }

    func lock() async {
        await change("Locking the archive") { engine, password, control, _ in
            try await engine.lock(self.url, password: password, control: control)
        }
    }

    func addRecoveryRecord(percent: Int) async {
        let changed = await change("Adding a recovery record") { engine, password, control, progress in
            try await engine.addRecoveryRecord(to: self.url, percent: percent, password: password, control: control, progress: progress)
        }
        if changed { notice = Notice(kind: .success, text: "The archive can now repair itself after damage") }
    }

    /// Makes recovery volumes for an archive that is split into volumes.
    func addRecoveryVolumes(count: Int) async {
        do {
            let made = try await perform("Making recovery volumes") { engine, password, control, progress in
                try await engine.addRecoveryVolumes(to: self.url, count: count, password: password, control: control, progress: progress)
            }
            notice = Notice(
                kind: .success,
                text: "Made \(Formatting.count(made.count, "recovery volume")): as many volumes may now get lost",
                reveal: made
            )
        } catch {
            report(error)
        }
    }

    /// Makes the volumes that are missing again, from the recovery volumes.
    func rebuildVolumes() async {
        do {
            let back = try await perform("Rebuilding the missing volumes") { engine, password, control, progress in
                try await engine.rebuildVolumes(of: self.url, password: password, control: control, progress: progress)
            }
            // If the first volume was among the lost, the window was opened on another
            // one and saw only part of the archive. Now it can look at all of it.
            let first = FileNaming.firstVolume(of: url)
            if first != url {
                app.remember(password, for: first)
                url = first
            }
            await reload()
            notice = Notice(
                kind: .success,
                text: back.count == 1 ? "“\(back[0].lastPathComponent)” is back" : "\(Formatting.count(back.count, "volume")) are back",
                reveal: back
            )
        } catch {
            report(error)
        }
    }

    func repair() async {
        do {
            let repaired = try await perform("Repairing \(title)") { engine, password, control, progress in
                try await engine.repairRar(self.url, password: password, control: control, progress: progress)
            }
            notice = Notice(kind: .success, text: "The repaired copy is “\(repaired.lastPathComponent)”", reveal: [repaired])
        } catch {
            report(error)
        }
    }

    /// Runs a change to the archive and reads it again. Returns whether it went through.
    @discardableResult
    private func change(
        _ title: String,
        _ work: (ArchiveEngine, String?, OperationControl, @escaping ProgressHandler) async throws -> Void
    ) async -> Bool {
        do {
            try await perform(title, work)
            await reload()
            return true
        } catch {
            report(error)
            // Whatever happened, show the archive as it is now.
            if !(error is CancellationError), (error as? ArchiveError) != .cancelled { await reload() }
            return false
        }
    }

    // MARK: Testing

    func test() async {
        do {
            let report = try await perform("Testing \(title)") { engine, password, control, progress in
                try await engine.test(self.url, password: password, control: control, progress: progress)
            }
            if report.failures.isEmpty {
                let files = report.fileCount ?? tree.root.fileCount
                notice = Notice(kind: .success, text: "No errors found in \(Formatting.count(files, "file"))")
            } else {
                notice = Notice(
                    kind: .failure,
                    text: "\(Formatting.count(report.failures.count, "file")) damaged",
                    details: report.failures.map { "\($0.path) — \($0.reason)" }
                )
                sheet = notice.map { .details($0) }
            }
        } catch {
            report(error)
        }
    }

    // MARK: Reporting

    /// Writes the list of what is in the archive to a file.
    func writeReport(to file: URL, as format: ArchiveReport.Format) {
        do {
            try ArchiveReport.make(of: listing, named: title, as: format).write(to: file, atomically: true, encoding: .utf8)
            notice = Notice(kind: .success, text: "The list of \(Formatting.count(listing.entries.count, "item")) is in “\(file.lastPathComponent)”", reveal: [file])
        } catch {
            report(error)
        }
    }

    // MARK: Running operations

    /// Runs an operation as the window's activity, and asks for the password when the
    /// archive turns out to need one or the one given turns out to be wrong.
    @discardableResult
    private func perform<Result>(
        _ title: String,
        _ work: (ArchiveEngine, String?, OperationControl, @escaping ProgressHandler) async throws -> Result
    ) async throws -> Result {
        // One thing at a time in a window: two operations on one archive would get in
        // each other's way.
        guard self.activity == nil else {
            throw ArchiveError.failed("“\(self.title)” is busy. Try again when it is done.")
        }
        let activity = Activity(title)
        self.activity = activity
        defer {
            if self.activity === activity { self.activity = nil }
        }
        let sink = ProgressSink { [weak activity] progress in
            guard let activity else { return }
            if let fraction = progress.fraction { activity.fraction = fraction }
            if !progress.currentItem.isEmpty { activity.item = progress.currentItem }
        }
        let engine = app.engine
        // Before anyone is asked, the passwords in the keychain are tried.
        var remembered = PasswordVault.Attempts()
        while true {
            do {
                let result = try await work(engine, password, activity.control, sink.handler)
                app.remember(password, for: url)
                if remembersPassword, let password, password == typedPassword {
                    remembersPassword = false
                    PasswordVault.save(password, label: self.title)
                }
                return result
            } catch ArchiveError.passwordRequired {
                if let next = remembered.next(after: password) {
                    password = next
                } else {
                    guard let entered = await askPassword(wrong: false) else { throw ArchiveError.cancelled }
                    password = entered
                }
            } catch ArchiveError.wrongPassword {
                if let next = remembered.next(after: password) {
                    password = next
                } else {
                    // "Not correct" is only said of a password that was typed.
                    guard let entered = await askPassword(wrong: password != nil && password == typedPassword) else { throw ArchiveError.cancelled }
                    password = entered
                }
            }
        }
    }

    private func report(_ error: Error) {
        if let error = error as? ArchiveError {
            if error == .cancelled { return }
            if case .toolMissing = error {
                notice = Notice(kind: .failure, text: "This needs RARLAB’s RAR, which is not installed. It can be set up in Settings.")
                return
            }
        }
        notice = Notice(kind: .failure, text: error.localizedDescription)
    }

    // MARK: Questions

    private func askPassword(wrong: Bool) async -> String? {
        // The demo can answer by itself, once: --answer-password secret --remember.
        if let answer = Demo.passwordAnswer() {
            typedPassword = answer
            remembersPassword = Demo.arguments.contains("--remember")
            return answer
        }
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordPrompt = PasswordPrompt(isWrong: wrong)
        }
    }

    /// Answers the question for the password. nil gives up. Safe to call when nothing is asked.
    func answerPassword(_ password: String?, remember: Bool = false) {
        passwordPrompt = nil
        if let password {
            typedPassword = password
            remembersPassword = remember
        }
        let continuation = passwordContinuation
        passwordContinuation = nil
        continuation?.resume(returning: password)
    }

    private func ask(about conflict: FileConflict) async -> ConflictDecision {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflictPrompt = ConflictPrompt(conflict: conflict)
        }
    }

    func answerConflict(_ decision: ConflictDecision) {
        conflictPrompt = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: decision)
    }

    /// The password the window knows, for handing the archive on to another operation.
    var knownPassword: String? { password }

    // MARK: Closing

    /// Stops what is running and removes what was extracted for looking at.
    func close() {
        activity?.cancel()
        answerPassword(nil)
        answerConflict(ConflictDecision(.stop))
        try? FileManager.default.removeItem(at: scratch)
    }
}
