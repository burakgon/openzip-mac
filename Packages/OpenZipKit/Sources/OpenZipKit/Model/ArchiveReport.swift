import Foundation

/// What is in an archive as a text to keep or to pass on: a table for a spreadsheet, or
/// a list to read. WinRAR calls this generating a report.
public enum ArchiveReport {
    public enum Format: String, CaseIterable, Sendable {
        /// Comma-separated values, one line per entry, with every column there is.
        case csv
        /// A list for reading, in columns of fixed width.
        case text

        public var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .text: "txt"
            }
        }
    }

    /// Writes the report. The entries are in the order of their paths, and times are
    /// written as the given time zone has them.
    public static func make(of listing: ArchiveListing, named name: String, as format: Format, timeZone: TimeZone = .current) -> String {
        let entries = listing.entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = timeZone
        switch format {
        case .csv:
            dates.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return csv(entries, dates: dates)
        case .text:
            dates.dateFormat = "yyyy-MM-dd HH:mm"
            return text(entries, info: listing.info, name: name, dates: dates)
        }
    }

    private static func kind(of entry: ArchiveEntry) -> String {
        entry.isDirectory ? "folder" : (entry.isSymbolicLink ? "link" : "file")
    }

    // MARK: CSV

    private static func csv(_ entries: [ArchiveEntry], dates: DateFormatter) -> String {
        var lines = ["Path,Kind,Size,Packed,Modified,CRC32,Method,Encrypted,Permissions,Link"]
        for entry in entries {
            let fields = [
                entry.path,
                kind(of: entry),
                entry.isDirectory ? "" : String(entry.size),
                entry.isDirectory ? "" : (entry.packedSize.map { String($0) } ?? ""),
                entry.modified.map(dates.string(from:)) ?? "",
                entry.crc.map { String(format: "%08X", $0) } ?? "",
                entry.method,
                entry.isEncrypted ? "yes" : "",
                entry.permissions,
                entry.linkTarget,
            ]
            lines.append(fields.map(quoted).joined(separator: ","))
        }
        // The line ends that RFC 4180 asks for, and a last one after the last line.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A field as CSV wants it: in quotes when it holds a comma, a quote or a line end,
    /// with the quotes inside doubled.
    private static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Text

    private static func text(_ entries: [ArchiveEntry], info: ArchiveInfo, name: String, dates: DateFormatter) -> String {
        let files = entries.filter { !$0.isDirectory }
        let folders = entries.count - files.count
        let size = files.reduce(UInt64(0)) { $0.addingReportingOverflow($1.size).partialValue }
        var summary = "\(info.displayType), \(files.count) \(files.count == 1 ? "file" : "files")"
        if folders > 0 { summary += ", \(folders) \(folders == 1 ? "folder" : "folders")" }
        summary += ", \(size) bytes"
        if let packed = info.physicalSize { summary += " in \(packed)" }

        var lines = [name, summary, ""]
        lines.append(row("Modified", "Size", "Packed", "Name"))
        for entry in entries {
            lines.append(row(
                entry.modified.map(dates.string(from:)) ?? "",
                entry.isDirectory ? "" : String(entry.size),
                entry.isDirectory ? "" : (entry.packedSize.map { String($0) } ?? ""),
                entry.path + (entry.isDirectory ? "/" : "") + (entry.linkTarget.isEmpty ? "" : " -> \(entry.linkTarget)")
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func row(_ modified: String, _ size: String, _ packed: String, _ name: String) -> String {
        modified.padding(toLength: 16, withPad: " ", startingAt: 0) + "  " + right(size, 12) + "  " + right(packed, 12) + "  " + name
    }

    private static func right(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
}
