import Darwin
import Foundation

/// Resolves the PATH the user actually has in their shell.
///
/// A Finder-launched app inherits launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not the one
/// built up by `.zshenv`/`/etc/zprofile`/`.zshrc`. That hides every tool installed outside those
/// directories — `~/.cargo/bin` most notably — so package scans silently come back empty.
///
/// Resolution runs the login shell once and caches the result. Call ``prime()`` at launch, then
/// ``searchPaths(timeout:)`` from a background thread or ``cachedSearchPaths()`` from the main one.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let condition = NSCondition()
    private let resolver: @Sendable () -> [String]
    private var resolved: [String]?
    private var isResolving = false

    init(resolver: @escaping @Sendable () -> [String] = { ShellEnvironment.loginShellSearchPaths() }) {
        self.resolver = resolver
    }

    /// Kicks off resolution on a background queue. Cheap, idempotent, safe from the main thread.
    public func prime() {
        condition.lock()
        guard resolved == nil, !isResolving else {
            condition.unlock()
            return
        }
        isResolving = true
        condition.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let paths = self.resolver()
            self.condition.lock()
            self.resolved = paths
            self.isResolving = false
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    /// Whatever has been resolved so far, without waiting. Empty until resolution finishes.
    public func cachedSearchPaths() -> [String] {
        condition.lock()
        defer { condition.unlock() }
        return resolved ?? []
    }

    /// Awaits resolution without blocking the calling thread, so callers do not have to know that
    /// probing the shell blocks. Returns straight away once resolution has happened.
    public func resolvedSearchPaths() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.searchPaths())
            }
        }
    }

    /// Blocks until the shell PATH is resolved. Never call this from the main thread.
    public func searchPaths(timeout: TimeInterval = 10) -> [String] {
        prime()
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while resolved == nil, condition.wait(until: deadline) {}
        return resolved ?? []
    }
}

extension ShellEnvironment {
    /// The user's login shell, from the password database rather than `SHELL` — a bundled app
    /// launched by Finder does not reliably inherit `SHELL`.
    static func userLoginShell() -> String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }),
           !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    static func loginShellSearchPaths() -> [String] {
        let shell = userLoginShell()
        // `-i -l` sources the full chain (.zshenv, /etc/zprofile's path_helper, .zshrc), which is
        // the only way to see entries added by an interactive rc. Fall back to `-l` alone if the
        // interactive pass fails or hangs — some rc files misbehave without a tty.
        for arguments in [["-i", "-l", "-c", pathProbeScript], ["-l", "-c", pathProbeScript]] {
            if let output = runProbe(shell, arguments),
               let path = parseProbeOutput(output) {
                let paths = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                if !paths.isEmpty { return paths }
            }
        }
        return []
    }

    static func parseProbeOutput(_ output: String) -> String? {
        // rc files chatter on stdout, so the value is fenced by markers rather than assumed to be
        // the whole output.
        guard let start = output.range(of: probeBeginMarker),
              let end = output.range(of: probeEndMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        return value.isEmpty ? nil : value
    }

    private static func runProbe(_ shell: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        // TERM=dumb keeps rc files from emitting escape sequences; the rest of the environment is
        // left intact so ZDOTDIR and friends still apply.
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }

        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let reader = AsyncPipeReader(output)
        reader.start()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return String(data: reader.data(), encoding: .utf8)
    }
}

private let probeBeginMarker = "__PMM_PATH_BEGIN__"
private let probeEndMarker = "__PMM_PATH_END__"
private let pathProbeScript = #"printf '\n__PMM_PATH_BEGIN__%s__PMM_PATH_END__\n' "$PATH""#
