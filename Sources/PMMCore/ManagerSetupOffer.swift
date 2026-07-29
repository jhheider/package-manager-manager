import Foundation

/// A suggestion that installing an optional tool would improve what a package manager can do.
///
/// The manager supplies the copy and a stable identifier; nothing above this type needs to know
/// which manager produced it. The identifier is the same string used to record a dismissal in
/// ``PackagePreferences`` and to name the tool over the host notification, so a manager owns one
/// namespace rather than three.
public struct ManagerSetupOffer: Sendable, Equatable, Identifiable {
    public let id: String
    public let manager: PackageManagerKind
    public let title: String
    public let explanation: String
    public let symbolName: String

    public init(
        id: String,
        manager: PackageManagerKind,
        title: String,
        explanation: String,
        symbolName: String
    ) {
        self.id = id
        self.manager = manager
        self.title = title
        self.explanation = explanation
        self.symbolName = symbolName
    }
}

/// The setup offers every package manager wants to make, and the state behind them.
///
/// Cargo is currently the only manager with anything to suggest — it is the one that can neither
/// report outdated crates natively nor install prebuilt binaries without help. This type is the
/// single place that knows that, keeping manager-specific knowledge in PMMCore alongside the
/// scanners and updaters rather than in the transport or the view model.
public struct ManagerSetupState: Sendable, Equatable {
    private var cargo: CargoSetupState
    /// The helper whose install is in flight, if any.
    public var installingHelperID: String?

    public init(preferences: PackagePreferences = PackagePreferences()) {
        cargo = CargoSetupState(preferences: preferences)
    }

    private init(cargo: CargoSetupState, installingHelperID: String?) {
        self.cargo = cargo
        self.installingHelperID = installingHelperID
    }

    /// Detects what each manager has available. Shells out, so never call this on the main thread.
    public static func detect(preferences: PackagePreferences) -> ManagerSetupState {
        ManagerSetupState(
            cargo: CargoSetupState(status: CargoToolchain().status(), preferences: preferences),
            installingHelperID: nil
        )
    }

    /// Carries an in-flight install and any newly detected state forward together.
    public func merging(_ detected: ManagerSetupState) -> ManagerSetupState {
        ManagerSetupState(cargo: detected.cargo, installingHelperID: installingHelperID)
    }

    /// The one offer worth showing, given which managers actually have packages installed.
    public func offer(installedManagers: Set<PackageManagerKind>) -> ManagerSetupOffer? {
        cargo.offer(installedManagers: installedManagers)?.setupOffer
    }

    public mutating func dismiss(_ helperID: String) {
        cargo.preferences.dismiss(helperID)
    }

    public var preferences: PackagePreferences { cargo.preferences }

    /// What to call a helper in progress UI, or the raw identifier if no manager claims it.
    public static func helperDisplayName(id: String) -> String {
        CargoHelper(promptKey: id)?.crateName ?? id
    }

    /// Runs the install a given offer identifier asks for. Returns false when no manager claims it.
    public static func installHelper(
        id: String,
        onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil
    ) throws -> Bool {
        guard let helper = CargoHelper(promptKey: id) else { return false }
        try CargoToolchain().install(helper, onProgress: onProgress)
        return true
    }
}
