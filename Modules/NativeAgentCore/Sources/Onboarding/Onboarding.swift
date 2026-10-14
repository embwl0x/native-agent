import Foundation
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine

/// Settings sends an explicit replay edge to the main-content tour mount.
@MainActor
@Observable
public final class OnboardingTourReplayCoordinator {
    public static let shared = OnboardingTourReplayCoordinator()

    public private(set) var requestID = 0
    private var deliveredRequestID = 0

    @discardableResult
    public func requestReplay() -> Int {
        requestID += 1
        return requestID
    }

    /// The persisted showTour preference still covers a later scene mount.
    public func claim(_ requestID: Int) -> Bool {
        guard requestID == self.requestID,
              requestID > deliveredRequestID,
              requestID > 0 else { return false }
        deliveredRequestID = requestID
        return true
    }
}

// MARK: - Onboarding
//
// This module is the sole implementation of the onboarding subsystem. It
// serves start/complete/repair-profile/reset through Swift code inside
// NativeAgent.app.
// `complete` refuses unrelated persona state, but resumes an exact durable
// pending transaction after interruption. It generates SOUL/VOICE/USER/GROWTH
// from persona templates, writes them atomically, and updates
// `<dataRoot>/memory/profile.json` (name/personaKind/voice). `reset`
// backs up SOUL/VOICE/USER/GROWTH/AGENTS as `<name>.pre-reset-<utcStamp>.bak`
// and clears them.
//
// Compatibility caveats:
//
//   • Persona root: `PersistenceCore.defaultPersonaRoot` — `<repo>/persona`
//     for a checkout's data root, otherwise `<dataRoot>/persona`.
//
//   • `complete` is file-authoritative: SOUL/VOICE/USER/GROWTH + profile.json
//     must all verify before `.onboarded` is durably published.
//
//   • `repairProfile` (User, 2026-09-06) covers the one state `complete` and
//     `reset` between them cannot: an anchored install whose profile.json is
//     simply absent. It rewrites that file and NOTHING else — no persona doc,
//     no sentinel, no transaction — and refuses if a completion transaction is
//     pending, if onboarding is not provably FINISHED (the `.onboarded`
//     sentinel, or the complete legacy SOUL/VOICE/USER/GROWTH set — a lone
//     SOUL.md is an interrupted first run and takes the reset lane), or if a
//     profile already exists.

// MARK: - Result types — start

public struct AbilityOverviewEntry: Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let systemImage: String

    public init(id: String, title: String, detail: String, systemImage: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

public struct OnboardingStartResult: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case resume, repairProfile, reset, alreadyOnboarded, blockedNeedsReset, fresh
    }

    public func disposition(buildFailed: Bool) -> Disposition {
        if pendingRecovery { return .resume }
        if profileRepairRequired { return .repairProfile }
        if resetRequired { return .reset }
        if hasExisting { return buildFailed ? .blockedNeedsReset : .alreadyOnboarded }
        return .fresh
    }

    public let hasExisting: Bool
    /// Mirrors Python's `current_name if has_existing else None` — when no
    /// persona exists yet this is nil; when a persona exists the field is the
    /// raw name from `profile.json` (may be empty string if `name` is missing
    /// or empty, matching `str(profile.get('name') or '')`).
    public let currentPersonaName: String?
    public let abilityOverview: [AbilityOverviewEntry]
    /// True when a durable completion transaction exists and can only be
    /// resumed by the exact identity that created it. This additive wire field
    /// lets newer clients distinguish recoverable partial onboarding from an
    /// unrelated pre-existing persona; older clients continue to honor
    /// `has_existing` and therefore remain fail-closed.
    public let pendingRecovery: Bool
    /// True when transaction-owned persona bytes exist without a canonical
    /// identity anchor or resumable manifest. The only honest next step is an
    /// explicit, backup-preserving reset; treating this as complete would hide
    /// a broken first run, while treating it as fresh would dead-end submit.
    public let resetRequired: Bool
    /// True when onboarding really completed — the `.onboarded` sentinel, or
    /// on pre-sentinel installs the complete SOUL/VOICE/USER/GROWTH set — but
    /// `<dataRoot>/memory/profile.json` is GONE. A lone SOUL.md is an
    /// interrupted first run, not a completed one, and takes `resetRequired`.
    ///
    /// User, 2026-09-06: this state used to be invisible to the wizard. SOUL.md
    /// counted as an identity anchor on its own, so `resetRequired`
    /// stayed false, `hasExisting` was true, and the wizard exited through
    /// `onComplete` — every downstream reader then substituted a default
    /// profile and the configured agent and user names were silently gone.
    /// Reset is the WRONG answer here (it would back out perfectly good
    /// persona documents over a single missing file), so this is its own
    /// state: re-enter the two names, rewrite only profile.json, continue.
    /// Deliberately absence-only — a profile that exists but is malformed
    /// carries bytes that must not be destroyed, and Doctor still names it.
    public let profileRepairRequired: Bool

    public var requiresPresentation: Bool {
        pendingRecovery || resetRequired || profileRepairRequired || !hasExisting
    }

    public init(
        hasExisting: Bool,
        currentPersonaName: String?,
        abilityOverview: [AbilityOverviewEntry],
        pendingRecovery: Bool = false,
        resetRequired: Bool = false,
        profileRepairRequired: Bool = false
    ) {
        self.hasExisting = hasExisting
        self.currentPersonaName = currentPersonaName
        self.abilityOverview = abilityOverview
        self.pendingRecovery = pendingRecovery
        self.resetRequired = resetRequired
        self.profileRepairRequired = profileRepairRequired
    }
}

// MARK: - Result types — complete

public struct OnboardingCompletePayload: Sendable, Equatable {
    public let agentName: String
    public let personaType: String
    public let userName: String

