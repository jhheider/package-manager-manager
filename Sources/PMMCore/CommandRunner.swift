import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32

    public init(stdout: String, stderr: String, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

public struct CommandRunOptions: Sendable, Equatable {
    public var terminal: Bool
    public var environment: [String: String]
    public var streamsStandardOutput: Bool
    /// How long a query may produce nothing at all before it is abandoned.
    ///
    /// Inactivity, not elapsed time: a scan command that is still printing is still working, and a
    /// package operation is allowed to take as long as it takes. What this catches is the one that
    /// has stopped — `cargo install-update` polling a registry that never answers, a tool waiting on
    /// a package-cache lock another terminal holds, anything blocked on an unresponsive home
    /// directory. Those never returned, and the refresh spinner never resolved.
    ///
    /// Off unless a caller asks for it. Defaulting it on armed the budget for everything that runs
    /// through the non-terminal path, including SSH to a remote host: a remote inventory prints
    /// only its final JSON, so a slow one was killed at two minutes and reported as "stopped
    /// responding" while that machine was still working, or had already finished. A capability that
    /// kills processes belongs at the call sites that know the command is a quick local query.
    public var inactivityTimeout: TimeInterval?

    public init(
        terminal: Bool = false,
        environment: [String: String] = [:],
        streamsStandardOutput: Bool = true,
        inactivityTimeout: TimeInterval? = nil
    ) {
        self.terminal = terminal
        self.environment = environment
        self.streamsStandardOutput = streamsStandardOutput
        self.inactivityTimeout = inactivityTimeout
    }
}

/// Generous on purpose. Several scan commands print nothing until they finish, so for them this is
/// effectively a total budget rather than an idle one — and a query that has produced no output at
/// all for two minutes has stopped, not slowed down.
public let defaultQueryInactivityTimeout: TimeInterval = 120

public enum CommandRunError: Error, LocalizedError, Equatable {
    case spawnFailed(String)
    case timedOut(command: String, afterInactivity: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let command):
            "Could not run \(command)."
        case .timedOut(let command, let seconds):
            "\(command) stopped responding — no output for \(Int(seconds))s."
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        try run(executable, arguments)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions
    ) throws -> CommandResult {
        try run(executable, arguments, options: options, onOutput: nil)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        if options.terminal {
            return try runInTerminal(executable, arguments, options: options, onOutput: onOutput)
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
                  environment: commandEnvironment(options.environment),
                  standardInput: devNull,
                  standardOutput: output.fileHandleForWriting.fileDescriptor,
                  standardError: error.fileHandleForWriting.fileDescriptor
              )
        else { throw CommandRunError.spawnFailed(command) }
        // The parent's copies of the write ends have to go, or the readers never see EOF.
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        // Every chunk from either stream counts as activity, whether or not the caller wanted it
        // streamed — a command printing only to stderr is still working.
        let activity = ActivityClock()
        let stdout = AsyncPipeReader(output) { text in
            activity.touch()
            if options.streamsStandardOutput { onOutput?(text) }
        }
        let stderr = AsyncPipeReader(error) { text in
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
            if let limit = options.inactivityTimeout, activity.elapsed >= limit {
                // The whole group: killing `cargo` alone would leave its fetches and its rustc
                // children running, and they hold the pipes this call is about to read.
                child.terminateGroup(grace: 2)
                throw CommandRunError.timedOut(command: command, afterInactivity: limit)
            }
        }

        // The leader exiting is not the tree exiting. A descendant that inherited the pipes holds
        // them open, and `data()` below then waits for an EOF that never comes — `sh -c 'sleep 600 &'`
        // returns instantly and hangs this call forever. So the budget covers reader completion too.
        var abandoned = false
        while !stdout.isFinished || !stderr.isFinished {
            guard let limit = options.inactivityTimeout else { break }
            if activity.elapsed >= limit {
                child.terminateRemainingGroup(grace: 2)
                abandoned = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Whatever the command already produced still counts: the leader succeeded, and only its
        // stragglers were given up on.
        if !abandoned { child.reap() }

        return CommandResult(
            stdout: String(data: stdout.data(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.data(), encoding: .utf8) ?? "",
            status: status ?? 0
        )
    }

    private func runInTerminal(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
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
        process.environment = commandEnvironment(terminalEnvironment(options.environment))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let output = AsyncFileHandleReader(masterHandle, onOutput: onOutput)
        output.start()
        try process.run()
        try? slaveHandle.close()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: output.data(), encoding: .utf8) ?? "",
            stderr: "",
            status: process.terminationStatus
        )
    }

    private func terminalEnvironment(_ overrides: [String: String]) -> [String: String] {
        [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "CLICOLOR_FORCE": "1",
            "FORCE_COLOR": "3",
            "HOMEBREW_COLOR": "1",
            "COLUMNS": "80",
            "LINES": "24",
        ].merging(overrides) { _, new in new }
    }
}

/// Last-touched timestamp, shared between the two readers and the watchdog.
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.withLock { last = Date() } }
    var elapsed: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
}

