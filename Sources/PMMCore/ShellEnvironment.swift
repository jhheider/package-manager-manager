import Darwin
import Foundation

/// Resolves the exported environment the user actually has in their shell.
///
/// A Finder-launched app inherits launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not the one
/// built up by `.zshenv`/`/etc/zprofile`/`.zshrc`. That hides every tool installed outside those
/// directories — `~/.cargo/bin` most notably — and misses configuration such as
/// `CARGO_INSTALL_ROOT`, so package scans silently come back empty.
///
/// Resolution runs the login shell once and caches the result. Call ``prime()`` at launch, then
/// ``environment()`` from a background thread or ``cachedEnvironment()`` from the main one.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    /// The resolver runs here rather than on `DispatchQueue.global`.
    ///
    /// A blocked worker on a global queue is not replaced past the pool's limit, and the callers of
    /// ``searchPaths()`` block. Running the resolver on the same pool it can fill therefore risks
    /// the one arrangement this type must never reach: every waiter parked, and no thread left for
    /// the work they are waiting on. A private queue always gets its own thread, so the resolver
    /// cannot be starved by its own waiters.
    private static let queue = DispatchQueue(label: "dev.mxcl.pmm.shell-environment")

    /// How long a failed probe is allowed to stand before another attempt is worth making.
    ///
    /// Not zero: a probe runs the user's rc files, and retrying on every lookup would re-run their
    /// side effects. Not forever either — see ``prime()``.
    public static let retryInterval: TimeInterval = 60

    private let condition = NSCondition()
    private let resolver: @Sendable () -> [String: String]
    private var resolved: [String: String]?
    private var isResolving = false
    private var failedAt: Date?
    private var waiters: [CheckedContinuation<[String: String], Never>] = []

    init(resolver: @escaping @Sendable () -> [String: String] = { ShellEnvironment.loginShellEnvironment() }) {
        self.resolver = resolver
    }

    /// Kicks off resolution on a background queue. Cheap, idempotent, safe from the main thread.
    ///
    /// A probe that came back with nothing is retried later. Caching that answer for the life of
    /// the process is how one bad moment — a network home not mounted yet at login, an rc file that
    /// overran its timeout once, rustup installed while the app was already open — turns into an
    /// inventory that stays wrong until the user thinks to quit and relaunch. A success is final;
    /// only failure is reconsidered, and no more often than ``retryInterval``.
    public func prime(retryAfter: TimeInterval = ShellEnvironment.retryInterval) {
        condition.lock()
        guard !isResolving, shouldAttemptLocked(retryAfter: retryAfter) else {
            condition.unlock()
            return
        }
        isResolving = true
        condition.unlock()

        Self.queue.async {
            let environment = self.resolver()
            self.condition.lock()
            self.resolved = environment
            self.failedAt = Self.searchPaths(in: environment).isEmpty ? Date() : nil
            self.isResolving = false
            let waiters = self.waiters
            self.waiters = []
            self.condition.broadcast()
            self.condition.unlock()
            for waiter in waiters { waiter.resume(returning: environment) }
        }
    }

    /// Caller must hold the lock.
    private func shouldAttemptLocked(retryAfter: TimeInterval) -> Bool {
        guard let resolved else { return true }
        guard Self.searchPaths(in: resolved).isEmpty, let failedAt else { return false }
        return Date().timeIntervalSince(failedAt) >= retryAfter
    }

    /// Whatever has been resolved so far, without waiting. Empty until resolution finishes.
    public func cachedEnvironment() -> [String: String] {
        condition.lock()
        defer { condition.unlock() }
        return resolved ?? [:]
    }

    public func cachedSearchPaths() -> [String] { Self.searchPaths(in: cachedEnvironment()) }

    /// Awaits resolution without blocking the calling thread, so callers do not have to know that
    /// probing the shell blocks. Returns straight away once resolution has happened.
    ///
    /// Parks a continuation rather than a thread: the obvious version dispatches ``searchPaths()``
    /// onto a queue and blocks there, which costs one worker per concurrent caller for the whole
    /// probe. Every scan calls this, so those add up against exactly the pool the resolver needs.
    public func resolvedEnvironment() async -> [String: String] {
        prime()
        return await withCheckedContinuation { continuation in
            condition.lock()
            // A retry in flight is worth waiting for: taking the cached failure would hand this
            // scan the same empty PATH that the retry exists to replace.
            if let resolved, !isResolving {
                condition.unlock()
                continuation.resume(returning: resolved)
                return
            }
            waiters.append(continuation)
            condition.unlock()
        }
    }

    public func resolvedSearchPaths() async -> [String] {
        Self.searchPaths(in: await resolvedEnvironment())
    }

    /// Blocks until the shell PATH is resolved. Never call this from the main thread.
    ///
    /// Deliberately carries no deadline of its own. Every probe is individually bounded and the
    /// resolver always publishes a result, so a second deadline here could only abandon a probe
    /// that was about to succeed and hand back a truncated PATH — which is exactly the bug this
    /// type exists to fix.
    public func environment(retryAfter: TimeInterval = ShellEnvironment.retryInterval) -> [String: String] {
        prime(retryAfter: retryAfter)
        condition.lock()
        defer { condition.unlock() }
        while resolved == nil || isResolving { condition.wait() }
        return resolved ?? [:]
    }

    public func searchPaths(retryAfter: TimeInterval = ShellEnvironment.retryInterval) -> [String] {
        Self.searchPaths(in: environment(retryAfter: retryAfter))
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

    /// How a shell wants to be asked for its exported environment.
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

    /// A single way to ask a shell for its PATH.
    struct ProbeInvocation: Equatable {
        let arguments: [String]
        /// The script, when it has to be fed on stdin because the shell cannot take one as a flag.
        let input: String?

        init(_ arguments: [String], input: String? = nil) {
            self.arguments = arguments
            self.input = input
        }
    }

    /// The invocations to try for a dialect, most complete first.
    static func probeInvocations(for dialect: ProbeDialect) -> [ProbeInvocation] {
        switch dialect {
        case .bourne:
            // `-i -l` sources the full chain (.zshenv, /etc/zprofile's path_helper, .zshrc), which
            // is the only way to see entries added by an interactive rc. Fall back to `-l` alone if
            // the interactive pass fails or hangs — some rc files misbehave without a tty.
            [ProbeInvocation(["-i", "-l", "-c", environmentProbeScript]), ProbeInvocation(["-l", "-c", environmentProbeScript])]
        case .csh:
            // csh and tcsh accept `-l` only as the sole flag, so the script cannot ride along as
            // `-c` and goes on stdin instead. That is not only about flag syntax: `-c` reads
            // `.cshrc`/`.tcshrc` but never `/etc/csh.login` or `~/.login`, so a PATH entry added
            // only at login would be invisible. `$PATH` is the colon-joined environment variable in
            // csh too, so the Bourne script works verbatim. `-c` stays as the fallback, since an
            // rc-file PATH beats no PATH if the login shell itself fails.
            [
                ProbeInvocation(["-l"], input: environmentProbeScript + "\n"),
                ProbeInvocation(["-c", environmentProbeScript]),
            ]
        case .fish:
            [
                ProbeInvocation(["-i", "-l", "-c", environmentProbeScript]),
                ProbeInvocation(["-l", "-c", environmentProbeScript]),
            ]
        case .nushell:
            [
                ProbeInvocation(["-i", "-l", "-c", nushellEnvironmentProbeScript]),
                ProbeInvocation(["-l", "-c", nushellEnvironmentProbeScript]),
            ]
        case .elvish:
            [
                ProbeInvocation(["-l", "-c", elvishEnvironmentProbeScript]),
                ProbeInvocation(["-c", elvishEnvironmentProbeScript]),
            ]
        }
    }

    static func loginShellEnvironment() -> [String: String] {
        environment(forShell: userLoginShell())
    }

    static func environment(
        forShell shell: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        for invocation in probeInvocations(for: probeDialect(forShell: shell)) {
            if let output = runProbe(shell, invocation, environment: environment),
               let resolved = parseProbeOutput(output),
               !searchPaths(in: resolved).isEmpty {
                return resolved
            }
        }
        return [:]
    }

    static func searchPaths(
        forShell shell: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        searchPaths(in: self.environment(forShell: shell, environment: environment))
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

    static func searchPaths(in environment: [String: String]) -> [String] {
        environment["PATH"].map(searchPaths(fromProbeValue:)) ?? []
    }

    static func parseProbeOutput(_ output: String) -> [String: String]? {
        // rc files chatter on stdout, so the value is fenced by markers rather than assumed to be
        // the whole output.
        guard let start = output.range(of: probeBeginMarker),
              let end = output.range(of: probeEndMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = output[start.upperBound..<end.lowerBound]
        var environment: [String: String] = [:]
        for entry in value.split(separator: "\0") {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<separator])
            guard !name.isEmpty,
                  !ignoredEnvironmentVariables.contains(name),
                  !name.hasPrefix("BASH_FUNC_")
            else { continue }
            environment[name] = String(entry[entry.index(after: separator)...])
        }
        return environment.isEmpty ? nil : environment
    }

    static func runProbe(
        _ shell: String,
        _ invocation: ProbeInvocation,
        timeout: TimeInterval = 5,
        terminationGrace: TimeInterval = 2,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        // A real TERM, emphatically not `dumb`. `[[ "$TERM" == "dumb" ]] && return` is the standard
        // Emacs TRAMP guard and sits near the top of a great many real `.zshrc` files, above the
        // nvm/pyenv/asdf/mise block. Forcing `dumb` tripped it: the shell returned early, exited 0,
        // and handed back a PATH that was absolute, non-empty, and missing precisely the entries
        // this type exists to find — which the chain then accepted and cached. Escape sequences in
        // the output were the reason for `dumb`, and they cost nothing here: the value is fenced by
        // markers, so chatter around it is already ignored.
        let probeEnvironment = environment.merging(["TERM": "xterm-256color"]) { _, new in new }
        return ProcessExecution.runBounded(
            shell,
            invocation.arguments,
            input: invocation.input,
            timeout: timeout,
            terminationGrace: terminationGrace,
            environment: probeEnvironment,
            requiredOutputMarker: probeBeginMarker
        )
    }
}
private let probeBeginMarker = "__PMM_ENV_BEGIN__"
private let probeEndMarker = "__PMM_ENV_END__"
private let environmentProbeScript =
    #"printf '\n__PMM_ENV_BEGIN__'; /usr/bin/env -0; printf '__PMM_ENV_END__\n'"#
private let nushellEnvironmentProbeScript =
    #"print -n '__PMM_ENV_BEGIN__'; ^/usr/bin/env -0; print -n '__PMM_ENV_END__'"#
private let elvishEnvironmentProbeScript =
    #"print -n '__PMM_ENV_BEGIN__'; /usr/bin/env -0; print -n '__PMM_ENV_END__'"#
private let ignoredEnvironmentVariables: Set<String> = ["TERM", "PWD", "OLDPWD", "SHLVL", "_"]