    public init(agentName: String, personaType: String, userName: String) {
        self.agentName = agentName
        self.personaType = personaType
        self.userName = userName
    }
}

public struct OnboardingCompleteResult: Sendable, Equatable {
    public let ok: Bool
    public let agentName: String?
    public let personaType: String?
    public let userName: String?
    public let error: String?
    public let detail: String?

    public var requiresPersonaReset: Bool { error == "persona_already_exists" }
    public var requiresProfileRepairRecheck: Bool {
        error == "profile_already_present" || error == "onboarding_in_progress"
    }

    public init(
        ok: Bool,
        agentName: String? = nil,
        personaType: String? = nil,
        userName: String? = nil,
        error: String? = nil,
        detail: String? = nil
    ) {
        self.ok = ok
        self.agentName = agentName
        self.personaType = personaType
        self.userName = userName
        self.error = error
        self.detail = detail
    }
}

// MARK: - Result types — reset

public struct OnboardingResetResult: Sendable, Equatable {
    public let ok: Bool
    public let backedUp: [String]
    public let error: String?

    public init(
        ok: Bool,
        backedUp: [String] = [],
        error: String? = nil
    ) {
        self.ok = ok
        self.backedUp = backedUp
        self.error = error
    }
}

// MARK: - Errors

public enum OnboardingError: Error, Sendable, Equatable, LocalizedError {
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .ioFailure(let s): return "io failure: \(s)"
        }
    }
}

// MARK: - SwiftNative

public struct SwiftNativeOnboardingClient: Sendable {
    private let personaRoot: URL
    private let dataRoot: URL
    private let profileJSONPath: URL

    private struct OnboardingTargetIntent: Codable, Sendable {
        let role: String
        let content: String
        let sha256: String
        /// Hash of the bytes that existed when the transaction was prepared.
        /// Nil means the target was required to be absent.
        let baseSHA256: String?
    }

    private struct OnboardingTransactionManifest: Codable, Sendable {
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

    private enum OnboardingResetPhase: String, Codable, Sendable {
        case prepared
        case backupsCommitted
        case sourcesRemoved
    }

    private struct OnboardingResetTargetIntent: Codable, Sendable {
        let role: String
        let contentBase64: String
        let sha256: String
        let backupFileName: String
    }

    /// Durable reset intent. The original bytes live in the manifest so a
    /// restart can reconstruct a missing backup without relying on a source
    /// file that may already have been removed by an earlier phase.
    private struct OnboardingResetTransactionManifest: Codable, Sendable {
        let schemaVersion: Int
        let transactionID: String
        let createdAt: String
        let backupStamp: String
        let personaRoot: String
        let dataRoot: String
        let completionManifestSHA256: String?
        let sentinelSHA256: String?
        let phase: OnboardingResetPhase
        let targets: [OnboardingResetTargetIntent]
    }

    static let pendingTransactionRelativePath = "onboarding/pending-completion.json"
    static let pendingResetTransactionRelativePath = "onboarding/pending-reset.json"

