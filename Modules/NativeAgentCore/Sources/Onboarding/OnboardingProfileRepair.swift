import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingProfileRepair.swift` | Missing-only profile repair under completion and profile locks; completed persona bytes stay intact |
extension SwiftNativeOnboardingClient {
    /// Restore only missing profile.json from both supplied names, preserving persona documents.
    /// Require a completion anchor, no pending completion and no existing profile; use the completion schema.
    public func repairProfile(payload: OnboardingCompletePayload) async throws -> OnboardingCompleteResult {
        let agentName = payload.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = payload.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaType = payload.personaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if agentName.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_agent_name")
        }
        if userName.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_user_name")
        }
        if !PersonaTemplates.validTypes.contains(personaType) {
            return OnboardingCompleteResult(ok: false, error: "invalid_persona_type")
        }
        return try await SwiftNativePersistenceCore.withFileLock(transactionManifestPath) {
            let targets = Self.expectedTargetURLs(
                personaRoot: personaRoot,
                profilePath: profileJSONPath,
                dataRoot: dataRoot
            )
            // Refuse before reconciliation can remove persona documents.
            if let refusal = try profileRepairRefusalLocked(targets: targets) {
                return refusal
            }
            try await reconcilePendingResetLocked()
            // Reset reconciliation may remove the anchor; decide again over its resulting state.
            if let refusal = try profileRepairRefusalLocked(targets: targets) {
                return refusal
            }
            // Absence checking and writing share the profile-file lock.
            return try await SwiftNativePersistenceCore.withFileLock(profileJSONPath) {
                guard !FileManager.default.fileExists(atPath: profileJSONPath.path) else {
                    return OnboardingCompleteResult(
                        ok: false,
                        error: "profile_already_present",
                        detail: "profile.json is present; repair never overwrites existing bytes."
                    )
                }
                let plan = try Self.makeProfileUpdatePlan(
                    profilePath: profileJSONPath,
                    agentName: agentName,
                    personaType: personaType,
                    userName: userName
                )
                // A nil base hash requires absence; ensureCommitted also verifies the written bytes.
                let intent = OnboardingTargetIntent(
                    role: "profile",
                    content: plan.content,
                    sha256: Self.sha256(Data(plan.content.utf8)),
                    baseSHA256: plan.baseSHA256
                )
                try Self.ensureCommitted(intent, to: profileJSONPath)
                return OnboardingCompleteResult(
                    ok: true,
                    agentName: agentName,
                    personaType: personaType,
                    userName: userName
                )
            }
        }
    }
    /// Caller holds the completion-manifest lock; nil permits repair. Recheck after reset reconciliation.
    private func profileRepairRefusalLocked(
        targets: [String: URL]
    ) throws -> OnboardingCompleteResult? {
        if try Self.loadTransactionIfPresent(
            at: transactionManifestPath,
            personaRoot: personaRoot,
            profilePath: profileJSONPath
        ) != nil {
            return OnboardingCompleteResult(
                ok: false,
                error: "onboarding_in_progress",
                detail: "An interrupted onboarding transaction already owns profile.json. Resume it instead of repairing."
            )
        }
        let fm = FileManager.default
        guard Self.hasCompletionAnchor(personaTargets: targets, fileManager: fm) else {
            return OnboardingCompleteResult(
                ok: false,
                error: "profile_repair_not_required",
                detail: "No completed onboarding was found on this Mac, so there is no profile to repair."
            )
        }
        guard !fm.fileExists(atPath: profileJSONPath.path) else {
            return OnboardingCompleteResult(
                ok: false,
                error: "profile_already_present",
                detail: "profile.json is present; repair never overwrites existing bytes."
            )
        }
        return nil
    }
}
