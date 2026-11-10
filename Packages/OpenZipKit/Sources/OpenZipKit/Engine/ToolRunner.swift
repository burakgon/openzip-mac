import Foundation

/// One command to run.
struct ToolCommand: Sendable {
    var executable: URL
    var arguments: [String]
    var directory: URL?
    /// Written to the standard input, which is then closed. Passwords travel this way:
    /// an argument could be read by any other program on the Mac with `ps`.
    var input: Data?
}

/// Lets an operation be paused and stopped from outside while it runs. One control can be
/// handed to several operations in a row: cancelling it stops whichever is running, and
/// keeps the next ones from starting.
public final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false
    private var paused = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public var isPaused: Bool {
        lock.withLock { paused }
    }

    public func cancel() {
        let running: [Process] = lock.withLock {
            cancelled = true
            // A stopped process cannot react to the request to end, so it is woken first.
            if paused {
                paused = false
                processes.forEach { _ = $0.resume() }
            }
            return processes
        }
        Self.stop(running)
    }

    public func pause() {
        lock.withLock {
            guard !paused, !cancelled else { return }
            paused = true
            processes.forEach { _ = $0.suspend() }
        }
    }

    public func resume() {
        lock.withLock {
            guard paused else { return }
            paused = false
            processes.forEach { _ = $0.resume() }
        }
    }

    /// Throws if the operation was cancelled: for the steps between two tools.
    public func checkCancellation() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }

    func attach(_ new: [Process]) {
        let stopNow: Bool = lock.withLock {
            processes = new
            if paused { new.forEach { _ = $0.suspend() } }
            return cancelled
        }
        if stopNow { Self.stop(new) }
    }

    func detach() {
        lock.withLock { processes = [] }
    }

    /// Asks politely first: on an interrupt 7-Zip removes the half-written file it was
    /// working on. What ignores that is ended, and what ignores that too is killed.
    private static func stop(_ processes: [Process]) {
        guard !processes.isEmpty else { return }
        for process in processes where process.isRunning { process.interrupt() }
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + 2) {
            for process in processes where process.isRunning { process.terminate() }
        }
        queue.asyncAfter(deadline: .now() + 4) {
            for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum ToolRunner {
    /// The environment the tools get. Not the one of the app: 7-Zip converts names with
    /// the locale, and an app started from the Finder has none, while one started from a
    /// Turkish terminal upper-cases "i" differently. Every run gets the same.
    static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory(),
        "LC_ALL": "en_US.UTF-8",
        "LANG": "en_US.UTF-8",
    ]

    /// Runs one command, or several as a pipeline in which each reads what the one before
    /// it writes. Returns the exit code of each.
    ///
    /// `onOutput` gets what the commands print, as it comes, with the index of the command:
    /// for the last one its output and errors together, in order; for the ones before it
    /// only what they print to standard error, their output being data for the next.
    /// It is called on background threads, one per command.
    static func run(
        _ commands: [ToolCommand],
        control: OperationControl? = nil,
        onOutput: @escaping @Sendable (_ index: Int, _ data: Data) -> Void
    ) async throws -> [Int32] {
        let control = control ?? OperationControl()
        try control.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int32], Error>) in
                // Waiting for a process blocks, so it gets a thread of its own instead of
                // one of the few that Swift's tasks share.
                let thread = Thread {
                    do {
                        continuation.resume(returning: try runBlocking(commands, control: control, onOutput: onOutput))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "OpenZip tool"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            control.cancel()
        }
    }

    private static func runBlocking(
        _ commands: [ToolCommand],
        control: OperationControl,
        onOutput: @escaping @Sendable (Int, Data) -> Void
    ) throws -> [Int32] {
        var processes: [Process] = []
        var captures: [FileHandle] = []
        var inputs: [(FileHandle, Data)] = []
        var link: Pipe?

        for (index, command) in commands.enumerated() {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.currentDirectoryURL = command.directory
            process.environment = environment

            if let link {
                process.standardInput = link
            } else if let data = command.input {
                let pipe = Pipe()
                process.standardInput = pipe
                inputs.append((pipe.fileHandleForWriting, data))
            } else {
                process.standardInput = FileHandle.nullDevice
            }

            let capture = Pipe()
            process.standardError = capture
            if index == commands.count - 1 {
                process.standardOutput = capture
                link = nil
            } else {
                let next = Pipe()
                process.standardOutput = next
                link = next
            }
            captures.append(capture.fileHandleForReading)
            processes.append(process)
        }

        // Launching closes this side's copies of the ends the children use, which is what
        // lets a reader see the end of the data when the writer exits.
        for (index, process) in processes.enumerated() {
            do {
                try process.run()
            } catch {
                for started in processes.prefix(index) where started.isRunning { started.terminate() }
                throw ArchiveError.toolMissing(commands[index].executable.lastPathComponent)
            }
        }
        control.attach(processes)
        defer { control.detach() }

        for (handle, data) in inputs {
            // A tool that exits without reading must not take the app down with SIGPIPE.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = write(handle.fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                        if written > 0 {
                            offset += written
                        } else if written < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                }
                try? handle.close()
            }
        }

        let readers = DispatchGroup()
        for (index, handle) in captures.enumerated() {
            readers.enter()
            Thread.detachNewThread {
                let size = 64 * 1024
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
                defer {
                    buffer.deallocate()
                    readers.leave()
                }
                while true {
                    let count = read(handle.fileDescriptor, buffer, size)
                    if count > 0 {
                        onOutput(index, Data(bytes: buffer, count: count))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
        readers.wait()
        for process in processes { process.waitUntilExit() }

        if control.isCancelled { throw ArchiveError.cancelled }
        return processes.map(\.terminationStatus)
    }
}

/// Collects what is fed to it from several threads.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func with<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }

    var current: Value {
        lock.withLock { value }
    }
}
