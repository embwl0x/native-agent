import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingCompletion.swift` | Durable completion intent and recovery; persona and profile bytes verify before the sentinel |
extension SwiftNativeOnboardingClient {
    struct OnboardingTargetIntent: Codable, Sendable {
        let role: String
        let content: String
        let sha256: String
        /// Hash of the bytes that existed when the transaction was prepared.
        /// Nil means the target was required to be absent.
        let baseSHA256: String?
    }
    struct OnboardingTransactionManifest: Codable, Sendable {
        let schemaVersion: Int
        let transactionID: String
        let createdAt: String
        let personaRoot: String
        let profilePath: String
        let identityHash: String
        let agentName: String
        let personaType: String
        let userName: String
        let targets: [OnboardingTargetIntent]
    }
    static let pendingTransactionRelativePath = "onboarding/pending-completion.json"
    var transactionManifestPath: URL {
        dataRoot.appendingPathComponent(Self.pendingTransactionRelativePath)
    }
    /// Publish exact content, base hashes/absence and normalized identity before any persona byte.
    /// Retries resume only that intent; unrelated bytes or identities fail closed.
    public func completeOnboarding(payload: OnboardingCompletePayload) async throws -> OnboardingCompleteResult {
        let agentName = payload.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userNameTrimmed = payload.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = userNameTrimmed.isEmpty ? "User" : userNameTrimmed
        let personaType = payload.personaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if agentName.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_agent_name")
        }
        if !PersonaTemplates.validTypes.contains(personaType) {
            return OnboardingCompleteResult(ok: false, error: "invalid_persona_type")
        }
        let manifestPath = transactionManifestPath
        return try await SwiftNativePersistenceCore.withFileLock(manifestPath) {
            try await reconcilePendingResetLocked()
            let requestedIdentityHash = Self.identityHash(
                agentName: agentName,
                personaType: personaType,
                userName: userName,
                personaRoot: personaRoot,
                profilePath: profileJSONPath
            )
            let manifest: OnboardingTransactionManifest
            if let pending = try Self.loadTransactionIfPresent(
                at: manifestPath,
                personaRoot: personaRoot,
                profilePath: profileJSONPath
            ) {
                guard pending.identityHash == requestedIdentityHash else {
                    return OnboardingCompleteResult(
                        ok: false,
                        error: "onboarding_in_progress",
                        detail: "A different onboarding identity is pending recovery. Resume it or reset onboarding first."
                    )
                }
                manifest = pending
            } else {
                // Unowned persona/sentinel bytes require reset; only a hash-pinned USER projection is replaceable.
                let allTargets = Self.expectedTargetURLs(
                    personaRoot: personaRoot,
                    profilePath: profileJSONPath,
                    dataRoot: dataRoot
                )
                let userPath = allTargets["user"]!
                let userShape = try Self.classifyUserDoc(at: userPath)
                let preexisting = allTargets
                    .filter { $0.key != "profile" && $0.key != "user" }
                    .contains { FileManager.default.fileExists(atPath: $0.value.path) }
                    || userShape == .authored
                guard !preexisting else {
                    return OnboardingCompleteResult(
                        ok: false,
                        error: "persona_already_exists",
                        detail: "Personality documents already exist. Start setup over to back them up before trying again."
                    )
                }
                // Pin projection bytes so ensureCommitted refuses changes after preparation.
                let userBaseSHA256: String? = userShape == .generatorProjection
                    ? (try? Data(contentsOf: userPath)).map { Self.sha256($0) }
                    : nil
                let docs: PersonaTemplates.Docs
                do {
                    docs = try PersonaTemplates.generate(
                        name: agentName,
                        personaType: personaType,
                        userName: userName
                    )
                } catch let e as OnboardingError {
                    return OnboardingCompleteResult(ok: false, error: "template_error", detail: e.errorDescription ?? "")
                } catch {
                    return OnboardingCompleteResult(ok: false, error: "template_error", detail: String(describing: error))
                }
                // Prepare before publishing intent; malformed profile bytes remain intact and fail closed.
                let profilePlan = try Self.makeProfileUpdatePlan(
                    profilePath: profileJSONPath,
                    agentName: agentName,
                    personaType: personaType,
                    userName: userName
                )
                let sentinelBody = "completed_at=\(Self.utcStamp())\n"
                let staged: [(String, String, String?)] = [
                    ("soul", docs.soul, nil),
                    ("voice", docs.voice, nil),
                    ("user", docs.user, userBaseSHA256),
                    ("growth", docs.growth, nil),
                    ("profile", profilePlan.content, profilePlan.baseSHA256),
                    ("sentinel", sentinelBody, nil),
                ]
                manifest = OnboardingTransactionManifest(
                    schemaVersion: 1,
                    transactionID: UUID().uuidString.lowercased(),
                    createdAt: NativeTimestampFormat.fractionalZulu(Date()),
                    personaRoot: Self.canonicalPath(personaRoot),
                    profilePath: Self.canonicalPath(profileJSONPath),
                    identityHash: requestedIdentityHash,
                    agentName: agentName,
                    personaType: personaType,
                    userName: userName,
                    targets: staged.map {
                        OnboardingTargetIntent(role: $0.0, content: $0.1, sha256: Self.sha256(Data($0.1.utf8)), baseSHA256: $0.2)
                    }
                )
                try Self.writeTransaction(manifest, to: manifestPath, encodingContext: "onboarding transaction")
            }
            return try await commitPreparedTransaction(
                manifest,
                manifestPath: manifestPath
            )
        }
    }
    /// Resume only the hash-checked manifest, without reconstructing inputs or staged bytes.
    public func resumePendingOnboarding() async throws -> OnboardingCompleteResult {
        let manifestPath = transactionManifestPath
        return try await SwiftNativePersistenceCore.withFileLock(manifestPath) {
            try await reconcilePendingResetLocked()
            guard let manifest = try Self.loadTransactionIfPresent(
                at: manifestPath,
                personaRoot: personaRoot,
                profilePath: profileJSONPath
            ) else {
                return OnboardingCompleteResult(
                    ok: false,
                    error: "no_pending_onboarding",
                    detail: "No interrupted onboarding transaction is available to resume."
                )
            }
            return try await commitPreparedTransaction(
                manifest,
                manifestPath: manifestPath
            )
        }
    }
    private func commitPreparedTransaction(
        _ manifest: OnboardingTransactionManifest,
        manifestPath: URL
    ) async throws -> OnboardingCompleteResult {
        try ensureDirectoryExists(personaRoot)
        let targetURLs = Self.expectedTargetURLs(
            personaRoot: personaRoot,
            profilePath: profileJSONPath,
            dataRoot: dataRoot
        )
        let intents = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.role, $0) })
        for role in ["soul", "voice", "user", "growth", "profile"] {
            guard let intent = intents[role], let target = targetURLs[role] else {
                throw OnboardingError.ioFailure("onboarding transaction missing required target '\(role)'")
            }
            try await SwiftNativePersistenceCore.withFileLock(target) {
                try Self.ensureCommitted(intent, to: target)
            }
        }
        // The completion marker is deliberately last. A successful result is
        // impossible until every document and profile byte is durable.
        guard let sentinelIntent = intents["sentinel"], let sentinelURL = targetURLs["sentinel"] else {
            throw OnboardingError.ioFailure("onboarding transaction missing completion sentinel")
        }
        try await SwiftNativePersistenceCore.withFileLock(sentinelURL) {
            try Self.ensureCommitted(sentinelIntent, to: sentinelURL)
        }
        do {
            try FileManager.default.removeItem(at: manifestPath)
            try SwiftNativePersistenceCore.syncDirectory(manifestPath.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure("clear onboarding transaction failed: \(error.localizedDescription)")
        }
        return OnboardingCompleteResult(
            ok: true,
            agentName: manifest.agentName,
            personaType: manifest.personaType,
            userName: manifest.userName
        )
    }
    /// Reject corrupt intent, substituted roots, duplicate roles and mismatched hashes.
    static func loadTransactionIfPresent(
        at path: URL,
        personaRoot: URL,
        profilePath: URL
    ) throws -> OnboardingTransactionManifest? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw OnboardingError.ioFailure("read onboarding transaction failed: \(error.localizedDescription)")
        }
        let manifest: OnboardingTransactionManifest
        do {
            manifest = try JSONDecoder().decode(OnboardingTransactionManifest.self, from: data)
        } catch {
            throw OnboardingError.ioFailure("onboarding transaction is malformed; preserving it for recovery")
        }
        guard manifest.schemaVersion == 1,
              manifest.personaRoot == canonicalPath(personaRoot),
              manifest.profilePath == canonicalPath(profilePath) else {
            throw OnboardingError.ioFailure("onboarding transaction belongs to a different root or schema")
        }
        let expectedIdentity = identityHash(
            agentName: manifest.agentName,
            personaType: manifest.personaType,
            userName: manifest.userName,
            personaRoot: personaRoot,
            profilePath: profilePath
        )
        guard manifest.identityHash == expectedIdentity else {
            throw OnboardingError.ioFailure("onboarding transaction identity evidence does not match")
        }
        let requiredRoles: Set<String> = ["soul", "voice", "user", "growth", "profile", "sentinel"]
        let roles = manifest.targets.map(\.role)
        guard manifest.targets.count == requiredRoles.count,
              Set(roles) == requiredRoles,
              Set(roles).count == roles.count else {
            throw OnboardingError.ioFailure("onboarding transaction target set is invalid")
        }
        for target in manifest.targets {
            guard sha256(Data(target.content.utf8)) == target.sha256 else {
                throw OnboardingError.ioFailure("onboarding transaction hash mismatch for '\(target.role)'")
            }
        }
        return manifest
    }
}
