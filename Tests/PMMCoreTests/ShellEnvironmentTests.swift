import Foundation
import Testing
@testable import PMMCore

@Test func parseProbeOutputExtractsTheFencedValue() {
    let output = "some rc chatter\n__PMM_PATH_BEGIN__/a/bin:/b/bin__PMM_PATH_END__\n"
    #expect(ShellEnvironment.parseProbeOutput(output) == "/a/bin:/b/bin")
}

@Test func parseProbeOutputIgnoresUnfencedOutput() {
    #expect(ShellEnvironment.parseProbeOutput("/a/bin:/b/bin") == nil)
    #expect(ShellEnvironment.parseProbeOutput("") == nil)
}

@Test func parseProbeOutputRejectsAnEmptyValue() {
    #expect(ShellEnvironment.parseProbeOutput("__PMM_PATH_BEGIN____PMM_PATH_END__") == nil)
}

@Test func userLoginShellIsExecutable() {
    #expect(FileManager.default.isExecutableFile(atPath: ShellEnvironment.userLoginShell()))
}

@Test func searchPathsCachesTheResolverResult() {
    let counter = CallCounter()
    let environment = ShellEnvironment {
        counter.increment()
        return ["/resolved/bin"]
    }

    #expect(environment.searchPaths() == ["/resolved/bin"])
    #expect(environment.searchPaths() == ["/resolved/bin"])
    #expect(environment.cachedSearchPaths() == ["/resolved/bin"])
    #expect(counter.value == 1)
}

@Test func cachedSearchPathsIsEmptyBeforeResolution() {
    let environment = ShellEnvironment { ["/resolved/bin"] }
    #expect(environment.cachedSearchPaths().isEmpty)
}

@Test func probeInvocationsAskCShellsToLogInWithTheScriptOnStdin() {
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/tcsh") == .csh)
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/csh") == .csh)

    let invocations = ShellEnvironment.probeInvocations(for: .csh)
    // `-l` alone, because csh and tcsh exit 1 on any `-l` combined with another flag — so the
    // script cannot ride along as `-c` and has to arrive on stdin.
    #expect(invocations.first?.arguments == ["-l"])
    #expect(invocations.first?.input?.contains("__PMM_PATH_BEGIN__") == true)
    // `-c` stays behind it: an rc-file PATH beats no PATH if the login shell itself fails.
    #expect(invocations.last?.arguments.contains("-c") == true)
    #expect(invocations.last?.input == nil)
}

@Test func probeInvocationsUseLoginFlagsForBourneShells() {
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/zsh") == .bourne)
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/bash") == .bourne)
    #expect(ShellEnvironment.probeInvocations(for: .bourne).first?.arguments.prefix(2) == ["-i", "-l"])
}

@Test func probeInvocationsBuildTheFenceForShellsWithoutStringInterpolation() {
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/nu") == .nushell)
    #expect(ShellEnvironment.probeDialect(forShell: "/usr/local/bin/elvish") == .elvish)
    // Neither expands `$PATH` inside a string literal, so the Bourne script comes back holding the
    // two literal characters and both keep PATH as a list that has to be joined.
    #expect(ShellEnvironment.probeInvocations(for: .nushell).allSatisfy { $0.arguments.last?.contains("str join") == true })
    #expect(ShellEnvironment.probeInvocations(for: .elvish).allSatisfy { $0.arguments.last?.contains("$E:PATH") == true })
}

@Test func searchPathsKeepOnlyAbsoluteDirectories() {
    // The exact output nushell and elvish produce for the Bourne script: non-empty, parseable, and
    // nonsense. Accepting it would stop the fallback invocations from ever running.
    #expect(ShellEnvironment.searchPaths(fromProbeValue: "$PATH").isEmpty)
    #expect(ShellEnvironment.searchPaths(fromProbeValue: ".:..:relative/bin").isEmpty)
    #expect(
        ShellEnvironment.searchPaths(fromProbeValue: "/usr/bin::.:/opt/homebrew/bin")
            == ["/usr/bin", "/opt/homebrew/bin"]
    )
}

// Every other dialect test is pure string work, so it runs anywhere. These two spawn a real shell,
// and `#require` would fail rather than skip where that shell is absent — hence the trait.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh")))
func searchPathsResolveThroughARealCShell() {
    // macOS ships tcsh as a registered login shell, so the csh dialect can be exercised for real
    // rather than only asserted about.
    let paths = ShellEnvironment.searchPaths(forShell: "/bin/tcsh")

    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasPrefix("/") })
    #expect(paths.contains("/usr/bin"))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh")))
