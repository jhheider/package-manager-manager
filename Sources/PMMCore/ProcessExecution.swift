import Darwin
import Foundation

/// Owns subprocess spawning, output capture, waiting, timeouts, process-group cleanup, and reaping.
enum ProcessExecution {
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        terminal: Bool,
        streamsStandardOutput: Bool,
        inactivityTimeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        if terminal {
            return try runInTerminal(
                executable,
                arguments,
                environment: environment,
                onOutput: onOutput
            )
        }

        let output = Pipe()
        let error = Pipe()
        let devNull = open("/dev/null", O_RDONLY)
        defer { if devNull >= 0 { close(devNull) } }
        let command = ([executable] + arguments).joined(separator: " ")
        guard devNull >= 0,
              let child = ProcessGroupChild.spawn(
                  executable: executable,
                  arguments: arguments,
                  environment: environment,
                  standardInput: devNull,
                  standardOutput: output.fileHandleForWriting.fileDescriptor,
                  standardError: error.fileHandleForWriting.fileDescriptor
              )
        else { throw CommandRunError.spawnFailed(command) }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        let activity = ActivityClock()
        let stdout = AsyncReader(
            output.fileHandleForReading,
            onOutput: { text in
                activity.touch()
                if streamsStandardOutput { onOutput?(text) }
            }
        )
        let stderr = AsyncReader(error.fileHandleForReading) { text in
            activity.touch()
            onOutput?(text)
        }
        stdout.start()
        stderr.start()

        var status: Int32?
        while status == nil {
            if let exited = child.wait(timeout: 0.25) {
                status = exited
                break
            }
            if let inactivityTimeout, activity.elapsed >= inactivityTimeout {
                child.terminateGroup(grace: 2)
                throw CommandRunError.timedOut(command: command, afterInactivity: inactivityTimeout)
            }
        }

        var abandoned = false
        while !stdout.isFinished || !stderr.isFinished {
            guard let inactivityTimeout else { break }
            if activity.elapsed >= inactivityTimeout {
                child.terminateRemainingGroup(grace: 2)
                abandoned = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !abandoned { child.reap() }

        return CommandResult(
            stdout: String(decoding: stdout.data(), as: UTF8.self),
            stderr: String(decoding: stderr.data(), as: UTF8.self),
            status: status ?? 0
        )
    }

    static func runBounded(
        _ executable: String,
        _ arguments: [String],
        input: String?,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        environment: [String: String],
        requiredOutputMarker: String? = nil
    ) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmm-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let sink = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? sink.close() }

        let nullInput = open("/dev/null", O_RDONLY)
        defer { if nullInput >= 0 { close(nullInput) } }
        guard nullInput >= 0 else { return nil }

        var inputHandle: FileHandle?
        let inputURL = input.map { _ in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("pmm-probe-in-\(UUID().uuidString)")
        }
        defer {
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            try? inputHandle?.close()
        }
        if let input, let inputURL {
            guard FileManager.default.createFile(atPath: inputURL.path, contents: Data(input.utf8)),
                  let handle = try? FileHandle(forReadingFrom: inputURL)
            else { return nil }
            inputHandle = handle
        }

        let nullOutput = open("/dev/null", O_WRONLY)
        defer { if nullOutput >= 0 { close(nullOutput) } }
        guard nullOutput >= 0,
              let child = ProcessGroupChild.spawn(
                  executable: executable,
                  arguments: arguments,
                  environment: environment,
                  standardInput: inputHandle?.fileDescriptor ?? nullInput,
                  standardOutput: sink.fileDescriptor,
                  standardError: nullOutput
              )
        else { return nil }

        guard let status = child.wait(timeout: timeout) else {
            child.terminateGroup(grace: terminationGrace)
            return nil
        }
        child.terminateRemainingGroup()
        guard status == 0,
              let reader = try? FileHandle(forReadingFrom: outputURL)
        else { return nil }
        defer { try? reader.close() }

        guard var data = readTail(reader, bytes: maxProbeOutputBytes) else { return nil }
        if let requiredOutputMarker,
           !String(decoding: data, as: UTF8.self).contains(requiredOutputMarker),
           let wider = readTail(reader, bytes: maxProbeOutputBytes * 16) {
            data = wider
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func readTail(_ handle: FileHandle, bytes: UInt64) -> Data? {
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return try? handle.read(upToCount: Int(bytes))
    }

    private static func runInTerminal(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let output = AsyncReader(masterHandle, onOutput: onOutput)
        output.start()
        try process.run()
        try? slaveHandle.close()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(decoding: output.data(), as: UTF8.self),
            stderr: "",
            status: process.terminationStatus
        )
    }
}

private let maxProbeOutputBytes: UInt64 = 1 << 20

private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.withLock { last = Date() } }
    var elapsed: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
}

private final class AsyncReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var chunks = Data()
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    var isFinished: Bool { lock.withLock { isDone } }

    init(_ handle: FileHandle, onOutput: (@Sendable (String) -> Void)? = nil) {
        self.handle = handle
        self.onOutput = onOutput
    }

    func start() {
        Thread.detachNewThread {
            var data = Data()
            var decoder = IncrementalUTF8Decoder()
            while true {
                let chunk = self.handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = decoder.decode(chunk)
                if !text.isEmpty { self.onOutput?(text) }
            }
            let finalText = decoder.finish()
            if !finalText.isEmpty { self.onOutput?(finalText) }
            self.lock.withLock {
                self.chunks = data
                self.isDone = true
            }
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        return lock.withLock { chunks }
    }
}

