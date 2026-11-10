import AppKit
import Observation
import OpenZipKit
import UserNotifications

/// An operation that runs without an archive window of its own: extracting from the
/// Finder's menu, creating an archive.
@Observable
final class BackgroundOperation: Identifiable {
    enum State: Equatable {
        case running
        case finished(String)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let title: String
    /// The name of an SF Symbol that says what kind of operation this is.
    let symbol: String
    var item = ""
    var fraction: Double?
    var state = State.running
    var isPaused = false
    /// What to show in the Finder when the user asks where the result is.
    var results: [URL] = []
    let started = Date()
    @ObservationIgnored let control = OperationControl()

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var isRunning: Bool { state == .running }

    /// How long the rest will take, judged by how long it took so far.
    var remaining: String? {
        guard isRunning, !isPaused, let fraction, fraction > 0.03, fraction < 0.995 else { return nil }
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

/// What an operation leaves behind when it went well.
struct OperationOutcome {
    var message: String
    var results: [URL] = []
}

/// The operations that run in the background, for the activity window, the Dock icon and
/// the notifications.
@Observable
final class OperationCenter {
    private(set) var operations: [BackgroundOperation] = []

    var running: [BackgroundOperation] {
        operations.filter(\.isRunning)
    }

    /// Starts an operation and returns at once.
    @discardableResult
    func start(
        _ title: String, symbol: String,
        work: @escaping (BackgroundOperation, @escaping ProgressHandler) async throws -> OperationOutcome
    ) -> BackgroundOperation {
        let operation = BackgroundOperation(title: title, symbol: symbol)
        operations.insert(operation, at: 0)
        let sink = ProgressSink { [weak operation] progress in
            guard let operation, operation.isRunning else { return }
            if let fraction = progress.fraction { operation.fraction = max(fraction, operation.fraction ?? 0) }
            if !progress.currentItem.isEmpty { operation.item = progress.currentItem }
            DockProgress.update()
        }
        Task {
            do {
                let outcome = try await work(operation, sink.handler)
                operation.results = outcome.results
                operation.state = .finished(outcome.message)
            } catch ArchiveError.cancelled {
                operation.state = .cancelled
            } catch {
                operation.state = .failed(error.localizedDescription)
            }
            operation.fraction = nil
            DockProgress.update()
            announce(operation)
        }
        // A window to watch it in, unless it is over before anyone could look.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if operation.isRunning { AppModel.shared.open(.activity) }
        }
        return operation
    }

    func clearFinished() {
        operations.removeAll { !$0.isRunning }
    }

    func remove(_ operation: BackgroundOperation) {
        guard !operation.isRunning else { return }
        operations.removeAll { $0.id == operation.id }
    }

    /// Says how an operation ended, where it will be noticed: a notification while
    /// another app is in front, the Dock icon otherwise.
    private func announce(_ operation: BackgroundOperation) {
        switch operation.state {
        case .finished(let message):
            if !NSApp.isActive {
                Notifications.post(title: operation.title, body: message, when: AppModel.shared.settings.notifiesWhenDone)
            }
        case .failed(let message):
            NSApp.requestUserAttention(.informationalRequest)
            if !NSApp.isActive {
                Notifications.post(title: operation.title, body: message, when: AppModel.shared.settings.notifiesWhenDone)
            }
            AppModel.shared.open(.activity)
        case .running, .cancelled:
            break
        }
        AppDelegate.shared?.quitIfOnlyStartedForBackgroundWork()
    }
}

/// A progress bar on the Dock icon while something runs in the background.
enum DockProgress {
    private static var indicator: NSProgressIndicator?

    static func update() {
        let running = AppModel.shared.operations.running
        let tile = NSApp.dockTile
        guard !running.isEmpty else {
            if indicator != nil {
                indicator = nil
                tile.contentView = nil
                tile.display()
            }
            return
        }
        if indicator == nil {
            let size = tile.size
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            let icon = NSImageView(frame: view.bounds)
            icon.image = NSApp.applicationIconImage
            view.addSubview(icon)
            let bar = NSProgressIndicator(frame: NSRect(x: size.width * 0.12, y: size.height * 0.08, width: size.width * 0.76, height: 12))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            bar.isIndeterminate = false
            view.addSubview(bar)
            tile.contentView = view
            indicator = bar
        }
        // Several operations: how far they are on average.
        let known = running.compactMap(\.fraction)
        indicator?.doubleValue = known.isEmpty ? 0 : known.reduce(0, +) / Double(running.count)
        tile.display()
    }
}

/// Notifications for operations that end while the app is in the background.
enum Notifications {
    static func post(title: String, body: String, when enabled: Bool) {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
