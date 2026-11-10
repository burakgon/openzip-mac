import OpenZipKit
import SwiftUI

/// The sheets and questions of an archive window.
struct SessionDialogs: ViewModifier {
    @Bindable var session: ArchiveSession

    func body(content: Content) -> some View {
        content
            .sheet(item: $session.sheet) { sheet in
                switch sheet {
                case .extract(let selection):
                    ExtractSheet(session: session, selection: selection)
                case .add(let urls, let folder):
                    AddSheet(session: session, urls: urls, folder: folder)
                case .newFolder:
                    NewFolderSheet(session: session)
                case .comment:
                    CommentSheet(session: session)
                case .recoveryRecord:
                    RecoveryRecordSheet(session: session)
                case .details(let notice):
                    DetailsSheet(notice: notice)
                }
            }
            // Dismissing with Escape must answer the operation that is waiting, too.
            .sheet(item: $session.passwordPrompt, onDismiss: { session.answerPassword(nil) }) { prompt in
                PasswordSheet(archive: session.title, isWrong: prompt.isWrong) { session.answerPassword($0) }
            }
            .sheet(item: $session.conflictPrompt, onDismiss: { session.answerConflict(ConflictDecision(.stop)) }) { prompt in
                ConflictSheet(conflict: prompt.conflict) { session.answerConflict($0) }
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(get: { session.pendingDeletion != nil }, set: { if !$0 { session.pendingDeletion = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    let ids = session.pendingDeletion ?? []
                    session.pendingDeletion = nil
                    Task { await session.delete(ids) }
                }
                Button("Cancel", role: .cancel) { session.pendingDeletion = nil }
            } message: {
                Text("They are removed from the archive for good. Nothing on your disk outside of it is touched.")
            }
            .alert(
                "“\(session.pendingUpdate?.name ?? "")” Was Changed",
                isPresented: Binding(get: { session.pendingUpdate != nil }, set: { if !$0 { session.pendingUpdate = nil } })
            ) {
                Button("Update Archive") {
                    guard let file = session.pendingUpdate else { return }
                    session.pendingUpdate = nil
                    Task { await session.updateArchive(with: file) }
                }
                Button("Not Now", role: .cancel) { session.pendingUpdate = nil }
            } message: {
                Text("You saved it in another app. Put the changed file back into the archive?")
            }
    }

    private var deletionTitle: String {
        let ids = session.pendingDeletion ?? []
        if ids.count == 1, let id = ids.first, session.tree.contains(id) {
            return "Delete “\(session.tree[id].name)” from the archive?"
        }
        return "Delete \(ids.count) items from the archive?"
    }
}

// MARK: Password

struct PasswordSheet: View {
    let archive: String
    let isWrong: Bool
    let answer: (String?) -> Void
    @State private var password = ""
    @State private var isVisible = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(archive)” is protected with a password")
                        .font(.headline)
                    Text(isWrong ? "That password is not correct. Try again." : "Enter the password to open it.")
                        .font(.callout)
                        .foregroundStyle(isWrong ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            HStack {
                Group {
                    if isVisible {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
                Button(isVisible ? "Hide" : "Show", systemImage: isVisible ? "eye.slash" : "eye") { isVisible.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(isVisible ? "Hide the password" : "Show the password")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { answer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        answer(password)
    }
}

// MARK: Extract

struct ExtractSheet: View {
    let session: ArchiveSession
    let selection: [Int]?
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL
    @State private var folderChoice: FolderChoice
    @State private var conflictPolicy: ConflictPolicy
    @State private var flatten = false
    @State private var reveal: Bool

    init(session: ArchiveSession, selection: [Int]?) {
        self.session = session
        self.selection = selection
        let settings = session.settings
        // Where the last extraction went, if that still exists; else next to the archive.
        let last = settings.recentDestinations.first.map { URL(filePath: $0) }
        let fallback = session.url.deletingLastPathComponent()
        _destination = State(initialValue: last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback)
        _folderChoice = State(initialValue: settings.folderChoice)
        _conflictPolicy = State(initialValue: settings.conflictPolicy)
        _reveal = State(initialValue: settings.revealAfterExtracting)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("To") {
                        HStack {
                            Menu {
                                ForEach(candidates, id: \.self) { folder in
                                    Button(Formatting.folder(folder)) { destination = folder }
                                }
                                Divider()
                                Button("Choose…", action: choose)
                            } label: {
                                Label(Formatting.folder(destination), systemImage: "folder")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Button("Choose…", action: choose)
                        }
                    }
                } header: {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
                Section {
                    if selection == nil {
                        Picker("Make a folder for it", selection: $folderChoice) {
                            ForEach(FolderChoice.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Picker("If a file exists already", selection: $conflictPolicy) {
                        ForEach(ConflictPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Leave out the folders: every file directly into the destination", isOn: $flatten)
                    Toggle("Show in Finder when done", isOn: $reveal)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Extract") {
                    let options = ExtractOptions(destination: destination, folderChoice: folderChoice, conflictPolicy: conflictPolicy, flatten: flatten, reveal: reveal)
                    dismiss()
                    Task { await session.extract(selection, options: options) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        guard let selection else { return "Extract “\(session.title)”" }
        if selection.count == 1, let id = selection.first { return "Extract “\(session.tree[id].name)”" }
        return "Extract \(selection.count) Items"
    }

    /// The archive's own folder, the recent destinations, Downloads and the Desktop.
    private var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let all = [session.url.deletingLastPathComponent()]
            + session.settings.recentDestinations.map { URL(filePath: $0) }
            + [home.appending(path: "Downloads"), home.appending(path: "Desktop"), home.appending(path: "Documents")]
        var seen = Set<String>()
        return all.filter { seen.insert($0.standardizedFileURL.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Choose"
        panel.message = "Choose the folder to extract to."
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}

// MARK: Adding

/// Adding files with choices: how hard to compress, and what to do with files that are in
/// the archive already. Dropping files into the window skips this and uses the defaults.
struct AddSheet: View {
    let session: ArchiveSession
    let urls: [URL]
    let folder: Int
    @Environment(\.dismiss) private var dismiss
    @State private var level = CompressionLevel.normal
    @State private var updateMode = UpdateMode.addAndReplace
    @State private var excludeMacFiles = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Into", value: "/" + session.tree.displayPath(of: folder))
                    if session.listing.info.format?.supportsLevels == true {
                        Picker("Compression", selection: $level) {
                            ForEach(CompressionLevel.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    Picker("Files that are in the archive", selection: $updateMode) {
                        ForEach(UpdateMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Leave out .DS_Store and other files macOS makes", isOn: $excludeMacFiles)
                } header: {
                    Text("Add \(Formatting.count(urls.count, "Item")) to “\(session.title)”")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                } footer: {
                    if session.listing.hasEncryptedEntries {
                        Text("The archive is encrypted. What is added is encrypted with the same password.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var options = CompressionOptions()
                    options.level = level
                    options.updateMode = updateMode
                    options.excludeMacFiles = excludeMacFiles
                    dismiss()
                    Task { await session.add(urls, into: folder, options: options, password: nil) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Conflicts

struct ConflictSheet: View {
    let conflict: FileConflict
    let answer: (ConflictDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: conflict.existing.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(conflict.existing.lastPathComponent)” already exists")
                        .font(.headline)
                    Text("In \(Formatting.folder(conflict.existing.deletingLastPathComponent())). Replace it with the one from the archive?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                description("On disk", of: conflict.existing)
                description("In the archive", of: conflict.source)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

            Toggle("Do the same for every other file that exists", isOn: $applyToAll)

            HStack {
                Button("Stop", role: .cancel) { answer(ConflictDecision(.stop)) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { answer(ConflictDecision(.skip, applyToAll: applyToAll)) }
                Button("Keep Both") { answer(ConflictDecision(.keepBoth, applyToAll: applyToAll)) }
                Button("Replace") { answer(ConflictDecision(.replace, applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func description(_ label: String, of url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if values?.isDirectory == true {
                Text("Folder")
            } else {
                Text(Formatting.bytes(UInt64(values?.fileSize ?? 0)))
                    .monospacedDigit()
            }
            Text(Formatting.date(values?.contentModificationDate))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Small ones

struct NewFolderSheet: View {
    let session: ArchiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = "untitled folder"
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Folder")
                .font(.headline)
            Text("In /\(session.currentPath)")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/")
    }

    private func create() {
        guard isValid else { return }
        let name = name
        dismiss()
        Task { await session.newFolder(named: name) }
    }
}

struct CommentSheet: View {
    let session: ArchiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var comment: String

    init(session: ArchiveSession) {
        self.session = session
        _comment = State(initialValue: session.listing.info.comment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment of “\(session.title)”")
                .font(.headline)
            Text("A note that travels with the archive. Programs that open it show it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $comment)
                .font(.body.monospaced())
                .frame(height: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let comment = comment
                    dismiss()
                    Task { await session.setComment(comment) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(comment == session.listing.info.comment)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct RecoveryRecordSheet: View {
    let session: ArchiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var percent = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Protect “\(session.title)” from Damage")
                .font(.headline)
            Text("A recovery record is extra data in the archive. If part of the file gets damaged, on a bad disk or a failed download, it can be repaired from it. The larger the record, the more damage it covers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Slider(value: $percent, in: 1...30, step: 1)
                Text("\(Int(percent))% of the archive")
                    .monospacedDigit()
                    .frame(width: 130, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Recovery Record") {
                    let percent = Int(percent)
                    dismiss()
                    Task { await session.addRecoveryRecord(percent: percent) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// More than fits into a line: the files a test or an extraction failed on.
struct DetailsSheet: View {
    let notice: Notice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(notice.text)
                .font(.headline)
            List(notice.details, id: \.self) { line in
                Text(line)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .listStyle(.bordered)
            .frame(minHeight: 180)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(notice.details.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }
}
