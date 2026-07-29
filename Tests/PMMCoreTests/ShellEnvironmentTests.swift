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
