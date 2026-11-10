import AppKit
import OpenZipKit
import SwiftUI
import UniformTypeIdentifiers

/// The list of files in an archive window.
///
/// This is an AppKit table and not a SwiftUI one, for what it has to do: show a folder of
/// a hundred thousand files without a pause, rename in place, and hand files to the Finder
/// as promises, which are only extracted once they are dropped somewhere.
struct FileTable: NSViewRepresentable {
    let session: ArchiveSession
    // Passed in so that a change of any of them brings the table up to date. The table
    // reads the rest from the session when it needs it.
    let version: Int
    let selection: Set<Int>
    let renameRequest: Int?
    let canEdit: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = FileTableView()
        table.style = .inset
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.gridStyleMask = []
        for column in Column.allCases {
            table.addTableColumn(column.make())
        }
        // After the columns exist: this restores the widths, the order and what is hidden.
        table.autosaveName = "OpenZip.FileList"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClicked)
        table.onKey = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        table.selectedNames = { [session] in session.selectedRows.map { session.tree[$0].name } }
        table.menu = NSMenu()
        table.menu?.delegate = coordinator
        table.headerView?.menu = coordinator.makeColumnsMenu(for: table)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.setDraggingSourceOperationMask([.move], forLocal: true)
        table.registerForDraggedTypes([.fileURL, Coordinator.nodeType])
        table.sortDescriptors = [NSSortDescriptor(key: session.settings.sortKey.rawValue, ascending: session.settings.sortAscending)]

        coordinator.table = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(version: version, selection: selection, renameRequest: renameRequest)
    }

    // MARK: Columns

    enum Column: String, CaseIterable {
        case name, size, packedSize, kind, modified, ratio, crc, method, permissions

        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .packedSize: "Packed"
            case .kind: "Kind"
            case .modified: "Date Modified"
            case .ratio: "Ratio"
            case .crc: "CRC32"
            case .method: "Method"
            case .permissions: "Permissions"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 280
            case .size, .packedSize: 82
            case .kind: 150
            case .modified: 156
            case .ratio: 62
            case .crc: 84
            case .method: 120
            case .permissions: 104
            }
        }

        var alignsRight: Bool {
            self == .size || self == .packedSize || self == .ratio
        }

        /// Shown from the start. The others can be turned on from the header's menu.
        var isDefault: Bool {
            switch self {
            case .name, .size, .packedSize, .kind, .modified: true
            default: false
            }
        }

        /// What clicking the header sorts by.
        var sortKey: ArchiveTree.SortKey? {
            switch self {
            case .name: .name
            case .size: .size
            case .packedSize: .packedSize
            case .kind: .kind
            case .modified: .modified
            default: nil
            }
        }

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(rawValue)
        }

        func make() -> NSTableColumn {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = self == .name ? 140 : 48
            column.isHidden = !isDefault
            column.headerCell.alignment = alignsRight ? .right : .left
            if let sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: self != .modified && self != .size)
            }
            return column
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSFilePromiseProviderDelegate {
        static let nodeType = NodePromiseProvider.nodeType

        let session: ArchiveSession
        weak var table: FileTableView?
        /// What the table is showing: the session's rows, tree and entries as of the last
        /// reload. The table is asked for its cells at moments of its own choosing, also
        /// between an archive being read again and the list being told; with its own
        /// copies it never looks up an old row in a new tree.
        private var rows: [Int] = []
        private var tree = ArchiveTree()
        private var entries: [ArchiveEntry] = []
        private var appliedVersion = -1
        private var appliedSelection: Set<Int> = []
        private var isApplyingSelection = false
        private var didTakeFocus = false
        private var drags: [UUID: DragExtraction] = [:]
        private var currentDrag = UUID()
        private var draggedIDs: [Int] = []
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            return queue
        }()

        /// The list of the window that was opened last, for the demo's steps.
        static weak var latest: Coordinator?

        init(session: ArchiveSession) {
            self.session = session
            super.init()
            Self.latest = self
        }

        /// Keeps the promises a drag of these nodes into a folder would make, the way the
        /// Finder would ask for them. For trying the path a drag takes without a mouse.
        func keepPromises(for ids: [Int], in folder: URL) async -> [String] {
            let drag = UUID()
            drags[drag] = DragExtraction(ids: ids)
            var results: [String] = []
            for id in ids {
                let name = session.tree[id].name
                do {
                    try await fulfill(PromisedNode(id: id, name: name, drag: drag), at: folder.appending(path: name))
                    results.append("kept \(name)")
                } catch {
                    results.append("failed \(name): \(error.localizedDescription)")
                }
            }
            return results
        }

        func sync(version: Int, selection: Set<Int>, renameRequest: Int?) {
            guard let table else { return }
            if version != appliedVersion {
                appliedVersion = version
                rows = session.rows
                tree = session.tree
                entries = session.listing.entries
                appliedSelection = []
                table.reloadData()
                isApplyingSelection = true
                table.deselectAll(nil)
                isApplyingSelection = false
                if !didTakeFocus {
                    // The list is what a new window is about: arrow keys, typing a name and
                    // Space work at once, without a click to wake it.
                    didTakeFocus = true
                    DispatchQueue.main.async {
                        guard let window = table.window, window.firstResponder === window || window.firstResponder == nil else { return }
                        window.makeFirstResponder(table)
                    }
                }
            }
            if selection != appliedSelection {
                appliedSelection = selection
                var indexes = IndexSet()
                if !selection.isEmpty {
                    for (row, id) in rows.enumerated() where selection.contains(id) { indexes.insert(row) }
                }
                isApplyingSelection = true
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                isApplyingSelection = false
                if let first = indexes.first { table.scrollRowToVisible(first) }
            }
            if let id = renameRequest {
                // Not while SwiftUI is in the middle of an update.
                DispatchQueue.main.async { [self] in
                    session.renameRequest = nil
                    beginRenaming(id)
                }
            }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), row < rows.count else { return nil }
            let node = tree[rows[row]]
            let entry = node.entry.flatMap { $0 < entries.count ? entries[$0] : nil }

            if column == .name {
                let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NameCell ?? NameCell(identifier: column.identifier)
                cell.imageView?.image = FileIcons.icon(for: node.name, isDirectory: node.isDirectory)
                cell.textField?.stringValue = node.name
                cell.textField?.isEditable = session.canEdit
                cell.textField?.delegate = self
                cell.setBadges(isEncrypted: node.isEncrypted, isLink: node.isSymbolicLink)
                // In a search or a flat list, files of the same name come from different
                // folders: the tooltip says which.
                cell.toolTip = session.isSearching || session.isFlat ? tree.displayPath(of: node.id) : nil
                return cell
            }

            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? TextCell ?? TextCell(identifier: column.identifier, column: column)
            let text: String
            switch column {
            case .name: text = ""
            case .size: text = node.isDirectory && node.fileCount == 0 ? "—" : Formatting.bytes(node.size)
            case .packedSize:
                // A solid archive compresses files together and knows no size for one of them.
                text = node.packedSize == 0 && node.size > 0 ? "—" : (node.isDirectory && node.fileCount == 0 ? "—" : Formatting.bytes(node.packedSize))
            case .kind: text = FileIcons.kind(for: node.name, isDirectory: node.isDirectory, isLink: node.isSymbolicLink)
            case .modified: text = Formatting.date(node.modified)
            case .ratio: text = Formatting.ratio(packed: node.packedSize, size: node.size)
            case .crc: text = entry?.crc.map { String(format: "%08X", $0) } ?? ""
            case .method: text = entry?.method ?? ""
            case .permissions: text = entry?.permissions ?? ""
            }
            cell.textField?.stringValue = text
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row < rows.count ? tree[rows[row]].name : nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil })
            appliedSelection = ids
            session.selection = ids
            Task { await session.updatePreview() }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(ArchiveTree.SortKey.init(rawValue:)) else { return }
            session.sort(by: key, ascending: descriptor.ascending)
        }

        // MARK: Opening and keys

        @objc func openClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            session.open(rows[table.clickedRow])
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 49 where modifiers.isEmpty:  // Space
                session.togglePreview()
                return true
            case 36, 76:  // Return, Enter: rename, as in the Finder. What cannot be renamed is opened.
                guard modifiers.isEmpty, let id = session.selectedRows.first else { return false }
                if session.canEdit, session.selection.count == 1 {
                    beginRenaming(id)
                } else {
                    session.open(id)
                }
                return true
            case 53:  // Escape
                if session.previewURL != nil {
                    session.togglePreview()
                    return true
                }
                if session.isSearching {
                    session.searchText = ""
                    return true
                }
                return false
            default:
                return false
            }
        }

        // MARK: Renaming

        func beginRenaming(_ id: Int) {
            guard session.canEdit, session.tree.contains(id), let table, let row = rows.firstIndex(of: id) else { return }
            let column = table.column(withIdentifier: Column.name.identifier)
            guard column >= 0 else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            table.editColumn(column, row: row, with: nil, select: true)
            // Like the Finder: the name is selected, the extension is not.
            if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
               let editor = cell.textField?.currentEditor() {
                let name = session.tree[id].name
                let base = session.tree[id].isDirectory ? name : FileNaming.split(name).base
                editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let table else { return }
            let row = table.row(for: field)
            guard row >= 0, row < rows.count else { return }
            let id = rows[row]
            let old = tree[id].name
            let new = field.stringValue
            guard new != old else { return }
            // Until the archive has been rewritten the list still shows the old name.
            field.stringValue = old
            Task { await session.rename(id, to: new) }
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            menu.removeAllItems()
            let clicked = table.clickedRow
            if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let onRow = clicked >= 0
            let selected = session.selectedRows

            func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let item = ActionMenuItem.make(title: title, symbol: symbol, action: action)
                item.isEnabled = enabled
                menu.addItem(item)
            }

            if onRow, let first = selected.first {
                add(session.tree[first].isDirectory && selected.count == 1 ? "Open" : "Open", "arrow.up.forward.square") { [session] in
                    selected.forEach { session.open($0) }
                }
                add("Quick Look", "eye", enabled: selected.contains { !self.session.tree[$0].isDirectory }) { [session] in
                    session.togglePreview()
                }
                menu.addItem(.separator())
                add("Extract…", "arrow.down.doc") { [session] in
                    session.sheet = .extract(selection: session.selectedRoots)
                }
                menu.addItem(.separator())
                add("Rename", "pencil", enabled: session.canEdit && selected.count == 1) { [weak self] in
                    self?.beginRenaming(first)
                }
                add("Delete", "trash", enabled: session.canEdit) { [session] in
                    session.requestDeletion(session.selectedRoots)
                }
                menu.addItem(.separator())
                add(selected.count == 1 ? "Copy Name" : "Copy Names", "doc.on.doc") { [session] in
                    Self.copy(selected.map { session.tree[$0].name })
                }
                add(selected.count == 1 ? "Copy Path" : "Copy Paths", "point.topleft.down.to.point.bottomright.curvepath") { [session] in
                    Self.copy(selected.map { session.tree.displayPath(of: $0) })
                }
            } else {
                add("Extract All…", "arrow.down.doc", enabled: session.isReady) { [session] in
                    session.sheet = .extract(selection: nil)
                }
                add("Select All", "checklist") { [session] in session.selectAll() }
            }
            menu.addItem(.separator())
            add("New Folder", "folder.badge.plus", enabled: session.canEdit) { [session] in
                session.sheet = .newFolder
            }
            add("Add Files…", "plus", enabled: session.canEdit) { [session] in
                BrowserActions.chooseFilesToAdd(to: session)
            }
        }

        private static func copy(_ lines: [String]) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        /// The menu of the header: which columns are shown.
        func makeColumnsMenu(for table: NSTableView) -> NSMenu {
            let menu = NSMenu()
            for column in Column.allCases where column != .name {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                menu.addItem(item)
            }
            menu.delegate = ColumnsMenuDelegate.shared
            return menu
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String, let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(name)) else { return }
            column.isHidden.toggle()
        }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            // Nothing is promised while the window is busy: the promise could not be kept
            // before the other operation is over.
            guard row < rows.count, session.isReady, !session.isBusy else { return nil }
            let node = tree[rows[row]]
            let ext = (node.name as NSString).pathExtension
            let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
            let provider = NodePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = PromisedNode(id: node.id, name: node.name, drag: currentDrag)
            return provider
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            draggedIDs = rowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
            drags[currentDrag] = DragExtraction(ids: draggedIDs)
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // A drag that was dropped nowhere, or inside the window, promised nothing.
            if operation != .copy { drags[currentDrag] = nil }
            currentDrag = UUID()
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? PromisedNode)?.name ?? "File"
        }

        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            // The work happens in a task on the main actor and in 7-Zip; this queue only waits.
            OperationQueue.main
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
        ) {
            guard let promised = filePromiseProvider.userInfo as? PromisedNode else {
                completionHandler(CocoaError(.fileWriteUnknown))
                return
            }
            let done = UncheckedSendable(completionHandler)
            Task { @MainActor in
                do {
                    try await self.fulfill(promised, at: url)
                    done.value(nil)
                } catch {
                    done.value(error)
                }
            }
        }

        /// Writes one promised item. The first promise of a drag starts one extraction for
        /// everything that was dragged; the others wait for it and take their file.
        private func fulfill(_ promised: PromisedNode, at url: URL) async throws {
            guard let drag = drags[promised.drag] else { throw CocoaError(.fileWriteUnknown) }
            if drag.task == nil {
                let session = session
                let ids = drag.ids
                let folder = url.deletingLastPathComponent()
                drag.task = Task { try await session.extractForDrag(ids, near: folder) }
            }
            defer {
                drag.remaining -= 1
                if drag.remaining <= 0 {
                    drags[promised.drag] = nil
                    if let work = drag.work { try? FileManager.default.removeItem(at: work) }
                }
            }
            let locations = try await drag.task!.value
            guard let source = locations[promised.id] else { throw CocoaError(.fileNoSuchFile) }
            drag.work = source.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: source, to: url)
        }

        // MARK: Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard session.canEdit else { return [] }
            let isOwn = (info.draggingSource as? NSTableView) === tableView
            let onFolder = dropOperation == .on && row >= 0 && row < rows.count && tree[rows[row]].isDirectory
            if isOwn {
                // Items of this archive can be moved into one of its folders.
                guard onFolder, !draggedIDs.contains(rows[row]) else { return [] }
                return .move
            }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            // Files from outside go into the folder they are dropped on, or else into the
            // one the window shows: then the whole list is the target.
            if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let target = row >= 0 && row < rows.count ? rows[row] : session.folder
            if (info.draggingSource as? NSTableView) === tableView {
                let ids = draggedIDs
                Task { await session.move(ids, to: target) }
                return true
            }
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            Task { await session.add(urls, into: target, options: nil, password: nil) }
            return true
        }
    }
}

