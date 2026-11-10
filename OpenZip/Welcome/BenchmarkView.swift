import OpenZipKit
import SwiftUI

/// What the benchmark window shows, and the benchmark behind it.
@Observable
final class BenchmarkModel {
    private(set) var result = BenchmarkResult()
    private(set) var isRunning = false
    private(set) var failure: String?
    @ObservationIgnored private var control: OperationControl?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        failure = nil
        result = BenchmarkResult()
        let control = OperationControl()
        self.control = control
        let engine = AppModel.shared.engine
        Task {
            do {
                result = try await engine.benchmark(control: control) { update in
                    Task { @MainActor in
                        // A late report of a pass must not undo the result of a run that is over.
                        if self.isRunning, self.control === control { self.result = update }
                    }
                }
            } catch ArchiveError.cancelled {
                // Stopped: what was measured until then stays to be read.
            } catch {
                failure = error.localizedDescription
            }
            if self.control === control {
                isRunning = false
                self.control = nil
            }
        }
    }

    func stop() {
        control?.cancel()
    }

    /// The result as text, for pasting somewhere.
    var summary: String {
        var lines = ["OpenZip benchmark (7-Zip LZMA)", result.processor]
        if let threads = result.threads { lines.append("\(threads) threads") }
        for pass in result.passes {
            lines.append("Dictionary \(BenchmarkView.dictionary(pass.dictionaryBits)): compressing \(pass.compressing.rating) MIPS, decompressing \(pass.decompressing.rating) MIPS")
        }
        if let total = result.totalRating { lines.append("Total rating: \(total) MIPS") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The window that measures how fast this Mac packs and unpacks: WinRAR's "Benchmark".
struct BenchmarkView: View {
    @State private var model = BenchmarkModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            passes
            Text("7-Zip compresses and decompresses data it makes up, with LZMA, the method of 7z, on every core of this Mac. The rating says how much work that was, in millions of instructions a second, and can be compared with other Macs and PCs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = model.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Result") { FileClipboard.write(names: [model.summary]) }
                    .disabled(!model.result.isComplete)
                if model.isRunning {
                    Button("Stop") { model.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Run Again") { model.start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.result.processor.isEmpty ? "This Mac" : model.result.processor)
                    .font(.headline)
                Text(model.result.threads.map { Formatting.count($0, "thread") } ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.result.totalRating.map { Formatting.number($0) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("MIPS in total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passes: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow {
                Text("Dictionary")
                    .gridColumnAlignment(.leading)
                Text("Compressing")
                    .gridCellColumns(2)
                Text("Decompressing")
                    .gridCellColumns(2)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(model.result.passes, id: \.dictionaryBits) { pass in
                row(Self.dictionary(pass.dictionaryBits), pass)
            }
            // The passes that are still to come keep their place, so that the window
            // does not grow while it is being read.
            ForEach(0..<max(0, 4 - model.result.passes.count), id: \.self) { _ in
                GridRow {
                    Text("…")
                        .foregroundStyle(.tertiary)
                    Text(" ").gridCellColumns(4)
                }
            }
            Divider()
            if let average = model.result.average {
                row("Average", average)
            } else {
                GridRow {
                    Text("Average")
                        .foregroundStyle(.tertiary)
                    Text(" ").gridCellColumns(4)
                }
            }
        }
        .monospacedDigit()
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func row(_ title: String, _ pass: BenchmarkResult.Pass) -> some View {
        GridRow {
            Text(title)
            Text(Self.speed(pass.compressing.speed))
            Text("\(Formatting.number(pass.compressing.rating)) MIPS")
                .foregroundStyle(.secondary)
            Text(Self.speed(pass.decompressing.speed))
            Text("\(Formatting.number(pass.decompressing.rating)) MIPS")
                .foregroundStyle(.secondary)
        }
        // Numbers are not to be cut short, whatever their width.
        .lineLimit(1)
        .fixedSize()
    }

    /// 24 is a dictionary of 16 MB.
    static func dictionary(_ bits: Int) -> String {
        bits >= 20 ? "\(1 << (bits - 20)) MB" : "\(1 << max(0, bits - 10)) KB"
    }

    /// 7-Zip counts in units of 1024 bytes a second.
    private static func speed(_ kibibytes: UInt64) -> String {
        "\(Formatting.bytes(kibibytes * 1024))/s"
    }
}
