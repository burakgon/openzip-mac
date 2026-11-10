import Foundation
import Testing
@testable import OpenZipKit

@Suite("Reading what 7-Zip prints")
struct ParsingTests {
    private func parse(_ text: String, chunk: Int? = nil) -> ListingParser {
        var parser = ListingParser()
        let data = Data(text.utf8)
        if let chunk {
            // In pieces, as it comes through a pipe: lines are cut anywhere.
            var offset = 0
            while offset < data.count {
                parser.feed(data.subdata(in: offset..<min(offset + chunk, data.count)))
                offset += chunk
            }
        } else {
            parser.feed(data)
        }
        parser.finish()
        return parser
    }

    private let zipListing = """

    7-Zip (z) 26.06 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-11-06
     64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:18 OPEN_MAX:1048576, ASM

    Scanning the drive for archives:
    1 file, 3014553 bytes (2944 KiB)

    Listing archive: a.zip

    --
    Path = a.zip
    Type = zip
    Physical Size = 3014553
    Comment =
    {
    Two lines
    of comment
    }

    ----------
    Path = docs
    Folder = +
    Size = 0
    Packed Size = 0
    Modified = 2026-11-10 21:58:25.7570288
    Created =
    Accessed =
    Attributes = D drwxr-xr-x
    Encrypted = -
    Comment =
    CRC =
    Method = Store
    Characteristics = NTFS
    Host OS = Unix
    Version = 20
    Volume Index = 0
    Offset = 0

    Path = docs/a = b.txt
    Folder = -
    Size = 5000000
    Packed Size = 13250
    Modified = 2026-11-10 21:58:25
    Created =
    Accessed =
    Attributes =  -rwxr-xr-x
    Encrypted = +
    Comment =
    CRC = 9669D6F6
    Method = AES-256 Deflate
    Characteristics = NTFS
    Host OS = Unix
    Version = 20
    Volume Index = 0
    Offset = 3000080

    Path = link
    Folder = -
    Size = 9
    Packed Size = 9
    Modified = 2026-11-10 21:58:25.7562232
    Attributes =  lrwxr-xr-x
    Encrypted = -
    CRC = AF083B2D
    Method = Store

    """

    @Test func readsArchiveAndEntries() {
        let parser = parse(zipListing)
        #expect(parser.foundArchive)
        #expect(parser.info.type == "zip")
        #expect(parser.info.physicalSize == 3_014_553)
        #expect(parser.info.comment == "Two lines\nof comment")
        #expect(parser.entries.map(\.path) == ["docs", "docs/a = b.txt", "link"])

        let folder = parser.entries[0]
        #expect(folder.isDirectory)
        #expect(folder.permissions == "drwxr-xr-x")

        let file = parser.entries[1]
        #expect(!file.isDirectory)
        #expect(file.size == 5_000_000)
        #expect(file.packedSize == 13_250)
        #expect(file.isEncrypted)
        #expect(file.crc == 0x9669_D6F6)
        #expect(file.method == "AES-256 Deflate")
        #expect(file.permissions == "-rwxr-xr-x")

        #expect(parser.entries[2].isSymbolicLink)
        #expect(!parser.entries[2].isDirectory)
    }

    @Test(arguments: [1, 7, 64, 1000])
    func readsTheSameInPieces(chunk: Int) {
        let whole = parse(zipListing)
        let pieces = parse(zipListing, chunk: chunk)
        #expect(pieces.entries == whole.entries)
        #expect(pieces.info == whole.info)
    }

    @Test func readsDatesInTheLocalTimeZone() throws {
        let parser = parse(zipListing)
        let date = try #require(parser.entries[0].modified)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 10)
        #expect(parts.hour == 21 && parts.minute == 58 && parts.second == 25)
        #expect(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.75)
    }

    @Test func sevenZipFoldersAreKnownByTheirAttributes() {
        let parser = parse("""
        --
        Path = a.7z
        Type = 7z
        Method = LZMA2:23
        Solid = +
        Blocks = 1

        ----------
        Path = empty dir
        Size = 0
        Packed Size = 0
        Modified = 2026-11-10 21:58:25.7559067
        Attributes = D drwxr-xr-x
        CRC =
        Encrypted = -
        Method =
        Block =

        Path = made on windows
        Size = 0
        Attributes = D

        Path = docs/random.bin
        Size = 3000000
        Packed Size =
        Attributes = A -rw-r--r--
        CRC = 94A31C6B
        Encrypted = -
        Method = LZMA2:23
        Block = 0

        """)
        #expect(parser.info.isSolid)
        #expect(parser.entries.map(\.isDirectory) == [true, true, false])
        #expect(parser.entries[2].packedSize == nil)
    }

