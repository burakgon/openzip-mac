import OpenZipKit
import SwiftUI

/// The state of a "New Archive" window.
@Observable
final class CompressModel {
    var sources: [URL]
    let converting: URL?
    let convertingPassword: String?
    var name: String
    var folder: URL
    var options: CompressionOptions
    var password = ""
    var verification = ""
    var showsPassword = false
    var separate = false
    var trashOriginals = false
    var testAfterwards = false
    /// The size of the volumes in megabytes, when it is none of the usual ones.
    var customVolume = ""
    var usesCustomVolume = false
    private(set) var scan: SourceScan?

    @ObservationIgnored private let app = AppModel.shared

    init(draft: CompressDraft) {
        sources = draft.sources
        converting = draft.converting
        convertingPassword = draft.convertingPassword
        var options = AppModel.shared.settings.lastOptions
        // What belonged to the last archive only.
        options.comment = ""
        options.updateMode = .addAndReplace
        options.selfExtracting = false
        options.lock = false
        self.options = options

        if let converting = draft.converting {
            name = FileNaming.archiveBaseName(converting.lastPathComponent)
            folder = converting.deletingLastPathComponent()
            // Converting to the format it already has would be pointless.
            if ArchiveFormat(fileName: converting.lastPathComponent) == options.format {
                self.options.format = options.format == .zip ? .sevenZip : .zip
            }
        } else {
            name = CompressPlan.suggestedName(for: draft.sources)
            folder = draft.sources.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        }
        fit()
        // A new archive starts with a name that is free. Adding to an existing archive is
        // possible, by choosing its name, and never happens by accident.
        let free = FileNaming.uniqueURL(for: archive)
        name = String(free.lastPathComponent.dropLast(format.fileExtension.count + 1))
    }

    // MARK: What is possible

    var format: ArchiveFormat { options.format }

    /// Whether what is to be packed is one file and nothing else.
    var isSingleFile: Bool {
        guard converting == nil, sources.count == 1 else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: sources[0].path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    var hasRar: Bool { app.tools.rar != nil }

    func isAvailable(_ format: ArchiveFormat) -> Bool {
        if format.needsRar { return hasRar }
        if format.isSingleFile { return isSingleFile }
        return true
    }

    /// Brings the options in line with what the format can do.
    func fit() {
        if !isAvailable(options.format) { options.format = .zip }
        let format = options.format
        if let method = options.method, !format.methods.contains(method) { options.method = nil }
        if let size = options.dictionarySize, !format.dictionarySizes(method: options.method).contains(size) { options.dictionarySize = nil }
        if !format.supportsSolid { options.solid = nil }
        if !format.supportsVolumes { options.volumeSize = nil }
        if !format.supportsEncryptedNames { options.encryptFileNames = false }
        if !format.supportsSelfExtracting || format != .rar { options.selfExtracting = false }
        if format != .rar {
            options.recoveryPercent = 0
            options.lock = false
        }
        if !format.supportsComment { options.comment = "" }
        if !format.supportsPassword {
            password = ""
            verification = ""
        }
        if format.isSingleFile { separate = false }
    }

    // MARK: Where it goes

    var archive: URL {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return folder.appending(path: "\(trimmed.isEmpty ? "Archive" : trimmed).\(format.fileExtension)")
    }

    /// The archive exists: creating it means adding to it.
    var exists: Bool {
        !separate && FileManager.default.fileExists(atPath: archive.path)
    }

    /// What keeps the archive from being created, if anything.
    var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the archive a name." }
        if trimmed.contains("/") || trimmed.contains(":") { return "The name cannot contain a slash or a colon." }
        if !password.isEmpty {
            if !showsPassword, password != verification { return "The two passwords are not the same." }
            if let problem = format.problem(withPassword: password) { return problem }
        }
        if usesCustomVolume, format.supportsVolumes, customVolumeBytes == nil { return "Enter the size of the volumes in megabytes." }
        if let converting, converting.standardizedFileURL == archive.standardizedFileURL { return "Choose another name or format: this is the archive being converted." }
        return nil
    }

    var customVolumeBytes: UInt64? {
        guard let megabytes = Double(customVolume.replacingOccurrences(of: ",", with: ".")), megabytes >= 0.1 else { return nil }
        return UInt64(megabytes * 1_048_576)
    }

