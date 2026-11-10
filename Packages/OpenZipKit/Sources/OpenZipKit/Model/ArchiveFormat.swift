import Foundation

/// The formats OpenZip can create. It reads many more: everything 7-Zip opens.
public enum ArchiveFormat: String, Sendable, CaseIterable, Codable, Identifiable {
    case zip
    case sevenZip = "7z"
    case rar
    case tar
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case gzip = "gz"
    case bzip2 = "bz2"
    case xz
    case wim

    public var id: String { rawValue }

    /// The extension of the files, without a dot. For compressed tars it has two parts.
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7z"
        case .rar: "RAR"
        case .tar: "TAR"
        case .tarGzip: "TAR.GZ"
        case .tarBzip2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .gzip: "GZIP"
        case .bzip2: "BZIP2"
        case .xz: "XZ"
        case .wim: "WIM"
        }
    }

    /// One line on what the format is good for, for the format picker.
    public var summary: String {
        switch self {
        case .zip: "Opens everywhere without extra software."
        case .sevenZip: "Smallest files, and strong encryption that can hide the file names."
        case .rar: "Solid compression with a recovery record that survives damage."
        case .tar: "Keeps Unix permissions and links. Not compressed."
        case .tarGzip: "The usual way to pack source code and servers' files."
        case .tarBzip2: "Like tar.gz, a little smaller and slower."
        case .tarXz: "Like tar.gz, much smaller and slower."
        case .gzip: "Compresses a single file."
        case .bzip2: "Compresses a single file."
        case .xz: "Compresses a single file."
        case .wim: "Windows disk images. Not compressed."
        }
    }

    /// What 7-Zip calls the format after its -t switch. A compressed tar is a tar that is
    /// then compressed, so it has two: see `compressor`.
    var sevenZipType: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .rar: "rar"
        case .tar, .tarGzip, .tarBzip2, .tarXz: "tar"
        case .gzip: "gzip"
        case .bzip2: "bzip2"
        case .xz: "xz"
        case .wim: "wim"
        }
    }

    /// The 7-Zip type of the compression around the tar, for compressed tars.
    var compressor: String? {
        switch self {
        case .tarGzip: "gzip"
        case .tarBzip2: "bzip2"
        case .tarXz: "xz"
        default: nil
        }
    }

    public var isCompressedTar: Bool { compressor != nil }

    /// Holds exactly one file, without a name of its own: compression, not an archive.
    public var isSingleFile: Bool {
        self == .gzip || self == .bzip2 || self == .xz
    }

    /// RAR is a proprietary format: only RARLAB's own program writes it.
    public var needsRar: Bool { self == .rar }

    public var supportsPassword: Bool {
        self == .zip || self == .sevenZip || self == .rar
    }

    /// Can also encrypt the list of files, so that the archive reveals nothing without the password.
    public var supportsEncryptedNames: Bool {
        self == .sevenZip || self == .rar
    }

    /// Can compress files together as one stream, which is smaller and slower to change.
    public var supportsSolid: Bool {
        self == .sevenZip || self == .rar
    }

    public var supportsVolumes: Bool {
        switch self {
        case .zip, .sevenZip, .rar, .tar: true
        default: false
        }
    }

    public var supportsComment: Bool {
        self == .zip || self == .rar
    }

    /// Whether there is anything to choose between "store" and "ultra".
    public var supportsLevels: Bool {
        self != .tar && self != .wim
    }

    public var supportsSelfExtracting: Bool {
        self == .sevenZip || self == .rar
    }

    /// The compression methods to choose from, the default first. Empty when the format
    /// has only one.
    public var methods: [String] {
        switch self {
        case .zip: ["Deflate", "Deflate64", "BZip2", "LZMA", "PPMd"]
        case .sevenZip: ["LZMA2", "LZMA", "PPMd", "BZip2", "Deflate"]
        default: []
        }
    }

    /// The dictionary sizes worth offering, in bytes. Empty when the format has a fixed one.
    public func dictionarySizes(method: String?) -> [UInt64] {
        let mb: UInt64 = 1 << 20
        switch self {
        case .sevenZip:
            switch method ?? "LZMA2" {
            case "LZMA2", "LZMA":
                return [1, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 1536].map { $0 * mb }
            case "PPMd":
                return [16, 32, 64, 128, 256, 512, 1024].map { $0 * mb }
            default:
                return []
            }
        case .zip:
            switch method ?? "Deflate" {
            case "LZMA": return [1, 4, 8, 16, 32, 64, 128, 256].map { $0 * mb }
            case "PPMd": return [16, 32, 64, 128, 256].map { $0 * mb }
            default: return []
            }
        case .rar:
            return [1, 4, 16, 32, 64, 128, 256, 512, 1024].map { $0 * mb }
        case .tarXz, .xz:
            return [1, 4, 8, 16, 32, 64, 128, 256].map { $0 * mb }
        default:
            return []
        }
    }

    /// What is wrong with a password for this format, if anything.
    ///
    /// Zip never said how a password becomes bytes, and programs disagree about every
    /// character outside of ASCII. 7-Zip refuses to write such an archive rather than
    /// write one that other programs cannot open.
    public func problem(withPassword password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        if !supportsPassword {
            return "\(displayName) archives cannot be protected with a password."
        }
        if self == .zip, !password.allSatisfy({ $0.isASCII }) {
            return "A ZIP password can only have plain letters, digits and punctuation. For a password with other characters, choose 7z."
        }
        return nil
    }

    /// The format a file name asks for, from its extension.
    public init?(fileName: String) {
        let lower = fileName.lowercased()
        // The two-part extensions first: ".tar.gz" also ends in ".gz".
        let table: [(String, ArchiveFormat)] = [
            (".tar.gz", .tarGzip), (".tgz", .tarGzip),
            (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
            (".tar.xz", .tarXz), (".txz", .tarXz),
            (".zip", .zip), (".7z", .sevenZip), (".rar", .rar), (".tar", .tar),
            (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".wim", .wim),
        ]
        guard let match = table.first(where: { lower.hasSuffix($0.0) }) else { return nil }
        self = match.1
    }
}

