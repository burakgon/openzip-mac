import Foundation

/// The entries of an archive as folders and files.
///
/// An archive is a flat list of paths. Folders may be listed or only implied by the paths
/// of the files in them, paths may start with "./", and the same folder may come up
/// thousands of entries apart. The tree is what a window shows: every folder exists once,
/// knows what is in it and how much that adds up to.
public struct ArchiveTree: Sendable {
    public struct Node: Sendable, Identifiable {
        /// The position of the node in `nodes`. The root is 0.
        public let id: Int
        public var name: String
        /// -1 for the root.
        public var parent: Int
        public var children: [Int] = []
        public var isDirectory: Bool
        /// The index of the node's entry in the listing. nil for the root and for folders
        /// that no entry of their own stands for.
        public var entry: Int?
        /// The path to give 7-Zip for this node: that of its entry, or for a folder
        /// without one, the part of its files' paths that leads to it.
        public var path: String
        /// For a file its size, for a folder that of everything in it.
        public var size: UInt64 = 0
        public var packedSize: UInt64 = 0
        /// How many files and folders are in a folder, at any depth.
        public var fileCount = 0
        public var folderCount = 0
        public var modified: Date?
        public var isEncrypted = false
        public var isSymbolicLink = false

        /// A file that macOS made and nobody packed on purpose.
        public var isMacMetadata: Bool {
            FileNaming.isMacMetadata(name: name)
        }
    }

    public private(set) var nodes: [Node]

    public static let rootID = 0

    public var root: Node { nodes[0] }

    public init(entries: [ArchiveEntry] = []) {
        var nodes = [Node(id: 0, name: "", parent: -1, isDirectory: true, entry: nil, path: "")]
        nodes.reserveCapacity(entries.count + 16)
        // Folders by their tidy path: "docs/img" for an entry stored as "./docs/img/".
        var folders: [String: Int] = ["": 0]
        // Entries of one folder tend to follow each other: remembering the last folder
        // saves looking it up for every file.
        var lastFolderPath: Substring = ""
        var lastFolder = 0
        var lastIsValid = false

        func makeNode(_ name: Substring, parent: Int, isDirectory: Bool, entry: Int?, path: String) -> Int {
            let id = nodes.count
            nodes.append(Node(id: id, name: String(name), parent: parent, isDirectory: isDirectory, entry: entry, path: path))
            nodes[parent].children.append(id)
            return id
        }

        /// The node of a folder given by the parts of its path, creating what is missing.
        func folder(for parts: ArraySlice<(name: Substring, end: String.Index)>, of raw: String) -> Int {
            var parent = 0
            var tidy = ""
            for part in parts {
                if !tidy.isEmpty { tidy.append("/") }
                tidy.append(contentsOf: part.name)
                if let existing = folders[tidy] {
                    parent = existing
                } else {
                    parent = makeNode(part.name, parent: parent, isDirectory: true, entry: nil, path: String(raw[..<part.end]))
                    folders[tidy] = parent
                }
            }
            return parent
        }

        for (index, entry) in entries.enumerated() {
            let raw = entry.path
            if !entry.isDirectory {
                let folderPath: Substring
                let name: Substring
                if let slash = raw.lastIndex(of: "/") {
                    folderPath = raw[..<slash]
                    name = raw[raw.index(after: slash)...]
                } else {
                    folderPath = ""
                    name = raw[...]
                }
                guard !name.isEmpty else { continue }
                if !lastIsValid || folderPath != lastFolderPath {
                    lastFolder = folder(for: Self.parts(of: raw).dropLast(), of: raw)
                    lastFolderPath = folderPath
                    lastIsValid = true
                }
                let id = makeNode(name, parent: lastFolder, isDirectory: false, entry: index, path: raw)
                nodes[id].size = entry.size
                nodes[id].packedSize = entry.packedSize ?? 0
                nodes[id].modified = entry.modified
                nodes[id].isEncrypted = entry.isEncrypted
                nodes[id].isSymbolicLink = entry.isSymbolicLink
            } else {
                let parts = Self.parts(of: raw)
                guard !parts.isEmpty else { continue }
                let id = folder(for: parts[...], of: raw)
                // The folder may have been made for a file inside it that was listed first.
                nodes[id].entry = index
                nodes[id].path = raw
                nodes[id].modified = entry.modified
            }
        }

        // Children always come after their parents, so going backwards adds everything up.
        var index = nodes.count - 1
        while index > 0 {
            let node = nodes[index]
            // A listing can claim sizes that do not add up to anything a number can hold.
            nodes[node.parent].size = nodes[node.parent].size.addingSaturated(node.size)
            nodes[node.parent].packedSize = nodes[node.parent].packedSize.addingSaturated(node.packedSize)
            if node.isDirectory {
                nodes[node.parent].fileCount += node.fileCount
                nodes[node.parent].folderCount += node.folderCount + 1
            } else {
                nodes[node.parent].fileCount += 1
            }
            index -= 1
        }
        self.nodes = nodes
    }