    public init(personaRoot: URL? = nil, dataRoot: URL? = nil) {
        let resolvedDataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.personaRoot = personaRoot ?? Self.resolvePersonaRoot()
        self.dataRoot = resolvedDataRoot
        self.profileJSONPath = resolvedDataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    /// Resolve the persona root by delegating to `PersonaRootResolver.resolve()`
    /// — the one canonical rule. The previous Onboarding-local resolver
    /// diverged from PersonaEngine (env-first, sibling-dir before canonical)
    /// and could land the wizard at a different root than the engine reading
    /// the persona at chat/runtime — onboarding would write SOUL/USER docs to
    /// one location while PersonaEngine read from another. Single source of
    /// truth: PersonaRootResolver.
    public static func resolvePersonaRoot() -> URL {
        return PersonaRootResolver.resolve()
    }

    // MARK: start

    public func startOnboarding() async throws -> OnboardingStartResult {
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(transactionManifestPath) {
            // A reset is an operation, not an ambiguous half-onboarded state.
            // Finish its exact manifest before exposing start state so a crash
            // after one rename can never make the wizard exit or resume the
            // completion transaction the reset was cancelling.
            try await reconcilePendingResetLocked(persistence: persistence)

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
            // fix-blank-install-onboarding (2026-08-02, revised by gpt-5.5
            // review): USER.md is NEVER proof that onboarding completed, in ANY
            // gate. Two independent reasons:
            //
            //   1. It is a generator-owned file. `UserMDGenerator.regenerate`
            //      replaces the whole document with its own autogen body, so
            //      onboarding's template prose survives only until the first
            //      regeneration. Content that a subsystem rewrites on a timer
            //      cannot be durable evidence of an event.
            //   2. Accepting its content is the circularity that hid the wizard
            //      on blank installs. A blank machine wrote a header-only
            //      USER.md, USER.md satisfied "already onboarded", and the
            //      wizard never appeared. Any rule of the shape "USER.md's
            //      content proves onboarding" can relatch the moment one write
            //      escapes the producer gate.
            //
            // A genuinely completed install always carries SOUL.md (written
            // first in the commit order and never touched by the generator) and,
            // since the transaction landed, `.onboarded`. Those are the proofs.
            // `MemoryV2.UserMDGenerator.onboardingHasCompleted` accepts exactly
            // the same two — the three gates agree by EXCLUDING the ambiguous
            // file rather than by each re-deriving a subtle predicate.
            //
            // USER.md still matters to `completeOnboarding`, but only as bytes
            // that must not be destroyed silently — see `classifyUserDoc`.
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
            // User, 2026-09-06: proof that onboarding FINISHED, and the anchor
            // the profile-repair lane stands on. SOUL.md alone is NOT that
            // proof: it is written first in the commit order, so an
            // interrupted first run leaves exactly a lone SOUL.md, and
            // accepting it here wrote a profile and told the user the agent
            // was back while VOICE/USER/GROWTH and the sentinel were still
            // absent. `repairProfile` re-checks the same predicate.
            let hasCompletionAnchor = Self.hasCompletionAnchor(
                personaTargets: targets,
                fileManager: fm
            )
            // Persona bytes with no proof of completion: partial state, which
            // takes the reset lane. USER.md is excluded as evidence for the
            // reason above — the generator writes a header-only one on blank
            // machines, and accepting it would hide the wizard again.
            let hasPartialPersonaState = !hasCompletionAnchor
                && (fm.fileExists(atPath: soulPath.path)
                    || fm.fileExists(atPath: voicePath.path)
                    || fm.fileExists(atPath: growthPath.path))
            // `hasPartialPersonaState` (and therefore `resetRequired`) requires
            // NO completion anchor, so the two states can never both be true.
            let profileRepairRequired = pending == nil
                && hasCompletionAnchor
                && !fm.fileExists(atPath: profileJSONPath.path)
            let rawName = pending?.agentName ?? Self.readPersonaName(at: profileJSONPath)
            let currentName: String? = hasExisting ? rawName : nil
            return OnboardingStartResult(
                hasExisting: hasExisting,
                currentPersonaName: currentName,
                abilityOverview: Self.abilityOverview,
                pendingRecovery: pending != nil,
                resetRequired: pending == nil && hasPartialPersonaState,
                profileRepairRequired: profileRepairRequired
            )
        }
    }

    // MARK: complete

    /// Completes onboarding as a durable, resumable transaction. The manifest
    /// is committed before any persona byte. It carries the exact intended
    /// content, its hash, the original target hash (or required absence), and
    /// the normalized identity. A retry may therefore resume only this exact
    /// transaction; unrelated files or a different identity fail closed.
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
        let persistence = SwiftNativePersistenceCore()
        let manifestPath = transactionManifestPath
        return try await persistence.withFileLock(manifestPath) {
            try await reconcilePendingResetLocked(persistence: persistence)
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
                // Without a transaction manifest, any live persona/sentinel is
                // unrelated pre-existing state and must never be adopted as if
                // this call created it.
                //
                // fix-blank-install-onboarding (gpt-5.5 review BLOCKING 1): this
                // gate used to be a raw `fileExists` sweep INCLUDING USER.md,
                // which put it at odds with `startOnboarding`. A machine
                // contaminated by the old launch bug carries a header-only
                // USER.md: the start gate correctly opens the wizard, and this
                // gate then refused Build with `persona_already_exists` — a dead
                // end. The two gates now classify USER.md with the same
                // predicate. A `.generatorProjection` is a reproducible view of
                // the memory store, so it is overwritable (its exact bytes are
                // pinned as the transaction's base hash below); `.authored`
                // bytes still block, because reset must back them up first.
                let allTargets = Self.expectedTargetURLs(
                    personaRoot: personaRoot,
                    profilePath: profileJSONPath,
                    dataRoot: dataRoot
                )
                let userPath = allTargets["user"]!
                let userShape = Self.classifyUserDoc(at: userPath)
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
                // An overwritable projection is still bytes on disk, so the
                // transaction records the exact hash it intends to replace.
                // `ensureCommitted` then refuses if anything else changed the
                // file between manifest publication and commit — the same
                // fail-closed contract profile.json already had.
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

                // Strict profile preparation happens before the manifest is
                // published. Malformed existing bytes are preserved and the
                // operation fails closed rather than normalizing from `{}`.
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
                try Self.writeTransaction(manifest, to: manifestPath)
            }

            return try await commitPreparedTransaction(
                manifest,
                manifestPath: manifestPath,
                persistence: persistence
            )
        }
    }

