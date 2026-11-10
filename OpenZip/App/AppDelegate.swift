import AppKit
import OpenZipKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether the app was started, or woken, to open something.
    private var wasAskedToOpen = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A tool that exits before it read what it was sent must not take the app with it.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Demo.launch()
        // Files to open arrive around this moment. If none did, and no window came back
        // from the last session, the app was simply started: say hello.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            guard !wasAskedToOpen, !Self.hasVisibleWindows else { return }
            AppModel.shared.open(.welcome)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        wasAskedToOpen = true
        ExternalActions.handle(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.open(.welcome) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = AppModel.shared.operations.running
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "“\(running[0].title)” is still running" : "\(running.count) operations are still running"
        alert.informativeText = "Quitting stops them. Archives that are half written are removed; nothing that existed before is damaged."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        running.forEach { $0.cancel() }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private static var hasVisibleWindows: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    // MARK: Services

    /// "Extract with OpenZip" in the Services menu.
    @objc func extractFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.files(on: pasteboard)
        guard !urls.isEmpty else { return }
        wasAskedToOpen = true
        QuickActions.extract(urls, mode: .here)
    }

    /// "Compress with OpenZip…" in the Services menu.
    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.files(on: pasteboard)
        guard !urls.isEmpty else { return }
        wasAskedToOpen = true
        NSApp.activate()
        AppModel.shared.newArchive(from: urls)
    }

    private static func files(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
