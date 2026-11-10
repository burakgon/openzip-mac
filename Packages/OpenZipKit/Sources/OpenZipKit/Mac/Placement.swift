import Foundation

/// What to do when an extracted file meets one of the same name.
public enum ConflictPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
    case ask
    case replace
    case skip
    case keepBoth

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ask: "Ask"
        case .replace: "Replace"
        case .skip: "Skip"
        case .keepBoth: "Keep both"
        }
    }
}

/// An extracted item that cannot go where it belongs because something is there already.
public struct FileConflict: Sendable {
    /// The new item, waiting in the work folder.
    public let source: URL
    /// What is in its way.
    public let existing: URL

    public init(source: URL, existing: URL) {
        self.source = source
        self.existing = existing
    }
}

public enum ConflictChoice: Sendable {
    case replace
    case skip
    case keepBoth
    /// Stop the whole operation. What was put in place so far stays.
    case stop
}

public struct ConflictDecision: Sendable {
    public var choice: ConflictChoice
    /// Do the same for every further conflict of this operation.
    public var applyToAll: Bool

    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

/// Asked for every conflict when the policy is `.ask`.
public typealias ConflictResolver = @Sendable (FileConflict) async -> ConflictDecision

/// Moves extracted items from the work folder to where they belong.
///
/// Extracting into a work folder first and moving afterwards is what makes the rest
/// possible: nothing half-extracted ever shows up at the destination, a cancelled
/// operation leaves no trace, and what to do about a file that exists is decided here,
/// file by file, instead of by the console program.
struct Placer {
    let policy: ConflictPolicy
    let resolver: ConflictResolver?
    /// What was put in place, counting only the items handed to `place`, not their contents.
    private(set) var placed: [URL] = []
    private(set) var skipped = 0
    private var remembered: ConflictChoice?

    init(policy: ConflictPolicy, resolver: ConflictResolver?) {
        self.policy = policy
        self.resolver = resolver
    }

    mutating func place(_ source: URL, at destination: URL) async throws {
        if let final = try await move(source, to: destination) {
            placed.append(final)
        }
    }

    private mutating func move(_ source: URL, to destination: URL) async throws -> URL? {
        let files = FileManager.default
        guard Self.exists(destination) else {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: source, to: destination)
            return destination
        }

        // Two folders of the same name become one: that is what extracting into a folder
        // that has part of the content already means. Not for packages: an app merged with
        // another version of itself is neither.
        if Self.isPlainFolder(source), Self.isPlainFolder(destination) {
            for name in try Directory.names(in: source) {
                _ = try await move(source.appending(path: name), to: destination.appending(path: name))
            }
            return destination
        }

        switch await decide(FileConflict(source: source, existing: destination)) {
        case .replace:
            // Never a file with itself, which would delete it.
            guard source.standardizedFileURL != destination.standardizedFileURL else { return destination }
            _ = try files.replaceItemAt(destination, withItemAt: source)
            return destination
        case .keepBoth:
            let free = FileNaming.uniqueURL(for: destination, isTaken: Self.exists)
            try files.moveItem(at: source, to: free)
            return free
        case .skip:
            skipped += 1
            return nil
        case .stop:
            throw ArchiveError.cancelled
        }
    }

    private mutating func decide(_ conflict: FileConflict) async -> ConflictChoice {
        switch policy {
        case .replace: return .replace
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        case .ask:
            if let remembered { return remembered }
            // Nobody to ask: the choice that loses nothing.
            guard let resolver else { return .keepBoth }
            let decision = await resolver(conflict)
            if decision.applyToAll { remembered = decision.choice }
            return decision.choice
        }
    }

    /// Whether anything is at the location, including a link that points nowhere.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return !isPackage
    }
}
