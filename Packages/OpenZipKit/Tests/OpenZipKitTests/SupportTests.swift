import Foundation
import Testing
@testable import OpenZipKit

@Suite("Names")
struct NamingTests {
    @Test(arguments: [
        ("Photos.zip", "Photos"),
        ("backup.tar.gz", "backup"),
        ("backup.tgz", "backup"),
        ("Photos.part1.rar", "Photos"),
        ("Photos.part003.rar", "Photos"),
        ("big.7z.001", "big"),
        ("big.zip.002", "big"),
        ("my.project.v2.zip", "my.project.v2"),
        ("log.txt.gz", "log.txt"),
        ("data.cpio.gz", "data"),
        ("Report.pdf", "Report.pdf"),
        ("README", "README"),
        (".hidden.zip", ".hidden"),
    ])
    func theNameOfAnArchiveWithoutItsExtension(name: String, expected: String) {
        #expect(FileNaming.archiveBaseName(name) == expected)
    }

    @Test func splitsNamesWhereTheExtensionStarts() {
        #expect(FileNaming.split("a.tar.gz") == ("a", ".tar.gz"))
        #expect(FileNaming.split("photo.JPG") == ("photo", ".JPG"))
        #expect(FileNaming.split("Makefile") == ("Makefile", ""))
        #expect(FileNaming.split(".zshrc") == (".zshrc", ""))
        #expect(FileNaming.split("Version 1.2 notes") == ("Version 1.2 notes", ""))
    }

    @Test func countsUpToAFreeName() {
        let taken: Set<String> = ["/x/Report.pdf", "/x/Report 2.pdf", "/x/Folder", "/x/a.tar.gz"]
        func unique(_ path: String) -> String {
            FileNaming.uniqueURL(for: URL(filePath: path)) { taken.contains($0.path) }.path
        }
        #expect(unique("/x/Report.pdf") == "/x/Report 3.pdf")
        #expect(unique("/x/Folder") == "/x/Folder 2")
        #expect(unique("/x/a.tar.gz") == "/x/a 2.tar.gz")
        #expect(unique("/x/free.txt") == "/x/free.txt")
    }

    @Test func findsTheFirstVolume() throws {
        let scratch = try Scratch()
        for name in ["a.part01.rar", "a.part02.rar", "old.rar", "old.r00", "z.zip", "z.z01", "s.7z.001", "s.7z.002"] {
            try scratch.file(name)
        }
        #expect(FileNaming.firstVolume(of: scratch.path("a.part02.rar")) == scratch.path("a.part01.rar"))
        #expect(FileNaming.firstVolume(of: scratch.path("old.r00")) == scratch.path("old.rar"))
        #expect(FileNaming.firstVolume(of: scratch.path("z.z01")) == scratch.path("z.zip"))
        #expect(FileNaming.firstVolume(of: scratch.path("s.7z.002")) == scratch.path("s.7z.001"))
        // Not a volume, or its first is missing: itself.
        #expect(FileNaming.firstVolume(of: scratch.path("z.zip")) == scratch.path("z.zip"))
        #expect(FileNaming.firstVolume(of: scratch.path("gone.part2.rar")) == scratch.path("gone.part2.rar"))
    }

    @Test func recognizesFormatsByExtension() {
        #expect(ArchiveFormat(fileName: "A.ZIP") == .zip)
        #expect(ArchiveFormat(fileName: "a.tar.gz") == .tarGzip)
        #expect(ArchiveFormat(fileName: "a.tgz") == .tarGzip)
        #expect(ArchiveFormat(fileName: "a.gz") == .gzip)
        #expect(ArchiveFormat(fileName: "a.txz") == .tarXz)
        #expect(ArchiveFormat(fileName: "a.txt") == nil)
    }

    @Test func matchesPatterns() {
        #expect(Wildcard.matches("notes.TMP", pattern: "*.tmp"))
        #expect(Wildcard.matches("._resource", pattern: "._*"))
        #expect(Wildcard.matches("a1b", pattern: "a?b"))
        #expect(!Wildcard.matches("ab", pattern: "a?b"))
        #expect(Wildcard.matches("anything", pattern: "*"))
        #expect(Wildcard.matches("a.b.c", pattern: "*.*.c"))
        #expect(!Wildcard.matches("node_modules2", pattern: "node_modules"))
        #expect(Wildcard.matches("", pattern: "*"))
        #expect(!Wildcard.matches("x", pattern: ""))
    }
}

