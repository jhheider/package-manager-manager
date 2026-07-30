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

@Test func probeInvocationsAvoidBourneFlagsForCShells() {
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/tcsh") == .csh)
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/csh") == .csh)

    let invocations = ShellEnvironment.probeInvocations(for: .csh)
    #expect(!invocations.isEmpty)
    // csh and tcsh exit 1 on any `-l` that is not the only flag, so the PATH would never resolve.
    #expect(invocations.allSatisfy { !$0.contains("-l") && !$0.contains("-i") })
    #expect(invocations.allSatisfy { $0.contains("-c") })
}

@Test func probeInvocationsUseLoginFlagsForBourneShells() {
    #expect(ShellEnvironment.probeDialect(forShell: "/bin/zsh") == .bourne)
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/bash") == .bourne)
    #expect(ShellEnvironment.probeInvocations(for: .bourne).first?.prefix(2) == ["-i", "-l"])
}

@Test func probeInvocationsBuildTheFenceForShellsWithoutStringInterpolation() {
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/nu") == .nushell)
    #expect(ShellEnvironment.probeDialect(forShell: "/usr/local/bin/elvish") == .elvish)
    // Neither expands `$PATH` inside a string literal, so the Bourne script comes back holding the
    // two literal characters and both keep PATH as a list that has to be joined.
    #expect(ShellEnvironment.probeInvocations(for: .nushell).allSatisfy { $0.last?.contains("str join") == true })
    #expect(ShellEnvironment.probeInvocations(for: .elvish).allSatisfy { $0.last?.contains("$E:PATH") == true })
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

// Every other dialect test is pure string work, so it runs anywhere. This one spawns a real shell,
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

@Test func probeInvocationsJoinTheFishPathList() {
    #expect(ShellEnvironment.probeDialect(forShell: "/opt/homebrew/bin/fish") == .fish)
    // `"$PATH"` is space-separated in fish, so the script has to join the list itself.
    #expect(ShellEnvironment.probeInvocations(for: .fish).allSatisfy { $0.last?.contains("string join") == true })
}

@Test func runProbeReturnsWhenABackgroundProcessInheritsStdout() {
    // An rc file can leave a grandchild holding stdout open. Reading a pipe would block on an EOF
    // that only arrives when that grandchild exits; the probe must not wait for it.
    let started = Date()
    let output = ShellEnvironment.runProbe(
        "/bin/sh",
        ["-c", "sleep 20 & printf '\\n__PMM_PATH_BEGIN__/a/bin__PMM_PATH_END__\\n'"]
    )

    #expect(Date().timeIntervalSince(started) < 10)
    #expect(output.flatMap(ShellEnvironment.parseProbeOutput) == "/a/bin")
}

@Test func runProbeGivesUpOnAShellThatNeverExits() {
    let started = Date()
    #expect(ShellEnvironment.runProbe("/bin/sh", ["-c", "sleep 30"], timeout: 1) == nil)
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
