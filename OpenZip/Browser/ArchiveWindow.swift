import OpenZipKit
import QuickLook
import SwiftUI

/// The window of one archive.
struct ArchiveWindow: View {
    let url: URL?
    @State private var session: ArchiveSession?

    var body: some View {
        Group {
            if let session {
                ArchiveBrowser(session: session)
            } else {
                NoArchiveView()
            }
        }
        .task(id: url) {
            guard let url else { return }
            session?.close()
            let opened = ArchiveSession(url: url)
            session = opened
            await opened.load()
            Demo.stage(opened)
        }
        .onDisappear {
            session?.close()
        }
    }
}

/// A window of the archive group that has no archive: what "New Window" gives.
private struct NoArchiveView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Archive", systemImage: "doc.zipper")
        } description: {
            Text("Open an archive to see what is in it, or drop one here.")
        } actions: {
            Button("Open Archive…") { AppActions.openArchive() }
                .buttonStyle(.glassProminent)
        }
        .frame(minWidth: 520, minHeight: 360)
        .dropDestination(for: URL.self) { urls, _ in
            AppActions.open(urls)
            return true
        }
    }
}

struct ArchiveBrowser: View {
    @Bindable var session: ArchiveSession
    @SceneStorage("showsInspector") private var showsInspector = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isSearchPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 380)
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(subtitle)
        .navigationDocument(session.url)
        .searchable(text: $session.searchText, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Search")
        .inspector(isPresented: $showsInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
        }
        .focusedSceneValue(\.archiveSession, session)
        .focusedSceneValue(\.inspectorToggle, $showsInspector)
        .focusedSceneValue(\.searchToggle, $isSearchPresented)
        .quickLookPreview($session.previewURL)
        .modifier(SessionDialogs(session: session))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.checkEditedFiles()
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear {
            if Demo.arguments.contains("--inspector") { showsInspector = true }
        }
    }

    private var subtitle: String {
        guard session.isReady else { return "" }
        let root = session.tree.root
        let size = Formatting.bytes(root.size)
        return "\(session.listing.info.displayType) — \(Formatting.count(root.fileCount, "file")), \(size)"
    }

    // MARK: Content

    @ViewBuilder private var detail: some View {
        switch session.phase {
        case .loading:
            LoadingView(session: session)
        case .failed(let message):
            FailedView(session: session, message: message)
        case .ready:
            VStack(spacing: 0) {
                BannerStack(session: session)
                FileTable(
                    session: session,
                    version: session.rowsVersion,
                    selection: session.selection,
                    renameRequest: session.renameRequest,
                    canEdit: session.canEdit
                )
                .overlay { emptyState }
                BottomBar(session: session)
            }
            .overlay(alignment: .bottom) {
                StatusPill(session: session)
                    .padding(.bottom, 44)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if session.rows.isEmpty {
            if session.isSearching {
                ContentUnavailableView.search(text: session.searchText)
            } else if session.tree.root.children.isEmpty {
                ContentUnavailableView {
                    Label("Empty Archive", systemImage: "tray")
                } description: {
                    Text(session.canEdit ? "Drop files here to add them." : "There is nothing in this archive.")
                }
            } else {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } description: {
                    Text(session.canEdit ? "Drop files here to add them to this folder." : "There is nothing in this folder.")
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { session.goBack() }
                .disabled(!session.canGoBack)
                .help("Back to the folder before")
            Button("Forward", systemImage: "chevron.right") { session.goForward() }
                .disabled(!session.canGoForward)
                .help("Forward again")
        }

        ToolbarItemGroup {
            Button("Add", systemImage: "plus") { BrowserActions.chooseFilesToAdd(to: session) }
                .disabled(!session.canEdit)
                .help(session.readOnlyReason ?? "Add files and folders to this archive")
            Button("New Folder", systemImage: "folder.badge.plus") { session.sheet = .newFolder }
                .disabled(!session.canEdit)
                .help(session.readOnlyReason ?? "Make a folder in this archive")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Menu {
                ExtractMenuItems(session: session)
            } label: {
                Label("Extract", systemImage: "square.and.arrow.down")
            } primaryAction: {
                session.sheet = .extract(selection: session.selection.isEmpty ? nil : session.selectedRoots)
            }
            .disabled(!session.isReady || session.isBusy)
            .help(session.selection.isEmpty ? "Extract the archive" : "Extract what is selected")

            Button("Test", systemImage: "checkmark.shield") {
                Task { await session.test() }
            }
            .disabled(!session.isReady || session.isBusy)
            .help("Check every file of the archive for damage")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button("Quick Look", systemImage: "eye") { session.togglePreview() }
                .disabled(!session.selectedRows.contains { !session.tree[$0].isDirectory })
                .help("Look at the selected file without extracting it")
            Button("Delete", systemImage: "trash") { session.requestDeletion(session.selectedRoots) }
                .disabled(!session.canEdit || session.selection.isEmpty)
                .help(session.readOnlyReason ?? "Delete what is selected from the archive")
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            Menu {
                Toggle("Folders", isOn: Binding(get: { !session.isFlat }, set: { session.isFlat = !$0 }))
                Toggle("All Files in One List", isOn: $session.isFlat)
                Divider()
                Toggle("Show Files macOS Made", isOn: Binding(
                    get: { session.settings.showsMacFiles },
                    set: { session.settings.showsMacFiles = $0; session.refreshRows() }
                ))
            } label: {
                Label("View", systemImage: session.isFlat ? "list.bullet" : "list.bullet.indent")
            }
            .help("Choose how the files are listed")

            Button("Info", systemImage: "info.circle") { showsInspector.toggle() }
                .help("Show or hide what is known about the archive and the selection")
        }
    }
}

/// The destinations the Extract button offers without opening the dialog.
struct ExtractMenuItems: View {
    let session: ArchiveSession

    var body: some View {
        let selection = session.selection.isEmpty ? nil : session.selectedRoots
        Button(selection == nil ? "Extract…" : "Extract Selection…") {
            session.sheet = .extract(selection: selection)
        }
        Divider()
        Button("Extract Here") {
            extract(selection, to: session.url.deletingLastPathComponent())
        }
        ForEach(quickDestinations, id: \.self) { folder in
            Button("Extract to \(Formatting.folder(folder))") { extract(selection, to: folder) }
        }
    }

    /// Downloads and the Desktop, and before them where things were extracted to lately.
    private var quickDestinations: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = [home.appending(path: "Downloads"), home.appending(path: "Desktop")]
        let recent = session.settings.recentDestinations.prefix(4).map { URL(filePath: $0) }
        var seen = Set<String>([session.url.deletingLastPathComponent().standardizedFileURL.path])
        return (recent + standard).filter { seen.insert($0.standardizedFileURL.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func extract(_ selection: [Int]?, to folder: URL) {
        let settings = session.settings
        // Without the dialog nothing can be asked: what exists is kept, the new gets a number.
        let options = ExtractOptions(destination: folder, folderChoice: settings.folderChoice, conflictPolicy: .keepBoth, reveal: settings.revealAfterExtracting)
        Task { await session.extract(selection, options: options) }
    }
}

// MARK: States

private struct LoadingView: View {
    let session: ArchiveSession

    var body: some View {
        VStack(spacing: 14) {
            if let fraction = session.activity?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text("Opening “\(session.title)”…")
                .foregroundStyle(.secondary)
            if session.activity?.fraction != nil {
                // Only a compressed tar takes long enough to want to stop it: it has to
                // be unpacked from start to end to see what is in it.
                Button("Cancel") { session.activity?.cancel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedView: View {
    let session: ArchiveSession
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("“\(session.title)” Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await session.load() }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.url])
            }
        }
    }
}

/// What has to be said about the archive before anything is done with it.
private struct BannerStack: View {
    let session: ArchiveSession

    var body: some View {
        let info = session.listing.info
        VStack(spacing: 0) {
            if !info.errors.isEmpty {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: "This archive is damaged: \(info.errors.joined(separator: " "))") {
                    if info.isRar, AppModel.shared.tools.rar != nil {
                        Button("Repair…") { Task { await session.repair() } }
                    }
                }
            } else if !info.warnings.isEmpty {
                Banner(symbol: "exclamationmark.circle.fill", tint: .orange, text: info.warnings.joined(separator: " ")) {}
            }
            if case .needsRar = session.editability {
                Banner(symbol: "lock.fill", tint: .secondary, text: "RAR archives can be read as they are. Changing them needs RARLAB’s RAR.") {
                    SettingsLink { Text("Set Up…") }
                }
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: Bottom

/// The path of the folder on the left, what is in it or selected on the right.
private struct BottomBar: View {
    let session: ArchiveSession

    var body: some View {
        HStack(spacing: 12) {
            PathBar(session: session)
            Spacer(minLength: 12)
            Text(status)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var status: String {
        let tree = session.tree
        let chosen = session.selectedRows
        if !chosen.isEmpty {
            let size = chosen.reduce(UInt64(0)) { $0.addingClamped(tree[$1].size) }
            return "\(chosen.count) of \(session.rows.count) selected — \(Formatting.bytes(size))"
        }
        if session.isSearching {
            return Formatting.count(session.rows.count, "match", "matches")
        }
        let folder = tree[session.folder]
        var text = "\(Formatting.count(session.rows.count, "item")) — \(Formatting.bytes(folder.size))"
        if let saving = Formatting.saving(packed: folder.packedSize, size: folder.size) {
            text += ", \(saving) smaller packed"
        }
        return text
    }
}

private struct PathBar: View {
    let session: ArchiveSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let path = session.tree.ancestors(of: session.folder)
                ForEach(Array(path.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        session.navigate(to: id)
                    } label: {
                        Label(id == 0 ? session.title : session.tree[id].name, systemImage: id == 0 ? "doc.zipper" : "folder")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                    .padding(.horizontal, 4)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// What the window is doing, or what it just did: a capsule of glass over the list.
private struct StatusPill: View {
    let session: ArchiveSession

    var body: some View {
        Group {
            if let activity = session.activity {
                ActivityView(activity: activity)
                    .transition(.blurReplace)
            } else if let notice = session.notice {
                NoticeView(notice: notice, session: session)
                    .transition(.blurReplace)
                    .task(id: notice.id) {
                        // Good news goes away by itself. Bad news waits to be read.
                        guard notice.kind == .success else { return }
                        try? await Task.sleep(for: .seconds(notice.reveal.isEmpty ? 3.5 : 7))
                        if session.notice?.id == notice.id { session.notice = nil }
                    }
            }
        }
        .animation(.snappy(duration: 0.3), value: session.activity == nil)
        .animation(.snappy(duration: 0.3), value: session.notice)
    }
}

private struct ActivityView: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            if let fraction = activity.fraction {
                ProgressRing(fraction: fraction)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.isPaused ? "Paused" : activity.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                // The clock makes the time that is left count down between two reports.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            Button(activity.isPaused ? "Resume" : "Pause", systemImage: activity.isPaused ? "play.fill" : "pause.fill") {
                activity.togglePause()
            }
            .help(activity.isPaused ? "Go on" : "Pause")
            Button("Stop", systemImage: "xmark") { activity.cancel() }
                .help("Stop")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }

    private var detail: String {
        var parts: [String] = []
        if let fraction = activity.fraction {
            parts.append(Formatting.percent(fraction))
        }
        if let remaining = activity.remaining {
            parts.append(remaining)
        }
        if !activity.item.isEmpty {
            parts.append((activity.item as NSString).lastPathComponent)
        }
        return parts.isEmpty ? "Working…" : parts.joined(separator: " · ")
    }
}

private struct NoticeView: View {
    let notice: Notice
    let session: ArchiveSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Text(notice.text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !notice.details.isEmpty {
                Button("Details…") { session.sheet = .details(notice) }
                    .buttonStyle(.glass)
            }
            if !notice.reveal.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(notice.reveal)
                    session.notice = nil
                }
                .buttonStyle(.glass)
            }
            Button("Dismiss", systemImage: "xmark") { session.notice = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// A small ring that fills as an operation goes on.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(width: 22, height: 22)
    }
}

extension UInt64 {
    /// The sum, or the largest number there is when the sum would be larger still.
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

// MARK: Focus

struct ArchiveSessionKey: FocusedValueKey {
    typealias Value = ArchiveSession
}

struct InspectorToggleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct SearchToggleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// The archive of the window in front, for the menus.
    var archiveSession: ArchiveSession? {
        get { self[ArchiveSessionKey.self] }
        set { self[ArchiveSessionKey.self] = newValue }
    }

    var inspectorToggle: Binding<Bool>? {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }

    /// Puts the cursor into the search field of the window in front.
    var searchToggle: Binding<Bool>? {
        get { self[SearchToggleKey.self] }
        set { self[SearchToggleKey.self] = newValue }
    }
}
