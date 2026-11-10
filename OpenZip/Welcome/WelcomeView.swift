import SwiftUI

/// The window OpenZip opens with when it was not opened for a file: what it can do, and
/// the archives opened lately.
struct WelcomeView: View {
    @State private var isTargeted = false
    @State private var recents: [URL] = []
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            // What is above the list keeps its own height, whatever is left for the rest:
            // a stack would otherwise cut a line of text to even things out.
            header
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)
                .padding(.bottom, 26)

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    ActionCard(title: "New Archive", subtitle: "Pack files and folders", symbol: "doc.zipper", tint: .blue) {
                        AppActions.newArchive()
                    }
                    ActionCard(title: "Open", subtitle: "See what is in an archive", symbol: "folder", tint: .indigo) {
                        AppActions.openArchive()
                    }
                    ActionCard(title: "Extract", subtitle: "Unpack archives where they are", symbol: "square.and.arrow.down", tint: .teal) {
                        AppActions.extractArchives()
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)

            recentList
                .padding(.top, 22)
        }
        .frame(width: 620, height: height)
        .background {
            // What is behind the window shows through, tinted where a drop would land.
            Rectangle()
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        }
        .containerBackground(.thickMaterial, for: .window)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            AppActions.open(urls, forceBrowse: true)
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
            Text("OpenZip")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Drop an archive here to open it, or anything else to pack it.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recentList: some View {
        if recents.isEmpty {
            Spacer()
            Text("ZIP · 7z · RAR · TAR · GZ · XZ · ISO · DMG · CAB and 40 more formats")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 26)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 36)
                VStack(spacing: Self.rowSpacing) {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url)
                            .frame(height: Self.rowHeight)
                    }
                }
                .padding(.horizontal, 22)
            }
            Spacer(minLength: 0)
        }
    }

    // The latest few are all in view, with nothing to scroll: the window is as tall as
    // they need. The rest are in the File menu, under Open Recent.
    private static let mostRecents = 5
    private static let rowHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 2

    /// Three recent archives fit under the cards; each one more makes the window taller.
    private var height: CGFloat {
        560 + CGFloat(max(0, recents.count - 3)) * (Self.rowHeight + Self.rowSpacing)
    }

    private func refresh() {
        recents = Array(AppModel.shared.recentArchives.prefix(Self.mostRecents))
    }
}

/// One of the three things to do, on a card of glass.
private struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct RecentRow: View {
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            AppModel.shared.openArchive(url)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Formatting.folder(url.deletingLastPathComponent()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open") { AppModel.shared.openArchive(url) }
            Button("Extract Here") { QuickActions.extract([url], mode: .here) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    /// The file's own icon, or that of its kind when the file is not there to be asked.
    private var icon: NSImage {
        FileManager.default.fileExists(atPath: url.path)
            ? NSWorkspace.shared.icon(forFile: url.path)
            : FileIcons.icon(for: url.lastPathComponent, isDirectory: false)
    }
}

/// The operations that run in the background, each with how far it is.
struct ActivityWindow: View {
    private var center: OperationCenter { AppModel.shared.operations }

    var body: some View {
        Group {
            if center.operations.isEmpty {
                ContentUnavailableView("Nothing Is Running", systemImage: "checkmark.circle", description: Text("Archives being created or extracted in the background show up here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(center.operations) { operation in
                            OperationRow(operation: operation)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 440)
        .frame(minHeight: 150, idealHeight: 240, maxHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", systemImage: "xmark.circle") { center.clearFinished() }
                    .disabled(center.operations.allSatisfy(\.isRunning))
                    .help("Remove the operations that are over")
            }
        }
    }
}

private struct OperationRow: View {
    let operation: BackgroundOperation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(operation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if operation.isRunning {
                    if let fraction = operation.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(isFailure ? 4 : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if operation.isRunning {
                Button(operation.isPaused ? "Resume" : "Pause", systemImage: operation.isPaused ? "play.fill" : "pause.fill") {
                    operation.togglePause()
                }
                Button("Stop", systemImage: "xmark") { operation.cancel() }
            } else {
                if !operation.results.isEmpty {
                    Button("Show in Finder", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting(operation.results)
                    }
                    .help("Show in Finder")
                }
                Button("Remove", systemImage: "xmark") { AppModel.shared.operations.remove(operation) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var isFailure: Bool {
        if case .failed = operation.state { return true }
        return false
    }

    private var symbol: String {
        switch operation.state {
        case .running: operation.symbol
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle"
        }
    }

    private var tint: Color {
        switch operation.state {
        case .running: .accentColor
        case .finished: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private var detail: String {
        switch operation.state {
        case .finished(let message): return message
        case .failed(let message): return message
        case .cancelled: return "Stopped"
        case .running:
            if operation.isPaused { return "Paused" }
            var parts: [String] = []
            if let fraction = operation.fraction { parts.append(Formatting.percent(fraction)) }
            if let remaining = operation.remaining { parts.append(remaining) }
            if !operation.item.isEmpty { parts.append((operation.item as NSString).lastPathComponent) }
            return parts.isEmpty ? "Preparing…" : parts.joined(separator: " · ")
        }
    }
}
