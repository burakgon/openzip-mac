import Foundation

/// RARLAB's packages of RAR for the Mac, as its download page names them.
///
/// The page links one package for each version and processor, such as
/// "/rar/rarmacos-arm-723.tar.gz" for RAR 7.23 on Apple silicon. That processor has been
/// called both "arm" and "arm64" in these names, and an Intel Mac is "x64". A beta carries
/// a letter in its number, "730b2", and is left alone.
public enum RarPackages {
    public enum Processor: Sendable {
        case appleSilicon
        case intel

        /// The one this program was built for, and so runs on.
        public static var current: Processor {
            #if arch(arm64)
            .appleSilicon
            #else
            .intel
            #endif
        }
    }

    public struct Package: Equatable, Sendable {
        /// "7.23"
        public var version: String
        /// Where it is on RARLAB's server: "/rar/rarmacos-arm-723.tar.gz".
        public var path: String

        public init(version: String, path: String) {
            self.version = version
            self.path = path
        }
    }

    /// The last version that RARLAB built for Intel Macs.
    static let lastForIntel = 723

    /// The packages worth trying for a processor, the newest first.
    ///
    /// For Apple silicon these are the ones on the page. For Intel the page is of little
    /// help: RARLAB stopped listing those packages while it still published them next to
    /// the others, and has built none since 7.23. So the versions on the page are tried
    /// under the name an Intel package would have, and 7.23 after them. Whoever downloads
    /// has to be ready for the first of them not to be there.
    public static func packages(listedIn page: String, for processor: Processor) -> [Package] {
        guard let pattern = try? NSRegularExpression(pattern: #"/rar/rarmacos-(arm64|arm|x64)-(\d+)\.tar\.gz"#) else { return [] }
        var own: [Int: String] = [:]
        var forTheOther = Set<Int>()
        for match in pattern.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            guard let whole = Range(match.range, in: page), let name = Range(match.range(at: 1), in: page),
                  let digits = Range(match.range(at: 2), in: page), let number = Int(page[digits])
            else { continue }
            if (page[name] == "x64") == (processor == .intel) {
                own[number] = String(page[whole])
            } else {
                forTheOther.insert(number)
            }
        }
        if processor == .intel {
            for number in forTheOther.union([lastForIntel]) where own[number] == nil {
                own[number] = "/rar/rarmacos-x64-\(number).tar.gz"
            }
        }
        return own.sorted { $0.key > $1.key }.map { Package(version: version(from: $0.key), path: $0.value) }
    }

    /// 723 is RAR 7.23: the last two digits are what follows the point.
    static func version(from number: Int) -> String {
        let digits = String(number)
        guard digits.count > 2 else { return digits }
        return "\(digits.dropLast(2)).\(digits.suffix(2))"
    }
}