@Suite("The tree of an archive")
struct TreeTests {
    private func entry(_ path: String, folder: Bool = false, size: UInt64 = 0, packed: UInt64? = nil, date: TimeInterval? = nil) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: folder, size: size, packedSize: packed, modified: date.map(Date.init(timeIntervalSince1970:)))
    }

    private func names(_ tree: ArchiveTree, _ ids: [Int]) -> [String] {
        ids.map { tree[$0].name }
    }

    @Test func buildsFoldersThatAreOnlyImplied() throws {
        let tree = ArchiveTree(entries: [
            entry("a/b/c/file.txt", size: 10, packed: 4),
            entry("a/other.txt", size: 5, packed: 5),
            entry("top.txt", size: 1, packed: 1),
        ])
        #expect(Set(names(tree, tree.root.children)) == ["a", "top.txt"])
        let a = try #require(tree.node(atDisplayPath: "a"))
        #expect(tree[a].isDirectory)
        #expect(tree[a].entry == nil)
        #expect(tree[a].path == "a")
        #expect(tree[a].size == 15)
        #expect(tree[a].packedSize == 9)
        #expect(tree[a].fileCount == 2)
        #expect(tree[a].folderCount == 2)
        #expect(tree.root.size == 16)
        #expect(tree.root.fileCount == 3)

        let c = try #require(tree.node(atDisplayPath: "a/b/c"))
        #expect(tree[c].path == "a/b/c")
        #expect(tree.displayPath(of: c) == "a/b/c")
        #expect(names(tree, tree.ancestors(of: c)) == ["", "a", "b", "c"])
    }

    @Test func aFolderListedAfterItsFilesIsTheSameFolder() throws {
        let tree = ArchiveTree(entries: [
            entry("docs/a.txt", size: 1),
            entry("docs", folder: true, date: 1000),
            entry("docs/b.txt", size: 2),
            entry("empty", folder: true),
        ])
        #expect(tree.root.children.count == 2)
        let docs = try #require(tree.node(atDisplayPath: "docs"))
        #expect(tree[docs].entry == 1)
        #expect(tree[docs].children.count == 2)
        #expect(tree[docs].modified == Date(timeIntervalSince1970: 1000))
        #expect(tree.root.folderCount == 2)
    }

    @Test func tidiesPathsAndKeepsTheStoredOnes() throws {
        // The way tar writes them when a folder was packed as ".".
        let tree = ArchiveTree(entries: [
            entry(".", folder: true),
            entry("./docs", folder: true),
            entry("./docs/sub/a.txt", size: 3),
            entry("/absolute/b.txt", size: 4),
            entry("double//slash.txt", size: 5),
        ])
        #expect(Set(names(tree, tree.root.children)) == ["docs", "absolute", "double"])
        let file = try #require(tree.node(atDisplayPath: "docs/sub/a.txt"))
        #expect(tree[file].path == "./docs/sub/a.txt")
        let sub = try #require(tree.node(atDisplayPath: "docs/sub"))
        #expect(tree[sub].path == "./docs/sub")
        let absolute = try #require(tree.node(atDisplayPath: "absolute"))
        #expect(tree[absolute].path == "/absolute")
    }

    @Test func sortsLikeTheFinder() {
        let tree = ArchiveTree(entries: [
            entry("File 10.txt", size: 1, date: 30),
            entry("File 2.txt", size: 300, date: 10),
            entry("zebra", folder: true),
            entry("apple.png", size: 20, date: 20),
            entry("Älpha", folder: true),
        ])
        let ids = tree.root.children
        #expect(names(tree, tree.sorted(ids, by: .name, ascending: true)) == ["Älpha", "zebra", "apple.png", "File 2.txt", "File 10.txt"])
        #expect(names(tree, tree.sorted(ids, by: .name, ascending: false)) == ["zebra", "Älpha", "File 10.txt", "File 2.txt", "apple.png"])
        #expect(names(tree, tree.sorted(ids, by: .size, ascending: false)).suffix(3) == ["File 2.txt", "apple.png", "File 10.txt"])
        #expect(names(tree, tree.sorted(ids, by: .modified, ascending: true)).suffix(3) == ["File 2.txt", "apple.png", "File 10.txt"])
        #expect(names(tree, tree.sorted(ids, by: .kind, ascending: true, foldersFirst: false)).first == "Älpha")
    }

    @Test func searchesNamesAtAnyDepth() {
        let tree = ArchiveTree(entries: [
            entry("docs/Résumé.pdf"), entry("docs/deep/resume-old.PDF"), entry("notes.txt"),
            entry("__MACOSX/docs/._Résumé.pdf"), entry("src/main.swift"),
        ])
        #expect(Set(names(tree, tree.search("resume"))) == ["Résumé.pdf", "resume-old.PDF", "._Résumé.pdf"])
        #expect(Set(names(tree, tree.search("resume", includeMacMetadata: false))) == ["Résumé.pdf", "resume-old.PDF"])
        #expect(Set(names(tree, tree.search("*.pdf", includeMacMetadata: false))) == ["Résumé.pdf", "resume-old.PDF"])
        #expect(names(tree, tree.search("deep")) == ["deep"])
        #expect(tree.search("   ").isEmpty)
    }

    @Test func survivesSizesNoDiskCouldHold() {
        // A listing can claim anything. Adding it up must not be what brings the app down.
        let tree = ArchiveTree(entries: [
            entry("bomb/a", size: .max, packed: .max),
            entry("bomb/b", size: .max, packed: 10),
            entry("bomb/c", size: 5),
        ])
        #expect(tree.root.size == .max)
        #expect(tree.root.fileCount == 3)
    }

    @Test func handlesManyEntries() {
        var entries: [ArchiveEntry] = []
        for folder in 0..<200 {
            for file in 0..<500 {
                entries.append(entry("root/folder \(folder)/file \(file).dat", size: 100, packed: 50))
            }
        }
        let clock = ContinuousClock()
        var tree = ArchiveTree()
        let elapsed = clock.measure { tree = ArchiveTree(entries: entries) }
        #expect(tree.root.fileCount == 100_000)
        #expect(tree.root.size == 10_000_000)
        #expect(tree.nodes.count == 100_000 + 200 + 2)
        // A hundred thousand entries are a matter of a moment, not of a progress bar.
        #expect(elapsed < .seconds(2))
    }
}

