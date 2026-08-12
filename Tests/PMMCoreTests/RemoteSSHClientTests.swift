import Foundation
import Testing
@testable import PMMCore

@Test func remoteHostValidatesAndNormalizesConfiguration() throws {
    let host = try RemoteHost(name: "  Build Mac  ", destination: "  max@mac-mini  ")
    #expect(host.name == "Build Mac")
    #expect(host.destination == "max@mac-mini")
    #expect(host.displayName == "Build Mac")
    #expect(try RemoteHost(destination: "pangolin.local").displayName == "Pangolin")
    #expect(try RemoteHost(destination: "max@pangolin.local").displayName == "Max@pangolin")
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "-oProxyCommand=bad") }
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "host; touch /tmp/bad") }
}

@Test func remoteSSHArgumentsUseStrictNonInteractiveSSHAndQuoteEveryRemoteArgument() throws {
    let host = try RemoteHost(destination: "mac-mini")
    let arguments = RemoteSSHClient().sshArguments(
        for: host,
        remoteArguments: ["update", "--id", "npm:it's-a-package"]
    )
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("--"))
    #expect(arguments[arguments.count - 2] == "mac-mini")
    #expect(arguments.last?.contains("'/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl' 'remote' 'update' '--id' 'npm:it'\"'\"'s-a-package'") == true)
    #expect(arguments.last?.contains("uname -s") == true)
}

@Test func remoteLinuxInventoryFindsDNFCommandsAndExistingUserManagers() throws {
    let response = try #require(RemoteSSHClient.parseLinuxInventory(#"""
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Amazon Linux 2023	aarch64	1	dnf
    __PMM_DNF_FILES__
    bash	0:5.2-1.aarch64	-rwxr-xr-x	/usr/bin/bash
    bash	0:5.2-1.aarch64	-rw-r--r--	/usr/share/licenses/bash/COPYING
    hidden-tool	0:1.0-1.aarch64	-rwxr-xr-x	/usr/libexec/hidden-tool
    __PMM_DNF_UPDATES__
    bash	0:5.3-1.aarch64
    __PMM_NPM_ROOT__
    /usr/local/lib/node_modules
    __PMM_NPM_INSTALLED__
    {"dependencies":{"@openai/codex":{"version":"0.146.0"}}}
    __PMM_NPM_OUTDATED__
    {"@openai/codex":{"latest":"0.147.0"}}
    __PMM_CARGO__
    ripgrep v14.1.1:
        rg
    __PMM_UV_PYTHON_DIR__
    /home/ec2-user/.local/share/uv/python
    __PMM_UV_PYTHONS__
    [{"path":"/home/ec2-user/.local/share/uv/python/cpython-3.10/bin/python3.10","implementation":"cpython","version":"3.10.19","version_parts":{"major":3,"minor":10}}]
    __PMM_END__
    """#))

    #expect(response.hostDescription == "Amazon Linux 2023 (aarch64)")
    #expect(response.systemPackageManager == .dnf)
    #expect(response.canManageSystemPackages == true)
    #expect(response.inventory.packages.map(\.identifier) == ["cargo:ripgrep", "dnf:bash", "npm:@openai/codex", "uv:cpython:3.10"])
    #expect(response.inventory.packages.first(where: { $0.identifier == "dnf:bash" })?.latestVersion == "0:5.3-1.aarch64")
    #expect(response.inventory.packages.contains(where: { $0.identifier == "dnf:hidden-tool" }) == false)
    #expect(response.inventory.packages.first(where: { $0.identifier == "npm:@openai/codex" })?.isOutdated == true)
}

@Test @MainActor func remoteSSHExecutionLeavesMainThreadAndDecodesResponse() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "progress",
        status: 0
    ))
    let host = try RemoteHost(destination: "mac-mini")
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: host)

    #expect(decoded == response)
    #expect(runner.ranOnMainThread == false)
    #expect(runner.options?.streamsStandardOutput == false)
}

@Test func remoteSSHCanRequestAnUncachedAppInventory() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))

    _ = try await RemoteSSHClient(runner: runner).inventory(
        on: RemoteHost(destination: "mac-mini"),
        ignoringAppCache: true
    )

    #expect(runner.arguments?.last?.contains("'--ignore-app-cache'") == true)
}

@Test func remoteSSHDecodesPartialFailureResponseDespiteNonzeroStatus() async throws {
    let response = RemoteControlResponse(
        inventory: PackageInventory(packages: []),
        failures: [RemoteControlFailure(message: "one package failed")]
    )
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "failure detail",
        status: 1
    ))
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: try RemoteHost(destination: "mac-mini"))
    #expect(decoded == response)
}

@Test func remoteSSHExplainsUntrustedHostKeys() async {
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: "",
        stderr: "Host key verification failed.",
        status: 255
    ))
    await #expect(throws: RemoteSSHError.untrustedHost("mac-mini")) {
        try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "mac-mini"))
    }
}

private final class RecordingRemoteRunner: CommandRunning, @unchecked Sendable {
    private let result: CommandResult
    private let lock = NSLock()
    private var _ranOnMainThread: Bool?
    private var _options: CommandRunOptions?
    private var _arguments: [String]?

    init(result: CommandResult) {
        self.result = result
    }

    var ranOnMainThread: Bool? { lock.withLock { _ranOnMainThread } }
    var options: CommandRunOptions? { lock.withLock { _options } }
    var arguments: [String]? { lock.withLock { _arguments } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult { result }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        lock.withLock {
            _ranOnMainThread = Thread.isMainThread
            _options = options
            _arguments = arguments
        }
        onOutput?(result.stderr)
        return result
    }
}