    /// Resume the exact durable intent already recorded by onboarding. This is
    /// intentionally payload-free: after an app restart the UI should not have
    /// to reconstruct the original user name/persona inputs or guess at staged
    /// bytes. The signed-by-hash manifest is the only accepted recovery source.
    public func resumePendingOnboarding() async throws -> OnboardingCompleteResult {
        let persistence = SwiftNativePersistenceCore()
        let manifestPath = transactionManifestPath
        return try await persistence.withFileLock(manifestPath) {
            try await reconcilePendingResetLocked(persistence: persistence)
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
                manifestPath: manifestPath,
                persistence: persistence
            )
        }
    }

    // MARK: repair profile

    /// Rewrite ONLY `profile.json` on an install that really did onboard but
    /// lost that one file (User, 2026-09-06 — see `profileRepairRequired`).
    ///
    /// The persona documents are the identity of record and are left exactly as
    /// they are; this restores the single derived file that went missing, with
    /// the same content and shape `completeOnboarding` would have written for
    /// these names. Fail-closed wherever this is not the honest operation: a
    /// pending completion transaction already owns profile.json and must be
    /// resumed instead, an install with no proof that onboarding FINISHED
    /// (sentinel, or the complete legacy document set) belongs in the wizard's
    /// normal lane, and an existing profile is never overwritten — those bytes
    /// may be the user's only copy. Both names are required: a repair that
    /// invents one of them writes a second wrong answer over the first.
    public func repairProfile(payload: OnboardingCompletePayload) async throws -> OnboardingCompleteResult {
        let agentName = payload.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = payload.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaType = payload.personaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if agentName.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_agent_name")
        }
        // User, 2026-09-06: an empty user name used to become "User". Repair
        // exists because the real names were lost; substituting a placeholder
        // for one of them writes a second wrong answer over the first.
        if userName.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_user_name")
        }
        if !PersonaTemplates.validTypes.contains(personaType) {
            return OnboardingCompleteResult(ok: false, error: "invalid_persona_type")
        }
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(transactionManifestPath) {
            let targets = Self.expectedTargetURLs(
                personaRoot: personaRoot,
                profilePath: profileJSONPath,
                dataRoot: dataRoot
            )
            // User, 2026-09-06: every refusal is decided BEFORE any state is
            // reconciled. `reconcilePendingResetLocked` commits a pending
            // reset — it backs up and REMOVES the persona documents — so
            // running it first let a repair that was going to be refused
            // destroy state on its way to the refusal.
            if let refusal = try profileRepairRefusalLocked(targets: targets) {
                return refusal
            }
            try await reconcilePendingResetLocked(persistence: persistence)
            // That reconcile may have committed a reset. Re-decide over the
            // state it actually left behind rather than the state checked
            // above; the anchor it was standing on may be gone.
            if let refusal = try profileRepairRefusalLocked(targets: targets) {
                return refusal
            }
            // User, 2026-09-06: the absence decision and the write now happen
            // under the SAME profile-file lock. They used to be split by the
            // plan build, which re-read profile.json — so a profile created in
            // that window was recorded as the plan's BASE hash, and
            // `ensureCommitted` permits replacing the base. The repair could
            // overwrite the very file whose absence it had just confirmed.
            return try await persistence.withFileLock(profileJSONPath) {
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
                // Same intent shape the completion transaction commits, so the
                // write keeps its fail-closed guarantee: the plan saw no file,
                // so its base hash is nil and `ensureCommitted` refuses any
                // existing bytes rather than clobbering them. The written bytes
                // are verified after.
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

    /// The complete set of reasons a profile repair is not the honest
    /// operation, in one place so it can be re-decided after a reconcile
    /// (User, 2026-09-06). Returns nil when the repair may proceed. Caller
    /// holds the transaction-manifest lock.
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

    private func commitPreparedTransaction(
        _ manifest: OnboardingTransactionManifest,
        manifestPath: URL,
        persistence: SwiftNativePersistenceCore
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
            try await persistence.withFileLock(target) {
                try Self.ensureCommitted(intent, to: target)
            }
        }

        // The completion marker is deliberately last. A successful result is
        // impossible until every document and profile byte is durable.
        guard let sentinelIntent = intents["sentinel"], let sentinelURL = targetURLs["sentinel"] else {
            throw OnboardingError.ioFailure("onboarding transaction missing completion sentinel")
        }
        try await persistence.withFileLock(sentinelURL) {
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

    // MARK: reset

    /// Reset is a durable phased transaction:
    ///   1. record the exact original bytes and marker hashes;
    ///   2. atomically publish and verify every backup;
    ///   3. remove only source bytes matching the recorded evidence;
    ///   4. clear the completion manifest and sentinel; and
    ///   5. remove the reset manifest last.
    /// Any restart resumes the same intent instead of starting another set of
    /// timestamped renames or reporting a partially reset persona as ready.
    public func resetOnboarding(confirm: Bool) async throws -> OnboardingResetResult {
        if !confirm {
            return OnboardingResetResult(ok: false, error: "confirmation_required")
        }
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(transactionManifestPath) {
            let manifest: OnboardingResetTransactionManifest
            if let pending = try Self.loadResetTransactionIfPresent(
                at: resetTransactionManifestPath,
                personaRoot: personaRoot,
                dataRoot: dataRoot
            ) {
                manifest = pending
            } else {
                manifest = try await prepareResetTransactionLocked(persistence: persistence)
            }
            return try await commitPreparedResetTransaction(
                manifest,
                persistence: persistence
            )
        }
    }

    private func reconcilePendingResetLocked(
        persistence: SwiftNativePersistenceCore
    ) async throws {
        guard let pending = try Self.loadResetTransactionIfPresent(
            at: resetTransactionManifestPath,
            personaRoot: personaRoot,
            dataRoot: dataRoot
        ) else { return }
        _ = try await commitPreparedResetTransaction(pending, persistence: persistence)
    }

    private func prepareResetTransactionLocked(
        persistence: SwiftNativePersistenceCore
    ) async throws -> OnboardingResetTransactionManifest {
        try ensureDirectoryExists(personaRoot)
        let transactionID = UUID().uuidString.lowercased()
        let backupStamp = Self.utcStamp()
        var targets: [OnboardingResetTargetIntent] = []
        for definition in Self.resetTargetDefinitions {
            let source = personaRoot.appendingPathComponent(definition.fileName)
            let intent: OnboardingResetTargetIntent? = try await persistence.withFileLock(source) {
                guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                let data: Data
                do {
                    data = try Data(contentsOf: source)
                } catch {
                    throw OnboardingError.ioFailure(
                        "read \(definition.fileName) for reset failed: \(error.localizedDescription)"
                    )
                }
                return OnboardingResetTargetIntent(
                    role: definition.role,
                    contentBase64: data.base64EncodedString(),
                    sha256: Self.sha256(data),
                    backupFileName: Self.resetBackupFileName(
                        sourceFileName: definition.fileName,
                        backupStamp: backupStamp,
                        transactionID: transactionID
                    )
                )
            }
            if let intent { targets.append(intent) }
        }

        let sentinel = dataRoot.appendingPathComponent(".onboarded")
        let sentinelSHA256 = try await persistence.withFileLock(sentinel) {
            try Self.fileHashIfPresent(sentinel, label: ".onboarded")
        }
        // The caller holds the completion-manifest lock for the whole reset
        // operation, so reading it again through withFileLock would nest the
        // same flock. Record its exact bytes directly under that outer lock.
        let completionManifestSHA256 = try Self.fileHashIfPresent(
            transactionManifestPath,
            label: "pending onboarding completion"
        )
        let manifest = OnboardingResetTransactionManifest(
            schemaVersion: 1,
            transactionID: transactionID,
            createdAt: NativeTimestampFormat.fractionalZulu(Date()),
            backupStamp: backupStamp,
            personaRoot: Self.canonicalPath(personaRoot),
            dataRoot: Self.canonicalPath(dataRoot),
            completionManifestSHA256: completionManifestSHA256,
            sentinelSHA256: sentinelSHA256,
            phase: .prepared,
            targets: targets
        )
        try Self.writeResetTransaction(manifest, to: resetTransactionManifestPath)
        return manifest
    }

    private func commitPreparedResetTransaction(
        _ manifest: OnboardingResetTransactionManifest,
        persistence: SwiftNativePersistenceCore
    ) async throws -> OnboardingResetResult {
        for target in manifest.targets {
            let backup = personaRoot.appendingPathComponent(target.backupFileName)
            try await persistence.withFileLock(backup) {
                try Self.ensureResetBackup(target, at: backup)
            }
        }
        for target in manifest.targets {
            guard let definition = Self.resetTargetDefinitions.first(where: { $0.role == target.role }) else {
                throw OnboardingError.ioFailure("reset transaction contains unknown role '\(target.role)'")
            }
            let source = personaRoot.appendingPathComponent(definition.fileName)
            try await persistence.withFileLock(source) {
                try Self.ensureResetSourceRemoved(target, at: source)
            }
        }
        // Re-verify every backup after source deletion. Only then may the two
        // completion markers be cleared. The completion manifest is removed
        // first so an older binary can fail closed on the still-present
        // sentinel, but cannot replay a completion the reset already cancelled.
        for target in manifest.targets {
            let backup = personaRoot.appendingPathComponent(target.backupFileName)
            try await persistence.withFileLock(backup) {
                try Self.ensureResetBackup(target, at: backup)
            }
        }
        try Self.ensureResetMarkerRemoved(
            expectedSHA256: manifest.completionManifestSHA256,
            at: transactionManifestPath,
            label: "pending onboarding completion"
        )
        let sentinel = dataRoot.appendingPathComponent(".onboarded")
        let expectedSentinelSHA256 = manifest.sentinelSHA256
        try await persistence.withFileLock(sentinel) {
            try Self.ensureResetMarkerRemoved(
                expectedSHA256: expectedSentinelSHA256,
                at: sentinel,
                label: ".onboarded"
            )
        }

        do {
            try FileManager.default.removeItem(at: resetTransactionManifestPath)
            try SwiftNativePersistenceCore.syncDirectory(resetTransactionManifestPath.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure(
                "clear onboarding reset transaction failed: \(error.localizedDescription)"
            )
        }
        return OnboardingResetResult(
            ok: true,
            backedUp: manifest.targets.map {
                personaRoot.appendingPathComponent($0.backupFileName).path
            }
        )
    }

    // MARK: Internals

    private var transactionManifestPath: URL {
        dataRoot.appendingPathComponent(Self.pendingTransactionRelativePath)
    }

    private var resetTransactionManifestPath: URL {
        dataRoot.appendingPathComponent(Self.pendingResetTransactionRelativePath)
    }

    private static func canonicalPath(_ url: URL) -> String {
        // Keep the transaction identity stable even when the target directory
        // did not exist at preparation time. Resolving symlinks can change the
        // string after directory creation and falsely orphan a valid manifest.
        url.standardizedFileURL.path
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func identityHash(
        agentName: String,
        personaType: String,
        userName: String,
        personaRoot: URL,
        profilePath: URL
    ) -> String {
        let components = [
            "onboarding-v1",
            agentName,
            personaType,
            userName,
            canonicalPath(personaRoot),
            canonicalPath(profilePath),
        ]
        return sha256(Data(components.joined(separator: "\u{0}").utf8))
    }

    /// What a USER.md on disk actually is.
    ///
    /// USER.md has two writers with opposite meanings. Onboarding writes it
    /// once from a persona template (prose about the user). `UserMDGenerator`
    /// then OWNS it: every regeneration replaces the whole file with an
    /// `<!-- USER_MD_AUTOGEN_START -->…END` body (a heading plus one bullet
    /// per active, recall-eligible, durable memory whose kind is in the
    /// person-kind allowlist — see `userIdentityKinds` in
    /// MemoryV2+UserMDGen.swift), preserving only a
    /// `<!-- USER_PREAMBLE_START -->…END` region if one is already there.
    ///
    /// So the only thing USER.md's content can prove is which of those two
    /// wrote it last — never that onboarding completed. See the `startOnboarding`
    /// comment for why no gate treats it as proof.
    enum UserDocShape: Equatable {
        /// No file, or unreadable bytes. Nothing to protect, nothing to prove.
        case absent
        /// Everything present is explicable as `UserMDGenerator` output: the
        /// autogen body region, autogen/preamble markers, headings, blank
        /// lines. Safe for onboarding to overwrite — it is a projection of the
        /// memory store, reproducible from SQLite.
        case generatorProjection
        /// Carries bytes the generator cannot produce: prose or bullets OUTSIDE
        /// the autogen body region, or human-edited preamble content. Never
        /// overwritten silently; reset backs it up first.
        case authored
    }

    /// Classify USER.md. Deliberately conservative: anything the generator
    /// could plausibly have emitted classifies as `.generatorProjection`, so
    /// the only files that block onboarding are ones with genuinely foreign
    /// bytes in them.
    static func classifyUserDoc(at path: URL) -> UserDocShape {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return .absent }
        // Strip the generator's own body region wholesale. Its contents —
        // heading, memory bullets, blank lines — are a projection of SQLite and
        // say nothing about who onboarded.
        var remainder = text
        if let start = remainder.range(of: UserMDAutogenMarkers.bodyStart),
           let end = remainder.range(of: UserMDAutogenMarkers.bodyEnd, range: start.upperBound..<remainder.endIndex) {
            remainder.removeSubrange(start.lowerBound..<end.upperBound)
        }
        for rawLine in remainder.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }           // markdown headings
            if line.hasPrefix("<!--") { continue }        // autogen/preamble markers
            return .authored
        }
        return .generatorProjection
    }

    /// Proof that onboarding FINISHED on this Mac: the `.onboarded` sentinel,
    /// or — for installs that predate it — the complete legacy document set.
    ///
    /// User, 2026-09-06: deliberately not "SOUL.md exists". SOUL is written
    /// first in the commit order, so a first run interrupted after one write
    /// leaves exactly that; it is partial state, and partial state belongs in
    /// the reset lane, never the profile-repair lane. Requiring all four
    /// documents for the legacy case matches what `NativeAgentPublicSafety`
    /// accepts as a pre-sentinel install.
    private static func hasCompletionAnchor(
        personaTargets targets: [String: URL],
        fileManager fm: FileManager
    ) -> Bool {
        if fm.fileExists(atPath: targets["sentinel"]!.path) { return true }
        return NativeAgentPublicSafety.hasLegacyCompletionAnchor(
            personaRoot: targets["soul"]!.deletingLastPathComponent(),
            profileURL: targets["profile"]!,
            allowMissingProfile: true
        )
    }

    private static func expectedTargetURLs(
        personaRoot: URL,
        profilePath: URL,
        dataRoot: URL
    ) -> [String: URL] {
        [
            "soul": personaRoot.appendingPathComponent("SOUL.md"),
            "voice": personaRoot.appendingPathComponent("VOICE.md"),
            "user": personaRoot.appendingPathComponent("USER.md"),
            "growth": personaRoot.appendingPathComponent("GROWTH.md"),
            "profile": profilePath,
            "sentinel": dataRoot.appendingPathComponent(".onboarded"),
        ]
    }

    private static var resetTargetDefinitions: [(role: String, fileName: String)] {
        [
            ("soul", "SOUL.md"),
            ("voice", "VOICE.md"),
            ("user", "USER.md"),
            ("growth", "GROWTH.md"),
            ("agents", "AGENTS.md"),
        ]
    }

    private static func resetBackupFileName(
        sourceFileName: String,
        backupStamp: String,
        transactionID: String
    ) -> String {
        "\(sourceFileName).pre-reset-\(backupStamp)-\(transactionID).bak"
    }

    private static func writeTransaction(_ manifest: OnboardingTransactionManifest, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw OnboardingError.ioFailure("encode onboarding transaction failed: \(error.localizedDescription)")
        }
        try atomicWriteText(String(decoding: data, as: UTF8.self), to: path)
    }

    private static func writeResetTransaction(
        _ manifest: OnboardingResetTransactionManifest,
        to path: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw OnboardingError.ioFailure(
                "encode onboarding reset transaction failed: \(error.localizedDescription)"
            )
        }
        try atomicWriteData(data, to: path)
    }

    private static func loadResetTransactionIfPresent(
        at path: URL,
        personaRoot: URL,
        dataRoot: URL
    ) throws -> OnboardingResetTransactionManifest? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw OnboardingError.ioFailure(
                "read onboarding reset transaction failed: \(error.localizedDescription)"
            )
        }
        let manifest: OnboardingResetTransactionManifest
        do {
            manifest = try JSONDecoder().decode(OnboardingResetTransactionManifest.self, from: data)
        } catch {
            throw OnboardingError.ioFailure(
                "onboarding reset transaction is malformed; preserving it for recovery"
            )
        }
        guard manifest.schemaVersion == 1,
              manifest.personaRoot == canonicalPath(personaRoot),
              manifest.dataRoot == canonicalPath(dataRoot),
              !manifest.transactionID.isEmpty,
              !manifest.backupStamp.isEmpty else {
            throw OnboardingError.ioFailure(
                "onboarding reset transaction belongs to a different root or schema"
            )
        }
        let definitions = Dictionary(uniqueKeysWithValues: resetTargetDefinitions.map { ($0.role, $0.fileName) })
        let roles = manifest.targets.map(\.role)
        guard Set(roles).count == roles.count,
              roles.allSatisfy({ definitions[$0] != nil }) else {
            throw OnboardingError.ioFailure("onboarding reset transaction target set is invalid")
        }
        for target in manifest.targets {
            guard let fileName = definitions[target.role] else {
                throw OnboardingError.ioFailure("onboarding reset transaction target role is invalid")
            }
            let expectedBackup = resetBackupFileName(
                sourceFileName: fileName,
                backupStamp: manifest.backupStamp,
                transactionID: manifest.transactionID
            )
            guard target.backupFileName == expectedBackup,
                  URL(fileURLWithPath: target.backupFileName).lastPathComponent == target.backupFileName,
                  let content = Data(base64Encoded: target.contentBase64),
                  sha256(content) == target.sha256 else {
                throw OnboardingError.ioFailure(
                    "onboarding reset transaction evidence is invalid for '\(target.role)'"
                )
            }
        }
        for markerHash in [manifest.completionManifestSHA256, manifest.sentinelSHA256].compactMap({ $0 }) {
            guard markerHash.count == 64,
                  markerHash.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 0x30...0x39, 0x61...0x66: return true
                      default: return false
                      }
                  }) else {
                throw OnboardingError.ioFailure("onboarding reset marker evidence is invalid")
            }
        }
        return manifest
    }

    private static func fileHashIfPresent(_ path: URL, label: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            return sha256(try Data(contentsOf: path))
        } catch {
            throw OnboardingError.ioFailure("read \(label) during reset failed: \(error.localizedDescription)")
        }
    }

    private static func resetContent(_ intent: OnboardingResetTargetIntent) throws -> Data {
        guard let data = Data(base64Encoded: intent.contentBase64), sha256(data) == intent.sha256 else {
            throw OnboardingError.ioFailure("reset evidence hash mismatch for '\(intent.role)'")
        }
        return data
    }

    private static func ensureResetBackup(
        _ intent: OnboardingResetTargetIntent,
        at backup: URL
    ) throws {
        let intended = try resetContent(intent)
        if FileManager.default.fileExists(atPath: backup.path) {
            let existing: Data
            do {
                existing = try Data(contentsOf: backup)
            } catch {
                throw OnboardingError.ioFailure(
                    "read reset backup \(backup.lastPathComponent) failed: \(error.localizedDescription)"
                )
            }
            guard sha256(existing) == intent.sha256 else {
                throw OnboardingError.ioFailure(
                    "reset backup \(backup.lastPathComponent) changed outside the pending transaction"
                )
            }
            try SwiftNativePersistenceCore.syncDirectory(backup.deletingLastPathComponent())
            return
        }
        try atomicWriteData(intended, to: backup)
        let persisted = try Data(contentsOf: backup)
        guard sha256(persisted) == intent.sha256 else {
            throw OnboardingError.ioFailure(
                "reset backup \(backup.lastPathComponent) failed post-write verification"
            )
        }
    }

    private static func ensureResetSourceRemoved(
        _ intent: OnboardingResetTargetIntent,
        at source: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            try SwiftNativePersistenceCore.syncDirectory(source.deletingLastPathComponent())
            return
        }
        let current: Data
        do {
            current = try Data(contentsOf: source)
        } catch {
            throw OnboardingError.ioFailure(
                "read \(source.lastPathComponent) during reset failed: \(error.localizedDescription)"
            )
        }
        guard sha256(current) == intent.sha256 else {
            throw OnboardingError.ioFailure(
                "\(source.lastPathComponent) changed outside the pending reset transaction"
            )
        }
        do {
            try FileManager.default.removeItem(at: source)
            try SwiftNativePersistenceCore.syncDirectory(source.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure(
                "remove \(source.lastPathComponent) during reset failed: \(error.localizedDescription)"
            )
        }
        guard !FileManager.default.fileExists(atPath: source.path) else {
            throw OnboardingError.ioFailure("\(source.lastPathComponent) remained after reset removal")
        }
    }

    private static func ensureResetMarkerRemoved(
        expectedSHA256: String?,
        at path: URL,
        label: String
    ) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
            return
        }
        guard let expectedSHA256 else {
            throw OnboardingError.ioFailure("\(label) appeared outside the pending reset transaction")
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw OnboardingError.ioFailure("read \(label) before reset removal failed")
        }
        guard sha256(data) == expectedSHA256 else {
            throw OnboardingError.ioFailure("\(label) changed outside the pending reset transaction")
        }
        do {
            try FileManager.default.removeItem(at: path)
            try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure(
                "remove \(label) during reset failed: \(error.localizedDescription)"
            )
        }
    }

    /// Strict transaction reader. The manifest contains intended persona bytes,
    /// so corruption, path substitution, duplicate roles, or hash mismatch is
    /// never recoverable by guessing.
    private static func loadTransactionIfPresent(
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

    /// Idempotently commit one staged target. Existing intended bytes prove a
    /// previous attempt reached this step. Otherwise only the exact base bytes
    /// observed at transaction preparation may be replaced.
    private static func ensureCommitted(_ intent: OnboardingTargetIntent, to path: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let current: Data
            do {
                current = try Data(contentsOf: path)
            } catch {
                throw OnboardingError.ioFailure("read \(path.lastPathComponent) during onboarding recovery failed")
            }
            let currentHash = sha256(current)
            if currentHash == intent.sha256 {
                try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
                return
            }
            guard let base = intent.baseSHA256, currentHash == base else {
                throw OnboardingError.ioFailure("\(path.lastPathComponent) changed outside the pending onboarding transaction")
            }
        } else if intent.baseSHA256 != nil {
            throw OnboardingError.ioFailure("\(path.lastPathComponent) disappeared after onboarding transaction preparation")
        }

        try atomicWriteText(intent.content, to: path)
        let committed = try Data(contentsOf: path)
        guard sha256(committed) == intent.sha256 else {
            throw OnboardingError.ioFailure("\(path.lastPathComponent) failed post-write verification")
        }
    }

    /// UTC stamp matching Python `_dt.now(_tz.utc).strftime("%Y%m%dT%H%M%SZ")`.
    /// Pure string format; no fractional seconds.
    static func utcStamp() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }

    /// Ensures `<dir>` exists with default permissions, matching
    /// Python `path.parent.mkdir(parents=True, exist_ok=True)`.
    private func ensureDirectoryExists(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw OnboardingError.ioFailure("mkdir \(dir.path) failed: \(error.localizedDescription)")
        }
    }

    /// Durable private write shared with the other canonical stores.
    static func atomicWriteText(_ content: String, to path: URL) throws {
        try atomicWriteData(Data(content.utf8), to: path)
    }

    /// Byte-preserving sibling used by reset backups. Persona files are
    /// normally UTF-8, but reset is a safety operation and must preserve the
    /// exact bytes it found rather than normalizing invalid or legacy text.
    static func atomicWriteData(_ data: Data, to path: URL) throws {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
        } catch {
            throw OnboardingError.ioFailure("write \(path.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    private struct ProfileUpdatePlan: Sendable {
        let content: String
        let baseSHA256: String?
    }

    /// Strictly load + normalize profile.json and prepare its exact replacement
    /// bytes. Existing malformed/non-object JSON is never treated as `{}`:
    /// those bytes may be important user state and are preserved fail-closed.
    ///
    /// Uses `PersonaCompiler.normalize` + `CompiledPersonalityProfile` for the
    /// normalization step — same canonical seed `default_personality()` and
    /// same field-level caps the daemon applies on every `personality()` read.
    private static func makeProfileUpdatePlan(
        profilePath: URL,
        agentName: String,
        personaType: String,
        userName: String
    ) throws -> ProfileUpdatePlan {
        var raw: [String: Any] = [:]
        var baseSHA256: String?
        if FileManager.default.fileExists(atPath: profilePath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: profilePath)
            } catch {
                throw OnboardingError.ioFailure("read existing profile.json failed: \(error.localizedDescription)")
            }
            baseSHA256 = sha256(data)
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw OnboardingError.ioFailure("existing profile.json is malformed; preserving original bytes")
            }
            guard let object = decoded as? [String: Any] else {
                throw OnboardingError.ioFailure("existing profile.json is not an object; preserving original bytes")
            }
            raw = object
        }
        // First normalize to current canonical shape.
        let current = PersonaCompiler.normalize(raw: raw, defaults: .defaults)

        // Override fields per Python L20343-L20347.
        let kindMap: [String: String] = ["female": "Female", "male": "Male", "ai": "AI"]
        let newKind = kindMap[personaType] ?? "AI"
        let voiceMap: [String: String] = [
            "female": "Warm, observational, judgment-forward.",
            "male": "Direct, dry, holds ground.",
            "ai": "Precise, characterful, honest.",
        ]
        let newVoice = voiceMap[personaType] ?? voiceMap["ai"]!

        // Build the on-disk dict. Re-runs normalize semantics: save_personality
        // in Python does {existing ∪ body} → normalize → write. We constructed
        // `current` from normalize(raw) so it already matches the
        // first-normalize step; now apply body overrides and normalize once more.
        var merged = SwiftNativePersonaEngine.profileToRawDict(current)
        merged["name"] = agentName
        merged["personaKind"] = newKind
        merged["voice"] = newVoice
        merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())
        let renormalized = PersonaCompiler.normalize(raw: merged, defaults: .defaults)
        var finalDict = SwiftNativePersonaEngine.profileToRawDict(renormalized)
        // The USER's name (not the agent's `name`). Injected AFTER normalize so
        // it survives regardless of the compiler's known-key set — the substrate
        // reads this to address the user in her inner voice (never hardcode a
        // name in the capsule/reflection cues). Trimmed; empty → omit.
        let trimmedUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserName.isEmpty {
            finalDict["userName"] = trimmedUserName
        }

        let json = JSONValue(fromFoundation: finalDict)
        let bytes = try json.serializedData(pretty: false)
        let text = String(decoding: bytes, as: UTF8.self)
        return ProfileUpdatePlan(content: text, baseSHA256: baseSHA256)
    }

    /// Best-effort read of `<dataRoot>/memory/profile.json` → `name` field.
    /// Mirrors the (now-retired, wave 37 W18) Python `NativeAgentRuntime.onboarding_start`,
    /// which read `self.root / 'memory' / 'profile.json'` (the daemon data root,
    /// NOT the persona root). Any IO/parse failure collapses to empty string,
    /// matching Python's `str(profile.get('name') or '')`.
    private static func readPersonaName(at path: URL) -> String {
        guard let data = try? Data(contentsOf: path) else { return "" }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { return "" }
        if let s = obj["name"] as? String { return s }
        return ""
    }

    /// Byte-for-byte port of the (now-retired, wave 37 W18) Python
    /// NativeAgentRuntime.onboarding_ability_overview. Six entries — chat,
    /// projects, mac, connectors, mobile, improve. This is now the sole source
    /// of the onboarding ability overview.
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
            detail: "Read approved projects, edit files, run tests, and keep receipts when access allows.",
            systemImage: "hammer"
        ),
        AbilityOverviewEntry(
            id: "mac",
            title: "Use Mac actions",
            detail: "Notifications, Spotlight, Shortcuts, files, shell, and app control behind Trust settings.",
            systemImage: "macbook"
        ),
        AbilityOverviewEntry(
            id: "connectors",
            title: "Connect services",
            detail: "Optional providers and connectors for chat models, Telegram, GitHub, email, calendar, and more.",
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

extension SwiftNativeOnboardingClient {
    public enum StarterOutcome: Equatable {
        case created
        case notesUnsaved(documentID: String, draft: String)
        case failed(String)
    }

    @MainActor
    public static func createStarterPersona(
        agentName: String,
        userName: String,
        notes: String,
        complete: (String, String) async throws -> OnboardingCompleteResult,
        reload: () async -> [PersonaDocSpec]?,
        save: (String, String) async -> Bool,
        failureMessage: (Error) -> String
    ) async -> StarterOutcome {
        do {
            let response = try await complete(
                agentName.trimmingCharacters(in: .whitespacesAndNewlines),
                userName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard response.ok else {
                return .failed(response.detail ?? response.error ?? "Could not create the persona.")
            }
            guard let documents = await reload() else {
                return .failed(
                    "The persona was created, but its documents could not be reloaded to save your setup notes. Retry from the Personality page before editing anything else."
                )
            }

            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNotes.isEmpty,
                  let soul = documents.first(where: { $0.id.uppercased() == "SOUL" })
            else {
                return .created
            }

            let draft = soul.content + "\n\n## From setup\n" + trimmedNotes + "\n"
            guard await save(soul.id, draft) else {
                return .notesUnsaved(documentID: soul.id, draft: draft)
            }
            return .created
        } catch {
            return .failed(failureMessage(error))
        }
    }
}
