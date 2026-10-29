import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `DoctorReadings.swift` | Shared Doctor readings, ownership, recovery steps, executable repair and provider observation values; CheckResult preserves the report and experience projection shape; app defects never create coding requests |

/// Stable Doctor check shape:   {"id", "title", "status", "detail", "harm", "repair"}. Readings use "unmeasured"; adverse rows
/// say why they matter in `harm`.
public struct CheckResult: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var detail: String
    public var harm: String?
    /// Executable repair instruction in reports; legacy core checks are normalized by EngineDoctorRuntime before they reach
    /// consumers.
    public var repair: String?
    public var receipt: String?
    /// Whether the repair changed app-owned state; nil in older readings.
    public var repairApplied: Bool?
    public var human_action: String?
    /// Live handler availability observed by EngineDoctorRuntime, not inferred from human instructions or completion receipts.
    /// Nil in older reports.
    public var repair_available: Bool?
    /// False where unattended repair would discard live continuity.
    public var automaticRepairEligible: Bool?
    /// Sign-ins and permissions join the consent inbox ask; app-defect recovery steps stay separate from consent.
    public var ask: DoctorAskKind?
    /// Who heals an adverse row (`DoctorOwner.of`). A check declares only `builder` where a build is the fix; Doctor derives
    /// the rest.
    public var owner: DoctorOwner?
    public var source: String?
    public var nextCall: String?
    public var repairExperience: Experience?

    public init(
        source: String? = nil,
        nextCall: String? = nil,
        id: String,
        title: String,
        status: String,
        detail: String,
        harm: String? = nil,
        repair: String? = nil,
        receipt: String? = nil,
        repairApplied: Bool? = nil,
        human_action: String? = nil,
        repair_available: Bool? = nil,
        automaticRepairEligible: Bool? = nil,
        ask: DoctorAskKind? = nil,
        owner: DoctorOwner? = nil,
        repairExperience: Experience? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.harm = harm
        self.repair = repair
        self.receipt = receipt
        self.repairApplied = repairApplied
        self.human_action = human_action
        self.repair_available = repair_available
        self.automaticRepairEligible = automaticRepairEligible
        self.ask = ask
        self.owner = owner
        self.source = source
        self.nextCall = nextCall
        self.repairExperience = repairExperience
    }

    /// The human step for an adverse row, including older cached rows with only legacy repair copy. Doctor repairs what it can;
    /// a row with neither a repair nor a step names its harm before it can be routed.
    public func recoveryAction(repairAvailable: Bool) -> String? {
        if let action = human_action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return action
        }
        guard !repairAvailable, DoctorSafeRepairPolicy.isAdverse(status) else { return nil }
        if let action = repair?.trimmingCharacters(in: .whitespacesAndNewlines),
           !action.isEmpty, !DoctorSafeRepairPolicy.isCoreRepairInstruction(action) {
            return action
        }
        return nil
    }
}

extension CheckResult {
    /// The check an owed repair is about: its operation names it; a measured row is itself.
    public var checkID: String {
        if let domain = repairExperience?.outcome?.domain, domain.hasPrefix("doctor.check:") { return String(domain.dropFirst("doctor.check:".count)) }
        return id
    }

    public var repairOwner: String? {
        if repairExperience != nil { return source }
        return owner == .builder ? "NativeAgent code: " + checkID : source
    }

    public var repairCall: String? {
        if repairExperience != nil { return nextCall }
        guard DoctorSafeRepairPolicy.isAdverse(status), ask == nil else { return nil }
        if let nextCall { return nextCall }
        if repair_available == true {
            return ToolFailureError.call("app", ["action": .string("doctor.repair"), "args": .object(["check_id": .string(id)])])
        }
        return nil
    }

    public var repairTap: String? {
        if repairExperience != nil { return human_action }
        guard DoctorSafeRepairPolicy.isAdverse(status), ask != nil || repairCall == nil else { return nil }
        if owner == .builder {
            return "Ask the person to resolve \(repairOwner ?? checkID). " + (recoveryAction(repairAvailable: false)
                ?? "Report this app defect and failed check \(checkID) to NativeAgent's maintainer; preserve saved data and all Trust, sign-in and privacy decisions.")
        }
        return recoveryAction(repairAvailable: false)
    }