func cshProbeSeesPathEntriesOnlyTheLoginFilesAdd() throws {
    // The regression this guards: `-c` sources `.cshrc` but never `~/.login`, so a PATH entry added
    // at login was invisible. Each file adds a different directory, and both have to come back.
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-csh-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try "set path = ( /tmp/pmm-login-only $path )\n"
        .write(to: home.appendingPathComponent(".login"), atomically: true, encoding: .utf8)
    try "set path = ( /tmp/pmm-cshrc-only $path )\n"
        .write(to: home.appendingPathComponent(".cshrc"), atomically: true, encoding: .utf8)

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    let paths = ShellEnvironment.searchPaths(forShell: "/bin/tcsh", environment: environment)

    #expect(paths.contains("/tmp/pmm-login-only"))
    #expect(paths.contains("/tmp/pmm-cshrc-only"))
}

@Test func probeInvocationsJoinTheFishPathList() {
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/fish") == .fish)
    // `"$PATH"` is space-separated in fish, so the script has to join the list itself.
    #expect(ShellEnvironment.probeInvocations(for: .fish).allSatisfy { $0.arguments.last?.contains("string join") == true })
}

@Test func runProbeReturnsWhenABackgroundProcessInheritsStdout() {
    // An rc file can leave a grandchild holding stdout open. Reading a pipe would block on an EOF
    // that only arrives when that grandchild exits; the probe must not wait for it.
    let started = Date()
    let output = ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", "sleep 20 & printf '\\n__PMM_PATH_BEGIN__/a/bin__PMM_PATH_END__\\n'"])
    )

    #expect(Date().timeIntervalSince(started) < 10)
    #expect(output.flatMap(ShellEnvironment.parseProbeOutput) == "/a/bin")
}

@Test func runProbeGivesUpOnAShellThatNeverExits() {
    let started = Date()
    #expect(ShellEnvironment.runProbe("/bin/sh", .init(["-c", "sleep 30"]), timeout: 1) == nil)
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func loginShellSearchPathsFindsRealToolDirectories() {
    // The probe has to survive whatever is in the user's rc files, so assert on the shape of the
    // result rather than on specific entries.
    let paths = ShellEnvironment.loginShellSearchPaths()
    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasPrefix("/") })
    #expect(paths.contains("/usr/bin"))
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Writes an executable stand-in shell that answers the probe however the test needs.
///
/// The name matters: anything outside the known dialects resolves to `.bourne`, which is the
/// two-invocation list the fallthrough tests need.
private func fakeShell(_ body: String) throws -> (path: String, remove: () -> Void) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-fakeshell-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let script = url.appendingPathComponent("fakeshell")
    try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script.path, { try? FileManager.default.removeItem(at: url) })
}

@Test func probeFallsThroughWhenTheFirstInvocationFails() throws {
    // The interactive pass is the one rc files misbehave in. Nothing tested that its failure
    // actually reached the second invocation rather than ending the chain.
    let shell = try fakeShell("""
    for a in "$@"; do
      if [ "$a" = "-i" ]; then exit 1; fi
    done
    printf '\\n__PMM_PATH_BEGIN__/second/bin__PMM_PATH_END__\\n'
    """)
    defer { shell.remove() }

    #expect(ShellEnvironment.searchPaths(forShell: shell.path) == ["/second/bin"])
}

@Test func probeFallsThroughWhenTheFirstInvocationSucceedsWithNonsense() throws {
    // nushell and elvish exit 0 having printed the literal characters `$PATH`. That parses, so
    // without the absolute-path filter the chain stops here holding one nonsense entry.
    let shell = try fakeShell("""
    for a in "$@"; do
      if [ "$a" = "-i" ]; then printf '\\n__PMM_PATH_BEGIN__$PATH__PMM_PATH_END__\\n'; exit 0; fi
    done
    printf '\\n__PMM_PATH_BEGIN__/second/bin__PMM_PATH_END__\\n'
    """)
    defer { shell.remove() }

    #expect(ShellEnvironment.searchPaths(forShell: shell.path) == ["/second/bin"])
}

