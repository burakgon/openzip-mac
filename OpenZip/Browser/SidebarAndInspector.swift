import CryptoKit
import OpenZipKit
import SwiftUI

/// The folders of the archive, as a tree.
struct SidebarView: View {
    let session: ArchiveSession
    @State private var expanded: Set<Int> = []

    var body: some View {
        List(selection: selection) {
            Section("Archive") {
                Label(session.title, systemImage: "doc.zipper")
                    .tag(ArchiveTree.rootID)
                if session.isReady {
                    FolderRows(session: session, parent: ArchiveTree.rootID, expanded: $expanded)
                }
            }
        }
        .onChange(of: session.folder, initial: true) { _, folder in
            // The tree opens down to where the window is.
            guard session.isReady else { return }
            expanded.formUnion(session.tree.ancestors(of: folder).dropLast())
        }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { session.folder },
            set: { id in
                if let id { session.navigate(to: id) }
            }
        )
    }
}

private struct FolderRows: View {
    let session: ArchiveSession
    let parent: Int
    @Binding var expanded: Set<Int>

    var body: some View {
        ForEach(session.folders(in: parent), id: \.self) { id in
            if session.tree[id].folderCount == 0 {
                label(id)
            } else {
                DisclosureGroup(isExpanded: isExpanded(id)) {
                    // Only what is open is built: an archive can have more folders than
                    // anyone will ever look into.
                    FolderRows(session: session, parent: id, expanded: $expanded)
                } label: {
                    label(id)
                }
            }
        }
    }

    private func label(_ id: Int) -> some View {
        Label(session.tree[id].name, systemImage: "folder")
            .tag(id)
    }

    private func isExpanded(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                if open { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

/// What is known about the archive and about what is selected in it.
struct InspectorView: View {
    let session: ArchiveSession
    @State private var checksum: String?
    @State private var isHashing = false

    var body: some View {
        Form {
            if session.isReady {
                selectionSection
                archiveSection
                if !session.listing.info.comment.isEmpty || session.listing.info.format?.supportsComment == true {
                    commentSection
                }
                detailsSection
            }
        }
        .formStyle(.grouped)
        .onChange(of: session.url) { checksum = nil }
    }

    // MARK: The selection

    @ViewBuilder private var selectionSection: some View {
        let chosen = session.selectedRows
        if chosen.count == 1, let id = chosen.first {
            let node = session.tree[id]
            let entry = node.entry.map { session.listing.entries[$0] }
            Section {
                HStack(spacing: 10) {
                    Image(nsImage: FileIcons.icon(for: node.name, isDirectory: node.isDirectory))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.headline)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Text(FileIcons.kind(for: node.name, isDirectory: node.isDirectory, isLink: node.isSymbolicLink))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if node.isDirectory {
                    LabeledContent("Contains", value: Formatting.contents(files: node.fileCount, folders: node.folderCount))
                }
                LabeledContent("Size", value: Formatting.bytes(node.size))
                if node.packedSize > 0 {
                    LabeledContent("Packed", value: "\(Formatting.bytes(node.packedSize)) (\(Formatting.ratio(packed: node.packedSize, size: node.size)))")
                }
                if let modified = node.modified {
                    LabeledContent("Modified", value: Formatting.date(modified))
                }
                if let entry {
                    if let created = entry.created { LabeledContent("Created", value: Formatting.date(created)) }
                    if !entry.method.isEmpty { LabeledContent("Method", value: entry.method) }
                    if let crc = entry.crc { LabeledContent("CRC32", value: String(format: "%08X", crc)) }
                    if !entry.permissions.isEmpty { LabeledContent("Permissions", value: entry.permissions) }
                    if !entry.linkTarget.isEmpty { LabeledContent("Points to", value: entry.linkTarget) }
                    if entry.isEncrypted { LabeledContent("Encrypted", value: "Yes") }
                    if !entry.comment.isEmpty { LabeledContent("Comment", value: entry.comment) }
                }
                LabeledContent("Where", value: "/" + session.tree.displayPath(of: node.parent))
            }
        } else if chosen.count > 1 {
            Section("\(chosen.count) Items Selected") {
                let size = chosen.reduce(UInt64(0)) { $0.addingClamped(session.tree[$1].size) }
                let packed = chosen.reduce(UInt64(0)) { $0.addingClamped(session.tree[$1].packedSize) }
                LabeledContent("Size", value: Formatting.bytes(size))
                if packed > 0 { LabeledContent("Packed", value: Formatting.bytes(packed)) }
            }
        }
    }

    // MARK: The archive

    private var archiveSection: some View {
        let info = session.listing.info
        let root = session.tree.root
        return Section("Archive") {
            LabeledContent("Format", value: info.displayType)
            LabeledContent("Contains", value: Formatting.contents(files: root.fileCount, folders: root.folderCount))
            LabeledContent("Size", value: Formatting.bytes(root.size))
            if let physical = info.physicalSize {
                LabeledContent("On disk") {
                    VStack(alignment: .trailing) {
                        Text(Formatting.bytes(physical))
                        if let saving = Formatting.saving(packed: physical, size: root.size) {
                            Text("\(saving) smaller")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !info.method.isEmpty { LabeledContent("Method", value: info.method) }
            if info.isSolid { LabeledContent("Solid", value: "Yes") }
            if info.isMultiVolume { LabeledContent("Volumes", value: info.volumeCount.map(String.init) ?? "Several") }
            if session.listing.hasEncryptedEntries {
                LabeledContent("Encrypted", value: info.hasEncryptedHeaders ? "Files and names" : "Files")
            }
            if info.hasRecoveryRecord { LabeledContent("Recovery record", value: "Yes") }
            if info.isLocked { LabeledContent("Locked", value: "Yes") }
            if let reason = session.readOnlyReason {
                Label(reason, systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("SHA-256") {
                if let checksum {
                    Text(checksum)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                } else if isHashing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Calculate") { hash() }
                        .controlSize(.small)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.url])
            }
        }
    }

    private var commentSection: some View {
        Section("Comment") {
            let comment = session.listing.info.comment
            if comment.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                Text(comment)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if session.listing.info.format?.supportsComment == true {
                Button(comment.isEmpty ? "Add a Comment…" : "Edit…") { session.sheet = .comment }
                    .disabled(!session.canEdit)
            }
        }
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("Everything 7-Zip Reports") {
                ForEach(session.listing.info.properties, id: \.self) { property in
                    LabeledContent(property.name) {
                        Text(property.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// The SHA-256 of the archive file, to compare with the one its source published.
    private func hash() {
        isHashing = true
        let url = session.url
        Task {
            let value = await Task.detached { Self.sha256(of: url) }.value
            checksum = value ?? "Could not be read"
            isHashing = false
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
