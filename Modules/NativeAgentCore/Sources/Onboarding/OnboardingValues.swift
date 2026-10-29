import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingValues.swift` | Onboarding payload, result and recovery verdict vocabulary |
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
        case resume, repairProfile, profileUnreadable, reset, alreadyOnboarded, blockedNeedsReset, fresh
    }
    public func disposition(buildFailed: Bool) -> Disposition {
        if pendingRecovery { return .resume }
        if profileRepairRequired { return .repairProfile }
        if profileUnreadable != nil { return .profileUnreadable }
        if resetRequired { return .reset }
        if hasExisting { return buildFailed ? .blockedNeedsReset : .alreadyOnboarded }
        return .fresh
    }
    public let hasExisting: Bool
    /// Nil without persona state; otherwise the pending name or raw profile name (empty if missing).
    public let currentPersonaName: String?
    public let abilityOverview: [AbilityOverviewEntry]
    /// A durable completion intent exists; only its exact identity may resume it.
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
    /// Deliberately absence-only — a profile that exists but is malformed
    /// carries bytes that must not be destroyed, and Doctor still names it.
    public let profileRepairRequired: Bool
    /// A completed install whose profile.json is there but cannot be read: the
    /// receipt (path, reason, lever). Neither repair nor reset may touch those
    /// bytes; moving the file aside turns this into the absence repair lane.
    public let profileUnreadable: String?
    public var requiresPresentation: Bool {
        pendingRecovery || resetRequired || profileRepairRequired || profileUnreadable != nil || !hasExisting
    }
    public init(
        hasExisting: Bool,
        currentPersonaName: String?,
        abilityOverview: [AbilityOverviewEntry],
        pendingRecovery: Bool = false,
        resetRequired: Bool = false,
        profileRepairRequired: Bool = false,
        profileUnreadable: String? = nil
    ) {
        self.hasExisting = hasExisting
        self.currentPersonaName = currentPersonaName
        self.abilityOverview = abilityOverview
        self.pendingRecovery = pendingRecovery
        self.resetRequired = resetRequired
        self.profileRepairRequired = profileRepairRequired
        self.profileUnreadable = profileUnreadable
    }
}
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
public enum OnboardingError: Error, Sendable, Equatable, LocalizedError {
    case ioFailure(String)
    public var errorDescription: String? {
        switch self {
        case .ioFailure(let s): return "io failure: \(s)"
        }
    }
}