@Test func probeGivesUpWhenEveryInvocationIsUseless() throws {
    // Nothing absolute anywhere means the static fallbacks have to take over, so this must be
    // empty rather than a list of junk the caller would put on a PATH.
    let shell = try fakeShell(#"printf '\n__PMM_PATH_BEGIN__$PATH:relative/bin__PMM_PATH_END__\n'"#)
    defer { shell.remove() }

    #expect(ShellEnvironment.searchPaths(forShell: shell.path).isEmpty)
}

@Test func runProbeRejectsOutputFromAFailedShell() {
    // A shell that printed a perfectly good fence and then exited non-zero did not finish its rc
    // chain, so its PATH is not one to trust.
    #expect(ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", "printf '\\n__PMM_PATH_BEGIN__/a/bin__PMM_PATH_END__\\n'; exit 3"])
    ) == nil)
}

@Test func runProbeSurvivesRcChatterThatIsNotUTF8() {
    // A prompt or rc file emitting Latin-1 under a non-UTF-8 locale is real. Strict decoding would
    // throw away the whole PATH over one stray byte, so the bytes go outside the fence here.
    let output = ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", #"printf 'chat\377ter\n__PMM_PATH_BEGIN__/a/bin__PMM_PATH_END__\n'"#])
    )

    #expect(output.flatMap(ShellEnvironment.parseProbeOutput) == "/a/bin")
}

@Test func runProbeKillsAShellThatIgnoresTermination() {
    // `sleep` dies on SIGTERM, so a probe that never escalates looks identical to one that does.
    // This shell refuses SIGTERM: only the SIGKILL stops it before it touches the sentinel.
    let sentinel = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-probe-sentinel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: sentinel) }

    #expect(ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", "trap '' TERM; sleep 2; touch \(sentinel.path)"]),
        timeout: 0.5,
        terminationGrace: 0.5
    ) == nil)

    Thread.sleep(forTimeInterval: 2.5)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test func concurrentCallersResolveOnceAndAllSeeTheAnswer() {
    // Sequential calls cannot pin this: the second one takes the already-resolved fast path, so the
    // in-flight guard and the broadcast are both unexercised. Every caller here is guaranteed to be
    // parked while resolution is still running, because the resolver itself blocks.
    let counter = CallCounter()
    let gate = DispatchSemaphore(value: 0)
    let environment = ShellEnvironment {
        counter.increment()
        gate.wait()
        return ["/resolved/bin"]
    }
    let results = LockedPaths()
    let group = DispatchGroup()

    // Default QoS deliberately: the resolver has a queue of its own, but piling waiters onto the
    // same pool it might have used is how this test would come to depend on the bug it guards.
    for _ in 0..<32 {
        DispatchQueue.global().async(group: group) { results.append(environment.searchPaths()) }
    }
    Thread.sleep(forTimeInterval: 0.1)
    gate.signal()

    #expect(group.wait(timeout: .now() + 10) == .success)
    #expect(counter.value == 1)
    #expect(results.values.count == 32)
    #expect(results.values.allSatisfy { $0 == ["/resolved/bin"] })
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    func append(_ value: [String]) { lock.withLock { storage.append(value) } }
    var values: [[String]] { lock.withLock { storage } }
}

@Test func aFailedProbeIsRetriedRatherThanCachedForTheSession() {
    // One bad moment — a network home not mounted yet, an rc file that overran its timeout once —
    // used to mean an empty PATH for the life of the process, and an inventory that stayed wrong
    // until the user thought to quit and relaunch.
    let attempts = CallCounter()
    let environment = ShellEnvironment {
        attempts.increment()
        return attempts.value == 1 ? [] : ["/recovered/bin"]
    }

    #expect(environment.searchPaths().isEmpty)
    #expect(environment.searchPaths(retryAfter: 0) == ["/recovered/bin"])
    #expect(attempts.value == 2)
}

