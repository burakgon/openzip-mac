import Foundation
import OpenZipKit

/// Fetches RARLAB's `rar` for people who want to create RAR archives.
///
/// RAR is not open source and may not be shipped inside another program, so OpenZip does
/// not carry it. What it can do is what anyone would do by hand: download the package
/// from rarlab.com, unpack it, and use the `rar` in it. It is RARLAB's trial version, free
/// to try for 40 days, and the settings say so.
enum RarInstaller {
    enum Failure: LocalizedError {
        case notFound
        case badPackage

        var errorDescription: String? {
            switch self {
            case .notFound: "No RAR for this Mac was found on rarlab.com. It can be downloaded there by hand and chosen here."
            case .badPackage: "What was downloaded is not the RAR package that was expected."
            }
        }
    }

    private static let page = URL(string: "https://www.rarlab.com/download.htm")!

    /// Downloads the newest released RAR for this Mac and unpacks it into OpenZip's folder
    /// in Application Support. Returns where the program is.
    static func install() async throws -> URL {
        let (data, _) = try await URLSession.shared.data(for: request(page))
        let packages = RarPackages.packages(listedIn: String(decoding: data, as: UTF8.self), for: .current)
        // The newest that is there and is what it should be. For an Intel Mac the first
        // may be neither: see RarPackages. Anything else that goes wrong, the network
        // for one, ends the attempt.
        var failure = Failure.notFound
        for package in packages {
            guard let url = URL(string: package.path, relativeTo: page) else { continue }
            do {
                return try await install(from: url.absoluteURL)
            } catch let error as Failure {
                failure = error
            }
        }
        throw failure
    }

    private static func install(from url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request(url))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.notFound }

        let work = try WorkDirectory.makeTemporary()
        defer { work.remove() }
        // The system's tar: the package is a plain .tar.gz with one folder, "rar".
        guard run("/usr/bin/tar", ["-xzf", file.path, "-C", work.url.path]) != nil else { throw Failure.badPackage }
        let unpacked = work.url.appending(path: "rar", directoryHint: .isDirectory)
        let program = unpacked.appending(path: "rar")
        guard FileManager.default.isExecutableFile(atPath: program.path), version(of: program) != nil else { throw Failure.badPackage }

        let folder = Tools.managedRarFolder
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: unpacked, to: folder)
        return folder.appending(path: "rar")
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // A plain browser-like name: the site is not served to everything.
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func remove() {
        try? FileManager.default.removeItem(at: Tools.managedRarFolder)
    }

    /// "RAR 7.23". Current versions answer `-iver` with their number; older ones do not
    /// know the switch and print their banner, which starts with it.
    nonisolated static func version(of rar: URL) -> String? {
        guard let output = run(rar.path, ["-iver"], requireSuccess: false) else { return nil }
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("RAR ") {
                return text.split(separator: " ").prefix(2).joined(separator: " ")
            }
            if let first = text.first, first.isNumber, text.allSatisfy({ $0.isNumber || $0 == "." }) {
                return "RAR \(text)"
            }
        }
        return nil
    }

    /// Whether this copy of RAR has a license next to it or in the user's home.
    nonisolated static func isRegistered(_ rar: URL) -> Bool {
        let places = [
            rar.deletingLastPathComponent().appending(path: "rarreg.key"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".rarreg.key"),
            URL(filePath: "/etc/rarreg.key"),
        ]
        return places.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, _ arguments: [String], requireSuccess: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if requireSuccess, process.terminationStatus != 0 { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