final class AsyncPipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var chunks = Data()
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    /// Whether the stream has reached EOF, readable without consuming what ``data()`` waits on.
    var isFinished: Bool { lock.withLock { isDone } }

    init(_ pipe: Pipe, onOutput: (@Sendable (String) -> Void)? = nil) {
        self.pipe = pipe
        self.onOutput = onOutput
    }

    func start() {
        // A dedicated thread, not a pooled queue. A saturated global pool can leave this block
        // unscheduled while the subprocess runs to completion — and for a pty, once the last slave
        // descriptor closes, anything still unread on the master is discarded, so late means gone.
        Thread.detachNewThread {
            var data = Data()
            var decoder = IncrementalUTF8Decoder()
            while true {
                let chunk = self.pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = decoder.decode(chunk)
                if !text.isEmpty {
                    self.onOutput?(text)
                }
            }
            let finalText = decoder.finish()
            if !finalText.isEmpty {
                self.onOutput?(finalText)
            }
            self.lock.lock()
            self.chunks = data
            self.isDone = true
            self.lock.unlock()
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

private final class AsyncFileHandleReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var chunks = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, onOutput: (@Sendable (String) -> Void)? = nil) {
        self.handle = handle
        self.onOutput = onOutput
    }

    func start() {
        // A dedicated thread, not a pooled queue. A saturated global pool can leave this block
        // unscheduled while the subprocess runs to completion — and for a pty, once the last slave
        // descriptor closes, anything still unread on the master is discarded, so late means gone.
        Thread.detachNewThread {
            var data = Data()
            var decoder = IncrementalUTF8Decoder()
            while true {
                let chunk = self.handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = decoder.decode(chunk)
                if !text.isEmpty {
                    self.onOutput?(text)
                }
            }
            let finalText = decoder.finish()
            if !finalText.isEmpty {
                self.onOutput?(finalText)
            }
            self.lock.lock()
            self.chunks = data
            self.lock.unlock()
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return chunks
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

private let fallbackCommandPaths = ["/usr/local/bin", "/opt/homebrew/bin"]

/// Directories worth searching even when the login shell could not be probed. `~/.cargo/bin` is the
/// one that matters in practice: cargo puts every `cargo install` binary there and nothing else on
/// the system adds it to a Finder-launched app's PATH.
func homeCommandPaths(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [String] {
    let cargoHome = environment["CARGO_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".cargo", isDirectory: true)
    let cargoInstallRoot = environment["CARGO_INSTALL_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? cargoHome
    var seen = Set<String>()
    return [
        cargoHome.appendingPathComponent("bin", isDirectory: true).path,
        cargoInstallRoot.appendingPathComponent("bin", isDirectory: true).path,
        home.appendingPathComponent(".local/bin", isDirectory: true).path,
    ].filter { seen.insert($0).inserted }
}

/// The login shell's PATH, waiting for it to be resolved if it has not been already. Blocking here
/// is what keeps an install/update/uninstall fired from a cached snapshot from racing the probe and
/// running with launchd's truncated PATH. Never call this from the main thread.
func defaultShellCommandPaths() -> [String] {
    // This is a defaulted argument to `commandPath`, so the blocking is easy to reach by accident.
    // On the main thread it is a silent multi-second beachball; make it a loud debug trap instead.
    dispatchPrecondition(condition: .notOnQueue(.main))
    return ShellEnvironment.shared.searchPaths()
}

/// The PATH launchd hands a process it started — a Finder launch, a login item, the menu bar
/// helper. Nobody chose it, which is the whole reason this file exists.
private let launchdDefaultPathEntries: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

/// Whether an inherited PATH carries no information, i.e. it is launchd's stock value or a subset.
///
/// The distinction matters because the two launch styles want opposite precedence, and only one of
/// them is the case this branch set out to fix.
func isLaunchdDefaultPath(_ path: String?) -> Bool {
    let entries = pathEntries(path)
    return entries.isEmpty || Set(entries).isSubset(of: launchdDefaultPathEntries)
}

/// Builds a search PATH for a child process.
///
/// `leading` is a PATH the caller asked for explicitly, so it keeps top precedence. After that the
/// order depends on where the inherited PATH came from:
///
/// - Launched by launchd (Finder, a login item, the menu bar helper), `inherited` is the stock
///   `/usr/bin:/bin:/usr/sbin:/sbin`. Nobody chose it, so the login shell's PATH leads and the
///   mise/nvm/asdf shims the user actually resolves win over `/usr/bin`.
/// - Launched from a terminal — which is how `pmmctl` is always run — `inherited` is the user's
///   *active* environment: an activated virtualenv, a project toolchain, a directory-scoped shim.
///   That is more specific than what their login shell produces in an empty directory, so it keeps
///   the lead. Demoting it would resolve a different `npm` than the one the user is looking at, and
///   then update or uninstall from the wrong prefix.
///
/// Duplicates keep their earliest slot.
func commandPath(
    leading: String? = nil,
    inherited: String?,
    shell: [String] = defaultShellCommandPaths(),
    home: [String] = homeCommandPaths()
) -> String {
    let inheritedEntries = pathEntries(inherited)
    let discovered = isLaunchdDefaultPath(inherited)
        ? shell + inheritedEntries
        : inheritedEntries + shell
    // `home` stands in for a PATH we could not read, so it only applies when the probe came back
    // with nothing. Appending it to a PATH the shell did resolve would rediscover a tool the user
    // deliberately left out — a stale `~/.cargo/bin` binary they had already stopped putting on
    // their own PATH would start showing up as installed again.
    let unresolvedFallbacks = shell.isEmpty ? home : []
    var seen = Set<String>()
    return (pathEntries(leading) + discovered + unresolvedFallbacks + fallbackCommandPaths)
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .joined(separator: ":")
}

/// Runs blocking work on a Dispatch queue instead of Swift's cooperative thread pool.
///
/// Everything that shells out belongs here. ``SystemCommandRunner`` waits on a subprocess, and tool
/// lookup waits on the login-shell probe whenever an action beats ``ShellEnvironment/prime()``.
/// Either one inside `Task.detached` pins a cooperative thread — there is roughly one per core —
/// for the whole window. ``PackageScanner`` already fans out this way.
public func runBlocking<T: Sendable>(
    qos: DispatchQoS.QoSClass = .background,
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}

private func pathEntries(_ path: String?) -> [String] {
    guard let path, !path.isEmpty else { return [] }
    return path.split(separator: ":").map(String.init)
}

func commandEnvironment(
    _ overrides: [String: String],
    inherited: [String: String] = ProcessInfo.processInfo.environment,
    shell: [String: String] = ShellEnvironment.shared.environment(),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [String: String] {
    var environment = isLaunchdDefaultPath(inherited["PATH"])
        ? inherited.merging(shell) { _, shell in shell }
        : shell.merging(inherited) { _, inherited in inherited }
    environment.merge(overrides) { _, override in override }
    environment["PATH"] = commandPath(
        leading: overrides["PATH"],
        inherited: inherited["PATH"],
        shell: ShellEnvironment.searchPaths(in: shell),
        home: homeCommandPaths(environment: environment, home: home)
    )
    return environment
}

/// Resolves a tool by name. Blocks until the login shell's PATH is known, so callers must be off
/// the main thread — every caller is already about to spawn a subprocess and wait on it.
public func firstExecutable(named name: String) -> String? {
    let pathParts = commandPath(inherited: ProcessInfo.processInfo.environment["PATH"])
        .split(separator: ":")
        .map(String.init)
    let candidates = pathParts.map { "\($0)/\(name)" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