@Suite("RARLAB's packages")
struct RarPackagesTests {
    /// The links of RARLAB's download page in November 2026: 7.23 is out, 7.30 is a beta,
    /// Apple silicon is changing its name and Intel Macs are no longer on the page.
    private let page = """
        <td><a href="/rar/rarlinux-x64-730b2.tar.gz">RAR for Linux x64 7.30 beta 2</a></td>
        <td><a href="/rar/rarmacos-arm64-730b2.tar.gz">RAR for macOS ARM64 7.30 beta 2</a></td>
        <td><a href="/rar/rarlinux-x64-723.tar.gz">RAR for Linux x64 7.23</a></td>
        <td><a href="/rar/rarbsd-x64-723.tar.gz">RAR for FreeBSD x64 7.23</a></td>
        <td><a href="/rar/rarmacos-arm-723.tar.gz">RAR for macOS ARM64 7.23</a></td>
        """

    @Test func findsTheReleaseForAppleSiliconAndLeavesTheBeta() {
        #expect(RarPackages.packages(listedIn: page, for: .appleSilicon) == [
            .init(version: "7.23", path: "/rar/rarmacos-arm-723.tar.gz"),
        ])
    }

    @Test func knowsAppleSiliconByItsNewNameToo() {
        let later = page.replacingOccurrences(of: "730b2", with: "730")
        #expect(RarPackages.packages(listedIn: later, for: .appleSilicon) == [
            .init(version: "7.30", path: "/rar/rarmacos-arm64-730.tar.gz"),
            .init(version: "7.23", path: "/rar/rarmacos-arm-723.tar.gz"),
        ])
    }

    @Test func offersAnIntelMacWhatIsNotOnThePage() {
        // The package of the version that is listed, under the name it has on the server.
        #expect(RarPackages.packages(listedIn: page, for: .intel) == [
            .init(version: "7.23", path: "/rar/rarmacos-x64-723.tar.gz"),
        ])
        // A later version may not exist for Intel: the last that does comes after it.
        let later = page.replacingOccurrences(of: "730b2", with: "730")
        #expect(RarPackages.packages(listedIn: later, for: .intel).map(\.path) == [
            "/rar/rarmacos-x64-730.tar.gz", "/rar/rarmacos-x64-723.tar.gz",
        ])
        // And a page that says nothing at all still leads to that one.
        #expect(RarPackages.packages(listedIn: "", for: .intel).map(\.version) == ["7.23"])
        #expect(RarPackages.packages(listedIn: "", for: .appleSilicon).isEmpty)
    }

    @Test func takesAnIntelPackageThatIsListed() {
        let earlier = """
            <a href="/rar/rarmacos-x64-712.tar.gz">RAR for macOS x64 7.12</a>
            <a href="/rar/rarmacos-arm-712.tar.gz">RAR for macOS ARM 7.12</a>
            """
        #expect(RarPackages.packages(listedIn: earlier, for: .intel) == [
            .init(version: "7.23", path: "/rar/rarmacos-x64-723.tar.gz"),
            .init(version: "7.12", path: "/rar/rarmacos-x64-712.tar.gz"),
        ])
        #expect(RarPackages.packages(listedIn: earlier, for: .appleSilicon) == [
            .init(version: "7.12", path: "/rar/rarmacos-arm-712.tar.gz"),
        ])
    }

    @Test func writesVersionsTheWayRarlabDoes() {
        #expect(RarPackages.version(from: 723) == "7.23")
        #expect(RarPackages.version(from: 700) == "7.00")
        #expect(RarPackages.version(from: 1005) == "10.05")
    }
}

