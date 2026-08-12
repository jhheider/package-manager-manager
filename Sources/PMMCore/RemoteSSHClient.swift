import Foundation

public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String?
    public var destination: String

    public init(id: UUID = UUID(), name: String? = nil, destination: String) throws {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDestination(destination) else { throw RemoteHostError.invalidDestination }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = normalizedName?.isEmpty == false ? normalizedName : nil
        self.destination = destination
    }

    public var displayName: String { Self.capitalizingHost(Self.droppingLocalSuffix(name ?? destination)) }

    public static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, destination.count <= 255, !destination.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@:%+-[]"))
        return destination.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func droppingLocalSuffix(_ value: String) -> String {
        value.lowercased().hasSuffix(".local") ? String(value.dropLast(6)) : value
    }

    private static func capitalizingHost(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }
}

public struct RemoteSSHClient: Sendable {
    public static let controlExecutable = "/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl"

    private let runner: CommandRunning
    private let sshExecutable: String

    public init(runner: CommandRunning = SystemCommandRunner(), sshExecutable: String = "/usr/bin/ssh") {
        self.runner = runner
        self.sshExecutable = sshExecutable
    }

    public func inventory(on host: RemoteHost, ignoringAppCache: Bool = false) async throws -> RemoteControlResponse {
        var arguments = ["inventory", "--protocol", String(remoteControlProtocolVersion)]
        if ignoringAppCache { arguments.append("--ignore-app-cache") }
        return try await run(host, arguments: arguments, linuxScript: Self.linuxInventoryScript)
    }

