import Foundation

/// A suggestion that installing an optional tool would improve what a package manager can do.
///
/// The manager supplies the copy and a stable identifier; nothing above this type needs to know
/// which manager produced it. The identifier is the same string used to record a dismissal in
/// ``PackagePreferences`` and to name the tool over the host notification, so a manager owns one
/// namespace rather than three.
///
/// Cargo is the only manager with anything to suggest — it is the one that can neither report
/// outdated crates natively nor install prebuilt binaries without help. Its state lives in
/// ``CargoSetupState`` and its offers come from ``CargoHelper/setupOffer``; this type is only the
/// value they hand to the UI. A second manager with something to offer is what would justify a
/// layer that dispatches between them.
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