    public var remedy: JSONValue? {
        guard DoctorSafeRepairPolicy.isAdverse(status), let repairOwner else { return nil }
        if let repairTap, ask != nil { return Repair.why(owner: repairOwner, tap: repairTap) }
        guard repairCall != nil || repairTap != nil else { return nil }
        return Repair.remedy(owner: repairOwner,
            nextCall: repairCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }, tap: repairTap,
            instruction: repair_available == true
            ? "Press Repair in Diagnostics → Health checks to retry this check."
            : repairCall == nil ? repairTap
            : repair ?? human_action ?? "Use the native repair action for \(repairOwner), preserving the original bytes.")
    }

    public var repairFace: String {
        // Evidence is prose; remedies and executable calls have their own fields.
        detail
    }

    /// The reported row: its human step, an executable repair only where one runs, and its owner. Every writer of a Doctor
    /// report settles through it.
    public func settled(liveAvailable: Bool, coreAvailable: Bool) -> CheckResult {
        let humanAction = recoveryAction(repairAvailable: liveAvailable || coreAvailable) ?? (liveAvailable
            ? "Press Repair in Diagnostics → Health checks to retry this live service."
            : nil)
        var reading = self
        reading.repair = liveAvailable ? "Press Repair in Diagnostics → Health checks to retry this live service." : (coreAvailable ? repair : nil)
        reading.human_action = humanAction
        reading.repair_available = liveAvailable || coreAvailable
        reading.owner = DoctorOwner.of(self, repairAvailable: liveAvailable || coreAvailable)
        return reading
    }
}

public enum DoctorAskKind: String, Sendable, Codable, Equatable {
    case signIn = "sign_in"
    case permission
}

/// Each adverse row's healer and route: `app` repairs it, `owner` (User) gets the one doctor-ask card, `agent` (Agent) is woken
/// to triage it, `builder` names an app defect for the person's recovery step.
public enum DoctorOwner: String, Sendable, Codable, Equatable {
    case app, owner, agent, builder

    /// A live repair or handler is the app's; a sign-in or permission is User's; a declared build fix is the builder's; Agent
    /// triages a named harm.
    public static func of(_ row: CheckResult, repairAvailable: Bool) -> DoctorOwner? {
        guard DoctorSafeRepairPolicy.isAdverse(row.status) else { return nil }
        if repairAvailable { return .app }
        if row.ask != nil { return .owner }
        guard let harm = row.harm?.trimmingCharacters(in: .whitespacesAndNewlines), !harm.isEmpty else { return nil }
        return row.owner == .builder ? .builder : .agent
    }
}

public enum DoctorChecksError: Error, LocalizedError {
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .underlying(let m): return m
        }
    }
}

public typealias DoctorTelegramSnapshot = (enabled: Bool, tokenConfigured: Bool, isTransientPollInterruption: Bool, actionableError: String?, pollerEnabled: Bool, hasFreshSuccessfulPoll: Bool, isStarting: Bool)
public typealias DoctorAutonomySnapshot = (enabled: Bool?, disabledReason: String?, status: String, mode: String?, runningImprovements: Int?)
public typealias DoctorToolSnapshot = (status: String, name: String)
public typealias DoctorBridgeSnapshot = (name: String, health: (failure: String?, boundPort: UInt16?, isActive: Bool, port: UInt16), expected: Bool)

/// A currently applicable action supplied by the owner; instructions alone never make a live finding executable.
public struct DoctorExecutableRepair: Sendable {
    public let checkID: String
    public let run: @Sendable () async throws -> DoctorRepairAttempt

    public init(checkID: String, run: @escaping @Sendable () async throws -> DoctorRepairAttempt) {
        self.checkID = checkID
        self.run = run
    }
}

public enum DoctorRepairAttempt: Sendable {
    case completed(String)
    case unverified(String)

    public var detail: String {
        switch self {
        case .completed(let detail), .unverified(let detail): return detail
        }
    }

    public var completed: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum DoctorProviderRuntimeReading: Sendable {
    case healthy(DoctorProviderProbeReading)
    case unhealthy(String)
    case configurationIssue(CheckResult)
    case unavailable
}
public enum DoctorProviderProbeReading: Sendable {
    case current
    case stale(String?)
    case unavailable(String)
    case failed(String)
}