@Suite("The report of what is in an archive")
struct ArchiveReportTests {
    private var listing: ArchiveListing {
        let time = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
        var info = ArchiveInfo()
        info.type = "zip"
        info.physicalSize = 2_048
        return ArchiveListing(info: info, entries: [
            ArchiveEntry(path: "notes/read me, \"first\".txt", size: 1_200, packedSize: 400, modified: time, crc: 0x00AB_CDEF, isEncrypted: true, method: "Deflate", permissions: "-rw-r--r--"),
            ArchiveEntry(path: "notes", isDirectory: true, modified: time),
            ArchiveEntry(path: "latest", size: 5, modified: time, linkTarget: "notes", isSymbolicLink: true),
            ArchiveEntry(path: "a.bin", size: 4_000, modified: nil, method: "Store"),
        ])
    }

    @Test func writesATableForASpreadsheet() {
        let report = ArchiveReport.make(of: listing, named: "Kit.zip", as: .csv, timeZone: TimeZone(identifier: "UTC")!)
        #expect(report == [
            "Path,Kind,Size,Packed,Modified,CRC32,Method,Encrypted,Permissions,Link",
            "a.bin,file,4000,,,,Store,,,",
            "latest,link,5,,2027-01-15 08:00:00,,,,,notes",
            "notes,folder,,,2027-01-15 08:00:00,,,,,",
            "\"notes/read me, \"\"first\"\".txt\",file,1200,400,2027-01-15 08:00:00,00ABCDEF,Deflate,yes,-rw-r--r--,",
            "",
        ].joined(separator: "\r\n"))
    }

    @Test func writesAListToRead() {
        let report = ArchiveReport.make(of: listing, named: "Kit.zip", as: .text, timeZone: TimeZone(identifier: "Europe/Istanbul")!)
        #expect(report == """
            Kit.zip
            ZIP, 3 files, 1 folder, 5205 bytes in 2048

            Modified                  Size        Packed  Name
                                      4000                a.bin
            2027-01-15 11:00             5                latest -> notes
            2027-01-15 11:00                              notes/
            2027-01-15 11:00          1200           400  notes/read me, "first".txt

            """)
    }

    @Test func anEmptyArchiveStillHasItsHeader() {
        #expect(ArchiveReport.make(of: ArchiveListing(), named: "e.7z", as: .csv) == "Path,Kind,Size,Packed,Modified,CRC32,Method,Encrypted,Permissions,Link\r\n")
        #expect(ArchiveReport.make(of: ArchiveListing(), named: "e.7z", as: .text).hasPrefix("e.7z\nArchive, 0 files, 0 bytes\n"))
    }
}
