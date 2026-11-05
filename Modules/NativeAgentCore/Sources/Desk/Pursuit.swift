import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `Pursuit.swift` | Durable work attempts and pursuit accounting values |

// MARK: - Durable work attempts

public enum DeskWorkDisposition: String, Sendable, Equatable {
    case unstarted
    case progress
    case goalSatisfied = "goal_satisfied"
    case blocked
    case abandon
}

public struct DeskWorkAttempt: Sendable, Equatable {
    public enum Lane: String, Sendable, Equatable {
        case ownerCadence = "owner_cadence"
        case pursuit
    }

    public var attemptId: String
    public var lane: Lane
    public var day: String
    public var slot: String
    public var reservedAt: String
    public var receipt: String?
    public var completedAt: String?
    public var receiptHandedOff: Bool
    public var disposition: DeskWorkDisposition?
    public var artifactRefs: [String]

    public init(
        attemptId: String,
        lane: Lane,
        day: String,
        slot: String,
        reservedAt: String,
        receipt: String? = nil,
        completedAt: String? = nil,
        receiptHandedOff: Bool = false,
        disposition: DeskWorkDisposition? = nil,
        artifactRefs: [String] = []
    ) {
        self.attemptId = attemptId
        self.lane = lane
        self.day = day
        self.slot = slot
        self.reservedAt = reservedAt
        self.receipt = receipt
        self.completedAt = completedAt
        self.receiptHandedOff = receiptHandedOff
        self.disposition = disposition
        self.artifactRefs = artifactRefs
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "attemptId": .string(attemptId),
            "lane": .string(lane.rawValue),
            "day": .string(day),
            "slot": .string(slot),
            "reservedAt": .string(reservedAt),
        ]
        if let receipt, !receipt.isEmpty { object["receipt"] = .string(receipt) }
        if let completedAt, !completedAt.isEmpty { object["completedAt"] = .string(completedAt) }
        if receiptHandedOff { object["receiptHandedOff"] = .bool(true) }
        if let disposition { object["disposition"] = .string(disposition.rawValue) }
        if !artifactRefs.isEmpty { object["artifactRefs"] = .array(artifactRefs.map(JSONValue.string)) }
        return .object(object)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskWorkAttempt? {
        guard case .object(let object) = value,
              object["reservationId"] == nil,
              let attemptId = object["attemptId"]?.stringValue, !attemptId.isEmpty,
              let lane = object["lane"]?.stringValue.flatMap(Lane.init(rawValue:)),
              let day = object["day"]?.stringValue,
              let slot = object["slot"]?.stringValue,
              let reservedAt = object["reservedAt"]?.stringValue,
              DeskClock.parseISO(reservedAt) != nil,
              DeskJSON.optionalStringsAreValid(object, keys: ["receipt", "completedAt", "disposition"]),
              let artifacts = DeskJSON.strings(object["artifactRefs"]) else { return nil }
        if let value = object["receiptHandedOff"] {
            guard case .bool = value else { return nil }
        }
        if let raw = object["disposition"]?.stringValue, DeskWorkDisposition(rawValue: raw) == nil { return nil }
        if let raw = object["completedAt"]?.stringValue, DeskClock.parseISO(raw) == nil { return nil }
        return DeskWorkAttempt(
            attemptId: attemptId,
            lane: lane,
            day: day,
            slot: slot,
            reservedAt: reservedAt,
            receipt: object["receipt"]?.stringValue,
            completedAt: object["completedAt"]?.stringValue,
            receiptHandedOff: object["receiptHandedOff"] == .bool(true),
            disposition: object["disposition"]?.stringValue.flatMap(DeskWorkDisposition.init(rawValue:)),
            artifactRefs: artifacts
        )
    }
    /// Omission means no attempts; a present collection must decode whole to preserve accounting.
    static func readAttempts(_ object: [String: JSONValue]) -> [DeskWorkAttempt]? {
        if case .object(let pursuit)? = object["pursuit"], pursuit["reservations"] != nil { return nil }
        guard let attempts = DeskJSON.collection(object["workAttempts"], decode: Self.fromJSON),
              Set(attempts.map(\.attemptId)).count == attempts.count else { return nil }
        return attempts
    }
}

// MARK: - Pursuit (the origin=agent, kind=project payload — carried on create)
// Required evidence rides the create op so a pursuit cannot exist without its admission proof.
// Read and write gates enforce lifetime bounds; attempts and daily counts preserve spent budget.

public struct Pursuit: Sendable, Equatable {
    public static let defaultMaxSessions = 12
    public static let maxMaxSessions = 24
    public static let defaultMaxDays = 10
    public static let maxMaxDays = 21