/// How hard to try. The names are 7-Zip's; RAR has six levels too.
public enum CompressionLevel: Int, Sendable, CaseIterable, Codable, Identifiable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .store: "Store"
        case .fastest: "Fastest"
        case .fast: "Fast"
        case .normal: "Normal"
        case .maximum: "Maximum"
        case .ultra: "Ultra"
        }
    }

    /// The same level on RAR's scale from 0 to 5.
    var rarLevel: Int {
        switch self {
        case .store: 0
        case .fastest: 1
        case .fast: 2
        case .normal: 3
        case .maximum: 4
        case .ultra: 5
        }
    }
}

/// What to do with files that are already in the archive when adding to it.
public enum UpdateMode: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Add everything, replacing files of the same name.
    case addAndReplace
    /// Add new files, and replace those that are older in the archive.
    case update
    /// Only replace files that are already in the archive and older there. Add nothing new.
    case freshen
    /// Like update, and remove from the archive what is no longer on disk.
    case synchronize

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .addAndReplace: "Add and replace files"
        case .update: "Add and update files"
        case .freshen: "Freshen existing files only"
        case .synchronize: "Synchronize archive contents"
        }
    }
}

public enum ZipEncryption: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Strong, and understood by 7-Zip, WinRAR, WinZip and Keka. Not by Windows Explorer
    /// or the Archive Utility of older systems.
    case aes256 = "AES256"
    /// The original zip encryption. Opens everywhere and protects very little.
    case zipCrypto = "ZipCrypto"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aes256: "AES-256"
        case .zipCrypto: "ZipCrypto (legacy)"
        }
    }
}

/// Everything that can be chosen when creating an archive or adding to one.
public struct CompressionOptions: Sendable, Hashable, Codable {
    public var format: ArchiveFormat = .zip
    public var level: CompressionLevel = .normal
    /// nil for the format's default.
    public var method: String?
    /// In bytes. nil lets the level decide.
    public var dictionarySize: UInt64?
    /// nil for the default: solid for 7z and not for RAR, as their own programs do.
    public var solid: Bool?
    /// nil to use every core.
    public var threads: Int?
    /// Split the archive into files of at most this many bytes.
    public var volumeSize: UInt64?
    public var updateMode: UpdateMode = .addAndReplace

    public var encryptFileNames = false
    public var zipEncryption: ZipEncryption = .aes256

    /// Leave out what the Finder scatters around: .DS_Store, and the "._" files that
    /// hold resource forks on disks that are not Mac formatted.
    public var excludeMacFiles = true
    /// Patterns of names to leave out, with * and ?, for example "*.tmp" or "node_modules".
    public var excludePatterns: [String] = []
    /// Keep symbolic links as links. Otherwise the file they point to is stored in their place.
    public var storeSymbolicLinks = true
    /// Put a program in front of the archive that extracts it.
    public var selfExtracting = false

    public var comment: String = ""

    /// RAR: the size of the recovery record, as a percentage of the archive. 0 for none.
    public var recoveryPercent = 0
    /// RAR: refuse later changes.
    public var lock = false

    public init() {}

    public init(format: ArchiveFormat, level: CompressionLevel = .normal) {
        self.format = format
        self.level = level
    }

    /// The names the exclusion of Mac files stands for.
    static let macFilePatterns = [".DS_Store", "__MACOSX", "._*", ".localized", ".fseventsd", ".Spotlight-V100", ".Trashes"]
}

/// The volume sizes people split archives into.
public enum VolumeSize {
    public static let presets: [(name: String, bytes: UInt64)] = [
        ("10 MB", 10 << 20),
        ("25 MB — email attachment", 25 << 20),
        ("100 MB", 100 << 20),
        ("700 MB — CD", 700 << 20),
        ("1 GB", 1 << 30),
        ("2 GB", 2 << 30),
        ("4 GB — FAT32", 4_294_967_295 - 1_048_575),
        ("4.7 GB — DVD", 4_480 << 20),
        ("25 GB — Blu-ray", 23_040 << 20),
    ]
}
