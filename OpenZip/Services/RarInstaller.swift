import Foundation
import OpenZipKit

/// Fetches RARLAB's `rar` for people who want to create RAR archives.
///
/// RAR is not open source and may not be shipped inside another program, so OpenZip does
/// not carry it. What it can do is what anyone would do by hand: download the package
/// from rarlab.com, unpack it, and use the `rar` in it. It is RARLAB's trial version, free
/// to try for 40 days, and the settings say so.
enum RarInstaller {
    struct Release {
        var version: String
        var url: URL
    }

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

    /// The newest released RAR for this Mac's processor, as the download page lists it.
    static func latest() async throws -> Release {
        var request = URLRequest(url: page)
        // A plain browser-like name: the page is not served to everything.
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        // RARLAB has called Apple silicon both "arm" and "arm64".
        #if arch(arm64)
        let architecture = "(?:arm64|arm)"
        #else
        let architecture = "x64"
        #endif
        // "/rar/rarmacos-arm-723.tar.gz". Betas have letters in the number and do not match.
        let pattern = try NSRegularExpression(pattern: "/rar/rarmacos-\(architecture)-(\\d+)\\.tar\\.gz")
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let versions = matches.compactMap { match -> (Int, String)? in
            guard let whole = Range(match.range, in: html), let number = Range(match.range(at: 1), in: html), let value = Int(html[number]) else { return nil }
            return (value, String(html[whole]))
        }
        guard let newest = versions.max(by: { $0.0 < $1.0 }), let url = URL(string: newest.1, relativeTo: page) else {
            throw Failure.notFound
        }
        let digits = String(newest.0)
        return Release(version: "\(digits.dropLast(2)).\(digits.suffix(2))", url: url.absoluteURL)
    }

    /// Downloads and unpacks RAR into OpenZip's folder in Application Support. Returns
    /// where the program is.
    static func install() async throws -> URL {
        let release = try await latest()
        var request = URLRequest(url: release.url)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let (file, _) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }

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
