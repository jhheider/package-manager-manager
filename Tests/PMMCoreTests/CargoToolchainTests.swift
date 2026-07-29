import Foundation
import Testing
@testable import PMMCore

@Test func cargoHelperCrateAndExecutableNamesDiffer() {
    // cargo-update installs an executable called cargo-install-update; conflating the two would
    // make detection always fail.
    #expect(CargoHelper.installUpdate.crateName == "cargo-update")
    #expect(CargoHelper.installUpdate.executableName == "cargo-install-update")
    #expect(CargoHelper.binstall.crateName == "cargo-binstall")
    #expect(CargoHelper.binstall.executableName == "cargo-binstall")
}

@Test func parseInstallUpdateListReadsLatestVersions() {
    let output = """
    Package         Installed  Latest   Needs update
    cargo-binstall  v1.21.0    v1.21.1  Yes
    just            v1.5.0     v1.57.0  Yes
    cbindgen        v0.29.4    v0.29.4  No
    """

    #expect(CargoToolchain.parseInstallUpdateList(output) == [
        "cargo-binstall": "1.21.1",
        "just": "1.57.0",
        "cbindgen": "0.29.4",
    ])
}

@Test func parseInstallUpdateListSkipsHeaderAndNoise() {
    let output = """
    Polling registry 'crates.io'...

    Package  Installed  Latest  Needs update
    mdtask   v0.3.0     v0.6.0  Yes

    Updating registry
    """

    #expect(CargoToolchain.parseInstallUpdateList(output) == ["mdtask": "0.6.0"])
}

@Test func parseInstallUpdateListIgnoresRowsWithoutVersionColumns() {
    #expect(CargoToolchain.parseInstallUpdateList("nothing here at all").isEmpty)
    #expect(CargoToolchain.parseInstallUpdateList("").isEmpty)
}

@Test func updateCommandsTryBinstallThenFallBackToCompiling() {
    let toolchain = CargoToolchain(runner: StubRunner())
    let status = CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil)

    // Not every crate publishes prebuilt artifacts, so compiling must remain as the trailing
    // fallback rather than the update dead-ending on a binstall miss.
    #expect(toolchain.updateCommands(for: "just", status: status) == [
        PackageCommand(executable: "cargo", arguments: ["binstall", "just", "--no-confirm", "--force"]),
        PackageCommand(executable: "cargo", arguments: ["install", "just", "--force", "--color", "always"]),
    ])
}

@Test func updateCommandsCompileOnlyWhenBinstallIsMissing() {
    let toolchain = CargoToolchain(runner: StubRunner())
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)

    #expect(toolchain.updateCommands(for: "just", status: status) == [
        PackageCommand(executable: "cargo", arguments: ["install", "just", "--force", "--color", "always"]),
    ])
}

@Test func packagePreferencesRecordDismissalsUnderEachManagersOwnKeys() {
    var preferences = PackagePreferences()
    #expect(!preferences.hasDismissed(CargoHelper.binstall.promptKey))

    preferences.dismiss(CargoHelper.binstall.promptKey)
    #expect(preferences.hasDismissed(CargoHelper.binstall.promptKey))
    // Namespacing keeps one manager's dismissals from affecting another's.
    #expect(!preferences.hasDismissed(CargoHelper.installUpdate.promptKey))
    #expect(!preferences.hasDismissed("homebrew.something"))

    preferences.restore(CargoHelper.binstall.promptKey)
    #expect(!preferences.hasDismissed(CargoHelper.binstall.promptKey))
}

@Test func packagePreferencesRoundTripThroughTheStore() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-prefs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = PackagePreferencesStore(url: url)

    #expect(store.load() == PackagePreferences())
    var preferences = PackagePreferences()
    preferences.dismiss(CargoHelper.installUpdate.promptKey)
    store.save(preferences)

    #expect(store.load().hasDismissed(CargoHelper.installUpdate.promptKey))
}

@Test func latestVersionsRequiresCargoUpdate() {
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: ["cargo": "/usr/bin/false"])
    // Status is passed explicitly so the assertion does not depend on whether cargo-update
    // happens to be installed on the machine running the suite.
    let absent = CargoToolchainStatus(cargo: "/usr/bin/false", binstall: nil, installUpdate: nil)
    #expect(throws: CargoToolchainError.helperUnavailable(.installUpdate)) {
        try toolchain.latestVersions(status: absent)
    }
}

