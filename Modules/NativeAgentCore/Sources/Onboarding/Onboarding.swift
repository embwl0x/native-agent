import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `Onboarding.swift` | Onboarding client roots, start verdict and ability catalog |
/// Completion/reset controls are excluded from local backup/export and phone sync in PrivacyMap.
/// PersonaEngine commits profiles; UserMDGenerator commits USER.md.
public struct SwiftNativeOnboardingClient: Sendable {
    let personaRoot: URL
    let dataRoot: URL
    let profileJSONPath: URL
    public init(personaRoot: URL? = nil, dataRoot: URL? = nil) {
        let resolvedDataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.personaRoot = personaRoot ?? PersistenceCore.defaultPersonaRoot(dataRoot: resolvedDataRoot)
        self.dataRoot = resolvedDataRoot
        self.profileJSONPath = resolvedDataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
    }
    public func startOnboarding() async throws -> OnboardingStartResult {
        return try await SwiftNativePersistenceCore.withFileLock(transactionManifestPath) {
            // A reset is an operation, not an ambiguous half-onboarded state.
            // Finish its exact manifest before exposing start state so a crash
            // after one rename can never make the wizard exit or resume the
            // completion transaction the reset was cancelling.
            try await reconcilePendingResetLocked()
            // A user is "already onboarded" if ANY transaction-owned persona
            // doc or the completion marker exists. `completeOnboarding` refuses
            // this exact set when no resumable manifest owns it.
            let fm = FileManager.default
            let targets = Self.expectedTargetURLs(
                personaRoot: personaRoot,
                profilePath: profileJSONPath,
                dataRoot: dataRoot
            )
            let soulPath = targets["soul"]!
            let voicePath = targets["voice"]!
            let growthPath = targets["growth"]!
            let personaPaths = [soulPath, voicePath, growthPath]
            let onboardedSentinel = targets["sentinel"]!
            let pending = try Self.loadTransactionIfPresent(
                at: transactionManifestPath,
                personaRoot: personaRoot,
                profilePath: profileJSONPath
            )
            let hasExisting = pending != nil
                || personaPaths.contains { fm.fileExists(atPath: $0.path) }
                || fm.fileExists(atPath: onboardedSentinel.path)
            // Completion is the sentinel or the complete, nonempty legacy
            // SOUL/VOICE/USER/GROWTH bundle. No single document proves it.
            let hasCompletionAnchor = Self.hasCompletionAnchor(
                personaTargets: targets,
                fileManager: fm
            )
            // Persona bytes with no proof of completion: partial state, which
            // takes the reset lane. A generator-only USER.md remains fresh state.
            let hasPartialPersonaState = !hasCompletionAnchor
                && (fm.fileExists(atPath: soulPath.path)
                    || fm.fileExists(atPath: voicePath.path)
                    || fm.fileExists(atPath: growthPath.path))
            // `hasPartialPersonaState` (and therefore `resetRequired`) requires
            // NO completion anchor, so the two states can never both be true.
            let profileRepairRequired = pending == nil
                && hasCompletionAnchor
                && !fm.fileExists(atPath: profileJSONPath.path)
            var currentName: String?
            var profileUnreadable: String?
            if hasExisting {
                do { currentName = try pending?.agentName ?? Self.readPersonaName(at: profileJSONPath) }
                catch OnboardingError.ioFailure(let why) where pending == nil && hasCompletionAnchor {
                    profileUnreadable = "Setup could not read the saved names: \(why). The persona documents are intact. Move \(profileJSONPath.path) aside on the Mac, then reopen setup to enter the two names again."
                }
            }
            return OnboardingStartResult(
                hasExisting: hasExisting,
                currentPersonaName: currentName,
                abilityOverview: Self.abilityOverview,
                pendingRecovery: pending != nil,
                resetRequired: pending == nil && hasPartialPersonaState,
                profileRepairRequired: profileRepairRequired,
                profileUnreadable: profileUnreadable
            )
        }
    }
    /// The sole catalog for onboarding's six ability tiles.
    public static let abilityOverview: [AbilityOverviewEntry] = [
        AbilityOverviewEntry(
            id: "chat",
            title: "Chat with memory",
            detail: "Long-running conversations, recall, corrections, and personality growth.",
            systemImage: "message"
        ),
        AbilityOverviewEntry(
            id: "projects",
            title: "Build with you",
            detail: "Read approved projects, edit files, run tests, and show results and keep an activity record when access allows.",
            systemImage: "hammer"
        ),
        AbilityOverviewEntry(
            id: "mac",
            title: "Use Mac actions",
            detail: "Notifications, Spotlight, Shortcuts, files, shell, and app control with your permission, managed in Trust.",
            systemImage: "macbook"
        ),
        AbilityOverviewEntry(
            id: "connectors",
            title: "Connect services",
            detail: "Optional providers and connectors for chat models, Telegram, email, calendar, and more.",
            systemImage: "point.3.connected.trianglepath.dotted"
        ),
        AbilityOverviewEntry(
            id: "mobile",
            title: "Work from iPhone",
            detail: "Pair the mobile app for chat, approvals, push notifications, inbox, activity, and remote actions.",
            systemImage: "iphone"
        ),
        AbilityOverviewEntry(
            id: "improve",
            title: "The agent improves with use",
            detail: "Work is checked and kept in a record you can read.",
            systemImage: "checkmark.shield"
        ),
    ]
}
