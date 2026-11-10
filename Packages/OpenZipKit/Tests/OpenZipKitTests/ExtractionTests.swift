import Foundation
import Testing
@testable import OpenZipKit

@Suite("Extracting")
struct ExtractionTests {
    let engine = Fixtures.engine

    private func makeZip(_ scratch: Scratch, name: String = "a.zip") async throws -> (URL, ArchiveListing) {
        let sample = try scratch.sample()
        let archive = scratch.path(name)
        var options = CompressionOptions()
        options.format = try #require(ArchiveFormat(fileName: name))
        _ = try await engine.compress(CompressionJob(sources: [sample], archive: archive, options: options))
        try FileManager.default.removeItem(at: sample)
        return (archive, try await engine.list(archive))
    }

    @Test(arguments: ["a.zip", "a.7z", "a.tar", "a.tar.gz", "a.tar.bz2", "a.tar.xz"])
    func bringsBackWhatWasPacked(name: String) async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch, name: name)
        let result = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))

        #expect(result.report.isClean)
        #expect(result.items == [scratch.path("out/Sample")])
        #expect(scratch.contents(of: "out") == [
            "Sample", "Sample/docs", "Sample/docs/Türkçe şğü İı.txt", "Sample/docs/deep",
            "Sample/docs/deep/notes.md", "Sample/docs/日本語.txt", "Sample/empty", "Sample/hello.txt",
            "Sample/link", "Sample/run.sh",
        ].sorted())
        #expect(scratch.text("out/Sample/docs/Türkçe şğü İı.txt") == "içerik\n")

        // The link is a link again, and the script may still be run.
        let files = FileManager.default
        #expect(try files.destinationOfSymbolicLink(atPath: scratch.path("out/Sample/link").path) == "hello.txt")
        #expect(files.isExecutableFile(atPath: scratch.path("out/Sample/run.sh").path))
        // Nothing of the work in progress is left next to the result.
        #expect(try files.contentsOfDirectory(atPath: scratch.url.path).sorted() == [name, "out"])
    }

    @Test func extractsASelectionRelativeToItself() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        var job = ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing)
        job.items = [.init(path: "Sample/docs/deep"), .init(path: "Sample/hello.txt")]
        let result = try await engine.extract(job)

        #expect(Set(result.items) == [scratch.path("out/deep"), scratch.path("out/hello.txt")])
        #expect(scratch.contents(of: "out") == ["deep", "deep/notes.md", "hello.txt"])
    }

    @Test func extractsWithoutFolders() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        var job = ExtractionJob(archive: archive, destination: scratch.path("flat"), listing: listing)
        job.items = [.init(path: "Sample/docs")]
        job.flatten = true
        _ = try await engine.extract(job)
        #expect(scratch.contents(of: "flat").contains("notes.md"))
        #expect(scratch.contents(of: "flat").contains("日本語.txt"))
    }

    // MARK: Folders

    @Test func oneItemAtTheTopNeedsNoFolder() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        var job = ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing)
        job.folderPolicy = .automatic("a")
        let result = try await engine.extract(job)
        #expect(result.container == scratch.path("out"))
        #expect(result.items == [scratch.path("out/Sample")])
    }

    @Test func severalItemsAtTheTopGetAFolder() async throws {
        let scratch = try Scratch()
        let one = try scratch.file("one.txt", "1")
        let two = try scratch.file("two.txt", "2")
        let archive = scratch.path("Loose Files.zip")
        _ = try await engine.compress(CompressionJob(sources: [one, two], archive: archive))

        var job = ExtractionJob(archive: archive, destination: scratch.path("out"))
        job.folderPolicy = .automatic(FileNaming.archiveBaseName(archive.lastPathComponent))
        job.conflictPolicy = .keepBoth
        var result = try await engine.extract(job)
        #expect(result.container == scratch.path("out/Loose Files"))
        #expect(scratch.contents(of: "out") == ["Loose Files", "Loose Files/one.txt", "Loose Files/two.txt"])

        // Again: a second folder, the way the Finder counts, not a mix with the first.
        result = try await engine.extract(job)
        #expect(result.container == scratch.path("out/Loose Files 2"))

        job.folderPolicy = .always("Chosen")
        result = try await engine.extract(job)
        #expect(scratch.contents(of: "out/Chosen") == ["one.txt", "two.txt"])
    }

    // MARK: What is there already

    @Test func asksAboutEveryFileThatExists() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        try scratch.file("out/Sample/hello.txt", "mine")
        try scratch.file("out/Sample/run.sh", "mine too")
        try scratch.file("out/Sample/untouched.txt", "stays")

        let asked = LockedBox<[String]>([])
        var job = ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing)
        job.conflictPolicy = .ask
        let result = try await engine.extract(job, resolver: { conflict in
            asked.with { $0.append(conflict.existing.lastPathComponent) }
            return ConflictDecision(conflict.existing.lastPathComponent == "hello.txt" ? .replace : .skip)
        })

        #expect(asked.current.sorted() == ["hello.txt", "run.sh"])
        #expect(result.skipped == 1)
        #expect(scratch.text("out/Sample/hello.txt") == "hello world\n")
        #expect(scratch.text("out/Sample/run.sh") == "mine too")
        // Folders are merged: what was in them and is not in the archive stays.
        #expect(scratch.text("out/Sample/untouched.txt") == "stays")
        #expect(scratch.text("out/Sample/docs/deep/notes.md") != nil)
    }

    @Test func oneAnswerCanStandForAll() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        try scratch.file("out/Sample/hello.txt", "mine")
        try scratch.file("out/Sample/run.sh", "mine too")

        let questions = LockedBox(0)
        var job = ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing)
        job.conflictPolicy = .ask
        _ = try await engine.extract(job, resolver: { _ in
            questions.with { $0 += 1 }
            return ConflictDecision(.keepBoth, applyToAll: true)
        })
        #expect(questions.current == 1)
        #expect(scratch.text("out/Sample/hello.txt") == "mine")
        #expect(scratch.text("out/Sample/hello 2.txt") == "hello world\n")
        #expect(scratch.text("out/Sample/run 2.sh") != nil)
    }

    @Test(arguments: [ConflictPolicy.replace, .skip, .keepBoth])
    func followsThePolicyWithoutAsking(policy: ConflictPolicy) async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        try scratch.file("out/Sample/hello.txt", "mine")
        var job = ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing)
        job.conflictPolicy = policy
        job.items = [.init(path: "Sample/hello.txt")]
        job.destination = scratch.path("out/Sample")
        _ = try await engine.extract(job, resolver: { _ in
            Issue.record("a policy was given: nothing should be asked")
            return ConflictDecision(.stop)
        })
        switch policy {
        case .replace:
            #expect(scratch.text("out/Sample/hello.txt") == "hello world\n")
        case .skip:
            #expect(scratch.text("out/Sample/hello.txt") == "mine")
            #expect(scratch.text("out/Sample/hello 2.txt") == nil)
        case .keepBoth:
            #expect(scratch.text("out/Sample/hello.txt") == "mine")
            #expect(scratch.text("out/Sample/hello 2.txt") == "hello world\n")
        case .ask:
            break
        }
    }

    // MARK: What a Mac expects

    @Test func passesTheQuarantineOn() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        // As a browser marks a download.
        let mark = Data("0083;6551a2c0;Safari;F1D2A3B4-0000-4000-8000-123456789ABC".utf8)
        Quarantine.apply(mark, to: archive)
        #expect(Quarantine.mark(of: archive) == mark)

        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))
        #expect(Quarantine.mark(of: scratch.path("out/Sample")) == mark)
        #expect(Quarantine.mark(of: scratch.path("out/Sample/run.sh")) == mark)
        #expect(Quarantine.mark(of: scratch.path("out/Sample/docs/deep/notes.md")) == mark)

        // And not when the archive has none.
        var job = ExtractionJob(archive: archive, destination: scratch.path("plain"), listing: listing)
        job.keepQuarantine = false
        _ = try await engine.extract(job)
        #expect(Quarantine.mark(of: scratch.path("plain/Sample/run.sh")) == nil)
    }

    @Test func foldsTheFindersResourceForksBackIn() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("Tagged/note.txt", "tagged")
        try scratch.file("Tagged/plain.txt", "plain")
        // An extended attribute, as a Finder tag or a "where from" would be.
        let value = Data("kept across the archive".utf8)
        _ = value.withUnsafeBytes { setxattr(file.path, "com.example.openzip.test", $0.baseAddress, $0.count, 0, 0) }
        // The Finder's own way of making a zip: attributes go into a __MACOSX folder.
        try scratch.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "Tagged", "finder.zip"])
        try FileManager.default.removeItem(at: scratch.path("Tagged"))

        let archive = scratch.path("finder.zip")
        let listing = try await engine.list(archive)
        #expect(listing.paths.contains("__MACOSX/Tagged/._note.txt"))

        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))
        #expect(scratch.contents(of: "out") == ["Tagged", "Tagged/note.txt", "Tagged/plain.txt"])
        #expect(xattr(of: scratch.path("out/Tagged/note.txt"), "com.example.openzip.test") == value)

        // A single file takes its attributes along too.
        var job = ExtractionJob(archive: archive, destination: scratch.path("one"), listing: listing)
        job.items = [.init(path: "Tagged/note.txt")]
        _ = try await engine.extract(job)
        #expect(scratch.contents(of: "one") == ["note.txt"])
        #expect(xattr(of: scratch.path("one/note.txt"), "com.example.openzip.test") == value)

        // Unless they are not wanted.
        job.destination = scratch.path("raw")
        job.items = nil
        job.restoreMacMetadata = false
        _ = try await engine.extract(job)
        #expect(scratch.contents(of: "raw").contains("__MACOSX/Tagged/._note.txt"))
    }

    @Test func foldsTarsResourceForksBackIn() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("Tagged/note.txt", "tagged")
        let value = Data("from a tar".utf8)
        _ = value.withUnsafeBytes { setxattr(file.path, "com.example.openzip.test", $0.baseAddress, $0.count, 0, 0) }
        try scratch.run("/usr/bin/tar", ["-czf", "mac.tar.gz", "Tagged"])
        try FileManager.default.removeItem(at: scratch.path("Tagged"))

        let archive = scratch.path("mac.tar.gz")
        let listing = try await engine.list(archive)
        #expect(listing.paths.contains("Tagged/._note.txt"))
        _ = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: listing))
        #expect(scratch.contents(of: "out") == ["Tagged", "Tagged/note.txt"])
        #expect(xattr(of: scratch.path("out/Tagged/note.txt"), "com.example.openzip.test") == value)
    }

    private func xattr(of url: URL, _ name: String) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data : nil
    }

    // MARK: Archives that mean harm, or have come to it

    @Test func nothingIsWrittenOutsideTheDestination() async throws {
        let scratch = try Scratch()
        // An archive whose entries try to climb out of the folder they are extracted to.
        let script = """
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1], 'w')
        z.writestr('../../escaped.txt', 'out')
        z.writestr('/tmp/openzip-absolute-\(UUID().uuidString).txt', 'out')
        z.writestr('fine/../../sneaky.txt', 'out')
        z.writestr('good.txt', 'in')
        z.close()
        """
        try scratch.file("make.py", script)
        try scratch.run("/usr/bin/python3", ["-I", "make.py", "evil.zip"])
        try scratch.folder("deep/down/out")

        let archive = scratch.path("evil.zip")
        let listing = try await engine.list(archive)
        _ = try? await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("deep/down/out"), listing: listing))

        #expect(scratch.text("deep/down/out/good.txt") == "in")
        // Whatever became of the others, they are inside the destination.
        let outside = scratch.contents(of: "").filter { !$0.hasPrefix("deep/down/out") && $0.hasSuffix(".txt") }
        #expect(outside.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.deletingLastPathComponent().appending(path: "escaped.txt").path))
    }

    @Test func aLinkCannotLeadAnExtractionOutside() async throws {
        let scratch = try Scratch()
        try scratch.folder("target")
        // A link to a folder outside, and then a file "through" that link.
        let script = """
        import zipfile, sys, stat
        z = zipfile.ZipFile(sys.argv[1], 'w')
        link = zipfile.ZipInfo('way')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        z.writestr(link, sys.argv[2])
        z.writestr('way/planted.txt', 'planted')
        z.close()
        """
        try scratch.file("make.py", script)
        try scratch.run("/usr/bin/python3", ["-I", "make.py", "link.zip", scratch.path("target").path])
        let archive = scratch.path("link.zip")
        _ = try? await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out")))
        #expect(scratch.contents(of: "target").isEmpty)
    }

    @Test func testingFindsTheDamagedFile() async throws {
        let scratch = try Scratch()
        try scratch.file("data/good.txt", "good")
        try scratch.file("data/victim.bin", bytes: 400_000)
        let archive = scratch.path("d.zip")
        _ = try await engine.compress(CompressionJob(sources: [scratch.path("data")], archive: archive, options: CompressionOptions(format: .zip, level: .store)))
        #expect(try await engine.test(archive).isClean)

        // Flip some bytes in the middle of the stored file.
        var data = try Data(contentsOf: archive)
        for index in 200_000..<200_016 { data[index] ^= 0xFF }
        try data.write(to: archive)

        let report = try await engine.test(archive)
        #expect(report.failures.map(\.path) == ["data/victim.bin"])

        // Extracting gives what is intact and says what is not. The broken file is not kept.
        let result = try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out")))
        #expect(result.report.failures.map(\.path) == ["data/victim.bin"])
        #expect(scratch.contents(of: "out") == ["data", "data/good.txt"])

        var keeping = ExtractionJob(archive: archive, destination: scratch.path("kept"))
        keeping.keepBrokenFiles = true
        _ = try await engine.extract(keeping)
        #expect(scratch.contents(of: "kept").contains("data/victim.bin"))
    }

    @Test func extractsOneFileForALook() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch, name: "a.7z")
        let file = try await engine.extractFile(
            "Sample/docs/日本語.txt", from: archive, listing: listing, password: nil, into: scratch.path("preview")
        )
        #expect(file == scratch.path("preview/日本語.txt"))
        #expect(scratch.text("preview/日本語.txt") == "こんにちは\n")
    }

    @Test func refusesWhenTheDiskIsTooSmall() async throws {
        let scratch = try Scratch()
        let (archive, listing) = try await makeZip(scratch)
        // An archive that claims to hold more than any disk.
        var huge = listing
        huge.entries[0].size = UInt64.max / 4
        await #expect(throws: ArchiveError.notEnoughSpace) {
            try await engine.extract(ExtractionJob(archive: archive, destination: scratch.path("out"), listing: huge))
        }
    }
}
