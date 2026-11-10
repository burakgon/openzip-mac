import Foundation
import Observation
import OpenZipKit

/// What happens when an archive is opened from the Finder.
enum OpenAction: String, CaseIterable, Identifiable {
    case browse
    case extract

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: "Show what is in it"
        case .extract: "Extract it"
        }
    }
}

/// Whether extracted items get a folder of their own.
enum FolderChoice: String, CaseIterable, Identifiable {
    case automatic
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "When there are several items"
        case .always: "Always"
        case .never: "Never"
        }
    }

    func policy(named name: String) -> FolderPolicy {
        switch self {
        case .automatic: .automatic(name)
        case .always: .always(name)
        case .never: .none
        }
    }
}

enum AfterCompressing: String, CaseIterable, Identifiable {
    case reveal
    case open
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reveal: "Show it in the Finder"
        case .open: "Open it in OpenZip"
        case .nothing: "Do nothing"
        }
    }
}

/// A set of compression choices under a name, to be chosen again with one click.
struct CompressionProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var options: CompressionOptions
}

/// The user's choices, stored in the defaults database. Views observe this object directly.
@Observable
final class AppSettings {
    private enum Key {
        static let openAction = "openAction"
        static let revealAfterExtracting = "revealAfterExtracting"
        static let trashArchiveAfterExtracting = "trashArchiveAfterExtracting"
        static let folderChoice = "folderChoice"
        static let conflictPolicy = "conflictPolicy"
        static let keepQuarantine = "keepQuarantine"
        static let restoreMacMetadata = "restoreMacMetadata"
        static let showsMacFiles = "showsMacFiles"
        static let afterCompressing = "afterCompressing"
        static let lastOptions = "lastCompressionOptions"
        static let profiles = "compressionProfiles"
        static let recentDestinations = "recentDestinations"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let customRarPath = "customRarPath"
        static let confirmsDeleting = "confirmsDeleting"
        static let notifiesWhenDone = "notifiesWhenDone"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// What a double click on an archive in the Finder does.
    var openAction: OpenAction { didSet { defaults.set(openAction.rawValue, forKey: Key.openAction) } }
    var revealAfterExtracting: Bool { didSet { defaults.set(revealAfterExtracting, forKey: Key.revealAfterExtracting) } }
    var trashArchiveAfterExtracting: Bool { didSet { defaults.set(trashArchiveAfterExtracting, forKey: Key.trashArchiveAfterExtracting) } }
    var folderChoice: FolderChoice { didSet { defaults.set(folderChoice.rawValue, forKey: Key.folderChoice) } }
    /// What to do about files that exist, when extracting from a window. Extracting from
    /// the Finder never asks and never replaces: it keeps both.
    var conflictPolicy: ConflictPolicy { didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) } }
    /// Pass the quarantine of a downloaded archive on to what is extracted from it.
    var keepQuarantine: Bool { didSet { defaults.set(keepQuarantine, forKey: Key.keepQuarantine) } }
    /// Fold the resource forks a Mac archive keeps beside its files back into them.
    var restoreMacMetadata: Bool { didSet { defaults.set(restoreMacMetadata, forKey: Key.restoreMacMetadata) } }
    /// Show .DS_Store, __MACOSX and the "._" files in archive windows.
    var showsMacFiles: Bool { didSet { defaults.set(showsMacFiles, forKey: Key.showsMacFiles) } }
    var afterCompressing: AfterCompressing { didSet { defaults.set(afterCompressing.rawValue, forKey: Key.afterCompressing) } }
    /// The choices of the last archive that was created: the next one starts with them.
    var lastOptions: CompressionOptions { didSet { store(lastOptions, Key.lastOptions) } }
    var profiles: [CompressionProfile] { didSet { store(profiles, Key.profiles) } }
    /// The folders extracted to most recently, newest first.
    var recentDestinations: [String] { didSet { defaults.set(recentDestinations, forKey: Key.recentDestinations) } }
    var sortKey: ArchiveTree.SortKey { didSet { defaults.set(sortKey.rawValue, forKey: Key.sortKey) } }
    var sortAscending: Bool { didSet { defaults.set(sortAscending, forKey: Key.sortAscending) } }
    /// A `rar` in a place OpenZip would not look by itself.
    var customRarPath: String { didSet { defaults.set(customRarPath, forKey: Key.customRarPath) } }
    var confirmsDeleting: Bool { didSet { defaults.set(confirmsDeleting, forKey: Key.confirmsDeleting) } }
    var notifiesWhenDone: Bool { didSet { defaults.set(notifiesWhenDone, forKey: Key.notifiesWhenDone) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.revealAfterExtracting: true,
            Key.keepQuarantine: true,
            Key.restoreMacMetadata: true,
            Key.sortAscending: true,
            Key.confirmsDeleting: true,
            Key.notifiesWhenDone: true,
        ])
        openAction = OpenAction(rawValue: defaults.string(forKey: Key.openAction) ?? "") ?? .browse
        revealAfterExtracting = defaults.bool(forKey: Key.revealAfterExtracting)
        trashArchiveAfterExtracting = defaults.bool(forKey: Key.trashArchiveAfterExtracting)
        folderChoice = FolderChoice(rawValue: defaults.string(forKey: Key.folderChoice) ?? "") ?? .automatic
        conflictPolicy = ConflictPolicy(rawValue: defaults.string(forKey: Key.conflictPolicy) ?? "") ?? .ask
        keepQuarantine = defaults.bool(forKey: Key.keepQuarantine)
        restoreMacMetadata = defaults.bool(forKey: Key.restoreMacMetadata)
        showsMacFiles = defaults.bool(forKey: Key.showsMacFiles)
        afterCompressing = AfterCompressing(rawValue: defaults.string(forKey: Key.afterCompressing) ?? "") ?? .reveal
        lastOptions = Self.load(CompressionOptions.self, Key.lastOptions, from: defaults) ?? CompressionOptions()
        profiles = Self.load([CompressionProfile].self, Key.profiles, from: defaults) ?? Self.builtInProfiles
        recentDestinations = defaults.stringArray(forKey: Key.recentDestinations) ?? []
        sortKey = ArchiveTree.SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .name
        sortAscending = defaults.bool(forKey: Key.sortAscending)
        customRarPath = defaults.string(forKey: Key.customRarPath) ?? ""
        confirmsDeleting = defaults.bool(forKey: Key.confirmsDeleting)
        notifiesWhenDone = defaults.bool(forKey: Key.notifiesWhenDone)
    }

    private func store<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Puts a folder at the front of the recent destinations.
    func noteDestination(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentDestinations = Array(([path] + recentDestinations.filter { $0 != path }).prefix(8))
    }

    /// The profiles a new installation starts with.
    static var builtInProfiles: [CompressionProfile] {
        var zip = CompressionOptions(format: .zip, level: .normal)
        zip.excludeMacFiles = true

        var small = CompressionOptions(format: .sevenZip, level: .ultra)
        small.solid = true

        var mail = CompressionOptions(format: .zip, level: .maximum)
        mail.volumeSize = 25 << 20

        var fast = CompressionOptions(format: .zip, level: .fastest)
        fast.excludeMacFiles = true

        var source = CompressionOptions(format: .tarGzip, level: .normal)
        source.excludePatterns = ["node_modules", ".git", ".build", "DerivedData"]

        return [
            CompressionProfile(name: "ZIP for everyone", options: zip),
            CompressionProfile(name: "Smallest possible (7z)", options: small),
            CompressionProfile(name: "Email attachments (25 MB parts)", options: mail),
            CompressionProfile(name: "Fast ZIP", options: fast),
            CompressionProfile(name: "Source code (tar.gz)", options: source),
        ]
    }
}
