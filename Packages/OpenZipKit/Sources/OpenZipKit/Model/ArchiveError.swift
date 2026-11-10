import Foundation

/// What can go wrong with an archive, in terms a person can act on.
public enum ArchiveError: Error, Sendable, Equatable {
    /// The archive is encrypted and no password was given.
    case passwordRequired
    /// A password was given and it is not the right one.
    case wrongPassword
    /// The file is not an archive of any format 7-Zip knows.
    case notAnArchive
    /// The archive is damaged. The message says what 7-Zip found.
    case damaged(String)
    /// The archive is fine, but this cannot be done with it: for example changing a format
    /// that can only be read.
    case unsupported(String)
    case cancelled
    /// A program the operation needs is missing. The associated value is its name.
    case toolMissing(String)
    case notEnoughSpace
    /// The system refused access to a file or folder.
    case accessDenied(String)
    /// RAR only: the archive is locked against changes.
    case locked
    /// Anything else, with what the tool printed.
    case failed(String)
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "This archive is protected with a password."
        case .wrongPassword:
            "The password is not correct."
        case .notAnArchive:
            "This file is not an archive, or it is in a format OpenZip cannot read."
        case .damaged(let detail):
            detail.isEmpty ? "The archive is damaged." : "The archive is damaged: \(detail)"
        case .unsupported(let detail):
            detail
        case .cancelled:
            "The operation was cancelled."
        case .toolMissing(let name):
            "\(name) is needed for this and was not found."
        case .notEnoughSpace:
            "There is not enough free space on the disk."
        case .accessDenied(let path):
            path.isEmpty ? "macOS did not allow access to a file." : "macOS did not allow access to “\(path)”."
        case .locked:
            "The archive is locked and cannot be changed."
        case .failed(let detail):
            detail.isEmpty ? "The operation failed." : detail
        }
    }
}

/// What an operation that went through has to report besides its success.
public struct OperationReport: Sendable, Equatable {
    /// Things that went wrong without stopping the operation, for example a file that
    /// could not be read while adding.
    public var warnings: [String] = []
    /// Files that failed, with the reason: what a test of a damaged archive finds.
    public var failures: [Failure] = []
    public var fileCount: Int?

    public struct Failure: Sendable, Equatable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public init() {}

    public var isClean: Bool { warnings.isEmpty && failures.isEmpty }
}

/// How far an operation has come.
public struct OperationProgress: Sendable, Equatable {
    /// From 0 to 1, or nil while it cannot be known yet.
    public var fraction: Double?
    /// The file being worked on, as a path inside the archive.
    public var currentItem: String = ""
    /// What is being done at the moment, for operations with more than one step.
    public var phase: Phase = .working

    public enum Phase: Sendable, Equatable {
        case preparing
        case working
        case finishing
    }

    public init(fraction: Double? = nil, currentItem: String = "", phase: Phase = .working) {
        self.fraction = fraction
        self.currentItem = currentItem
        self.phase = phase
    }
}

public typealias ProgressHandler = @Sendable (OperationProgress) -> Void