    /// The parts of a stored path that name something: without the empty ones a leading
    /// or doubled slash makes, and without ".". With each part, where it ends in the path.
    private static func parts(of path: String) -> [(name: Substring, end: String.Index)] {
        var result: [(Substring, String.Index)] = []
        var start = path.startIndex
        var index = path.startIndex
        while true {
            if index == path.endIndex || path[index] == "/" {
                let part = path[start..<index]
                if !part.isEmpty, part != "." { result.append((part, index)) }
                if index == path.endIndex { break }
                start = path.index(after: index)
            }
            index = path.index(after: index)
        }
        return result
    }

    // MARK: Finding

    public subscript(id: Int) -> Node {
        nodes[id]
    }

    public func contains(_ id: Int) -> Bool {
        nodes.indices.contains(id)
    }

    /// The path of a node as it is shown: its names from the top, joined with slashes.
    public func displayPath(of id: Int) -> String {
        var names: [String] = []
        var current = id
        while current > 0 {
            names.append(nodes[current].name)
            current = nodes[current].parent
        }
        return names.reversed().joined(separator: "/")
    }

    /// The folders from the root down to the node, the node included.
    public func ancestors(of id: Int) -> [Int] {
        var result: [Int] = []
        var current = id
        while current >= 0 {
            result.append(current)
            current = nodes[current].parent
        }
        return result.reversed()
    }

    /// The node with this display path, if there is one. Folders are found before files.
    public func node(atDisplayPath path: String) -> Int? {
        var current = 0
        for part in path.split(separator: "/") {
            let children = nodes[current].children
            guard let next = children.first(where: { nodes[$0].name == part && nodes[$0].isDirectory })
                    ?? children.first(where: { nodes[$0].name == part })
            else { return nil }
            current = next
        }
        return current
    }

    /// Whether `ancestor` is the node itself or one of the folders it is in.
    public func isNode(_ id: Int, inside ancestor: Int) -> Bool {
        var current = id
        while current >= 0 {
            if current == ancestor { return true }
            current = nodes[current].parent
        }
        return false
    }

    /// Everything in a folder, at any depth.
    public func descendants(of id: Int, includeFolders: Bool = true) -> [Int] {
        var result: [Int] = []
        var stack = nodes[id].children.reversed() as [Int]
        while let current = stack.popLast() {
            let node = nodes[current]
            if node.isDirectory {
                if includeFolders { result.append(current) }
                stack.append(contentsOf: node.children.reversed())
            } else {
                result.append(current)
            }
        }
        return result
    }

    /// The nodes in a folder whose name fits the query, at any depth. A query with * or ?
    /// is a pattern for the whole name; any other is looked for inside the name, without
    /// regard to case and accents.
    public func search(_ query: String, in folder: Int = 0, includeMacMetadata: Bool = true) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let isPattern = query.contains("*") || query.contains("?")
        var result: [Int] = []
        var stack = nodes[folder].children.reversed() as [Int]
        while let current = stack.popLast() {
            let node = nodes[current]
            if !includeMacMetadata, node.isMacMetadata { continue }
            let matches = isPattern
                ? Wildcard.matches(node.name, pattern: query)
                : node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if matches { result.append(current) }
            if node.isDirectory { stack.append(contentsOf: node.children.reversed()) }
        }
        return result
    }

    // MARK: Order

    public enum SortKey: String, Sendable, CaseIterable, Codable {
        case name
        case size
        case packedSize
        case modified
        case kind
    }

    /// Puts nodes in order. Folders come first, as in the Finder's list of an archive's
    /// worth of files; names are compared the way the Finder does, "File 2" before "File 10".
    public func sorted(_ ids: [Int], by key: SortKey, ascending: Bool, foldersFirst: Bool = true) -> [Int] {
        func compareNames(_ a: Node, _ b: Node) -> ComparisonResult {
            a.name.localizedStandardCompare(b.name)
        }
        func fileExtension(_ node: Node) -> String {
            node.isDirectory ? "" : (node.name as NSString).pathExtension.lowercased()
        }
        return ids.sorted { first, second in
            let a = nodes[first], b = nodes[second]
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch key {
            case .name:
                order = compareNames(a, b)
            case .size:
                order = a.size == b.size ? compareNames(a, b) : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .packedSize:
                order = a.packedSize == b.packedSize ? compareNames(a, b) : (a.packedSize < b.packedSize ? .orderedAscending : .orderedDescending)
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                order = x == y ? compareNames(a, b) : (x < y ? .orderedAscending : .orderedDescending)
            case .kind:
                let x = fileExtension(a), y = fileExtension(b)
                order = x == y ? compareNames(a, b) : (x < y ? .orderedAscending : .orderedDescending)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

extension UInt64 {
    /// The sum, or the largest number there is when the sum would be larger still.
    func addingSaturated(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
