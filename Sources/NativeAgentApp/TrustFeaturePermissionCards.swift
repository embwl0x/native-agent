import SwiftUI

/// The exhaustive set of compact permission surfaces mounted inside Trust
/// Center's Feature Permissions grid. Keep card ownership here rather than in
/// five anonymous view closures so additions cannot silently leave a settings
/// surface unmounted or duplicate a card.
enum TrustFeaturePermissionCardID: String, CaseIterable, Identifiable {
    case multimodal
    case chromeControl
    case selfImprovement
    case deskAutonomy
    case livingMemory

    var id: String { rawValue }
}

struct TrustFeaturePermissionCard: Identifiable {
    let id: TrustFeaturePermissionCardID
    let title: String
    let systemImage: String
    let tint: Color

    @ViewBuilder
    func content() -> some View {
        switch id {
        case .multimodal:
            MultimodalPermissionsView()
        case .chromeControl:
            ChromeControlPermissionsView()
        case .selfImprovement:
            TrainingPermissionsView()
        case .deskAutonomy:
            WorkshopPermissionsView()
        case .livingMemory:
            LivingMemoryPermissionsView()
        }
    }
}

enum TrustFeaturePermissionCards {
    static let all: [TrustFeaturePermissionCard] = [
        .init(id: .multimodal, title: "Multimodal", systemImage: "sparkles", tint: .blue),
        .init(id: .chromeControl, title: "Chrome Control", systemImage: "globe", tint: .orange),
        .init(id: .selfImprovement, title: "Self-Improvement", systemImage: "brain", tint: .purple),
        .init(id: .deskAutonomy, title: "Desk Autonomy", systemImage: "checklist", tint: .cyan),
        .init(id: .livingMemory, title: "Living Memory", systemImage: "brain.filled.head.profile", tint: .green),
    ]

    /// An executable construction seam for the mounted grid. This deliberately
    /// returns the real child view, not a string or source-text marker.
    static func content(for id: TrustFeaturePermissionCardID) -> AnyView? {
        guard let card = all.first(where: { $0.id == id }) else { return nil }
        return AnyView(card.content())
    }
}
