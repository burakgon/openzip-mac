import Foundation

/// Splits what a console program prints into the pieces it meant to show. 7-Zip and RAR
/// draw their progress by printing over what they printed before, with carriage returns
/// and backspaces, so those end a piece just as a new line does.
struct OutputTokenizer {
    private var pending: [UInt8] = []

    mutating func feed(_ data: Data, _ emit: (String) -> Void) {
        for byte in data {
            if byte == 0x0A || byte == 0x0D || byte == 0x08 {
                if !pending.isEmpty {
                    emit(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                }
            } else {
                pending.append(byte)
            }
        }
    }

    /// The piece being printed right now. The newest percentage sits here until the tool
    /// prints over it.
    var unfinished: String {
        String(decoding: pending, as: UTF8.self)
    }
}

/// Follows an operation of 7-Zip (extracting, adding, testing…) through what it prints.
struct OperationOutput {
    private(set) var percent: Int?
    private(set) var item = ""
    private(set) var sawPasswordPrompt = false
    private(set) var fileCount: Int?
    /// Files that failed, from lines such as "ERROR: CRC Failed : docs/a.txt".
    private(set) var failures: [OperationReport.Failure] = []
    /// What was printed about errors and warnings, and the lines that explain them.
    private(set) var messages: [String] = []
    private var tokenizer = OutputTokenizer()
    /// How many of the next lines belong to the message before them: 7-Zip puts the
    /// file an error is about on a line of its own.
    private var explaining = 0

    /// Returns whether the progress changed.
    mutating func feed(_ data: Data) -> Bool {
        var changed = false
        var tokens: [String] = []
        tokenizer.feed(data) { tokens.append($0) }
        for token in tokens where handle(token) { changed = true }
        // A percentage that has not been printed over yet.
        if let progress = Self.progress(in: tokenizer.unfinished.trimmingCharacters(in: .whitespaces)),
           progress.percent != percent {
            percent = progress.percent
            changed = true
        }
        return changed
    }

    private mutating func handle(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return false }

        if let progress = Self.progress(in: token) {
            percent = progress.percent
            if let name = progress.item { item = name }
            return true
        }
        if let name = Self.item(in: token) {
            item = name
            return true
        }

        if token.contains("Enter password") { sawPasswordPrompt = true }
        if token.hasPrefix("Files: "), let count = Int(token.dropFirst(7)) { fileCount = count }

        let upper = token.uppercased()
        if upper.hasPrefix("ERROR") || upper.hasPrefix("WARNING") || upper.hasPrefix("OPEN ERROR")
            || upper.hasPrefix("OPEN WARNING") || upper.hasPrefix("SYSTEM ERROR") || upper.hasPrefix("SCAN WARNING") {
            if let failure = Self.failure(in: token) {
                failures.append(failure)
            }
            note(token)
            explaining = 3
        } else if explaining > 0 {
            // Counters and rulers under the messages say nothing new.
            if !token.hasPrefix("---") && !token.hasPrefix("Sub items Errors") && !token.hasPrefix("Archives with Errors") {
                note(token)
            }
            explaining -= 1
        } else if token.hasPrefix("Break signaled") || token.contains("Can't allocate required memory")
                    || token.hasPrefix("Cannot ") || token.hasPrefix("Can not ") || token.hasPrefix("Duplicate filename") {
            note(token)
            explaining = 2
        }
        return false
    }

    private mutating func note(_ line: String) {
        guard messages.count < 200 else { return }
        messages.append(line)
    }

    /// "16%", "16% 3" and "16% 3 + name": the percentage, with the number of files done and
    /// the file being worked on when 7-Zip prints them on the same line.
    static func progress(in token: String) -> (percent: Int, item: String?)? {
        var value = 0
        var digits = 0
        var index = token.startIndex
        while index < token.endIndex, token[index].isASCII, let digit = token[index].wholeNumberValue {
            value = value * 10 + digit
            digits += 1
            index = token.index(after: index)
        }
        guard (1...3).contains(digits), index < token.endIndex, token[index] == "%" else { return nil }
        var rest = token[token.index(after: index)...].drop { $0 == " " }
        let afterCount = rest.drop { $0.isASCII && $0.isNumber }
        if afterCount.startIndex != rest.startIndex {
            rest = afterCount.drop { $0 == " " }
        }
        return (min(value, 100), rest.isEmpty ? nil : item(in: String(rest)))
    }

