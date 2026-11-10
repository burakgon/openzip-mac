import AppKit
import OpenZipKit

/// Staging for screenshots and for trying the app from a terminal:
///
///   OpenZip --demo --open /path/to/archive.zip --select "docs" --inspector
///
/// With --demo the app does not look for updates and takes commands that otherwise only
/// its Finder extension may send.
enum Demo {
    static let arguments = CommandLine.arguments

    static var isEnabled: Bool {
        arguments.contains("--demo")
    }

    static func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func values(_ name: String) -> [String] {
        arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    /// Archives to show as opened lately, for the picture of the welcome window.
    static var recents: [URL] {
        isEnabled ? values("--recent").map { URL(filePath: ($0 as NSString).expandingTildeInPath) } : []
    }

    /// The password the demo gives to the first question for one: --answer-password secret.
    /// Only the first: an answer that is wrong would otherwise be given forever.
    static func passwordAnswer() -> String? {
        guard isEnabled, !hasAnsweredPassword, let answer = value("--answer-password") else { return nil }
        hasAnsweredPassword = true
        return answer
    }

    private static var hasAnsweredPassword = false

    /// What to do once the app runs.
    static func launch() {
        guard isEnabled else { return }
        // Passwords for the keychain of the demo: --vault-clear --vault-add "Label=secret".
        if arguments.contains("--vault-clear") { PasswordVault.removeAll() }
        for pair in values("--vault-add") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { PasswordVault.save(parts[1], label: parts[0]) }
        }
        if arguments.contains("--clear-recents") {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
        if let appearance = value("--appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        for path in values("--open") {
            AppModel.shared.openArchive(URL(filePath: path))
        }
        if let archive = value("--convert") {
            AppModel.shared.convert(URL(filePath: archive), password: value("--password"))
        }
        let sources = values("--compress").map { URL(filePath: $0) }
        if !sources.isEmpty {
            AppModel.shared.newArchive(from: sources)
        }
        if arguments.contains("--welcome") {
            AppModel.shared.open(.welcome)
        }
        if arguments.contains("--activity") {
            AppModel.shared.open(.activity)
        }
        if arguments.contains("--settings") {
            AppModel.shared.open(.settings)
        }
        // For pictures the window has to be the one in front, whatever started the app.
        NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
    }

    /// What to show in an archive window once its archive is read.
    static func stage(_ session: ArchiveSession) {
        guard isEnabled else { return }
        NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
        if let folder = value("--folder"), let id = session.tree.node(atDisplayPath: folder) {
            session.navigate(to: id)
        }
        let names = Set(values("--select"))
        if !names.isEmpty {
            session.selection = Set(session.rows.filter { names.contains(session.tree[$0].name) })
        }
        if arguments.contains("--flat") { session.isFlat = true }
        if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if let query = value("--search") { session.searchText = query }
        switch value("--sheet") {
        case "extract": session.sheet = .extract(selection: session.selection.isEmpty ? nil : session.selectedRoots)
        case "newFolder": session.sheet = .newFolder
        case "comment": session.sheet = .comment
        default: break
        }
        if arguments.contains("--test") {
            Task { await session.test() }
        }
        let steps = values("--do")
        if !steps.isEmpty {
            Task { await run(steps, in: session) }
        }
    }

    /// Runs a list of steps in a window, one after the other, the way a person would:
    ///
    ///   --do select:hello.txt --do rename:greeting.txt --do add:/tmp/new.txt --do quit
    ///
    /// It is how the parts between the windows and the engine are tried from a script.
    private static func run(_ steps: [String], in session: ArchiveSession) async {
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "select":
                let names = Set(argument.split(separator: ",").map(String.init))
                session.selection = Set(session.rows.filter { names.contains(session.tree[$0].name) })
            case "open":
                if let id = session.rows.first(where: { session.tree[$0].name == argument }) { session.open(id) }
            case "up":
                session.goUp()
            case "extract":
                let options = ExtractOptions(destination: URL(filePath: argument), folderChoice: .automatic, conflictPolicy: .keepBoth, reveal: false)
                await session.extract(session.selection.isEmpty ? nil : session.selectedRoots, options: options)
            case "add":
                await session.add(argument.split(separator: ",").map { URL(filePath: String($0)) }, into: nil, options: nil, password: nil)
            case "delete":
                await session.delete(session.selectedRoots)
            case "rename":
                if let id = session.selectedRows.first { await session.rename(id, to: argument) }
            case "newFolder":
                await session.newFolder(named: argument)
            case "comment":
                await session.setComment(argument)
            case "test":
                await session.test()
            case "preview":
                await session.updatePreview(force: true)
            case "move":
                if let target = session.rows.first(where: { session.tree[$0].name == argument }) {
                    await session.move(session.selectedRoots.filter { $0 != target }, to: target)
                }
            case "edit":
                // What happens when a file is opened in another app and saved there,
                // without the other app: the extracted copy is changed behind its back.
                if let id = session.selectedRows.first, let file = await session.extractForDemo(id) {
                    session.watch(file, for: id)
                    try? Data(argument.utf8).write(to: file)
                    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
                    session.checkEditedFiles()
                    if let pending = session.pendingUpdate {
                        session.pendingUpdate = nil
                        await session.updateArchive(with: pending)
                    } else {
                        print("the change was not noticed")
                    }
                }
            case "promise":
                let ids = session.selectedRoots
                let kept = await FileTable.Coordinator.latest?.keepPromises(for: ids, in: URL(filePath: argument)) ?? ["no list"]
                print("PROMISES: \(kept.joined(separator: ", "))")
            case "extractAsking":
                let options = ExtractOptions(destination: URL(filePath: argument), folderChoice: .never, conflictPolicy: .ask, reveal: false)
                Task { await session.extract(session.selection.isEmpty ? nil : session.selectedRoots, options: options) }
            case "copy":
                await session.copySelection(askingAboutSize: false)
            case "paste":
                await session.pasteFiles()
            case "send":
                // What a menu item does: an action sent to whoever has the focus.
                let handled = NSApp.sendAction(Selector(argument + ":"), to: nil, from: nil)
                let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                print("SENT \(argument): \(handled ? "taken" : "not taken"), the focus is on \(responder) in \(NSApp.keyWindow?.title ?? "no key window")")
                try? await Task.sleep(for: .seconds(0.2))
            case "vault":
                print("VAULT: \(PasswordVault.entries().map(\.label).joined(separator: "|"))")
            case "clipboard":
                // What is on the clipboard: its files, and what it pastes as text.
                print("CLIPBOARD FILES: \(FileClipboard.files.map(\.path).joined(separator: "|"))")
                print("CLIPBOARD TEXT: \((FileClipboard.pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }.joined(separator: "|"))")
            case "wait":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "quit":
                // What the window has to say goes to the log first, for the script to read.
                print("NOTICE: \(session.notice?.text ?? "-")")
                print("ROWS: \(session.rows.map { session.tree[$0].name }.joined(separator: "|"))")
                print("WINDOWS: \(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(\.title).sorted().joined(separator: "|"))")
                fflush(stdout)
                NSApp.terminate(nil)
            default:
                print("unknown step: \(step)")
            }
            if let notice = session.notice { print("AFTER \(step): \(notice.text)") }
        }
    }
}