@Test func statusReportsHelpersFromToolPaths() {
    let toolchain = CargoToolchain(
        runner: StubRunner(),
        toolPaths: [
            "cargo": "/c",
            "cargo-binstall": "/b",
            "cargo-install-update": "/u",
        ]
    )
    let status = toolchain.status()

    #expect(status.hasCargo)
    #expect(status.has(.binstall))
    #expect(status.has(.installUpdate))
}

@Test func cargoSetupOffersBinstallFirstThenCargoUpdate() {
    let none = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil))
    #expect(none.offer(hasRustPackages: true) == .binstall)

    let withBinstall = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil))
    #expect(withBinstall.offer(hasRustPackages: true) == .installUpdate)

    let complete = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: "/u"))
    #expect(complete.offer(hasRustPackages: true) == nil)
}

@Test func cargoSetupSkipsDeclinedHelpersAndMovesOn() {
    var preferences = PackagePreferences()
    preferences.dismiss(CargoHelper.binstall.promptKey)
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)

    // Declining binstall must not block the cargo-update offer.
    #expect(CargoSetupState(status: status, preferences: preferences).offer(hasRustPackages: true) == .installUpdate)

    preferences.dismiss(CargoHelper.installUpdate.promptKey)
    #expect(CargoSetupState(status: status, preferences: preferences).offer(hasRustPackages: true) == nil)
}

@Test func cargoSetupStaysSilentWithoutRustOrBeforeDetection() {
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)
    #expect(CargoSetupState(status: status).offer(hasRustPackages: false) == nil)

    let noCargo = CargoToolchainStatus(cargo: nil, binstall: nil, installUpdate: nil)
    #expect(CargoSetupState(status: noCargo).offer(hasRustPackages: true) == nil)

    // Undetected must not be mistaken for "nothing installed" and prompt on launch.
    #expect(CargoSetupState().offer(hasRustPackages: true) == nil)
}

@Test func installBinstallAlwaysCompilesBecauseItCannotBootstrapItself() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    try toolchain.install(.binstall, status: present)

    #expect(runner.commands == ["/fake/cargo install cargo-binstall --force --color always"])
}

@Test func installCargoUpdateUsesBinstallWhenAvailable() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    // Compiling cargo-update is the multi-minute wait binstall exists to avoid.
    try toolchain.install(.installUpdate, status: present)

    #expect(runner.commands == ["/fake/cargo binstall cargo-update --no-confirm --force"])
}

@Test func binstallAlwaysForces() {
    // Without --force, binstall exits 0 having done nothing whenever cargo's install metadata
    // already records the target version, even if the binary is gone. That reads as success and
    // leaves the tool missing.
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    #expect(toolchain.updateCommands(for: "just", status: present).first?.arguments.contains("--force") == true)
    #expect(toolchain.installCommands(for: .installUpdate, status: present).first?.arguments.contains("--force") == true)
}

@Test func installFallsBackToCompilingWhenBinstallFails() throws {
    let runner = StubRunner()
    runner.failingCommandSubstring = "binstall"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    try toolchain.install(.installUpdate, status: present)

    #expect(runner.commands == [
        "/fake/cargo binstall cargo-update --no-confirm --force",
        "/fake/cargo install cargo-update --force --color always",
    ])
}

@Test func installThrowsWhenEveryCommandFails() {
    let runner = StubRunner()
    runner.status = 1
    runner.stderr = "nope\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    #expect(throws: CargoToolchainError.commandFailed("nope\n")) {
        try toolchain.install(.installUpdate, status: present)
    }
    #expect(runner.commands.count == 2)
}

@Test func installCargoUpdateCompilesWithoutBinstall() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)

    try toolchain.install(.installUpdate, status: absent)

    #expect(runner.commands == ["/fake/cargo install cargo-update --force --color always"])
}

@Test func installReportsCommandAndStreamsOutput() throws {
    // Regression: without these events the UI has no running action to render, so a multi-minute
    // compile shows no terminal and looks hung.
    let runner = StubRunner()
    runner.streamedOutput = "Compiling hickory-proto\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)
    let progress = ProgressRecorder()

    try toolchain.install(.binstall, status: absent) { progress.append($0) }

    #expect(progress.values == [
        .started(command: "cargo install cargo-binstall --force --color always"),
        .output("Compiling hickory-proto\n"),
    ])
    // Output only streams incrementally under a pty, which is what makes progress visible.
    #expect(runner.options.map(\.terminal) == [true])
}

