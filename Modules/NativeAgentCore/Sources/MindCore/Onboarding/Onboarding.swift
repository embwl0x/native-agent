import Foundation
import NativeAgentShared
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import DeskCore
// Blueprint: | `Onboarding.swift` | Onboarding client roots, start verdict and ability catalog |
/// Pending completion/reset controls stay local; completion evidence travels in backup/export, never raw phone sync. PersonaEngine commits profiles;
/// UserMDGenerator commits USER.md.
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
            // A reset is an operation, not an ambiguous half-onboarded state. Finish its exact manifest before exposing start state so a crash after one rename
            // can never make the wizard exit or resume the completion transaction the reset was cancelling.
            try await reconcilePendingResetLocked()
            return try inspectOnboardingLocked()
        }
    }

    /// Read-only presentations cannot finish a pending reset on the person's behalf.
    @concurrent public func readOnboarding() async throws -> OnboardingStartResult {
        try await SwiftNativePersistenceCore.withFileLock(transactionManifestPath) {
            guard try Self.loadResetTransactionIfPresent(at: resetTransactionManifestPath,
                personaRoot: personaRoot, dataRoot: dataRoot) == nil else {
                throw OnboardingError.ioFailure("A pending persona reset must settle before its identity can be presented.")
            }
            return try inspectOnboardingLocked()
        }
    }

    private func inspectOnboardingLocked() throws -> OnboardingStartResult {
        let fm = FileManager.default
        let targets = Self.expectedTargetURLs(personaRoot: personaRoot, profilePath: profileJSONPath, dataRoot: dataRoot)
        guard let soulPath = targets["soul"], let voicePath = targets["voice"], let growthPath = targets["growth"],
              let agentsPath = targets["agents"], let userPath = targets["user"] else {
            throw OnboardingError.ioFailure("The persona target catalog is incomplete.")
        }
        let personaPaths = [soulPath, voicePath, growthPath, agentsPath]
        let pending = try Self.loadTransactionIfPresent(
            at: transactionManifestPath,
            personaRoot: personaRoot,
            profilePath: profileJSONPath
        )
        let hasCompletionAnchor = NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        let hasExisting = try pending != nil || hasCompletionAnchor
            || personaPaths.contains { fm.fileExists(atPath: $0.path) }
            || Self.classifyUserDoc(at: userPath) == .authored
        let resetRequired = pending == nil && !hasCompletionAnchor && hasExisting
        let profileRepairRequired = pending == nil
            && hasCompletionAnchor
            && !fm.fileExists(atPath: profileJSONPath.path)
        var currentName: String?
        var profileUnreadable: String?
        if let pending {
            currentName = pending.agentName
        } else if hasExisting && !profileRepairRequired && !resetRequired {
            do { currentName = try PersonaCompiler.compileProfile(dataRoot: dataRoot).name }
            catch {
                profileUnreadable = """
                    Setup could not read the saved profile: \(error.localizedDescription). The persona documents are intact. Repair \
                    \(profileJSONPath.path) on the Mac, then check again.
                    """
            }
        }
        return OnboardingStartResult(
            hasExisting: hasExisting,
            currentPersonaName: currentName,
            abilityOverview: Self.abilityOverview,
            pendingRecovery: pending != nil,
            resetRequired: resetRequired,
            profileRepairRequired: profileRepairRequired,
            profileUnreadable: profileUnreadable
        )
    }
    public static let abilityOverview: [AbilityOverviewEntry] = [
        AbilityOverviewEntry(
            id: "chat",
            title: "Chat with memory",
            detail: "Long-running conversations, recall, corrections, and personality growth."
        ),
        AbilityOverviewEntry(
            id: "projects",
            title: "Build with you",
            detail: "Read approved projects, edit files, run tests, and show results and keep an activity record when access allows."
        ),
        AbilityOverviewEntry(
            id: "mac",
            title: "Use Mac actions",
            detail: "Notifications, Spotlight, Shortcuts, files, shell, and app control with your permission, managed in Trust."
        ),
        AbilityOverviewEntry(
            id: "connectors",
            title: "Connect services",
            detail: "Optional providers and connectors for chat models, Telegram, email, calendar, and more."
        ),
        AbilityOverviewEntry(
            id: "mobile",
            title: "Work from iPhone",
            detail: "Pair the mobile app for chat, approvals, push notifications, inbox, activity, and remote actions."
        ),
        AbilityOverviewEntry(
            id: "improve",
            title: "The agent improves with use",
            detail: "Work is checked and kept in a record you can read."
        ),
    ]
}