    @Test func readsRarProperties() {
        let parser = parse("""
        --
        Path = r1.rar
        Type = Rar5
        Physical Size = 3173651
        Characteristics = Solid Recovery Lock Locator QuickOpen:3006464 Recovery:3006550 Comment
        Encrypted = -
        Solid = +
        Multivolume = -
        Volumes = 1

        ----------
        Path = link-to-hello
        Folder = -
        Size = 0
        Attributes =  lrwxr-xr-x
        Symbolic Link = hello.txt

        """)
        #expect(parser.info.type == "Rar5")
        #expect(parser.info.isLocked)
        #expect(parser.info.hasRecoveryRecord)
        #expect(!parser.info.isMultiVolume)
        #expect(parser.entries[0].linkTarget == "hello.txt")
        #expect(parser.info.displayType == "RAR")
    }

    @Test func aSplitArchiveIsDescribedByItsInnerArchive() {
        let parser = parse("""
        --
        Path = big.7z.001
        Type = Split
        Physical Size = 1048576
        Volumes = 3
        Total Physical Size = 3001987
        ----
        Path = big.7z
        Size = 3001987
        --
        Path = big.7z
        Type = 7z
        Physical Size = 3001987
        Headers Size = 329

        ----------
        Path = a.txt
        Size = 12

        """)
        #expect(parser.info.type == "7z")
        #expect(parser.info.isMultiVolume)
        #expect(parser.info.volumeCount == 3)
        #expect(parser.entries.map(\.path) == ["a.txt"])
    }

    @Test func notesWhatIsWrongWithTheArchive() {
        let parser = parse("""
        --
        Path = broken.zip
        Type = zip
        ERRORS:
        Unexpected end of archive
        WARNINGS:
        There are data after the end of archive
        Physical Size = 100

        ----------
        Path = a.txt
        Size = 12

        Errors: 1
        """)
        #expect(parser.info.errors == ["Unexpected end of archive"])
        #expect(parser.info.warnings == ["There are data after the end of archive"])
        #expect(parser.entries.count == 1)
    }

    @Test func noticesThePasswordPrompt() {
        let parser = parse("Listing archive: p.7z\n\n\nEnter password (will not be echoed):\n\n\nBreak signaled\n")
        #expect(parser.sawPasswordPrompt)
        #expect(!parser.foundArchive)
    }

    // MARK: Progress

    @Test func readsProgressAndTheFileBeingWorkedOn() {
        var output = OperationOutput()
        let backspaces = String(repeating: "\u{8}", count: 6)
        var changed = output.feed(Data("  0%\u{8}\u{8}\u{8}\u{8}    \u{8}\u{8}\u{8}\u{8}- docs/a.txt\n".utf8))
        #expect(changed)
        #expect(output.percent == 0)
        #expect(output.item == "docs/a.txt")
        changed = output.feed(Data(" 16% 1\(backspaces)      \(backspaces)- 50% off.txt\n".utf8))
        #expect(changed)
        #expect(output.percent == 16)
        #expect(output.item == "50% off.txt")
        // A percentage that nothing has been printed over yet counts already.
        changed = output.feed(Data(" 73% 4".utf8))
        #expect(changed)
        #expect(output.percent == 73)
        _ = output.feed(Data("\r 99% 5 + last.bin\n".utf8))
        #expect(output.percent == 99)
        #expect(output.item == "last.bin")
    }

    @Test func aPercentageWithAFileOnTheSameLine() throws {
        let progress = try #require(OperationOutput.progress(in: "50% 3 + docs/r5.bin"))
        #expect(progress.percent == 50)
        #expect(progress.item == "docs/r5.bin")
        #expect(OperationOutput.progress(in: "Everything is Ok") == nil)
        #expect(OperationOutput.progress(in: "100%")?.percent == 100)
    }

