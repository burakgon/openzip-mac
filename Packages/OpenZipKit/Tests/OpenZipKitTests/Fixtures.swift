import Foundation
@testable import OpenZipKit

/// What the tests share: the tools, and folders to work in.
enum Fixtures {
    /// The 7zz that scripts/build-7zz.sh puts into Vendor, or the one OPENZIP_7ZZ names.
    static let sevenZip: URL = {
        if let path = ProcessInfo.processInfo.environment["OPENZIP_7ZZ"] {
            return URL(filePath: path)
        }
        // …/Packages/OpenZipKit/Tests/OpenZipKitTests/Fixtures.swift → the repository.
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Vendor/7zz/7zz")
    }()

    /// RARLAB's rar, if this Mac has it. The tests that write RAR archives need it and
    /// are skipped without.
    static let rar: URL? = {
        if let path = ProcessInfo.processInfo.environment["OPENZIP_RAR"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return Tools.findRar()
    }()

    /// The Windows program that makes a 7z archive extract itself, which the same script
    /// puts next to 7zz.
    static let sfxModule: URL? = {
        let module = sevenZip.deletingLastPathComponent().appending(path: "7z.sfx")
        return FileManager.default.fileExists(atPath: module.path) ? module : nil
    }()

    static var engine: ArchiveEngine {
        ArchiveEngine(tools: Tools(sevenZip: sevenZip, rar: rar, sfxModule: sfxModule))
    }
}

/// A folder for one test, removed when the test is over.
final class Scratch {
    let url: URL

    init() throws {
        // Resolved, because the temporary folder is reached through a link (/var → /private/var)
        // and paths are compared.
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "OpenZipTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> URL {
        url.appending(path: relative)
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "content") throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
        return target
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random, so that it does not compress.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
        try data.write(to: target)
        return target
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// A folder with a bit of everything: nested folders, an empty one, names that are
    /// not ASCII, a link, a script that may be run, and what the Finder leaves behind.
    @discardableResult
    func sample(_ name: String = "Sample") throws -> URL {
        try file("\(name)/hello.txt", "hello world\n")
        try file("\(name)/docs/Türkçe şğü İı.txt", "içerik\n")
        try file("\(name)/docs/日本語.txt", "こんにちは\n")
        try file("\(name)/docs/deep/notes.md", String(repeating: "lorem ipsum dolor sit amet\n", count: 2000))
        try file("\(name)/docs/.DS_Store", "finder")
        try file("\(name)/docs/deep/._notes.md", "resource fork")
        try folder("\(name)/empty")
        let script = try file("\(name)/run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(atPath: path("\(name)/link").path, withDestinationPath: "hello.txt")
        return path(name)
    }

    /// The paths of everything under a folder, relative to it, sorted.
    func contents(of relative: String) -> [String] {
        // Not with FileManager, which hides every name that starts with "._".
        Directory.walk(path(relative)).sorted()
    }

    func text(_ relative: String) -> String? {
        try? String(contentsOf: path(relative), encoding: .utf8)
    }

    /// Runs a program and returns what it printed.
    @discardableResult
    func run(_ executable: String, _ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory.map(path) ?? url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension ArchiveListing {
    /// The stored paths, sorted.
    var paths: [String] {
        entries.map(\.path).sorted()
    }

    func entry(_ path: String) -> ArchiveEntry? {
        entries.first { $0.path == path }
    }
}
