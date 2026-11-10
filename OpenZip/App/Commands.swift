import OpenZipKit
import SwiftUI

/// The menu bar.
struct AppCommands: Commands {
    @FocusedValue(\.archiveSession) private var session
    @FocusedValue(\.inspectorToggle) private var inspector
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppModel.shared.updater.checkForUpdates() }
                .disabled(!AppModel.shared.updater.isAvailable)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Archive…") { AppActions.newArchive() }
                .keyboardShortcut("n")
            Button("Open…") { AppActions.openArchive() }
                .keyboardShortcut("o")
            RecentMenu()
            Divider()
            Button("Extract Archives…") { AppActions.extractArchives() }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Show in Finder") {
                if let session { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
            }
            .keyboardShortcut("r")
            .disabled(session == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename") {
                if let session, let id = session.selectedRows.first { session.renameRequest = id }
            }
            .disabled(session?.canEdit != true || session?.selection.count != 1)
            Button("Delete") {
                if let session { session.requestDeletion(session.selectedRoots) }
            }
            .keyboardShortcut(.delete)
            .disabled(session?.canEdit != true || session?.selection.isEmpty != false)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Folders") { session?.isFlat = false }
                .keyboardShortcut("1")
                .disabled(session == nil)
            Button("All Files in One List") { session?.isFlat = true }
                .keyboardShortcut("2")
                .disabled(session == nil)
            Divider()
            Button(AppModel.shared.settings.showsMacFiles ? "Hide Files macOS Made" : "Show Files macOS Made") {
                AppModel.shared.settings.showsMacFiles.toggle()
                session?.refreshRows()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button(inspector?.wrappedValue == true ? "Hide Info" : "Show Info") {
                inspector?.wrappedValue.toggle()
            }
            .keyboardShortcut("i")
            .disabled(inspector == nil)
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(session?.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut("]")
                .disabled(session?.canGoForward != true)
            Button("Enclosing Folder") { session?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(session?.canGoUp != true)
            Divider()
            Button("Open") {
                if let session { session.selectedRows.prefix(8).forEach { session.open($0) } }
            }
            .keyboardShortcut(.downArrow)
            .disabled(session?.selection.isEmpty != false)
            Button("Quick Look") { session?.togglePreview() }
                .keyboardShortcut("y")
                .disabled(session?.selection.isEmpty != false)
        }

        CommandMenu("Archive") {
            Button("Add Files…") {
                if let session { BrowserActions.chooseFilesToAdd(to: session) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(session?.canEdit != true)
            Button("Add Files with Options…") {
                if let session { BrowserActions.chooseFilesToAdd(to: session, withOptions: true) }
            }
            .disabled(session?.canEdit != true)
            Button("New Folder") { session?.sheet = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session?.canEdit != true)
            Divider()
            Button(session?.selection.isEmpty == false ? "Extract Selection…" : "Extract…") {
                if let session { session.sheet = .extract(selection: session.selection.isEmpty ? nil : session.selectedRoots) }
            }
            .keyboardShortcut("e")
            .disabled(session?.isReady != true || session?.isBusy == true)
            Button("Extract Here") {
                guard let session else { return }
                let settings = session.settings
                let options = ExtractOptions(
                    destination: session.url.deletingLastPathComponent(), folderChoice: settings.folderChoice,
                    conflictPolicy: .keepBoth, reveal: settings.revealAfterExtracting
                )
                Task { await session.extract(session.selection.isEmpty ? nil : session.selectedRoots, options: options) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session?.isReady != true || session?.isBusy == true)
            Button("Test") {
                if let session { Task { await session.test() } }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(session?.isReady != true || session?.isBusy == true)
            Divider()
            Button("Edit Comment…") { session?.sheet = .comment }
                .disabled(session?.canEdit != true || session?.listing.info.format?.supportsComment != true)
            Button("Convert to Another Format…") {
                if let session { AppModel.shared.convert(session.url, password: session.knownPassword) }
            }
            .disabled(session?.isReady != true)
            Divider()
            // What only RAR has.
            Button("Add Recovery Record…") { session?.sheet = .recoveryRecord }
                .disabled(session?.canEdit != true || session?.listing.info.isRar != true)
            Button("Lock Against Changes…") {
                if let session { RarActions.confirmLock(session) }
            }
            .disabled(session?.canEdit != true || session?.listing.info.isRar != true)
            Button("Repair…") {
                if let session { Task { await session.repair() } }
            }
            .disabled(session?.isReady != true || session?.listing.info.isRar != true || AppModel.shared.tools.rar == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Welcome to OpenZip") { openWindow(id: WindowID.welcome) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Activity") { openWindow(id: WindowID.activity) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("OpenZip Website", destination: URL(string: "https://burakgon.github.io/openzip-mac/")!)
            Link("Report a Problem", destination: URL(string: "https://github.com/burakgon/openzip-mac/issues/new/choose")!)
        }
    }
}

/// The archives opened lately.
private struct RecentMenu: View {
    var body: some View {
        Menu("Open Recent") {
            let recents = AppModel.shared.recentArchives.prefix(12)
            ForEach(Array(recents), id: \.self) { url in
                Button(url.lastPathComponent) { AppModel.shared.openArchive(url) }
            }
            if !recents.isEmpty { Divider() }
            Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                .disabled(recents.isEmpty)
        }
    }
}

enum RarActions {
    /// Locking cannot be undone, so it is asked about in so many words.
    static func confirmLock(_ session: ArchiveSession) {
        let alert = NSAlert()
        alert.messageText = "Lock “\(session.title)” against changes?"
        alert.informativeText = "A locked archive can still be opened and extracted, and never changed again: nothing can be added, deleted or renamed. This cannot be undone."
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await session.lock() }
    }
}