    public func update(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "update", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], linuxScript: Self.linuxActionScript("update", package: package), onProgress: onProgress)
    }

    public func uninstall(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "uninstall", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], linuxScript: Self.linuxActionScript("uninstall", package: package), onProgress: onProgress)
    }

    public func updateAll(
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(
            host,
            arguments: ["update-all", "--protocol", String(remoteControlProtocolVersion)],
            linuxScript: Self.linuxUpdateAllScript,
            onProgress: onProgress
        )
    }

    public func sshArguments(for host: RemoteHost, remoteArguments: [String]) -> [String] {
        sshArguments(for: host, remoteArguments: remoteArguments, linuxScript: "echo 'Unsupported Linux command.' >&2; exit 64")
    }

    private func sshArguments(for host: RemoteHost, remoteArguments: [String], linuxScript: String) -> [String] {
        let controlArguments = ["remote"] + remoteArguments
        let macCommand = ([Self.controlExecutable] + controlArguments).map(Self.shellQuote).joined(separator: " ")
        let remoteCommand = "if [ -x \(Self.shellQuote(Self.controlExecutable)) ]; then exec \(macCommand); "
            + "elif [ \"$(uname -s 2>/dev/null)\" = Linux ]; then /bin/sh -c \(Self.shellQuote(linuxScript)); "
            + "else echo 'Package Manager Manager is not installed on this Mac.' >&2; exit 127; fi"
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "--",
            host.destination,
            remoteCommand,
        ]
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func run(
        _ host: RemoteHost,
        arguments: [String],
        linuxScript: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        let runner = runner
        let executable = sshExecutable
        let sshArguments = sshArguments(for: host, remoteArguments: arguments, linuxScript: linuxScript)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try runner.run(
                        executable,
                        sshArguments,
                        options: CommandRunOptions(streamsStandardOutput: false),
                        onOutput: onProgress
                    )
                    if let response = Self.response(from: result.stdout) {
                        guard response.protocolVersion == remoteControlProtocolVersion else {
                            throw RemoteSSHError.incompatibleProtocol
                        }
                        continuation.resume(returning: response)
                    } else if result.status == 0, result.stdout.contains("__PMM_LINUX_ACTION_OK__") {
                        let inventoryResult = try runner.run(
                            executable,
                            self.sshArguments(for: host, remoteArguments: ["inventory", "--protocol", String(remoteControlProtocolVersion)], linuxScript: Self.linuxInventoryScript),
                            options: CommandRunOptions(streamsStandardOutput: false),
                            onOutput: onProgress
                        )
                        if let response = Self.response(from: inventoryResult.stdout) {
                            continuation.resume(returning: response)
                        } else {
                            throw Self.error(for: inventoryResult, host: host)
                        }
                    } else {
                        throw Self.error(for: result, host: host)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func response(from output: String) -> RemoteControlResponse? {
        if let data = output.data(using: .utf8),
           let response = try? JSONDecoder().decode(RemoteControlResponse.self, from: data) {
            return response
        }
        return parseLinuxInventory(output)
    }

    static func parseLinuxInventory(_ output: String) -> RemoteControlResponse? {
        guard output.contains("__PMM_LINUX_V1__") else { return nil }
        let sections = linuxSections(output)
        let profile = sections["PROFILE"]?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) ?? []
        let description = profile.first.map { profile.count > 1 ? "\($0) (\(profile[1]))" : $0 }
        let canManage = profile.count > 2 ? profile[2] == "1" : false
        let manager = profile.count > 3 ? PackageManagerKind(rawValue: profile[3]) : nil
        let latestDNF = tabMap(sections["DNF_UPDATES"])
        var rpmPackages: [String: LinuxRPMPackage] = [:]

        for line in lines(sections["DNF_FILES"]) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4,
                  fields[2].contains("x"),
                  linuxCommandDirectories.contains(URL(fileURLWithPath: fields[3]).deletingLastPathComponent().path) else { continue }
            var package = rpmPackages[fields[0]] ?? LinuxRPMPackage(version: fields[1], paths: [])
            package.paths.append(fields[3])
            rpmPackages[fields[0]] = package
        }

        var packages = rpmPackages.map { name, package in
            let paths = Array(Set(package.paths)).sorted()
            return ManagedPackage(
                manager: .dnf,
                identifier: "dnf:\(name)",
                displayName: name,
                installedVersion: package.version,
                latestVersion: latestDNF[name],
                summary: "DNF package providing command-line tools",
                category: "system",
                binaryPath: paths.first,
                executableNames: paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            )
        }
        packages += linuxNPM(sections: sections)
        packages += linuxCargo(sections["CARGO"])
        packages += linuxUV(sections: sections)

        let failures = lines(sections["ERRORS"]).map { RemoteControlFailure(message: $0) }
        return RemoteControlResponse(
            inventory: PackageInventory(packages: packages.sorted(by: linuxPackageOrder), errors: failures.map(\.message)),
            failures: failures,
            hostDescription: description,
            systemPackageManager: manager,
            canManageSystemPackages: manager == nil ? nil : canManage
        )
    }

    private static func linuxNPM(sections: [String: String]) -> [ManagedPackage] {
        guard let data = sections["NPM_INSTALLED"]?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }
        let installRoot = sections["NPM_ROOT"]?.trimmed
        let latest: [String: String] = {
            guard let data = sections["NPM_OUTDATED"]?.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return values.reduce(into: [:]) { result, pair in
                guard let body = pair.value as? [String: Any], let version = body["latest"] as? String else { return }
                result[pair.key] = version
            }
        }()
        return dependencies.compactMap { name, value in
            guard let body = value as? [String: Any] else { return nil }
            return ManagedPackage(
                manager: .npm,
                identifier: "npm:\(name)",
                displayName: name,
                installedVersion: body["version"] as? String,
                latestVersion: latest[name],
                summary: "Globally installed npm package",
                category: "developer-tools",
                installLocation: installRoot.map { "\($0)/\(name)" }
            )
        }
    }

    private static func linuxCargo(_ output: String?) -> [ManagedPackage] {
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String, bins: [String])?
        func flush() {
            guard let crate = current else { return }
            packages.append(ManagedPackage(
                manager: .cargoInstall,
                identifier: "cargo:\(crate.name)",
                displayName: crate.name,
                installedVersion: crate.version,
                latestVersion: nil,
                summary: "cargo-installed Rust binary",
                category: "developer-tools",
                installLocation: "~/.cargo",
                binaryPath: crate.bins.first.map { "~/.cargo/bin/\($0)" },
                executableNames: crate.bins
            ))
        }
        for line in lines(output) {
            let trimmed = line.trimmed
            let parts = trimmed.dropLast().split(separator: " ").map(String.init)
            if trimmed.hasSuffix(":"), parts.count >= 2, parts.last?.hasPrefix("v") == true {
                flush()
                current = (parts.dropLast().joined(separator: " "), String(parts.last!.dropFirst()), [])
            } else if line.first?.isWhitespace == true, !trimmed.isEmpty {
                current?.bins.append(trimmed)
            }
        }
        flush()
        return packages
    }

    private static func linuxUV(sections: [String: String]) -> [ManagedPackage] {
        let toolDir = sections["UV_TOOL_DIR"]?.trimmed
        let outdated = uvLatest(sections["UV_OUTDATED"])
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String?, paths: [String])?
        func flush() {
            guard let tool = current else { return }
            packages.append(ManagedPackage(
                manager: .uv,
                identifier: "uv:tool:\(tool.name)",
                displayName: tool.name,
                installedVersion: tool.version,
                latestVersion: outdated[tool.name],
                summary: "uv-installed tool",
                category: "developer-tools",
                installLocation: tool.paths.first { toolDir.map($0.hasPrefix) ?? false },
                binaryPath: tool.paths.first,
                executableNames: tool.paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            ))
        }
        for line in lines(sections["UV_TOOLS"]) {
            let trimmed = line.trimmed
            let parts = trimmed.split(separator: " ").map(String.init)
            if line.first?.isWhitespace != true, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("-"),
               let name = parts.first, name != "No" {
                flush()
                current = (name, parts.dropFirst().first(where: { $0.hasPrefix("v") }).map { String($0.dropFirst()) }, [])
            } else if let slash = trimmed.firstIndex(of: "/") {
                current?.paths.append(String(trimmed[slash...]))
            }
        }
        flush()

        guard let pythonDir = sections["UV_PYTHON_DIR"]?.trimmed,
              let data = sections["UV_PYTHONS"]?.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return packages }
        packages += rows.compactMap { row in
            guard let path = row["path"] as? String,
                  path == pythonDir || path.hasPrefix("\(pythonDir)/"),
                  let implementation = row["implementation"] as? String,
                  let version = row["version"] as? String,
                  let parts = row["version_parts"] as? [String: Any],
                  let major = parts["major"] as? Int,
                  let minor = parts["minor"] as? Int else { return nil }
            return ManagedPackage(
                manager: .uv,
                identifier: "uv:\(implementation):\(major).\(minor)",
                displayName: "uv Managed Python \(major).\(minor)",
                installedVersion: version,
                latestVersion: nil,
                summary: "uv-managed Python",
                category: "language-runtime",
                installLocation: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                binaryPath: path
            )
        }
        return ManagedPackage.consolidatingInstalledVersions(in: packages)
    }

    private static func uvLatest(_ output: String?) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            let parts = line.trimmed.split(separator: " ").map(String.init)
            guard let name = parts.first,
                  let arrow = parts.firstIndex(of: "->"),
                  parts.indices.contains(arrow + 1) else { return }
            result[name] = parts[arrow + 1].trimmingCharacters(in: CharacterSet(charactersIn: "v)"))
        }
    }

    private static func linuxSections(_ output: String) -> [String: String] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("__PMM_"), line.hasSuffix("__"), line != "__PMM_LINUX_V1__" {
                current = String(line.dropFirst(6).dropLast(2))
            } else if let current {
                sections[current, default: []].append(line)
            }
        }
        return sections.mapValues { $0.joined(separator: "\n").trimmed }
    }

    private static func tabMap(_ output: String?) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 2 { result[fields[0]] = fields[1] }
        }
    }

    private static func lines(_ output: String?) -> [String] {
        output?.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    private static func linuxPackageOrder(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        lhs.manager == rhs.manager
            ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            : lhs.manager.rawValue < rhs.manager.rawValue
    }

    private struct LinuxRPMPackage {
        let version: String
        var paths: [String]
    }

    private static let linuxCommandDirectories: Set<String> = [
        "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/local/bin", "/usr/local/sbin",
    ]

    private static let linuxInventoryScript = #"""
    export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH"
    printf '__PMM_LINUX_V1__\n__PMM_PROFILE__\n'
    pretty=Linux
    if [ -r /etc/os-release ]; then . /etc/os-release; pretty=${PRETTY_NAME:-${NAME:-Linux}}; fi
    pretty=$(printf '%s' "$pretty" | tr '\t\r\n' '   ')
    can_sudo=0; sudo -n true >/dev/null 2>&1 && can_sudo=1
    system_manager=''
    command -v dnf >/dev/null 2>&1 && system_manager=dnf
    printf '%s\t%s\t%s\t%s\n' "$pretty" "$(uname -m)" "$can_sudo" "$system_manager"
    if [ "$system_manager" = dnf ]; then
      printf '__PMM_DNF_FILES__\n'
      rpm -qa --qf '[%{=NAME}\t%{=EPOCHNUM}:%{=VERSION}-%{=RELEASE}.%{=ARCH}\t%{FILEMODES:perms}\t%{FILENAMES}\n]' 2>/dev/null
      printf '__PMM_DNF_UPDATES__\n'
      if dnf -q makecache >/dev/null 2>&1; then
        dnf -q repoquery --upgrades --qf '%{name}\t%{epoch}:%{version}-%{release}.%{arch}' 2>/dev/null || true
      else
        printf '__PMM_ERRORS__\nDNF could not refresh repository metadata.\n'
      fi
    fi
    if command -v npm >/dev/null 2>&1; then
      printf '__PMM_NPM_ROOT__\n'; npm root -g 2>/dev/null || true
      printf '__PMM_NPM_INSTALLED__\n'; npm ls -g --depth=0 --json 2>/dev/null || true
      printf '__PMM_NPM_OUTDATED__\n'; npm outdated -g --json 2>/dev/null || true
    fi
    if command -v cargo >/dev/null 2>&1; then
      printf '__PMM_CARGO__\n'; cargo install --list --color never 2>/dev/null || true
    fi
    if command -v uv >/dev/null 2>&1; then
      printf '__PMM_UV_TOOL_DIR__\n'; uv tool dir --color never 2>/dev/null || true
      printf '__PMM_UV_TOOLS__\n'; uv tool list --show-paths --show-version-specifiers --show-python --offline --color never 2>/dev/null || true
      printf '__PMM_UV_OUTDATED__\n'; uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never 2>/dev/null || true
      printf '__PMM_UV_PYTHON_DIR__\n'; uv python dir --color never 2>/dev/null || true
      printf '__PMM_UV_PYTHONS__\n'; uv python list --only-installed --output-format json --offline --color never 2>/dev/null || true
    fi
    printf '__PMM_END__\n'
    """#

    private static func linuxActionScript(_ action: String, package: ManagedPackage) -> String {
        let token = shellQuote(package.packageToken)
        let command: String
        switch (action, package.manager) {
        case ("update", .dnf): command = "sudo -n dnf -y upgrade \(token)"
        case ("uninstall", .dnf): command = "sudo -n dnf -y remove \(token)"
        case ("update", .npm): command = "npm install -g \(shellQuote(package.packageToken + "@latest"))"
        case ("uninstall", .npm): command = "npm uninstall -g \(token)"
        case ("update", .uv) where package.summary == "uv-managed Python":
            command = "uv python install \(shellQuote(package.latestVersion ?? package.packageToken)) --color always"
        case ("uninstall", .uv) where package.summary == "uv-managed Python":
            command = "uv python uninstall \(shellQuote(package.installedVersion ?? package.packageToken)) --color always"
        case ("update", .uv): command = "uv tool upgrade \(token) --color always"
        case ("uninstall", .uv): command = "uv tool uninstall \(token) --color always"
        case ("uninstall", .cargoInstall): command = "cargo uninstall \(token) --color always"
        default: command = "echo 'This package action is not supported on Linux.' >&2; exit 64"
        }
        return "set -e; export PATH=\"$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH\"; \(command) 1>&2; printf '\\n__PMM_LINUX_ACTION_OK__\\n'"
    }

    private static let linuxUpdateAllScript = "set -e; export PATH=\"$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH\"; command -v dnf >/dev/null; sudo -n dnf -y upgrade 1>&2; printf '\\n__PMM_LINUX_ACTION_OK__\\n'"

    private static func error(for result: CommandResult, host: RemoteHost) -> RemoteSSHError {
        let output = (result.stderr + "\n" + result.stdout).lowercased()
        if output.contains("host key verification failed")
            || output.contains("no host key is known")
            || output.contains("remote host identification has changed") {
            return .untrustedHost(host.destination)
        }
        if output.contains("permission denied") || output.contains("authentication failed") {
            return .authenticationFailed(host.destination)
        }
        if output.contains("package manager manager is not installed on this mac") {
            return .missingRemotePMM
        }
        return .connectionFailed(host.destination, (result.stderr.isEmpty ? result.stdout : result.stderr).trimmed)
    }
}

public enum RemoteHostError: LocalizedError, Equatable {
    case invalidDestination

    public var errorDescription: String? {
        "Enter an SSH host or alias without options or spaces, such as mac-mini or max@server."
    }
}

public enum RemoteSSHError: LocalizedError, Equatable {
    case authenticationFailed(String)
    case connectionFailed(String, String)
    case incompatibleProtocol
    case missingRemotePMM
    case untrustedHost(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let host):
            "SSH authentication failed for \(host). Configure key or agent authentication first."
        case .connectionFailed(let host, let detail):
            detail.isEmpty ? "Could not connect to \(host) over SSH." : "Could not connect to \(host): \(detail)"
        case .incompatibleProtocol:
            "Update Package Manager Manager on the remote Mac."
        case .missingRemotePMM:
            "Package Manager Manager was not found in /Applications on the remote Mac."
        case .untrustedHost(let host):
            "The SSH host key for \(host) is not trusted. Connect with ssh in Terminal once, verify the key, and try again."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