    /// "- docs/a.txt": the lines 7-Zip prints per file. The first character says what is
    /// done with it: extract, add, update, test, keep, delete, rename, skip.
    static func item(in token: String) -> String? {
        guard token.utf8.count > 2 else { return nil }
        let first = token[token.startIndex]
        let second = token[token.index(after: token.startIndex)]
        guard second == " ", "+-TU=DR.".contains(first) else { return nil }
        return String(token.dropFirst(2))
    }

    /// "ERROR: CRC Failed : docs/a.txt". Errors of the system ("ERROR: errno=13 : Permission
    /// denied") have the same shape and are not about a file in the archive.
    static func failure(in token: String) -> OperationReport.Failure? {
        guard token.hasPrefix("ERROR: ") else { return nil }
        let body = token.dropFirst(7)
        guard let separator = body.range(of: " : ") else { return nil }
        let reason = String(body[..<separator.lowerBound])
        let path = String(body[separator.upperBound...])
        guard !reason.hasPrefix("errno="), !reason.hasPrefix("/"), !path.isEmpty, !path.hasPrefix("errno=") else { return nil }
        return OperationReport.Failure(path: path, reason: reason)
    }

    /// Everything that was said about what went wrong, as one text.
    var diagnosis: String {
        messages.joined(separator: "\n")
    }
}

/// Reads the technical listing of 7-Zip (`l -slt`), piece by piece as it arrives.
///
/// The listing is a block of "Name = value" lines about the archive between "--" and
/// "----------", and after that one such block per entry, separated by empty lines.
/// Archives can list hundreds of thousands of entries, so the lines are looked at as bytes
/// and only what is kept becomes a string.
struct ListingParser {
    private(set) var info = ArchiveInfo()
    private(set) var entries: [ArchiveEntry] = []
    private(set) var sawPasswordPrompt = false
    /// What was printed outside the listing: the reasons, when an archive does not open.
    private(set) var messages: [String] = []
    /// Whether the description of the archive was reached at all.
    private(set) var foundArchive = false

    private enum State { case preamble, properties, subfile, entries }
    private enum Issue { case errors, warnings }

    private var state = State.preamble
    private var carry: [UInt8] = []
    private var entry: ArchiveEntry?
    private var entryIsFolder = false
    private var issue: Issue?
    private var blocks = 0
    /// The property whose value is being read over several lines, between braces.
    private var multiline: (name: String, lines: [String])?
    /// The last property that had no value on its own line: the one a "{" would continue.
    private var emptyProperty: String?