struct IncrementalUTF8Decoder {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        var data = pending
        data.append(chunk)
        let suffixLength = incompleteSuffixLength(in: data)
        pending = suffixLength == 0 ? Data() : Data(data.suffix(suffixLength))
        return String(decoding: data.dropLast(suffixLength), as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    private func incompleteSuffixLength(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let bytes = [UInt8](data)
        let lowerBound = max(0, bytes.count - 4)
        for index in stride(from: bytes.count - 1, through: lowerBound, by: -1) {
            let byte = bytes[index]
            guard byte & 0xC0 != 0x80 else { continue }
            let expectedLength: Int
            switch byte {
            case 0xC2...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF4: expectedLength = 4
            default: return 0
            }
            let availableLength = bytes.count - index
            return availableLength < expectedLength ? availableLength : 0
        }
        return 0
    }
}

/// A child spawned into a process group of its own, so it can be killed with its descendants.
///
/// `Process` cannot do this. Its children inherit *our* process group, which makes `kill(-pgid,…)`
/// unusable — it would signal the app along with the child. Escalating to the child's pid alone is
/// what leaks: a shell that starts background work from an rc file dies while everything it started
/// keeps running, holding the descriptors it inherited. Spawning with `POSIX_SPAWN_SETPGROUP` makes
/// the child a group leader, and the whole group can then be signalled as one.
///
/// Used when a caller has explicitly bounded work. Terminal package operations stay outside this
/// path because an install the user requested is theirs to finish or stop.
private struct ProcessGroupChild {
    let id: pid_t

    /// Spawns `executable` as its own group leader. Descriptors are duplicated onto the standard
    /// streams; the caller keeps ownership of them.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32
    ) -> ProcessGroupChild? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // `setpgroup(0)` means "your own group, with you as leader".
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { return nil }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, target) in [
            (standardInput, STDIN_FILENO),
            (standardOutput, STDOUT_FILENO),
            (standardError, STDERR_FILENO),
        ] where posix_spawn_file_actions_adddup2(&actions, source, target) != 0 {
            return nil
        }

        var id: pid_t = 0
        let spawned = withCStringArray([executable] + arguments) { argv in
            withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&id, executable, &actions, &attributes, argv, envp)
            }
        }
        guard spawned == 0 else { return nil }
        return ProcessGroupChild(id: id)
    }

    /// Waits for exit, up to `timeout`. Returns the exit status, or nil if it was still running.
    ///
    /// Deliberately does not reap. Reaping frees the leader's pid, and the group id *is* that pid —
    /// so once reaped, a signal aimed at "the group" can land on whatever process has since
    /// inherited the number. Holding the zombie keeps the id reserved, which is the only thing that
    /// makes the cleanup below safe. Call ``reap()`` once the group is dealt with.
    func wait(timeout: TimeInterval, pollInterval: TimeInterval = 0.02) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let status = exitStatus() { return status }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return exitStatus()
    }

    /// Releases the zombie. Nothing may signal the group after this.
    func reap() {
        var status: Int32 = 0
        _ = waitpid(id, &status, 0)
    }

    /// The leader's exit status, observed without consuming it.
    private func exitStatus() -> Int32? {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(id), &info, WEXITED | WNOWAIT | WNOHANG) == 0, info.si_pid != 0 else {
            return nil
        }
        // Mirrors Process.terminationStatus: the code for a normal exit, 128+n for a signal.
        return info.si_code == Int32(CLD_EXITED) ? info.si_status : 128 + info.si_status
    }

    /// Signals the whole group — the child and everything it started that did not detach itself.
    ///
    /// A process that called `setsid` has left the group and survives, which is correct: an agent
    /// the user's rc file deliberately daemonised is not ours to kill.
    func terminateGroup(grace: TimeInterval) {
        kill(-id, SIGTERM)
        _ = wait(timeout: grace)
        // Escalate even when the leader went quietly. `wait` observes the leader and nothing else,
        // so stopping here on a polite shell left exactly the processes this exists to reach: the
        // ones ignoring SIGTERM, which they inherit across exec. Nothing has been reaped yet, so
        // the group id is still ours to signal.
        kill(-id, SIGKILL)
        reap()
    }

    /// Clears out whatever is left in the group once the leader is done.
    ///
    /// The leader exiting is not the tree exiting: `wait` observes the leader and nothing else, so an
    /// rc file's `foo &` outlives every *successful* probe as well as every timed-out one. Costs a
    /// single `kill(…, 0)` in the normal case, where the group is already empty.
    ///
    /// A process that called `setsid` has left the group and is not touched, which is intended.
    func terminateRemainingGroup(grace: TimeInterval = 0.25) {
        // Owns the reap on every path, including the early return. `wait` deliberately leaves the
        // leader a zombie so the group id stays reserved while it is signalled, and something has
        // to release it afterwards. Leaving that to the caller leaked one zombie per probe — and
        // the no-descendant early return, which is the ordinary case, leaked on every single one.
        defer { reap() }
        guard groupExists else { return }
        kill(-id, SIGTERM)
        let deadline = Date(timeIntervalSinceNow: grace)
        while Date() < deadline {
            if !groupExists { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Checked immediately before signalling, and never deferred to a later queue. A group id is
        // only free to be reused once the group is empty, so a delayed kill can land on whatever
        // process has since inherited the number — which is not a theoretical risk: an earlier
        // version of this scheduled the escalation and spent its afternoon killing unrelated
        // processes, including other tests' subprocesses.
        if groupExists { kill(-id, SIGKILL) }
    }

    /// Short on purpose: this runs on the success path of every probe, and what it is waiting for is
    /// leftovers nobody asked for. Costs nothing in the ordinary case, where the group is empty.
    static let remainingGroupGrace: TimeInterval = 0.25

    /// Whether the group still has members. The group outlives its leader while any remain, and the
    /// leader's pid cannot be reused while it is still a live group id.
    private var groupExists: Bool { kill(-id, 0) == 0 }

}

private func withCStringArray<R>(_ values: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
