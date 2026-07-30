import Foundation
import Testing
@testable import PMMCore

@Test func commandPathPreservesPathOrderAndAppendsFallbacks() {
    #expect(
        commandPath(inherited: "/custom/bin:/usr/bin", shell: [], home: [])
            == "/custom/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
    )
}

@Test func commandPathUsesFallbacksWhenPathIsMissing() {
    #expect(commandPath(inherited: nil, shell: [], home: []) == "/usr/local/bin:/opt/homebrew/bin")
}

@Test func commandPathPutsTheShellPathAheadOfTheInheritedOne() {
    // A Finder launch inherits launchd's PATH, which must not outrank the user's own shims.
    #expect(
        commandPath(inherited: "/usr/bin", shell: ["/shim/bin"], home: ["/home/bin"])
            == "/shim/bin:/usr/bin:/home/bin:/usr/local/bin:/opt/homebrew/bin"
    )
}

@Test func commandPathKeepsAnExplicitlyRequestedPathFirst() {
    #expect(
        commandPath(leading: "/custom/bin", inherited: "/usr/bin", shell: ["/shim/bin"], home: [])
            == "/custom/bin:/shim/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
    )
}

@Test func commandPathDropsDuplicatesKeepingTheEarliestOccurrence() {
    #expect(
        commandPath(inherited: "/custom/bin:/usr/local/bin", shell: ["/custom/bin"], home: ["/extra/bin"])
            == "/custom/bin:/usr/local/bin:/extra/bin:/opt/homebrew/bin"
    )
}

@Test func homeCommandPathsCoverCargoAndLocalBin() {
    let paths = homeCommandPaths(environment: [:], home: URL(fileURLWithPath: "/Users/example"))
    #expect(paths == ["/Users/example/.cargo/bin", "/Users/example/.local/bin"])
}

@Test func homeCommandPathsHonorCargoHome() {
    let paths = homeCommandPaths(
        environment: ["CARGO_HOME": "/opt/cargo"],
        home: URL(fileURLWithPath: "/Users/example")
    )
    #expect(paths.first == "/opt/cargo/bin")
}

@Test func systemCommandRunnerAppendsFallbacksToChildPath() throws {
    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "printf %s \"$PATH\""],
        options: CommandRunOptions(environment: ["PATH": "/custom/bin"])
    )
    let parts = result.stdout.split(separator: ":").map(String.init)

    #expect(parts.first == "/custom/bin")
    #expect(parts.contains("/usr/local/bin"))
    #expect(parts.contains("/opt/homebrew/bin"))
    #expect(parts.count == Set(parts).count)
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ value: String) {
        lock.lock()
        text += value
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

@Test func systemCommandRunnerDrainsLargeOutputWhileProcessRuns() throws {
    let result = try SystemCommandRunner().run("/bin/sh", ["-c", "yes x | head -c 200000"])

    #expect(result.status == 0)
    #expect(result.stdout.count == 200_000)
}

@Test func systemCommandRunnerTerminalModeStreamsTTYOutput() throws {
    let streamed = StringRecorder()

    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "test -t 1 && printf tty || printf pipe"],
        options: CommandRunOptions(terminal: true)
    ) { output in
        streamed.append(output)
    }

    #expect(result.status == 0)
    #expect(result.stdout == "tty")
    #expect(streamed.value == "tty")
}

@Test func systemCommandRunnerTerminalModeReportsEightyColumns() throws {
    let result = try SystemCommandRunner().run(
        "/usr/bin/python3",
        ["-c", "import fcntl, struct, sys, termios; print(*struct.unpack('hhhh', fcntl.ioctl(1, termios.TIOCGWINSZ, b'\\0' * 8))[:2]); print(__import__('os').environ['COLUMNS'], __import__('os').environ['LINES'])"],
        options: CommandRunOptions(terminal: true)
    )

    let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    #expect(lines == ["24 80", "80 24"])
}

@Test func streamingUTF8DecoderPreservesScalarsSplitAcrossChunks() {
    var decoder = IncrementalUTF8Decoder()

    #expect(decoder.decode(Data([0xE2])) == "")
    #expect(decoder.decode(Data([0x9C])) == "")
    #expect(decoder.decode(Data([0x94, 0x20, 0xF0, 0x9F])) == "✔ ")
    #expect(decoder.decode(Data([0x9A, 0x80])) == "🚀")
    #expect(decoder.finish() == "")
}

