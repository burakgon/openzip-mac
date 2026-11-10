import Foundation

/// What 7-Zip's benchmark measured: how fast this Mac compresses and decompresses with
/// LZMA, the method of 7z, on data the benchmark makes up.
public struct BenchmarkResult: Sendable, Equatable {
    /// One direction of one pass.
    public struct Side: Sendable, Equatable {
        /// How much data went through in a second, in units of 1024 bytes.
        public var speed: UInt64
        /// How much of one processor core was busy, in percent: 800 is eight cores.
        public var usage: Int
        /// The rating for one fully used core, in MIPS.
        public var ratingPerCore: UInt64
        /// The rating: the work done in a second, in MIPS.
        public var rating: UInt64

        public init(speed: UInt64, usage: Int, ratingPerCore: UInt64, rating: UInt64) {
            self.speed = speed
            self.usage = usage
            self.ratingPerCore = ratingPerCore
            self.rating = rating
        }
    }

    /// One pass: a size of dictionary, tried in both directions.
    public struct Pass: Sendable, Equatable {
        /// The dictionary as a power of two: 24 is 16 MB.
        public var dictionaryBits: Int
        public var compressing: Side
        public var decompressing: Side

        public init(dictionaryBits: Int, compressing: Side, decompressing: Side) {
            self.dictionaryBits = dictionaryBits
            self.compressing = compressing
            self.decompressing = decompressing
        }
    }

    /// The processor as it names itself: "Apple M5 Max 18C18T".
    public var processor = ""
    /// How many threads the benchmark used.
    public var threads: Int?
    public var passes: [Pass] = []
    /// The average of the passes. There once the benchmark is through.
    public var average: Pass?
    /// The rating of the whole: the average of both directions, in MIPS.
    public var totalRating: UInt64?
    /// The usage of the whole, in percent of one core.
    public var totalUsage: Int?

    public init() {}

    public var isComplete: Bool { totalRating != nil }
}

/// Reads what `7zz b` prints, line by line, into a result.
struct BenchmarkParser {
    private(set) var result = BenchmarkResult()
    private var pending = ""
    private var lastLine = ""

    /// Takes more of the output. Returns whether the result has changed.
    mutating func feed(_ data: Data) -> Bool {
        pending += String(decoding: data, as: UTF8.self)
        var changed = false
        while let end = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            if take(line) { changed = true }
        }
        return changed
    }

    private mutating func take(_ line: String) -> Bool {
        defer { if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastLine = line } }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // The processor names itself on the line before the first of the frequencies.
        if trimmed.hasPrefix("1T CPU Freq"), result.processor.isEmpty {
            result.processor = lastLine.trimmingCharacters(in: .whitespaces)
            return true
        }
        if let range = trimmed.range(of: "# Benchmark threads:") {
            result.threads = Int(trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces))
            return true
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let head = String(trimmed[..<colon])
        let numbers = trimmed[trimmed.index(after: colon)...].split(whereSeparator: { $0 == " " || $0 == "|" }).compactMap { UInt64($0) }

        if head == "Tot", numbers.count == 3 {
            result.totalUsage = Int(numbers[0])
            result.totalRating = numbers[2]
            return true
        }
        guard numbers.count == 8, head == "Avr" || Int(head) != nil else { return false }
        let pass = BenchmarkResult.Pass(
            dictionaryBits: Int(head) ?? 0,
            compressing: .init(speed: numbers[0], usage: Int(numbers[1]), ratingPerCore: numbers[2], rating: numbers[3]),
            decompressing: .init(speed: numbers[4], usage: Int(numbers[5]), ratingPerCore: numbers[6], rating: numbers[7])
        )
        if head == "Avr" {
            result.average = pass
        } else {
            result.passes.append(pass)
        }
        return true
    }
}

extension ArchiveEngine {
    /// Runs 7-Zip's benchmark, which takes about half a minute and every core there is.
    ///
    /// `onUpdate` gets the result as far as it is, after each pass, on a background thread.
    public func benchmark(
        control: OperationControl? = nil,
        onUpdate: (@Sendable (BenchmarkResult) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        let parser = LockedBox(BenchmarkParser())
        let text = LockedBox("")
        let codes = try await ToolRunner.run([sevenZip(["b"])], control: control) { _, data in
            text.with { $0 += String(decoding: data, as: UTF8.self) }
            let update: BenchmarkResult? = parser.with { $0.feed(data) ? $0.result : nil }
            if let update { onUpdate?(update) }
        }
        if control?.isCancelled == true { throw ArchiveError.cancelled }
        let result = parser.current.result
        guard codes.last == 0, result.isComplete else {
            throw ArchiveError.failed("The benchmark did not finish: " + (text.current.split(whereSeparator: \.isNewline).last.map(String.init) ?? "7-Zip said nothing"))
        }
        return result
    }
}
