import AppKit
import Observation
import OpenZipKit

/// A window that is to be opened.
enum WindowRequest: Hashable {
    case welcome
    case archive(URL)
    case compress(UUID)
    case activity
    case settings
}

/// What a "New Archive" window starts with.
struct CompressDraft {
    var sources: [URL]
    /// Start compressing right away, without showing the options: "Compress to ZIP" in the Finder.
    var isQuick = false
    /// An archive to repack into another format, instead of files to pack.
    var converting: URL?
    var convertingPassword: String?
}

/// What the whole app shares: the tools, the settings, the operations that run without a
/// window of their own.
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let operations = OperationCenter()
    let updater = Updater()
    private(set) var tools: Tools

    /// Windows waiting to be opened. Only a view can open a window in SwiftUI, so
    /// everything else puts its wish here and the scenes grant it.
    var windowRequests: [WindowRequest] = []
    /// What the "New Archive" windows were opened for, by the identifier they are opened with.
    @ObservationIgnored var drafts: [UUID: CompressDraft] = [:]
    /// Passwords that were typed in, for as long as the app runs: opening an archive a
    /// second time, or a window on an archive inside it, does not ask again.
    @ObservationIgnored private var passwords: [String: String] = [:]

    var engine: ArchiveEngine { ArchiveEngine(tools: tools) }

    private init() {
        tools = Self.locateTools(customRar: settings.customRarPath)
    }

    private static func locateTools(customRar: String) -> Tools {
        let sevenZip = Bundle.main.bundleURL.appending(path: "Contents/Helpers/7zz")
        var rar = Tools.findRar()
        if !customRar.isEmpty, FileManager.default.isExecutableFile(atPath: customRar) {
            rar = URL(filePath: customRar)
        }
        return Tools(sevenZip: sevenZip, rar: rar)
    }

    /// Looks for `rar` again: after it was installed, or pointed to in the settings.
    func refreshTools() {
        tools = Self.locateTools(customRar: settings.customRarPath)
    }

    // MARK: Windows

    /// Whether the app has shown a window since it started: an app that has is being
    /// used, and stays when its background work is done.
    @ObservationIgnored private(set) var hasShownWindow = false

    func open(_ request: WindowRequest) {
        // The activity window is opened by the app, not by the user: it does not count.
        if request != .activity { hasShownWindow = true }
        windowRequests.append(request)
    }

    /// Opens an archive in a window. Any piece of a split archive opens its first.
    func openArchive(_ url: URL) {
        let archive = FileNaming.firstVolume(of: url.standardizedFileURL)
        NSDocumentController.shared.noteNewRecentDocumentURL(archive)
        open(.archive(archive))
    }

    /// Opens the window that creates an archive from these files.
    func newArchive(from sources: [URL], quick: Bool = false) {
        let id = UUID()
        drafts[id] = CompressDraft(sources: sources, isQuick: quick)
        open(.compress(id))
    }

    /// Opens the window that repacks an archive into another format.
    func convert(_ archive: URL, password: String?) {
        let id = UUID()
        drafts[id] = CompressDraft(sources: [], converting: archive, convertingPassword: password)
        open(.compress(id))
    }

    var recentArchives: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Passwords

    func password(for archive: URL) -> String? {
        passwords[archive.standardizedFileURL.path]
    }

    func remember(_ password: String?, for archive: URL) {
        passwords[archive.standardizedFileURL.path] = password
    }
}

/// Brings progress from the threads of the engine to the main actor, a few times a second.
///
/// 7-Zip reports every file it touches. An archive of a hundred thousand files would
/// redraw the window a hundred thousand times; what the eye needs is the latest state now
/// and then.
nonisolated final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: OperationProgress?
    private var isScheduled = false
    private let deliver: @MainActor (OperationProgress) -> Void

    init(_ deliver: @escaping @MainActor (OperationProgress) -> Void) {
        self.deliver = deliver
    }

    var handler: ProgressHandler {
        { [self] progress in send(progress) }
    }

    private func send(_ progress: OperationProgress) {
        let schedule: Bool = lock.withLock {
            // A report without a file keeps the file of the one before.
            var progress = progress
            if progress.currentItem.isEmpty, let latest { progress.currentItem = latest.currentItem }
            if progress.fraction == nil, let latest { progress.fraction = latest.fraction }
            latest = progress
            if isScheduled { return false }
            isScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            let value: OperationProgress? = lock.withLock {
                isScheduled = false
                return latest
            }
            guard let value else { return }
            MainActor.assumeIsolated { deliver(value) }
        }
    }
}

extension ArchiveInfo {
    /// The format to write with when adding to this archive.
    var format: ArchiveFormat? {
        switch type.lowercased() {
        case "zip": .zip
        case "7z": .sevenZip
        case "rar", "rar5": .rar
        case "wim": .wim
        case "tar":
            switch compression.lowercased() {
            case "": .tar
            case "gzip": .tarGzip
            case "bzip2": .tarBzip2
            case "xz": .tarXz
            default: nil
            }
        default: nil
        }
    }

    var isRar: Bool {
        let lower = type.lowercased()
        return lower == "rar" || lower == "rar5"
    }
}
