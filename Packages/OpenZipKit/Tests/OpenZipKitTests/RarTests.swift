import Foundation
import Testing
@testable import OpenZipKit

/// Writing RAR archives needs RARLAB's rar. Without it on the Mac these are skipped;
/// OPENZIP_RAR can name one that is not installed.
@Suite("RAR archives", .enabled(if: Fixtures.rar != nil, "RARLAB's rar is not installed"))
struct RarTests {
    let engine = Fixtures.engine

    private func makeRar(_ scratch: Scratch, _ name: String = "a.rar", configure: (inout CompressionOptions) -> Void = { _ in }, password: String? = nil) async throws -> URL {
        let sample = try scratch.sample()
        var options = CompressionOptions(format: .rar)
        configure(&options)
        let result = try await engine.compress(CompressionJob(sources: [sample], archive: scratch.path(name), options: options, password: password))
        return result.output
    }

    @Test func createsAndReadsBack() async throws {
        let scratch = try Scratch()
        let archive = try await makeRar(scratch) { options in
            options.solid = true
            options.recoveryPercent = 5
            options.comment = "Packed by the tests\nİkinci satır"
        }
        let listing = try await engine.list(archive)
        #expect(listing.info.type == "Rar5")
        #expect(listing.info.isSolid)
        #expect(listing.info.hasRecoveryRecord)
        #expect(listing.info.comment == "Packed by the tests\nİkinci satır")
        #expect(listing.paths == [
            "Sample", "Sample/docs", "Sample/docs/Türkçe şğü İı.txt", "Sample/docs/deep",
            "Sample/docs/deep/notes.md", "Sample/docs/日本語.txt", "Sample/empty", "Sample/hello.txt",
            "Sample/link", "Sample/run.sh",
        ].sorted())
        #expect(listing.entry("Sample/link")?.linkTarget == "hello.txt")
        #expect(engine.editability(of: listing.info, at: archive) == .editable)

        try FileManager.default.removeItem(at: scratch.path("Sample"))
        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))
        #expect(scratch.text("out/Sample/docs/Türkçe şğü İı.txt") == "içerik\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path("out/Sample/link").path) == "hello.txt")
        #expect(try await engine.test(archive).isClean)
    }

    @Test func changesAnArchive() async throws {
        let scratch = try Scratch()
        let archive = try await makeRar(scratch)
        var listing = try await engine.list(archive)

        try await engine.delete(["Sample/docs/deep", "Sample/run.sh"], from: archive, info: listing.info)
        try await engine.rename([
            (from: "Sample/hello.txt", to: "Sample/greeting.txt"),
            (from: "Sample/docs", to: "Sample/papers"),
        ], in: archive, info: listing.info)
        try await engine.createFolder("Sample/new folder", in: archive, info: listing.info)

        let extra = try scratch.file("elsewhere/extra.txt", "extra")
        _ = try await engine.compress(CompressionJob(sources: [extra], archive: archive, folder: "Sample/papers", options: CompressionOptions(format: .rar)))

        listing = try await engine.list(archive)
        #expect(listing.paths == [
            "Sample", "Sample/empty", "Sample/greeting.txt", "Sample/link", "Sample/new folder", "Sample/papers",
            "Sample/papers/Türkçe şğü İı.txt", "Sample/papers/extra.txt", "Sample/papers/日本語.txt",
        ].sorted())

        try await engine.setComment("changed", of: archive, info: listing.info)
        #expect(try await engine.list(archive).info.comment == "changed")
        try await engine.setComment("", of: archive, info: listing.info)
        #expect(try await engine.list(archive).info.comment.isEmpty)
    }

    @Test func encryptsWithAndWithoutTheNames() async throws {
        let scratch = try Scratch()
        let open = try await makeRar(scratch, "data.rar", password: "pass word")
        let listing = try await engine.list(open)
        #expect(listing.entry("Sample/hello.txt")?.isEncrypted == true)
        await #expect(throws: ArchiveError.wrongPassword) {
            try await engine.extract(ExtractionJob(archive: open, destination: scratch.path("wrong"), listing: listing, password: "no"))
        }

        try FileManager.default.removeItem(at: scratch.path("Sample"))
        let hidden = try await makeRar(scratch, "hidden.rar", configure: { $0.encryptFileNames = true }, password: "pass word")
        await #expect(throws: ArchiveError.passwordRequired) { try await engine.list(hidden) }
        let revealed = try await engine.list(hidden, password: "pass word")
        #expect(revealed.info.hasEncryptedHeaders)

        // Changing it needs the password, and works with it.
        try await engine.delete(["Sample/hello.txt"], from: hidden, info: revealed.info, password: "pass word")
        #expect(try await !engine.list(hidden, password: "pass word").paths.contains("Sample/hello.txt"))
        await #expect(throws: ArchiveError.passwordRequired) { try await engine.list(hidden) }
    }

    @Test func aLockedArchiveStaysAsItIs() async throws {
        let scratch = try Scratch()
        let archive = try await makeRar(scratch)
        try await engine.lock(archive)
        let listing = try await engine.list(archive)
        #expect(listing.info.isLocked)
        if case .readOnly = engine.editability(of: listing.info, at: archive) {} else {
            Issue.record("a locked archive must be read-only")
        }
        await #expect(throws: ArchiveError.self) {
            try await engine.delete(["Sample/hello.txt"], from: archive, info: listing.info)
        }
    }

    @Test func repairsWithTheRecoveryRecord() async throws {
        let scratch = try Scratch()
        try scratch.file("data/payload.bin", bytes: 600_000)
        var options = CompressionOptions(format: .rar, level: .store)
        options.recoveryPercent = 10
        let archive = scratch.path("fragile.rar")
        _ = try await engine.compress(CompressionJob(sources: [scratch.path("data")], archive: archive, options: options))

        var data = try Data(contentsOf: archive)
        for index in 300_000..<300_064 { data[index] ^= 0xFF }
        try data.write(to: archive)
        #expect(try await !engine.test(archive).isClean)

        let repaired = try await engine.repairRar(archive)
        #expect(repaired.lastPathComponent.contains("fragile.rar"))
        #expect(try await engine.test(repaired).isClean)
    }

    @Test func makesAnArchiveThatExtractsItself() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("note.txt", "carried along")
        var options = CompressionOptions(format: .rar)
        options.selfExtracting = true
        let result = try await engine.compress(CompressionJob(sources: [file], archive: scratch.path("carry.rar"), options: options))
        #expect(result.output.lastPathComponent == "carry.sfx")
        #expect(FileManager.default.isExecutableFile(atPath: result.output.path))
        // It is a program with an archive at its end, and can be opened as one.
        let listing = try await engine.list(result.output)
        #expect(listing.paths == ["note.txt"])
        #expect(listing.info.isSelfExtracting)
    }

    @Test func splitsIntoVolumes() async throws {
        let scratch = try Scratch()
        try scratch.file("data/payload.bin", bytes: 900_000)
        var options = CompressionOptions(format: .rar, level: .store)
        options.volumeSize = 400_000
        let result = try await engine.compress(CompressionJob(sources: [scratch.path("data")], archive: scratch.path("v.rar"), options: options))
        #expect(result.output.lastPathComponent == "v.part1.rar")
        #expect(FileNaming.firstVolume(of: scratch.path("v.part3.rar")) == scratch.path("v.part1.rar"))
        let listing = try await engine.list(result.output)
        #expect(listing.info.isMultiVolume)
        _ = try await engine.extract(ExtractionJob(archive: result.output, destination: scratch.path("out"), listing: listing))
        #expect(try Data(contentsOf: scratch.path("out/data/payload.bin")) == Data(contentsOf: scratch.path("data/payload.bin")))
    }
}

@Suite("RAR archives without rar")
struct RarWithoutRarTests {
    @Test func canBeReadAndSaysWhatIsMissing() async throws {
        let engine = ArchiveEngine(tools: Tools(sevenZip: Fixtures.sevenZip, rar: nil))
        var info = ArchiveInfo()
        info.type = "Rar5"
        #expect(engine.editability(of: info, at: URL(filePath: "/tmp/a.rar")) == .needsRar)

        let scratch = try Scratch()
        let file = try scratch.file("a.txt")
        await #expect(throws: ArchiveError.toolMissing("RAR")) {
            try await engine.compress(CompressionJob(sources: [file], archive: scratch.path("a.rar"), options: CompressionOptions(format: .rar)))
        }
    }
}
