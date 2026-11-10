import Foundation

/// One file or folder as an archive lists it.
public struct ArchiveEntry: Sendable, Hashable {
    /// The path exactly as the archive stores it. This is the name 7-Zip has to be given
    /// to extract, delete or rename the entry, so it is never tidied up.
    public var path: String
    public var isDirectory: Bool
    /// The size of the file once extracted.
    public var size: UInt64
    /// The space the file takes in the archive. Solid archives compress files together
    /// and only know this for a whole block, in which case it is nil.
    public var packedSize: UInt64?
    public var modified: Date?
    public var created: Date?
    public var crc: UInt32?
    public var isEncrypted: Bool
    /// The compression method as 7-Zip names it, for example "Deflate" or "LZMA2:24".
    public var method: String
    /// The permissions as `ls` writes them, for example "-rw-r--r--", if the archive has them.
    public var permissions: String
    /// Where the link points to. Tar and RAR say so in their listing; zip and 7z keep
    /// the target as the content of the entry, so there it stays empty.
    public var linkTarget: String
    public var isSymbolicLink: Bool
    public var comment: String

    public init(
        path: String, isDirectory: Bool = false, size: UInt64 = 0, packedSize: UInt64? = nil,
        modified: Date? = nil, created: Date? = nil, crc: UInt32? = nil, isEncrypted: Bool = false,
        method: String = "", permissions: String = "", linkTarget: String = "",
        isSymbolicLink: Bool = false, comment: String = ""
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.created = created
        self.crc = crc
        self.isEncrypted = isEncrypted
        self.method = method
        self.permissions = permissions
        self.linkTarget = linkTarget
        self.isSymbolicLink = isSymbolicLink
        self.comment = comment
    }
}

/// What 7-Zip says about the archive as a whole.
public struct ArchiveInfo: Sendable, Hashable {
    /// The format as 7-Zip names it: "zip", "7z", "Rar5", "tar", "gzip", "Iso"…
    public var type: String = ""
    /// For a compressed tar (.tar.gz and its relatives) the format of the outer layer,
    /// for example "gzip"; `type` is then "tar". Empty for every other archive.
    public var compression: String = ""
    public var physicalSize: UInt64?
    public var method: String = ""
    public var isSolid = false
    public var isMultiVolume = false
    public var volumeCount: Int?
    /// The names of the files are encrypted too: nothing can be listed without the password.
    public var hasEncryptedHeaders = false
    public var comment: String = ""
    /// RAR only: the archive refuses to be changed.
    public var isLocked = false
    /// RAR only: the archive carries data to repair itself with.
    public var hasRecoveryRecord = false
    /// The archive does not start at the beginning of the file: there is a program in
    /// front of it that extracts it (a self-extracting archive).
    public var isSelfExtracting = false
    /// Every property 7-Zip printed, in its order, for the information panel.
    public var properties: [Property] = []
    /// Problems found while opening that did not keep the archive from being listed.
    public var warnings: [String] = []
    public var errors: [String] = []

    public struct Property: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public init() {}

    /// The format in the way people write it.
    public var displayType: String {
        let inner: String
        switch type.lowercased() {
        case "zip": inner = "ZIP"
        case "7z": inner = "7z"
        case "rar": inner = "RAR4"
        case "rar5": inner = "RAR"
        case "tar": inner = "TAR"
        case "gzip": inner = "GZIP"
        case "bzip2": inner = "BZIP2"
        case "xz": inner = "XZ"
        case "zstd": inner = "Zstandard"
        case "iso", "udf": inner = "ISO"
        case "dmg": inner = "DMG"
        case "cab": inner = "CAB"
        case "wim": inner = "WIM"
        case "xar": inner = "XAR"
        case "": inner = "Archive"
        default: inner = type.uppercased()
        }
        guard !compression.isEmpty else { return inner }
        switch compression.lowercased() {
        case "gzip": return "TAR.GZ"
        case "bzip2": return "TAR.BZ2"
        case "xz": return "TAR.XZ"
        case "zstd": return "TAR.ZST"
        case "z": return "TAR.Z"
        case "lzma": return "TAR.LZMA"
        default: return "TAR + \(compression.uppercased())"
        }
    }
}

/// An archive that has been read: what it is, and what is in it.
public struct ArchiveListing: Sendable {
    public var info: ArchiveInfo
    public var entries: [ArchiveEntry]

    public init(info: ArchiveInfo = ArchiveInfo(), entries: [ArchiveEntry] = []) {
        self.info = info
        self.entries = entries
    }

    /// Whether any file needs a password to be extracted.
    public var hasEncryptedEntries: Bool {
        info.hasEncryptedHeaders || entries.contains { $0.isEncrypted }
    }
}