/// What a promise carries from the moment a drag starts to the moment it is kept.
nonisolated final class PromisedNode: NSObject, Sendable {
    let id: Int
    let name: String
    let drag: UUID

    init(id: Int, name: String, drag: UUID) {
        self.id = id
        self.name = name
        self.drag = drag
    }
}

/// One drag out of a window: everything in it is extracted in one go.
private final class DragExtraction {
    let ids: [Int]
    var remaining: Int
    var task: Task<[Int: URL], Error>?
    var work: URL?

    init(ids: [Int]) {
        self.ids = ids
        remaining = ids.count
    }
}

nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// A file promise that also says which node of the archive it is, for moving items
/// around inside the window they came from.
nonisolated final class NodePromiseProvider: NSFilePromiseProvider {
    static let nodeType = NSPasteboard.PasteboardType("com.burakgon.openzip.node")

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.nodeType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.nodeType {
            return (userInfo as? PromisedNode).map { String($0.id) }
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// The table itself, which lets its coordinator have a go at the keys first.
final class FileTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    /// The names of the selected rows, for Copy.
    var selectedNames: (() -> [String])?

    /// Edit → Copy: the names of what is selected, one per line.
    @objc func copy(_ sender: Any?) {
        guard let names = selectedNames?(), !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// A right click on empty space is a click on the folder, not on the last selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }
}

/// The name of a file with its icon, and marks for what the name does not say.
final class NameCell: NSTableCellView {
    private let badge = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        imageView = icon

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.contentTintColor = .tertiaryLabelColor
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(badge)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func setBadges(isEncrypted: Bool, isLink: Bool) {
        let symbol = isEncrypted ? "lock.fill" : (isLink ? "arrow.turn.up.right" : nil)
        badge.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: isEncrypted ? "Encrypted" : "Link") }
        badge.isHidden = symbol == nil
    }
}

