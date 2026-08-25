import Foundation

/// The latest user-visible outcome of a skill lifecycle operation. Identity is
/// part of the contract: a repeated failure is a new event even when its text
/// is byte-for-byte identical to the prior one.
struct SkillLifecycleFeedback: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case failure
    }

    let id: UUID
    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.id = UUID()
        self.kind = kind
        self.message = message
    }
}

extension AppModel {
    @MainActor
    func recordSkillManifestFailure(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        skillManifestError = trimmed
        skillLifecycleFeedback = SkillLifecycleFeedback(kind: .failure, message: trimmed)
    }

    @MainActor
    func recordSkillManifestSuccess(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        skillManifestError = nil
        skillLifecycleFeedback = SkillLifecycleFeedback(kind: .success, message: trimmed)
    }

    @MainActor
    func dismissSkillManifestFeedback() {
        skillManifestError = nil
        skillLifecycleFeedback = nil
    }

    @MainActor
    func dismissSkillManifestSuccess(id: UUID) {
        guard skillLifecycleFeedback?.id == id,
              skillLifecycleFeedback?.kind == .success else { return }
        skillLifecycleFeedback = nil
    }
}