@Test func aSuccessfulProbeIsNeverRepeated() {
    // The converse: success is final. Re-running the probe would re-run the user's rc files, and
    // their side effects with them.
    let attempts = CallCounter()
    let environment = ShellEnvironment {
        attempts.increment()
        return ["/resolved/bin"]
    }

    #expect(environment.searchPaths(retryAfter: 0) == ["/resolved/bin"])
    #expect(environment.searchPaths(retryAfter: 0) == ["/resolved/bin"])
    #expect(attempts.value == 1)
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
func probeSeesPathEntriesBehindTheDumbTerminalGuard() throws {
    // `[[ "$TERM" == "dumb" ]] && return` is the standard Emacs TRAMP guard, and it sits above the
    // version-manager block in a great many real .zshrc files. A probe that announces itself as a
    // dumb terminal gets a PATH that is absolute, non-empty, and missing exactly what it came for —
    // and the chain has no way to tell that from success.
    let zdotdir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-zdotdir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: zdotdir) }
    try """
    [[ "$TERM" == "dumb" ]] && return
    export PATH="/tmp/pmm-interactive-only:$PATH"
    """.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    var environment = ProcessInfo.processInfo.environment
    environment["ZDOTDIR"] = zdotdir.path
    let paths = ShellEnvironment.searchPaths(forShell: "/bin/zsh", environment: environment)

    #expect(paths.contains("/tmp/pmm-interactive-only"))
}

@Test func asyncWaitersAreNeverParkedAfterTheResolverHasDrainedThem() async {
    // The async accessor parks a continuation rather than a thread. One appended after the resolver
    // drained its list would never be resumed, and the scan awaiting it would hang for the life of
    // the app. The resolver takes long enough here that every waiter genuinely parks, and a second
    // wave arrives during a retry — the one case where a result already exists while another run is
    // still in flight. A regression shows up as this test never returning, not as a failed check.
    let attempts = CallCounter()
    let environment = ShellEnvironment {
        attempts.increment()
        Thread.sleep(forTimeInterval: 0.2)
        return attempts.value == 1 ? [] : ["/resolved/bin"]
    }

    var during: [[String]] = []
    await withTaskGroup(of: [String].self) { group in
        for _ in 0..<16 { group.addTask { await environment.resolvedSearchPaths() } }
        for await value in group { during.append(value) }
    }
    #expect(during.count == 16, "every waiter parked during the first run resumed")
    #expect(attempts.value == 1, "and they shared one probe")

    environment.prime(retryAfter: 0)
    var afterRetry: [[String]] = []
    await withTaskGroup(of: [String].self) { group in
        for _ in 0..<16 { group.addTask { await environment.resolvedSearchPaths() } }
        for await value in group { afterRetry.append(value) }
    }
    #expect(afterRetry.count == 16, "every waiter parked during the retry resumed")
    #expect(afterRetry.allSatisfy { $0 == ["/resolved/bin"] }, "and got the retry's answer")
}

@Test func runProbeKillsWhatTheShellStartedAsWellAsTheShell() {
    // The leak this closes: an rc file starts background work, the probe times out, the shell is
    // signalled — and everything it started keeps running, holding the descriptor it inherited and
    // writing into a file already unlinked. Signalling the group takes the tree.
    let shellSentinel = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-shell-\(UUID().uuidString)")
    let childSentinel = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-child-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: shellSentinel)
        try? FileManager.default.removeItem(at: childSentinel)
    }

    // The child is what an rc file's `foo &` looks like; the shell then refuses to die politely.
    #expect(ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", """
        /bin/sh -c 'sleep 2; touch \(childSentinel.path)' &
        trap '' TERM
        sleep 2
        touch \(shellSentinel.path)
        """]),
        timeout: 0.5,
        terminationGrace: 0.5
    ) == nil)

    Thread.sleep(forTimeInterval: 2.5)
    #expect(!FileManager.default.fileExists(atPath: shellSentinel.path), "the shell died")
    #expect(!FileManager.default.fileExists(atPath: childSentinel.path), "and so did what it started")
}


@Test func aSuccessfulProbeTakesItsBackgroundChildrenWithIt() {
    // The leader exiting is not the tree exiting. An rc file's `foo &` used to outlive every
    // successful probe — this suite's own background-stdout test started a `sleep 20` on each run
    // and abandoned it — still holding the descriptor it inherited and writing into a file that had
    // already been unlinked.
    let sentinel = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-success-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: sentinel) }

    let output = ShellEnvironment.runProbe(
        "/bin/sh",
        .init(["-c", "(sleep 1; touch \(sentinel.path)) & printf '\\n__PMM_PATH_BEGIN__/a/bin__PMM_PATH_END__\\n'"])
    )

    #expect(output.flatMap(ShellEnvironment.parseProbeOutput) == "/a/bin", "the probe still succeeded")
    // The cleanup lands inside its 0.25s grace, well before the child's own second is up.
    Thread.sleep(forTimeInterval: 1.3)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}