    @Test func collectsTheFilesThatFailed() {
        var output = OperationOutput()
        _ = output.feed(Data("""
        ERROR: Wrong password : docs/sub/lorem.txt
        ERROR: CRC Failed : hello.txt
        ERROR: errno=13 : Permission denied
        /some/where

        Sub items Errors: 2

        """.utf8))
        #expect(output.failures == [
            .init(path: "docs/sub/lorem.txt", reason: "Wrong password"),
            .init(path: "hello.txt", reason: "CRC Failed"),
        ])
        #expect(output.diagnosis.contains("Permission denied"))
        #expect(output.diagnosis.contains("/some/where"))
    }

    @Test func classifiesWhatWentWrong() {
        #expect(ArchiveEngine.classify("ERROR: x.txt\nCannot open the file as archive", exitCode: 2) == .notAnArchive)
        #expect(ArchiveEngine.classify("ERROR: errno=28 : No space left on device", exitCode: 2) == .notEnoughSpace)
        #expect(ArchiveEngine.classify("ERROR: errno=13 : Permission denied\n/Volumes/x/file", exitCode: 2) == .accessDenied("/Volumes/x/file"))
        #expect(ArchiveEngine.classify("", exitCode: 255) == .cancelled)
        if case .damaged = ArchiveEngine.classify("ERRORS:\nUnexpected end of archive", exitCode: 2) {} else {
            Issue.record("a truncated archive should be reported as damaged")
        }
    }

    @Test func readsWhatRarPrints() {
        var output = RarOutput()
        let erase = "\u{8}\u{8}\u{8}\u{8}"
        _ = output.feed(Data("Creating archive q.rar\n\nAdding    /tmp/lab/docs/random.bin     \(erase) 29%\(erase) 37%".utf8))
        #expect(output.percent == 37)
        #expect(output.item == "random.bin")
        _ = output.feed(Data("\(erase) 99%\(erase)  OK \nDone\n".utf8))
        #expect(output.percent == 99)
        #expect(output.messages.isEmpty)
    }
}

@Suite("The benchmark")
struct BenchmarkTests {
    /// What `7zz b` printed on a Mac, shortened in the middle.
    private let output = """

        7-Zip (z) 26.06 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-11-06
         64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:18 OPEN_MAX:1048576, ASM

        Compiler:  CLANG 21.0.0 ver:Apple LLVM 21.0.0 (clang-2100.4.1.1) GCC 4.2.1 : CRYPTO SHA2 AES CRC32 UNALIGNED
        Darwin : 27.2.0 : Darwin Kernel Version 27.2.0: Thu Oct 15 00:22:36 PDT 2026; root:xnu-13432.41.4~27/RELEASE_ARM64_T6050 : arm64
        PageSize:16KB
        Apple M5 Max 18C18T

        1T CPU Freq (MHz):  4248  4255  4254  4285  4281  4169  4207
        9T CPU Freq (MHz): 891% 4161   889% 4118

        RAM size:   49152 MB,  # CPU hardware threads:  18
        RAM usage:   4003 MB,  # Benchmark threads:     18

                               Compressing  |                  Decompressing
        Dict     Speed Usage    R/U Rating  |      Speed Usage    R/U Rating
                 KiB/s     %   MIPS   MIPS  |      KiB/s     %   MIPS   MIPS

        22:     131584  1573   8136 128006  |    1422650  1778   6821 121294
        23:     124321  1601   7910 126669  |    1399001  1779   6803 121044
        ----------------------------------  | ------------------------------
        Avr:    127952  1587   8023 127337  |    1410825  1778   6812 121169
        Tot:            1683   7418 124253

        """

    @Test func readsThePassesAndTheTotal() {
        var parser = BenchmarkParser()
        _ = parser.feed(Data(output.utf8))
        let result = parser.result
        #expect(result.processor == "Apple M5 Max 18C18T")
        #expect(result.threads == 18)
        #expect(result.passes.map(\.dictionaryBits) == [22, 23])
        #expect(result.passes[0].compressing == .init(speed: 131_584, usage: 1_573, ratingPerCore: 8_136, rating: 128_006))
        #expect(result.passes[1].decompressing == .init(speed: 1_399_001, usage: 1_779, ratingPerCore: 6_803, rating: 121_044))
        #expect(result.average?.compressing.rating == 127_337)
        #expect(result.totalUsage == 1_683)
        #expect(result.totalRating == 124_253)
        #expect(result.isComplete)
    }

    @Test func followsTheOutputAsItComes() {
        var parser = BenchmarkParser()
        var updates = 0
        // In pieces that end in the middle of lines, the way a pipe delivers them.
        let bytes = Array(output.utf8)
        for start in stride(from: 0, to: bytes.count, by: 37) {
            if parser.feed(Data(bytes[start..<min(start + 37, bytes.count)])) { updates += 1 }
        }
        #expect(parser.result.passes.count == 2)
        #expect(parser.result.totalRating == 124_253)
        #expect(updates >= 5)
        #expect(!BenchmarkParser().result.isComplete)
    }

    @Test func measuresThisMac() async throws {
        // A short one: the engine's own always runs the full set of passes.
        var parser = BenchmarkParser()
        let process = Process()
        process.executableURL = Fixtures.sevenZip
        process.arguments = ["b", "-mmt2", "-md18"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = parser.feed(data)
        #expect(parser.result.isComplete)
        #expect(parser.result.passes.map(\.dictionaryBits) == [18])
        #expect((parser.result.totalRating ?? 0) > 100)
        #expect(!parser.result.processor.isEmpty)
    }
}
