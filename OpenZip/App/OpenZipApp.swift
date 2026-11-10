import OpenZipKit
import SwiftUI

enum WindowID {
    static let welcome = "welcome"
    static let archive = "archive"
    static let compress = "compress"
    static let activity = "activity"
}

@main
struct OpenZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var app = AppModel.shared

    var body: some Scene {
        // The welcome comes first, which makes it the window a plain launch shows. It is
        // suppressed all the same: whether to show it depends on why the app was started,
        // and the delegate knows that.
        Window("OpenZip", id: WindowID.welcome) {
            WelcomeView()
                .environment(\.locale, Formatting.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { AppCommands() }
        // Everything that wants a window puts its wish into the model; here is the one
        // place that may grant it.
        .onChange(of: app.windowRequests, initial: true) { _, requests in
            guard !requests.isEmpty else { return }
            app.windowRequests.removeAll()
            requests.forEach(open)
        }

        WindowGroup(id: WindowID.archive, for: URL.self) { $url in
            ArchiveWindow(url: url)
                .environment(\.locale, Formatting.locale)
        }
        .defaultSize(width: 1120, height: 700)
        // Files are opened by the delegate. Without this, SwiftUI would open a second,
        // empty window for each of them.
        .handlesExternalEvents(matching: [])

        WindowGroup("New Archive", id: WindowID.compress, for: UUID.self) { $draft in
            CompressView(draftID: draft)
                .environment(\.locale, Formatting.locale)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Window("Activity", id: WindowID.activity) {
            ActivityWindow()
                .environment(\.locale, Formatting.locale)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(\.locale, Formatting.locale)
        }
    }

    private func open(_ request: WindowRequest) {
        switch request {
        case .welcome:
            openWindow(id: WindowID.welcome)
        case .archive(let url):
            openWindow(id: WindowID.archive, value: url)
            // The welcome has done its job once an archive is open.
            dismissWindow(id: WindowID.welcome)
        case .compress(let id):
            openWindow(id: WindowID.compress, value: id)
            dismissWindow(id: WindowID.welcome)
        case .activity:
            openWindow(id: WindowID.activity)
        }
    }
}