/// A cell of plain text for the other columns.
final class TextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, column: FileTable.Column) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alignment = column.alignsRight ? .right : .left
        switch column {
        case .crc, .permissions:
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        default:
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

/// A menu item that runs a closure.
enum ActionMenuItem {
    /// What an item calls when it is chosen. The item keeps it alive as its represented object.
    private final class Handler: NSObject {
        let action: () -> Void

        init(_ action: @escaping () -> Void) {
            self.action = action
        }

        @objc func run() {
            action()
        }
    }

    static func make(title: String, symbol: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = Handler(action)
        let item = NSMenuItem(title: title, action: #selector(Handler.run), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}

/// Puts the check marks into the menu of the columns when it opens.
final class ColumnsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ColumnsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let name = item.representedObject as? String,
                  let coordinator = item.target as? FileTable.Coordinator,
                  let column = coordinator.table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(name))
            else { continue }
            item.state = column.isHidden ? .off : .on
        }
    }
}

/// What several parts of a window do in the same way.
enum BrowserActions {
    /// Asks for files and adds them to the folder the window shows.
    static func chooseFilesToAdd(to session: ArchiveSession, withOptions: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files and folders to add to “\(session.title)”."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        if withOptions {
            session.sheet = .add(urls, folder: session.folder)
        } else {
            Task { await session.add(urls, into: nil, options: nil, password: nil) }
        }
    }
}