    mutating func feed(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                guard let found = memchr(base + start, 0x0A, bytes.count - start) else { break }
                let end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                if carry.isEmpty {
                    handle(UnsafeBufferPointer(start: base + start, count: end - start))
                } else {
                    carry.append(contentsOf: UnsafeBufferPointer(start: base + start, count: end - start))
                    let line = carry
                    carry.removeAll(keepingCapacity: true)
                    line.withUnsafeBufferPointer { handle($0) }
                }
                start = end + 1
            }
            if start < bytes.count {
                carry.append(contentsOf: UnsafeBufferPointer(start: base + start, count: bytes.count - start))
            }
        }
    }

    mutating func finish() {
        if !carry.isEmpty {
            let line = carry
            carry.removeAll()
            line.withUnsafeBufferPointer { handle($0) }
        }
        flushEntry()
    }

    // MARK: Lines

    private mutating func handle(_ full: UnsafeBufferPointer<UInt8>) {
        var line = full
        if let last = line.last, last == 0x0D {
            line = UnsafeBufferPointer(rebasing: line.dropLast())
        }

        if multiline != nil {
            if line.count == 1, line[0] == UInt8(ascii: "}") {
                finishMultiline()
            } else {
                multiline?.lines.append(String(decoding: line, as: UTF8.self))
            }
            return
        }
        if line.count == 1, line[0] == UInt8(ascii: "{"), let name = emptyProperty {
            multiline = (name, [])
            emptyProperty = nil
            return
        }
        emptyProperty = nil

        switch state {
        case .preamble:
            if Self.isRule(line, length: 2) {
                beginArchive()
            } else {
                note(line)
            }
        case .properties:
            if Self.isRule(line, length: 10) {
                state = .entries
            } else if Self.isRule(line, length: 4) {
                // What follows describes the one file inside a wrapper, such as the 7z in
                // a split archive. The archive itself is described after the next "--".
                state = .subfile
            } else if Self.isRule(line, length: 2) {
                beginArchive()
            } else {
                handleProperty(line)
            }
        case .subfile:
            if Self.isRule(line, length: 2) { beginArchive() }
        case .entries:
            if line.isEmpty {
                flushEntry()
            } else {
                handleEntryLine(line)
            }
        }
    }

    private mutating func beginArchive() {
        state = .properties
        foundArchive = true
        blocks += 1
        issue = nil
    }

    private mutating func note(_ line: UnsafeBufferPointer<UInt8>) {
        guard !line.isEmpty, messages.count < 100 else { return }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if text.contains("Enter password") { sawPasswordPrompt = true }
        messages.append(text)
    }

    private static func isRule(_ line: UnsafeBufferPointer<UInt8>, length: Int) -> Bool {
        line.count == length && line.allSatisfy { $0 == UInt8(ascii: "-") }
    }

    /// The position of " = " in a line, and where the value starts. A property without a
    /// value is printed as "Name = " and may have lost the space at its end.
    private static func separator(in line: UnsafeBufferPointer<UInt8>) -> (key: Int, value: Int)? {
        let count = line.count
        guard count >= 2 else { return nil }
        var index = 0
        while index + 2 < count {
            if line[index] == 0x20, line[index + 1] == 0x3D, line[index + 2] == 0x20 {
                return (index, index + 3)
            }
            index += 1
        }
        if line[count - 2] == 0x20, line[count - 1] == 0x3D {
            return (count - 2, count)
        }
        return nil
    }

    private static func string(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> String {
        guard start < bytes.count else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self)
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, upTo end: Int, _ name: StaticString) -> Bool {
        guard end == name.utf8CodeUnitCount else { return false }
        return memcmp(bytes.baseAddress!, name.utf8Start, end) == 0
    }

    // MARK: The archive

    private mutating func handleProperty(_ line: UnsafeBufferPointer<UInt8>) {
        guard let position = Self.separator(in: line) else {
            // "ERRORS:" and "WARNINGS:" are headings; the lines under them say what is wrong.
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return }
            if text == "ERRORS:" {
                issue = .errors
            } else if text == "WARNINGS:" {
                issue = .warnings
            } else if issue == .errors {
                info.errors.append(text)
            } else if issue == .warnings {
                info.warnings.append(text)
            }
            return
        }
        issue = nil
        let name = String(decoding: UnsafeBufferPointer(rebasing: line[..<position.key]), as: UTF8.self)
        let value = Self.string(line, from: position.value)
        if value.isEmpty { emptyProperty = name }
        setProperty(name, value)
    }

    private mutating func setProperty(_ name: String, _ value: String) {
        switch name {
        case "Type":
            // A wrapper comes first: "Split" for an archive in numbered pieces.
            if value == "Split" {
                info.isMultiVolume = true
            } else {
                info.type = value
            }
        case "Physical Size":
            if info.physicalSize == nil || blocks == 1 { info.physicalSize = UInt64(value) }
        case "Total Physical Size":
            info.physicalSize = UInt64(value)
        case "Method":
            info.method = value
        case "Solid":
            info.isSolid = value == "+"
        case "Multivolume":
            if value == "+" { info.isMultiVolume = true }
        case "Volumes":
            info.volumeCount = Int(value)
            if let count = info.volumeCount, count > 1 { info.isMultiVolume = true }
        case "Encrypted":
            if value == "+" { info.hasEncryptedHeaders = true }
        case "Comment":
            info.comment = value
        case "Characteristics":
            let words = value.split(separator: " ")
            if words.contains("Lock") { info.isLocked = true }
            if words.contains(where: { $0.hasPrefix("Recovery") }) { info.hasRecoveryRecord = true }
        case "Offset", "Embedded Stub Size":
            if let offset = UInt64(value), offset > 0 { info.isSelfExtracting = true }
        default:
            break
        }
        if name != "Path", !value.isEmpty {
            if let index = info.properties.firstIndex(where: { $0.name == name }) {
                info.properties[index].value = value
            } else {
                info.properties.append(.init(name: name, value: value))
            }
        }
    }

    private mutating func finishMultiline() {
        guard let (name, lines) = multiline else { return }
        multiline = nil
        let value = lines.joined(separator: "\n")
        if entry != nil {
            if name == "Comment" { entry?.comment = value }
        } else {
            setProperty(name, value)
        }
    }

    // MARK: Entries

    private mutating func handleEntryLine(_ line: UnsafeBufferPointer<UInt8>) {
        guard let position = Self.separator(in: line) else {
            // After the last entry: counters, and errors found while reading.
            if entry == nil { note(line) }
            return
        }
        let key = position.key
        let valueStart = position.value
        let value = UnsafeBufferPointer(rebasing: line[min(valueStart, line.count)...])

        if Self.matches(line, upTo: key, "Path") {
            flushEntry()
            entry = ArchiveEntry(path: String(decoding: value, as: UTF8.self))
            entryIsFolder = false
            return
        }
        if entry == nil {
            // Formats that only compress (xz, bzip2) list their one file without a name.
            entry = ArchiveEntry(path: "")
            entryIsFolder = false
        }
        if value.isEmpty {
            if Self.matches(line, upTo: key, "Comment") { emptyProperty = "Comment" }
            return
        }

        if Self.matches(line, upTo: key, "Size") {
            entry?.size = Self.number(value) ?? 0
        } else if Self.matches(line, upTo: key, "Packed Size") {
            entry?.packedSize = Self.number(value)
        } else if Self.matches(line, upTo: key, "Modified") {
            entry?.modified = Self.date(value)
        } else if Self.matches(line, upTo: key, "Created") {
            entry?.created = Self.date(value)
        } else if Self.matches(line, upTo: key, "Folder") {
            if value[0] == UInt8(ascii: "+") { entryIsFolder = true }
        } else if Self.matches(line, upTo: key, "Attributes") || Self.matches(line, upTo: key, "Mode") {
            applyAttributes(String(decoding: value, as: UTF8.self))
        } else if Self.matches(line, upTo: key, "Encrypted") {
            entry?.isEncrypted = value[0] == UInt8(ascii: "+")
        } else if Self.matches(line, upTo: key, "CRC") {
            entry?.crc = Self.hex(value)
        } else if Self.matches(line, upTo: key, "Method") {
            entry?.method = String(decoding: value, as: UTF8.self)
        } else if Self.matches(line, upTo: key, "Symbolic Link") {
            entry?.linkTarget = String(decoding: value, as: UTF8.self)
            entry?.isSymbolicLink = true
        } else if Self.matches(line, upTo: key, "Comment") {
            entry?.comment = String(decoding: value, as: UTF8.self)
        }
    }

    /// "D drwxr-xr-x", "A -rw-r--r--", "D", "RHSA" or just "-rwxr-xr-x": the attributes of
    /// Windows, the permissions of Unix, or both.
    private mutating func applyAttributes(_ text: String) {
        for word in text.split(separator: " ") {
            if word.utf8.count == 10, let first = word.first, "-dlbcps".contains(first) {
                entry?.permissions = String(word)
                if first == "d" { entryIsFolder = true }
                if first == "l" { entry?.isSymbolicLink = true }
            } else if word.contains("D") {
                entryIsFolder = true
            }
        }
    }

    private mutating func flushEntry() {
        guard var finished = entry else { return }
        entry = nil
        finished.isDirectory = entryIsFolder
        entries.append(finished)
    }

    // MARK: Values

    private static func number(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        var result: UInt64 = 0
        for byte in bytes {
            guard byte >= 48, byte <= 57 else { return nil }
            let (product, overflow) = result.multipliedReportingOverflow(by: 10)
            if overflow { return nil }
            result = product &+ UInt64(byte - 48)
        }
        return bytes.isEmpty ? nil : result
    }

    private static func hex(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard bytes.count == 8 else { return nil }
        var result: UInt32 = 0
        for byte in bytes {
            let digit: UInt8
            switch byte {
            case 48...57: digit = byte - 48
            case 65...70: digit = byte - 55
            case 97...102: digit = byte - 87
            default: return nil
            }
            result = result << 4 | UInt32(digit)
        }
        return result
    }

    /// "2026-11-10 21:58:25.7570288", with or without the fraction or the time. 7-Zip
    /// prints the time of the Mac's own time zone.
    static func date(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        func digits(_ from: Int, _ length: Int) -> Int32? {
            guard from + length <= bytes.count else { return nil }
            var result: Int32 = 0
            for index in from..<(from + length) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                result = result * 10 + Int32(byte - 48)
            }
            return result
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2) else { return nil }
        var time = tm()
        time.tm_year = year - 1900
        time.tm_mon = month - 1
        time.tm_mday = day
        time.tm_isdst = -1
        var fraction = 0.0
        if let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) {
            time.tm_hour = hour
            time.tm_min = minute
            time.tm_sec = second
            if bytes.count > 20, bytes[19] == UInt8(ascii: ".") {
                var scale = 0.1
                var index = 20
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
            }
        }
        let seconds = mktime(&time)
        guard seconds != -1 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