    // MARK: Looking at the sources

    func rescan() async {
        guard converting == nil else { return }
        let sources = sources
        let options = options
        scan = await Task.detached { ArchiveEngine.scan(sources, options: options) }.value
    }

    var summary: String {
        if let converting { return "Everything in “\(converting.lastPathComponent)”" }
        guard let scan else { return Formatting.count(sources.count, "item") }
        var text = "\(Formatting.contents(files: scan.fileCount, folders: max(0, scan.folderCount))) — \(Formatting.bytes(scan.totalSize))"
        if !scan.excluded.isEmpty { text += ", \(scan.excluded.count) left out" }
        return text
    }

    // MARK: Going

    func start() {
        var options = options
        if usesCustomVolume, format.supportsVolumes { options.volumeSize = customVolumeBytes }
        let plan = CompressPlan(
            sources: sources, archive: archive, options: options, password: password.isEmpty ? nil : password,
            separate: separate, trashOriginals: trashOriginals, testAfterwards: testAfterwards,
            converting: converting, convertingPassword: convertingPassword
        )
        CompressRunner.start(plan)
    }
}

/// The window that creates an archive: what WinRAR calls "Archive name and parameters".
struct CompressView: View {
    let draftID: UUID?
    @State private var model: CompressModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                CompressForm(model: model, close: { dismiss() })
            } else {
                // The window of an earlier session, restored: what it was for is gone.
                ContentUnavailableView("Nothing to Pack", systemImage: "doc.zipper", description: Text("Choose New Archive from the File menu to start again."))
                    .frame(width: 520, height: 300)
            }
        }
        .onAppear {
            guard model == nil, let draftID, let draft = AppModel.shared.drafts[draftID] else { return }
            model = CompressModel(draft: draft)
        }
        .onDisappear {
            if let draftID { AppModel.shared.drafts[draftID] = nil }
        }
    }
}

private struct CompressForm: View {
    @Bindable var model: CompressModel
    let close: () -> Void
    @State private var showsAdvanced = false
    @State private var savingProfile = false
    @State private var profileName = ""