@Test func aQueryThatStopsProducingOutputIsAbandonedWithItsWholeTree() throws {
    // The stall this catches: cargo-update polling a registry that never answers, a tool waiting on
    // a lock another terminal holds. Before, the refresh spinner simply never resolved.
    let childSentinel = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-query-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: childSentinel) }
    let started = Date()

    #expect(throws: CommandRunError.self) {
        try SystemCommandRunner().run(
            "/bin/sh",
            ["-c", "/bin/sh -c 'sleep 3; touch \(childSentinel.path)' & sleep 3"],
            options: CommandRunOptions(inactivityTimeout: 0.5)
        )
    }

    #expect(Date().timeIntervalSince(started) < 3, "it gave up rather than waiting the command out")
    Thread.sleep(forTimeInterval: 3.5)
    // Killing the shell alone would leave cargo's fetches and its rustc children running.
    #expect(!FileManager.default.fileExists(atPath: childSentinel.path), "its children went too")
}

@Test func aQueryStillPrintingIsNotAbandoned() throws {
    // Inactivity, not elapsed time. This runs well past the limit while still producing output.
    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "for i in 1 2 3 4 5 6; do printf 'working\\n'; sleep 0.2; done; printf done"],
        options: CommandRunOptions(inactivityTimeout: 0.5)
    )

    #expect(result.status == 0)
    #expect(result.stdout.hasSuffix("done"))
}

@Test func queryTimeoutsAreOptInSoQuietWorkIsNotKilled() {
    // Defaulting this on armed a silence budget for everything on the non-terminal path, SSH to a
    // remote host included. A remote inventory prints only its final JSON, so a slow one was killed
    // at two minutes and reported as "stopped responding" while that machine was still working.
    #expect(CommandRunOptions().inactivityTimeout == nil)
    #expect(CommandRunOptions(streamsStandardOutput: false).inactivityTimeout == nil, "the remote shape")
    #expect(CommandRunOptions(terminal: true).inactivityTimeout == nil)
}

@Test func aUserInitiatedActionIsNeverAbandonedForGoingQuiet() throws {
    // A linker can be silent for minutes. Killing a compile the user asked for, because it stopped
    // narrating, would be its own bug — those stop when the user says so.
    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "sleep 1; printf quiet"],
        options: CommandRunOptions(terminal: true, inactivityTimeout: 0.2)
    )

    #expect(result.status == 0)
    #expect(result.stdout.contains("quiet"))
}

// Time-limited on purpose: without the fix the reader is never scheduled and `data()` waits
// forever, so a regression would hang the suite rather than fail it.
@Test(.timeLimit(.minutes(1)))
func terminalOutputSurvivesASaturatedThreadPool() throws {
    // The reader used to be dispatched to a pooled queue *after* the child started. With the pool
    // busy it could sit unscheduled until the subprocess had exited — and once a pty's last slave
    // descriptor closes, whatever is still unread on the master is discarded. Gone, not delayed:
    // for an install, a progress sheet that never showed a line.
    let blockers = DispatchGroup()
    let release = DispatchSemaphore(value: 0)
    for _ in 0..<64 {
        DispatchQueue.global(qos: .utility).async(group: blockers) { release.wait() }
    }
    defer { for _ in 0..<64 { release.signal() } }
    Thread.sleep(forTimeInterval: 0.1)

    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "printf tty"],
        options: CommandRunOptions(terminal: true)
    )

    #expect(result.stdout == "tty")
}

// Time-limited because the regression is a hang, not a wrong answer.
@Test(.timeLimit(.minutes(1)))
func aDescendantHoldingThePipesDoesNotStallTheCall() throws {
    // The watchdog stopped once the leader exited, and `data()` then waited on an EOF the surviving
    // child would never send. `sh -c 'sleep 30 &'` returns instantly and used to hang the call for
    // the child's whole lifetime, inactivity budget or not.
    let started = Date()

    let result = try SystemCommandRunner().run(
        "/bin/sh",
        ["-c", "sleep 30 & printf done"],
        options: CommandRunOptions(inactivityTimeout: 0.5)
    )

    #expect(result.stdout.contains("done"), "what the command did produce still counts")
    #expect(result.status == 0)
    #expect(Date().timeIntervalSince(started) < 10, "it did not wait out the straggler")
}
