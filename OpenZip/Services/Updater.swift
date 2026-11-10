import AppKit
import Observation
import Sparkle

/// Updates, through Sparkle. Updates are downloaded over HTTPS from the project's GitHub
/// releases and are only installed if they carry the project's EdDSA signature.
@Observable
final class Updater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// False in builds that have no update key, and in the demo, which must never go
    /// online or offer anything.
    var isAvailable: Bool { controller != nil }

    override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !Demo.isEnabled else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
