import Darwin
import Foundation

/// Resolves the PATH the user actually has in their shell.
///
/// A Finder-launched app inherits launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not the one
/// built up by `.zshenv`/`/etc/zprofile`/`.zshrc`. That hides every tool installed outside those
/// directories — `~/.cargo/bin` most notably — so package scans silently come back empty.
///
/// Resolution runs the login shell once and caches the result. Call ``prime()`` at launch, then
/// ``searchPaths()`` from a background thread or ``cachedSearchPaths()`` from the main one.
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
    ///
    /// Deliberately carries no deadline of its own. Every probe is individually bounded and the
    /// resolver always publishes a result, so a second deadline here could only abandon a probe
    /// that was about to succeed and hand back a truncated PATH — which is exactly the bug this
    /// type exists to fix.
    public func searchPaths() -> [String] {
        prime()
        condition.lock()
        defer { condition.unlock() }
        while resolved == nil { condition.wait() }
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

    /// How a shell wants to be asked for its PATH.
    ///
    /// Bourne flags and Bourne syntax are both non-universal. macOS ships `/bin/csh` and
    /// `/bin/tcsh` as valid login shells and both exit 1 on `-l -c`. fish, nushell, and elvish take
    /// the flags but do not expand `$PATH` inside a double-quoted string the way sh does — fish
    /// because `PATH` is a list, nushell and elvish because their string literals do not
    /// interpolate at all.
    enum ProbeDialect {
        case bourne
        case csh
        case fish
        case nushell
        case elvish
    }

    static func probeDialect(forShell shell: String) -> ProbeDialect {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "csh", "tcsh": .csh
        case "fish": .fish
        case "nu": .nushell
        case "elvish": .elvish
        default: .bourne
        }
    }

    /// The argument lists to try for a dialect, most complete first.
    static func probeInvocations(for dialect: ProbeDialect) -> [[String]] {
        switch dialect {
        case .bourne:
            // `-i -l` sources the full chain (.zshenv, /etc/zprofile's path_helper, .zshrc), which
            // is the only way to see entries added by an interactive rc. Fall back to `-l` alone if
            // the interactive pass fails or hangs — some rc files misbehave without a tty.
            [["-i", "-l", "-c", pathProbeScript], ["-l", "-c", pathProbeScript]]
        case .csh:
            // csh and tcsh accept `-l` only as the sole flag, so a login shell cannot also run a
            // command. `-c` still sources `~/.cshrc`/`~/.tcshrc`, which is where csh users set
            // `path` precisely so non-login shells inherit it. `$PATH` is the colon-joined
            // environment variable in csh too, so the Bourne script works verbatim.
            [["-c", pathProbeScript]]
        case .fish:
            [["-i", "-l", "-c", fishPathProbeScript], ["-l", "-c", fishPathProbeScript]]
        case .nushell:
            [["-i", "-l", "-c", nushellPathProbeScript], ["-l", "-c", nushellPathProbeScript]]
        case .elvish:
            [["-l", "-c", elvishPathProbeScript], ["-c", elvishPathProbeScript]]
        }
    }

    static func loginShellSearchPaths() -> [String] {
        searchPaths(forShell: userLoginShell())
    }

    static func searchPaths(forShell shell: String) -> [String] {
        for arguments in probeInvocations(for: probeDialect(forShell: shell)) {
            if let output = runProbe(shell, arguments),
               let path = parseProbeOutput(output) {
                let paths = searchPaths(fromProbeValue: path)
                if !paths.isEmpty { return paths }
            }
        }
        return []
    }

    /// Absolute directories only.
    ///
    /// A shell with no dialect of its own still gets the Bourne script, and one that does not
    /// interpolate `$PATH` inside double quotes prints the two literal characters back — verified
    /// against nushell and elvish, which both exit 0 having emitted `$PATH`. That parses as a
    /// perfectly good non-empty value, so without this filter the probe "succeeds" holding one
    /// nonsense entry and never falls through to the next invocation or the static fallbacks.
    /// Relative entries go the same way: they resolve against a working directory this app has no
    /// business guessing.
    static func searchPaths(fromProbeValue value: String) -> [String] {
        value.split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
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

    static func runProbe(_ shell: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        // The probe collects output in a temporary file rather than a pipe. An rc file can start a
        // background process that inherits stdout; the shell then exits while that grandchild keeps
        // the write end open, and a pipe read would block forever on an EOF that never comes. A
        // regular file is readable the moment we stop waiting, no matter who else still holds it.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmm-path-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: outputURL)
        else { return nil }
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        // TERM=dumb keeps rc files from emitting escape sequences; the rest of the environment is
        // left intact so ZDOTDIR and friends still apply.
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL)
        else { return nil }
        // Lenient decoding: an rc file that emits a stray non-UTF-8 byte must not cost us the PATH.
        return String(decoding: data, as: UTF8.self)
    }
}

private let terminationGrace: TimeInterval = 2
private let probeBeginMarker = "__PMM_PATH_BEGIN__"
private let probeEndMarker = "__PMM_PATH_END__"
private let pathProbeScript = #"printf '\n__PMM_PATH_BEGIN__%s__PMM_PATH_END__\n' "$PATH""#
/// fish keeps `PATH` as a list, so `"$PATH"` would come back space-separated.
private let fishPathProbeScript =
    #"printf '\n__PMM_PATH_BEGIN__%s__PMM_PATH_END__\n' (string join : $PATH)"#
/// nushell keeps `PATH` as a list and does not interpolate in ordinary string literals, so both the
/// join and the fence have to be built explicitly.
private let nushellPathProbeScript =
    #"print ("__PMM_PATH_BEGIN__" + ($env.PATH | str join ":") + "__PMM_PATH_END__")"#
/// elvish exposes the raw colon-joined variable as `$E:PATH`; `$PATH` is its own list type.
private let elvishPathProbeScript =
    #"print "__PMM_PATH_BEGIN__"$E:PATH"__PMM_PATH_END__"; print "\n""#