    private var settings: AppSettings { AppModel.shared.settings }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                destinationSection
                formatSection
                if model.format.supportsPassword { passwordSection }
                optionsSection
                if model.format.supportsComment { commentSection }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 520, idealHeight: 720, maxHeight: 940)
        .navigationTitle(model.converting == nil ? "New Archive" : "Convert Archive")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                profilesMenu
            }
        }
        .task(id: ScanKey(sources: model.sources, excludeMac: model.options.excludeMacFiles, patterns: model.options.excludePatterns)) {
            await model.rescan()
        }
        .onChange(of: model.options.format) { model.fit() }
        .alert("Save These Settings as a Profile", isPresented: $savingProfile) {
            TextField("Name", text: $profileName)
            Button("Save") {
                var options = model.options
                options.comment = ""
                settings.profiles.append(CompressionProfile(name: profileName.isEmpty ? "My Profile" : profileName, options: options))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The format, the compression and the options. The password is not stored.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.converting == nil else { return false }
            model.sources.append(contentsOf: urls.filter { !model.sources.contains($0) })
            return true
        }
    }

    private struct ScanKey: Hashable {
        var sources: [URL]
        var excludeMac: Bool
        var patterns: [String]
    }

    // MARK: Sections

    private var destinationSection: some View {
        Section {
            LabeledContent("Packing") {
                Text(model.summary)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Name") {
                HStack(spacing: 4) {
                    TextField("Name", text: $model.name)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Text(".\(model.format.fileExtension)")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.separate)
            LabeledContent("Where") {
                Menu {
                    ForEach(folders, id: \.self) { folder in
                        Button(Formatting.folder(folder)) { model.folder = folder }
                    }
                    Divider()
                    Button("Choose…", action: chooseFolder)
                } label: {
                    Text(Formatting.folder(model.folder))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
            if model.exists {
                Label("“\(model.archive.lastPathComponent)” exists. The files are added to it.", systemImage: "plus.rectangle.on.folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Files that are in it already", selection: $model.options.updateMode) {
                    ForEach(UpdateMode.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private var formatSection: some View {
        Section {
            Picker("Format", selection: $model.options.format) {
                ForEach(ArchiveFormat.allCases) { format in
                    Text(label(for: format))
                        .tag(format)
                        .selectionDisabled(!model.isAvailable(format))
                }
            }
            if model.format.supportsLevels {
                Picker("Compression", selection: $model.options.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            DisclosureGroup("More", isExpanded: $showsAdvanced) {
                if !model.format.methods.isEmpty, model.options.level != .store {
                    Picker("Method", selection: $model.options.method) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.format.methods, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .onChange(of: model.options.method) { model.fit() }
                }
                let sizes = model.format.dictionarySizes(method: model.options.method)
                if !sizes.isEmpty, model.options.level != .store {
                    Picker("Dictionary", selection: $model.options.dictionarySize) {
                        Text("Automatic").tag(UInt64?.none)
                        ForEach(sizes, id: \.self) { Text(Formatting.bytes($0)).tag(UInt64?.some($0)) }
                    }
                    .help("How far back the compression looks for repetitions. Larger compresses better and needs more memory, to pack and to unpack.")
                }
                if model.format.supportsSolid {
                    Picker("Solid archive", selection: $model.options.solid) {
                        Text("Automatic").tag(Bool?.none)
                        Text("Yes").tag(Bool?.some(true))
                        Text("No").tag(Bool?.some(false))
                    }
                    .help("Compress the files together as one stream. Smaller, especially for many similar files, and slower to change or to take a single file out of.")
                }
                Picker("Processor cores", selection: $model.options.threads) {
                    Text("All").tag(Int?.none)
                    ForEach(threadChoices, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                if model.format.supportsVolumes {
                    Picker("Split into volumes", selection: volumeSelection) {
                        Text("No").tag(VolumeChoice.none)
                        ForEach(VolumeSize.presets, id: \.bytes) { preset in
                            Text(preset.name).tag(VolumeChoice.preset(preset.bytes))
                        }
                        Text("Other…").tag(VolumeChoice.custom)
                    }
                    if model.usesCustomVolume {
                        LabeledContent("Size of a volume") {
                            HStack(spacing: 4) {
                                TextField("Megabytes", text: $model.customVolume)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 90)
                                Text("MB")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if model.format == .rar {
                    Stepper(value: $model.options.recoveryPercent, in: 0...30) {
                        LabeledContent("Recovery record", value: model.options.recoveryPercent == 0 ? "None" : "\(model.options.recoveryPercent)%")
                    }
                    .help("Extra data with which the archive can repair itself after damage.")
                    Toggle("Lock the archive against changes", isOn: $model.options.lock)
                    Toggle("Make it extract itself (a program for the Terminal)", isOn: $model.options.selfExtracting)
                }
            }
        } footer: {
            Text(footnote)
        }
    }

    private var passwordSection: some View {
        Section {
            LabeledContent("Password") {
                HStack {
                    Group {
                        if model.showsPassword {
                            TextField("None", text: $model.password)
                        } else {
                            SecureField("None", text: $model.password)
                        }
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    Button(model.showsPassword ? "Hide" : "Show", systemImage: model.showsPassword ? "eye.slash" : "eye") {
                        model.showsPassword.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            if !model.password.isEmpty {
                if !model.showsPassword {
                    LabeledContent("Again") {
                        SecureField("To be sure", text: $model.verification)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                }
                if model.format.supportsEncryptedNames {
                    Toggle("Encrypt the names of the files too", isOn: $model.options.encryptFileNames)
                        .help("Without the password the archive then shows nothing at all, not even what is in it.")
                }
                if model.format == .zip {
                    Picker("Encryption", selection: $model.options.zipEncryption) {
                        ForEach(ZipEncryption.allCases) { Text($0.displayName).tag($0) }
                    }
                    .help("AES-256 is strong and is opened by 7-Zip, WinRAR, WinZip and OpenZip. ZipCrypto opens everywhere, including Windows Explorer, and protects very little.")
                }
            }
        } footer: {
            if !model.password.isEmpty {
                Text("There is no way to recover a forgotten password. Keep it somewhere safe.")
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Leave out .DS_Store and the other files macOS makes", isOn: $model.options.excludeMacFiles)
            LabeledContent("Also leave out") {
                TextField("*.tmp, node_modules", text: patternsText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .help("Names to leave out wherever they occur, separated by commas. * stands for any characters, ? for one.")
            }
            Toggle("Keep symbolic links as links", isOn: $model.options.storeSymbolicLinks)
                .help("Turned off, the file or folder a link points to is packed in its place.")
            if model.converting == nil {
                if model.sources.count > 1, !model.format.isSingleFile {
                    Toggle("Make one archive for each of the \(model.sources.count) items", isOn: $model.separate)
                }
                Toggle("Test the archive when it is done", isOn: $model.testAfterwards)
                Toggle("Then move the originals to the Trash", isOn: $model.trashOriginals)
            }
        }
    }

    private var commentSection: some View {
        Section("Comment") {
            TextEditor(text: $model.options.comment)
                .font(.callout.monospaced())
                .frame(height: 54)
                .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .lineLimit(2)
            } else {
                Text(Formatting.folder(model.archive))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button(model.converting != nil ? "Convert" : (model.exists ? "Add" : "Create")) {
                model.start()
                close()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .disabled(model.problem != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var profilesMenu: some View {
        Menu("Profiles", systemImage: "slider.horizontal.3") {
            ForEach(settings.profiles) { profile in
                Button(profile.name) {
                    let comment = model.options.comment
                    model.options = profile.options
                    model.options.comment = comment
                    model.usesCustomVolume = false
                    model.fit()
                }
                .disabled(!model.isAvailable(profile.options.format))
            }
            Divider()
            Button("Save as Profile…") {
                profileName = ""
                savingProfile = true
            }
            if !settings.profiles.isEmpty {
                Menu("Delete Profile") {
                    ForEach(settings.profiles) { profile in
                        Button(profile.name, role: .destructive) { settings.profiles.removeAll { $0.id == profile.id } }
                    }
                }
            }
        }
        .help("Settings under a name, to use again")
    }

    // MARK: Pieces

    private func label(for format: ArchiveFormat) -> String {
        if format.needsRar, !model.hasRar { return "\(format.displayName) — needs RARLAB’s RAR (see Settings)" }
        if format.isSingleFile, !model.isSingleFile { return "\(format.displayName) — for a single file" }
        return format.displayName
    }

    private var footnote: String {
        var text = model.format.summary
        if model.format == .zip, model.options.volumeSize != nil || model.usesCustomVolume {
            text += " Split ZIP archives are joined again by 7-Zip, OpenZip and Keka, not by every program."
        }
        return text
    }

    private var threadChoices: [Int] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return [1, 2, 4, 8, 12, 16, 24, 32].filter { $0 < cores }
    }

    private enum VolumeChoice: Hashable {
        case none
        case preset(UInt64)
        case custom
    }

    private var volumeSelection: Binding<VolumeChoice> {
        Binding(
            get: {
                if model.usesCustomVolume { return .custom }
                guard let size = model.options.volumeSize else { return .none }
                return VolumeSize.presets.contains { $0.bytes == size } ? .preset(size) : .custom
            },
            set: { choice in
                switch choice {
                case .none:
                    model.usesCustomVolume = false
                    model.options.volumeSize = nil
                case .preset(let bytes):
                    model.usesCustomVolume = false
                    model.options.volumeSize = bytes
                case .custom:
                    model.usesCustomVolume = true
                    if model.customVolume.isEmpty { model.customVolume = "50" }
                }
            }
        )
    }

    /// The patterns to leave out, as people type them: separated by commas.
    private var patternsText: Binding<String> {
        Binding(
            get: { model.options.excludePatterns.joined(separator: ", ") },
            set: { text in
                model.options.excludePatterns = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        )
    }

    /// The folder of the items, the recent destinations, the Desktop and Downloads.
    private var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = model.converting?.deletingLastPathComponent() ?? model.sources.first?.deletingLastPathComponent()
        let all = [base].compactMap { $0 } + [home.appending(path: "Desktop"), home.appending(path: "Downloads"), home.appending(path: "Documents")]
        var seen = Set<String>()
        return all.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        panel.prompt = "Choose"
        panel.message = "Choose where to save the archive."
        if panel.runModal() == .OK, let url = panel.url { model.folder = url }
    }
}