    public var why: String
    public var evidence: PromotionDossier   // required, source-mix enforced
    public var doneLooksLike: String
    public var maxSessions: Int
    public var maxDays: Int
    public var abandonCondition: String
    public var privateName: String?
    public var lastWorkedAt: String?
    public var retiredSessionsByDay: [String: Int]
    public var retiredSessions: Int { retiredSessionsByDay.values.reduce(0, +) }
    public func sessionsUsed(in attempts: [DeskWorkAttempt]) -> Int {
        retiredSessions + attempts.filter { $0.lane == .pursuit && $0.disposition != .unstarted }.count
    }
    public init(
        why: String,
        evidence: PromotionDossier,
        doneLooksLike: String,
        maxSessions: Int = Pursuit.defaultMaxSessions,
        maxDays: Int = Pursuit.defaultMaxDays,
        abandonCondition: String,
        privateName: String? = nil,
        lastWorkedAt: String? = nil,
        retiredSessionsByDay: [String: Int] = [:]
    ) {
        self.why = why
        self.evidence = evidence
        self.doneLooksLike = doneLooksLike
        self.maxSessions = maxSessions
        self.maxDays = maxDays
        self.abandonCondition = abandonCondition
        self.privateName = privateName
        self.lastWorkedAt = lastWorkedAt
        self.retiredSessionsByDay = retiredSessionsByDay
    }

    /// Share structural validation between admission and decoding so persisted work cannot bypass evidence gates.
    public func validationError() -> String? {
        if !(1...Self.maxMaxSessions).contains(maxSessions) { return "pursuit: maxSessions must be in 1...\(Self.maxMaxSessions)" }
        if !(1...Self.maxMaxDays).contains(maxDays) { return "pursuit: maxDays must be in 1...\(Self.maxMaxDays)" }
        if why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'why' is required" }
        if doneLooksLike.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'doneLooksLike' is required" }
        if abandonCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'abandonCondition' is required" }
        if let e = evidence.validationError() { return e }
        return nil
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "why": .string(why),
            "evidence": evidence.toJSON(),
            "doneLooksLike": .string(doneLooksLike),
            "maxSessions": .int(Int64(maxSessions)),
            "maxDays": .int(Int64(maxDays)),
            "abandonCondition": .string(abandonCondition),
        ]
        if let privateName, !privateName.isEmpty { obj["privateName"] = .string(privateName) }
        if let lastWorkedAt, !lastWorkedAt.isEmpty { obj["lastWorkedAt"] = .string(lastWorkedAt) }
        if !retiredSessionsByDay.isEmpty {
            obj["retiredSessionsByDay"] = .object(retiredSessionsByDay.mapValues { .int(Int64($0)) })
        }
        return .object(obj)
    }

    /// Reject lossy accounting from feed and base so replay preserves the same budget.
    public static func fromJSON(_ value: JSONValue) -> Pursuit? {
        guard case .object(let obj) = value, obj["reservations"] == nil,
              let why = obj["why"]?.stringValue,
              let evidenceValue = obj["evidence"], let evidence = PromotionDossier.fromJSON(evidenceValue),
              let doneLooksLike = obj["doneLooksLike"]?.stringValue,
              case .int(let rawSessions)? = obj["maxSessions"], let maxSessions = Int(exactly: rawSessions),
              case .int(let rawDays)? = obj["maxDays"], let maxDays = Int(exactly: rawDays),
              let abandonCondition = obj["abandonCondition"]?.stringValue,
              DeskJSON.optionalStringsAreValid(obj, keys: ["privateName", "lastWorkedAt"]) else { return nil }
        if let last = obj["lastWorkedAt"]?.stringValue, DeskClock.parseISO(last) == nil { return nil }
        var retiredSessionsByDay: [String: Int] = [:]
        var total = 0
        if let value = obj["retiredSessionsByDay"] {
            guard case .object(let days) = value else { return nil }
            for (day, value) in days {
                guard DeskClock.normalizedDay(day) == day,
                      case .int(let raw) = value, raw > 0, let count = Int(exactly: raw) else { return nil }
                let addition = total.addingReportingOverflow(count)
                guard !addition.overflow else { return nil }
                total = addition.partialValue
                retiredSessionsByDay[day] = count
            }
        }
        let pursuit = Pursuit(
            why: why,
            evidence: evidence,
            doneLooksLike: doneLooksLike,
            maxSessions: maxSessions,
            maxDays: maxDays,
            abandonCondition: abandonCondition,
            privateName: obj["privateName"]?.stringValue,
            lastWorkedAt: obj["lastWorkedAt"]?.stringValue,
            retiredSessionsByDay: retiredSessionsByDay
        )
        return pursuit.validationError() == nil ? pursuit : nil
    }
}
