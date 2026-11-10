import Foundation
import Testing
@testable import OpenZipKit

@Suite("Creating, listing and changing archives")
struct ArchiveTests {
    let engine = Fixtures.engine

    /// Creates an archive of the sample folder and returns where it is.
    private func makeArchive(_ scratch: Scratch, _ name: String, options: CompressionOptions? = nil, password: String? = nil) async throws -> URL {
        let sample = try scratch.sample()
        var options = options ?? CompressionOptions()
        if options.format == .zip, let format = ArchiveFormat(fileName: name) { options.format = format }
        let archive = scratch.path(name)
        let result = try await engine.compress(CompressionJob(sources: [sample], archive: archive, options: options, password: password))
        #expect(result.report.isClean)
        return result.output
    }

    // MARK: Creating and listing

    @Test(arguments: ["a.zip", "a.7z", "a.tar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.tar.xz"])
    func createsAndListsEveryFormat(name: String) async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, name)
        let listing = try await engine.list(archive)

        // What the Finder leaves behind is left out; everything else is there, under the
        // name of the folder that was added.
        #expect(listing.paths == [
            "Sample", "Sample/docs", "Sample/docs/Türkçe şğü İı.txt", "Sample/docs/deep",
            "Sample/docs/deep/notes.md", "Sample/docs/日本語.txt", "Sample/empty", "Sample/hello.txt",
            "Sample/link", "Sample/run.sh",
        ].sorted())
        #expect(listing.entry("Sample/docs")?.isDirectory == true)
        #expect(listing.entry("Sample/empty")?.isDirectory == true)
        #expect(listing.entry("Sample/hello.txt")?.size == 12)
        #expect(listing.entry("Sample/link")?.isSymbolicLink == true)
        #expect(listing.entry("Sample/run.sh")?.permissions == "-rwxr-xr-x")
        #expect(listing.info.physicalSize ?? 0 > 0)

        let format = try #require(ArchiveFormat(fileName: name))
        #expect(listing.info.displayType == format.displayName)
        #expect(listing.info.compression.isEmpty != format.isCompressedTar)
        #expect(engine.editability(of: listing.info, at: archive) == .editable)
    }

    @Test func keepsTheFinderFilesWhenAsked() async throws {
        let scratch = try Scratch()
        var options = CompressionOptions(format: .zip)
        options.excludeMacFiles = false
        let listing = try await engine.list(try await makeArchive(scratch, "a.zip", options: options))
        #expect(listing.paths.contains("Sample/docs/.DS_Store"))
        #expect(listing.paths.contains("Sample/docs/deep/._notes.md"))
    }

    @Test func leavesOutWhatThePatternsName() async throws {
        let scratch = try Scratch()
        var options = CompressionOptions(format: .sevenZip)
        options.excludePatterns = ["*.md", "empty"]
        let listing = try await engine.list(try await makeArchive(scratch, "a.7z", options: options))
        #expect(!listing.paths.contains("Sample/docs/deep/notes.md"))
        #expect(!listing.paths.contains("Sample/empty"))
        #expect(listing.paths.contains("Sample/hello.txt"))
    }

    @Test func aNameWithAWildcardCharacterIsOneFile() async throws {
        let scratch = try Scratch()
        let question = try scratch.file("what?.txt", "the one")
        try scratch.file("whatX.txt", "another")
        let star = try scratch.file("star*.txt", "starred")
        let archive = scratch.path("w.zip")
        _ = try await engine.compress(CompressionJob(sources: [question, star], archive: archive))
        #expect(try await engine.list(archive).paths == ["star*.txt", "what?.txt"])
    }

    @Test func followsLinksWhenToldTo() async throws {
        let scratch = try Scratch()
        var options = CompressionOptions(format: .zip)
        options.storeSymbolicLinks = false
        let listing = try await engine.list(try await makeArchive(scratch, "a.zip", options: options))
        let link = try #require(listing.entry("Sample/link"))
        #expect(!link.isSymbolicLink)
        #expect(link.size == 12)
    }

    @Test func compressesASingleFile() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("log.txt", String(repeating: "line\n", count: 5000))
        let archive = scratch.path("log.txt.gz")
        _ = try await engine.compress(CompressionJob(sources: [file], archive: archive, options: CompressionOptions(format: .gzip)))
        let listing = try await engine.list(archive)
        #expect(listing.info.type == "gzip")
        #expect(listing.paths == ["log.txt"])
        #expect(engine.editability(of: listing.info, at: archive) != .editable)

        // A folder is not a single file.
        let folder = try scratch.sample()
        await #expect(throws: ArchiveError.self) {
            try await engine.compress(CompressionJob(sources: [folder], archive: scratch.path("x.gz"), options: CompressionOptions(format: .gzip)))
        }
    }

    @Test func writesWindowsImages() async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, "a.wim", options: CompressionOptions(format: .wim))
        var listing = try await engine.list(archive)
        #expect(listing.info.type == "wim")
        #expect(listing.paths.contains("Sample/docs/deep/notes.md"))
        #expect(engine.editability(of: listing.info, at: archive) == .editable)
        try await engine.delete(["Sample/run.sh"], from: archive, info: listing.info)
        listing = try await engine.list(archive)
        #expect(!listing.paths.contains("Sample/run.sh"))
        #expect(try await engine.test(archive).isClean)
    }

    @Test func splitsIntoVolumes() async throws {
        let scratch = try Scratch()
        let big = try scratch.file("big.bin", bytes: 700_000)
        var options = CompressionOptions(format: .sevenZip, level: .store)
        options.volumeSize = 256 * 1024
        let result = try await engine.compress(CompressionJob(sources: [big], archive: scratch.path("big.7z"), options: options))
        #expect(result.output.lastPathComponent == "big.7z.001")
        #expect(FileManager.default.fileExists(atPath: scratch.path("big.7z.003").path))

        let listing = try await engine.list(result.output)
        #expect(listing.info.isMultiVolume)
        #expect(listing.info.type == "7z")
        #expect(listing.paths == ["big.bin"])
        if case .readOnly = engine.editability(of: listing.info, at: result.output) {} else {
            Issue.record("a split archive must not be offered for changes")
        }
        // Any of its pieces leads to the first.
        #expect(FileNaming.firstVolume(of: scratch.path("big.7z.003")) == scratch.path("big.7z.001"))

        let extracted = try await engine.extract(ExtractionJob(archive: result.output, destination: scratch.path("out")))
        #expect(extracted.items.count == 1)
        #expect(try Data(contentsOf: scratch.path("out/big.bin")) == Data(contentsOf: big))
    }

    @Test func aFileThatIsNoArchive() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("plain.txt", "just text, nothing packed")
        await #expect(throws: ArchiveError.notAnArchive) {
            try await engine.list(file)
        }
    }

    @Test func aDamagedArchiveIsListedWithWhatIsWrong() async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, "a.zip")
        // Cut the end off: the directory of a zip is at its end.
        let data = try Data(contentsOf: archive)
        try data.prefix(data.count - 200).write(to: archive)
        do {
            let listing = try await engine.list(archive)
            #expect(!listing.info.errors.isEmpty || !listing.info.warnings.isEmpty)
        } catch let error as ArchiveError {
            // Too damaged to list is an answer too, as long as it is the right one.
            #expect(error != .cancelled && error != .passwordRequired)
        }
    }

    // MARK: Passwords

    @Test func encryptsFilesInAZip() async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, "p.zip", password: "open sesame 1!")
        let listing = try await engine.list(archive)
        // The names can be read, the files cannot.
        #expect(listing.entry("Sample/hello.txt")?.isEncrypted == true)
        #expect(listing.entry("Sample/hello.txt")?.method.contains("AES-256") == true)
        #expect(listing.hasEncryptedEntries)
        #expect(!listing.info.hasEncryptedHeaders)

        await #expect(throws: ArchiveError.passwordRequired) {
            try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("none"), listing: listing))
        }
        await #expect(throws: ArchiveError.wrongPassword) {
            try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("wrong"), listing: listing, password: "nope"))
        }
        // A failed attempt leaves nothing behind.
        #expect(scratch.contents(of: "none").isEmpty)
        #expect(scratch.contents(of: "wrong").isEmpty)

        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("right"), listing: listing, password: "open sesame 1!"))
        #expect(scratch.text("right/Sample/hello.txt") == "hello world\n")
    }

    @Test func aZipPasswordHasToBeAscii() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("a.txt")
        #expect(ArchiveFormat.zip.problem(withPassword: "şifre") != nil)
        #expect(ArchiveFormat.zip.problem(withPassword: "password 1!") == nil)
        #expect(ArchiveFormat.sevenZip.problem(withPassword: "şifre") == nil)
        #expect(ArchiveFormat.tar.problem(withPassword: "any") != nil)
        await #expect(throws: ArchiveError.self) {
            try await engine.compress(CompressionJob(sources: [file], archive: scratch.path("a.zip"), password: "şifre"))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path("a.zip").path))
    }

    @Test func hidesTheNamesInA7z() async throws {
        let scratch = try Scratch()
        var options = CompressionOptions(format: .sevenZip)
        options.encryptFileNames = true
        // A password that is not ASCII and has a space in it: 7z takes any.
        let archive = try await makeArchive(scratch, "p.7z", options: options, password: "şifre ö1")
        #expect(try await engine.list(archive, password: "şifre ö1").paths.contains("Sample/hello.txt"))
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.removeItem(at: scratch.path("Sample"))
        _ = try await makeArchive(scratch, "p.7z", options: options, password: "secret")

        await #expect(throws: ArchiveError.passwordRequired) { try await engine.list(archive) }
        await #expect(throws: ArchiveError.wrongPassword) { try await engine.list(archive, password: "wrong") }
        let listing = try await engine.list(archive, password: "secret")
        #expect(listing.info.hasEncryptedHeaders)
        #expect(listing.paths.contains("Sample/hello.txt"))

        // Changing the archive keeps the names hidden.
        try await engine.delete(["Sample/hello.txt"], from: archive, info: listing.info, password: "secret")
        await #expect(throws: ArchiveError.passwordRequired) { try await engine.list(archive) }
        #expect(try await !engine.list(archive, password: "secret").paths.contains("Sample/hello.txt"))

        let report = try await engine.test(archive, password: "secret")
        #expect(report.isClean)
    }

    // MARK: Changing

    @Test(arguments: ["a.zip", "a.7z", "a.tar", "a.tar.gz"])
    func deletesRenamesAndMoves(name: String) async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, name)
        var listing = try await engine.list(archive)

        try await engine.delete(["Sample/docs/deep", "Sample/run.sh"], from: archive, info: listing.info)
        listing = try await engine.list(archive)
        #expect(!listing.paths.contains("Sample/docs/deep"))
        #expect(!listing.paths.contains("Sample/docs/deep/notes.md"))
        #expect(!listing.paths.contains("Sample/run.sh"))
        #expect(listing.paths.contains("Sample/hello.txt"))

        try await engine.rename([
            (from: "Sample/hello.txt", to: "Sample/greeting.txt"),
            (from: "Sample/docs", to: "Sample/papers"),
            (from: "Sample/link", to: "Sample/moved/there/link"),
        ], in: archive, info: listing.info)
        listing = try await engine.list(archive)
        #expect(listing.paths.contains("Sample/greeting.txt"))
        #expect(listing.paths.contains("Sample/papers/Türkçe şğü İı.txt"))
        #expect(listing.paths.contains("Sample/moved/there/link"))
        #expect(!listing.paths.contains("Sample/hello.txt"))
        #expect(!listing.paths.contains { $0.hasPrefix("Sample/docs") })

        // The archive still holds what it should, bit for bit.
        #expect(try await engine.test(archive).isClean)
        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))
        #expect(scratch.text("out/Sample/greeting.txt") == "hello world\n")
        #expect(scratch.text("out/Sample/papers/日本語.txt") == "こんにちは\n")
    }

    @Test(arguments: ["a.zip", "a.7z", "a.tar", "a.tar.xz"])
    func addsIntoAFolderOfTheArchive(name: String) async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, name)
        let info = try await engine.list(archive).info

        let photo = try scratch.file("elsewhere/photo.jpg", "jpeg")
        let extras = try scratch.folder("elsewhere/extras")
        try scratch.file("elsewhere/extras/one.txt", "1")
        try scratch.file("elsewhere/extras/.DS_Store", "finder")
        var options = CompressionOptions(format: try #require(ArchiveFormat(fileName: name)))
        options.level = .fast
        _ = try await engine.compress(CompressionJob(sources: [photo, extras], archive: archive, folder: "Sample/docs/new place", options: options))

        let listing = try await engine.list(archive)
        #expect(listing.paths.contains("Sample/docs/new place/photo.jpg"))
        #expect(listing.paths.contains("Sample/docs/new place/extras/one.txt"))
        #expect(!listing.paths.contains("Sample/docs/new place/extras/.DS_Store"))
        // What was there is still there.
        #expect(listing.paths.contains("Sample/hello.txt"))
        #expect(listing.info.type == info.type)

        try await engine.createFolder("Sample/brand new/inner", in: archive, info: listing.info)
        let after = try await engine.list(archive)
        #expect(after.entry("Sample/brand new/inner")?.isDirectory == true)
        #expect(try await engine.test(archive).isClean)
    }

    @Test func twoItemsOfTheSameNameBothGoIn() async throws {
        let scratch = try Scratch()
        let first = try scratch.file("one/readme.txt", "first")
        let second = try scratch.file("two/readme.txt", "second")
        let archive = scratch.path("both.zip")
        _ = try await engine.compress(CompressionJob(sources: [first, second], archive: archive))
        #expect(try await engine.list(archive).paths == ["readme 2.txt", "readme.txt"])
    }

    @Test func replacesAndUpdatesFilesThatAreInTheArchive() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("data/note.txt", "old")
        let folder = scratch.path("data")
        let archive = scratch.path("u.zip")
        _ = try await engine.compress(CompressionJob(sources: [folder], archive: archive))

        // Freshen: a newer file replaces its entry, a new file is not added.
        try scratch.file("data/note.txt", "new and longer")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        try scratch.file("data/added.txt", "added")
        var options = CompressionOptions(format: .zip)
        options.updateMode = .freshen
        _ = try await engine.compress(CompressionJob(sources: [folder], archive: archive, options: options))
        var listing = try await engine.list(archive)
        #expect(listing.entry("data/note.txt")?.size == 14)
        #expect(listing.entry("data/added.txt") == nil)

        // Update: now the new file goes in too.
        options.updateMode = .update
        _ = try await engine.compress(CompressionJob(sources: [folder], archive: archive, options: options))
        listing = try await engine.list(archive)
        #expect(listing.entry("data/added.txt") != nil)

        // Synchronize: what is gone from disk goes from the archive.
        try FileManager.default.removeItem(at: scratch.path("data/added.txt"))
        options.updateMode = .synchronize
        _ = try await engine.compress(CompressionJob(sources: [folder], archive: archive, options: options))
        listing = try await engine.list(archive)
        #expect(listing.entry("data/added.txt") == nil)
        #expect(listing.entry("data/note.txt") != nil)
    }

    @Test func writesTheCommentOfAZip() async throws {
        let scratch = try Scratch()
        let archive = try await makeArchive(scratch, "c.zip")
        var listing = try await engine.list(archive)
        #expect(listing.info.comment.isEmpty)

        try await engine.setComment("Made with OpenZip\nİkinci satır", of: archive, info: listing.info)
        listing = try await engine.list(archive)
        #expect(listing.info.comment == "Made with OpenZip\nİkinci satır")
        #expect(try await engine.test(archive).isClean)

        try await engine.setComment("shorter", of: archive, info: listing.info)
        #expect(try await engine.list(archive).info.comment == "shorter")
        try await engine.setComment("", of: archive, info: listing.info)
        #expect(try await engine.list(archive).info.comment.isEmpty)
        #expect(try await engine.list(archive).paths.contains("Sample/hello.txt"))
    }

    @Test func refusesToChangeWhatCanOnlyBeRead() async throws {
        let scratch = try Scratch()
        // A disk image made by the system: 7-Zip reads those and writes none.
        try scratch.sample()
        try scratch.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", "disc.iso", "Sample"])
        let archive = scratch.path("disc.iso")
        let listing = try await engine.list(archive)
        #expect(listing.entries.contains { $0.path.lowercased().contains("hello") })
        if case .readOnly = engine.editability(of: listing.info, at: archive) {} else {
            Issue.record("an ISO image must be read-only")
        }
        await #expect(throws: ArchiveError.self) {
            try await engine.delete([listing.entries[0].path], from: archive, info: listing.info)
        }
    }

    // MARK: Stopping

    @Test func aCancelledOperationStopsAndLeavesNothing() async throws {
        let scratch = try Scratch()
        let big = try scratch.file("big.bin", bytes: 60_000_000)
        let archive = scratch.path("slow.7z")
        let control = OperationControl()
        let started = LockedBox(false)
        var options = CompressionOptions(format: .sevenZip, level: .ultra)
        options.threads = 1

        let task = Task {
            try await engine.compress(CompressionJob(sources: [big], archive: archive, options: options), control: control) { _ in
                started.with { $0 = true }
            }
        }
        while !started.current { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(150))
        control.cancel()
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        // 7-Zip removes the file it was writing when it is interrupted.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(scratch.contents(of: "").filter { $0.contains("slow") }.isEmpty)
    }

    @Test func reportsProgress() async throws {
        let scratch = try Scratch()
        try scratch.file("many/a.bin", bytes: 40_000_000)
        try scratch.file("many/b.bin", bytes: 40_000_000)
        let updates = LockedBox<[OperationProgress]>([])
        var options = CompressionOptions(format: .sevenZip, level: .normal)
        options.threads = 2
        _ = try await engine.compress(CompressionJob(sources: [scratch.path("many")], archive: scratch.path("m.7z"), options: options)) { progress in
            updates.with { $0.append(progress) }
        }
        let seen = updates.current
        #expect(seen.contains { $0.currentItem.hasSuffix("a.bin") })
        #expect(seen.contains { ($0.fraction ?? 0) > 0 })
        #expect(seen.allSatisfy { ($0.fraction ?? 0) <= 1 })
    }
}
