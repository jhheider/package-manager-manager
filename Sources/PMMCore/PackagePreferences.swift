import Foundation

/// Choices the user has made that outlive a single launch.
///
/// Deliberately generic: it records that a prompt was dismissed, not what the prompt was about, so
/// no single package manager reaches into app-wide state. Managers own their own key namespace.
public struct PackagePreferences: Sendable, Equatable, Codable {
    public var dismissedPrompts: Set<String>

    public init(dismissedPrompts: Set<String> = []) {
        self.dismissedPrompts = dismissedPrompts
    }

    public func hasDismissed(_ prompt: String) -> Bool {
        dismissedPrompts.contains(prompt)
    }

    public mutating func dismiss(_ prompt: String) {
        dismissedPrompts.insert(prompt)
    }

    public mutating func restore(_ prompt: String) {
        dismissedPrompts.remove(prompt)
    }
}

/// Persists ``PackagePreferences`` beside the host snapshot.
///
/// Not `UserDefaults`: the main app and the menu bar helper are separate bundle identifiers with
/// separate defaults domains, and the helper is the process that runs installs and updates.
public struct PackagePreferencesStore: Sendable {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? PackageHostStore.defaultDirectory()
            .appendingPathComponent("package-preferences.json", isDirectory: false)
    }

    public func load() -> PackagePreferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(PackagePreferences.self, from: data)
        else { return PackagePreferences() }
        return preferences
    }

    public func save(_ preferences: PackagePreferences) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
