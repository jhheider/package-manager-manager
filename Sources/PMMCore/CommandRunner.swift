import Foundation

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
    /// How long a query may produce no output before it is abandoned. Off unless requested.
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

/// A query silent for two minutes has stopped, not merely slowed down.
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
    private let shellEnvironment: ShellEnvironment
    private let inheritedEnvironment: [String: String]

    public init() {
        shellEnvironment = .shared
        inheritedEnvironment = ProcessInfo.processInfo.environment
    }

    init(shellEnvironment: ShellEnvironment, inheritedEnvironment: [String: String]) {
        self.shellEnvironment = shellEnvironment
        self.inheritedEnvironment = inheritedEnvironment
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        try ProcessExecution.run(
            executable,
            arguments,
            environment: childEnvironment(
                options.terminal ? terminalEnvironment(options.environment) : options.environment
            ),
            terminal: options.terminal,
            streamsStandardOutput: options.streamsStandardOutput,
            inactivityTimeout: options.inactivityTimeout,
            onOutput: onOutput
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

    private func childEnvironment(_ overrides: [String: String]) -> [String: String] {
        commandEnvironment(
            overrides,
            inherited: inheritedEnvironment,
            shell: shellEnvironment.environment(),
            home: FileManager.default.homeDirectoryForCurrentUser
        )
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

/// The environment local commands should inherit. Resolving the shell can block; never call this
/// from the main thread.
public func commandEnvironment(_ overrides: [String: String] = [:]) -> [String: String] {
    commandEnvironment(
        overrides,
        inherited: ProcessInfo.processInfo.environment,
        shell: ShellEnvironment.shared.environment(),
        home: FileManager.default.homeDirectoryForCurrentUser
    )
}

func commandEnvironment(
    _ overrides: [String: String],
    inherited: [String: String],
    shell: [String: String],
    home: URL
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