@Test func installThrowsWhenCargoFails() {
    let runner = StubRunner()
    runner.status = 1
    runner.stderr = "no matching package\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)

    #expect(throws: CargoToolchainError.commandFailed("no matching package\n")) {
        try toolchain.install(.binstall, status: absent)
    }
}

@Test func installRequiresCargo() {
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: [:])
    let noCargo = CargoToolchainStatus(cargo: nil, binstall: nil, installUpdate: nil)

    #expect(throws: CargoToolchainError.cargoUnavailable) {
        try toolchain.install(.binstall, status: noCargo)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PackageCommandProgress] = []

    func append(_ event: PackageCommandProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [PackageCommandProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class StubRunner: CommandRunning, @unchecked Sendable {
    var stdout = ""
    var stderr = ""
    var status: Int32 = 0
    var streamedOutput = ""
    /// Commands containing this substring exit non-zero, so fallback chains can be exercised.
    var failingCommandSubstring: String?
    private let lock = NSLock()
    private var recordedCommands: [String] = []
    private var recordedOptions: [CommandRunOptions] = []

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var options: [CommandRunOptions] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOptions
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        lock.lock()
        recordedCommands.append(command)
        recordedOptions.append(options)
        lock.unlock()
        if !streamedOutput.isEmpty { onOutput?(streamedOutput) }
        if let failingCommandSubstring, command.contains(failingCommandSubstring) {
            return CommandResult(stdout: "", stderr: "no prebuilt artifact\n", status: 1)
        }
        return CommandResult(stdout: stdout, stderr: stderr, status: status)
    }
}

@Test func helperIDRoundTripsThroughItsPromptKey() {
    // The same string identifies the offer, the dismissal, and the tool to install over the host
    // notification, so a manager owns one namespace rather than three.
    for helper in CargoHelper.allCases {
        #expect(CargoHelper(promptKey: helper.promptKey) == helper)
        #expect(helper.setupOffer.id == helper.promptKey)
    }
    #expect(CargoHelper(promptKey: "homebrew.something") == nil)
}

@Test func managerSetupIgnoresIdentifiersNoManagerClaims() throws {
    #expect(try ManagerSetupState.installHelper(id: "homebrew.nonexistent") == false)
    #expect(ManagerSetupState.helperDisplayName(id: "homebrew.nonexistent") == "homebrew.nonexistent")
    #expect(ManagerSetupState.helperDisplayName(id: CargoHelper.installUpdate.promptKey) == "cargo-update")
}

@Test func cargoOffersOnlyWhenItsOwnManagersHavePackages() {
    let none = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil))

    // Cargo decides what "in use" means for itself; callers just pass what is installed.
    #expect(none.offer(installedManagers: [.cargoInstall]) == .binstall)
    #expect(none.offer(installedManagers: [.rustup]) == .binstall)
    #expect(none.offer(installedManagers: [.homebrew, .npm]) == nil)
    #expect(none.offer(installedManagers: []) == nil)
}

@Test func managerSetupSurfacesOffersWithoutNamingTheManager() {
    var state = ManagerSetupState()
    #expect(state.offer(installedManagers: [.cargoInstall]) == nil, "undetected must not prompt")

    state = state.merging(.detect(preferences: PackagePreferences()))
    if let offer = state.offer(installedManagers: [.cargoInstall]) {
        #expect(offer.manager == .cargoInstall)
        #expect(!offer.title.isEmpty)
        #expect(!offer.explanation.isEmpty)
        #expect(!offer.symbolName.isEmpty)
    }
}

@Test func managerSetupCarriesAnInFlightInstallAcrossDetection() {
    var state = ManagerSetupState()
    state.installingHelperID = CargoHelper.binstall.promptKey

    let merged = state.merging(.detect(preferences: PackagePreferences()))

    // Losing this on a refresh would drop the card back to its idle button mid-install.
    #expect(merged.installingHelperID == CargoHelper.binstall.promptKey)
}

@Test func managerSetupDismissalSuppressesTheOffer() {
    var state = ManagerSetupState().merging(.detect(preferences: PackagePreferences()))
    guard let offer = state.offer(installedManagers: [.cargoInstall]) else { return }

    state.dismiss(offer.id)

    #expect(state.offer(installedManagers: [.cargoInstall])?.id != offer.id)
    #expect(state.preferences.hasDismissed(offer.id))
}
