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

/// The execution record for pursuit and owner-cadence work.
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
              let attemptId = object["attemptId"]?.stringValue ?? object["reservationId"]?.stringValue,
              let lane = object["lane"]?.stringValue.flatMap(Lane.init(rawValue:))
                ?? (object["reservationId"] != nil ? .pursuit : nil),
              let day = object["day"]?.stringValue,
              let slot = object["slot"]?.stringValue,
              let reservedAt = object["reservedAt"]?.stringValue else { return nil }
        if let value = object["receiptHandedOff"] {
            guard case .bool = value else { return nil }
        }
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
            artifactRefs: (object["artifactRefs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        )
    }
    /// Historical embedded reservations enter the item ledger only at decode.
    static func readAttempts(_ object: [String: JSONValue]) -> [DeskWorkAttempt]? {
        var attempts: [DeskWorkAttempt] = []
        var collections = [object["workAttempts"]]
        if case .object(let pursuit)? = object["pursuit"] { collections.append(pursuit["reservations"]) }
        for value in collections.compactMap({ $0 }) {
            guard case .array(let rows) = value else { return nil }
            let decoded = rows.compactMap(Self.fromJSON)
            guard decoded.count == rows.count else { return nil }
            for attempt in decoded {
                guard !attempts.contains(where: { $0.attemptId == attempt.attemptId }) else { return nil }
                attempts.append(attempt)
            }
        }
        return attempts
    }
}

// MARK: - Pursuit (the origin=agent, kind=project payload — carried on create)
//
// All REQUIRED fields (why/evidence/doneLooksLike/abandonCondition) ride the
// create op payload so a pursuit is fully evidenced the moment it
// exists; the store REFUSES a create missing any of them. maxSessions/maxDays
// bound the pursuit ("unbounded pursuits are theater") — defaulted and capped.
// Item attempts and retired daily counts preserve the pursuit lifetime budget.

public struct Pursuit: Sendable, Equatable {
    public static let defaultMaxSessions = 12
    public static let maxMaxSessions = 24
    public static let defaultMaxDays = 10
    public static let maxMaxDays = 21

    public var why: String                 // first-person, required
    public var evidence: PromotionDossier   // required, source-mix enforced
    public var doneLooksLike: String        // required
    public var maxSessions: Int             // default 12, cap 24
    public var maxDays: Int                 // default 10, cap 21
    public var abandonCondition: String     // required
    public var privateName: String?         // hers, optional
    public var workSessionsToday: Int        // derived from item work slots
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
        workSessionsToday: Int = 0,
        lastWorkedAt: String? = nil,
        retiredSessionsByDay: [String: Int] = [:]
    ) {
        self.why = why
        self.evidence = evidence
        self.doneLooksLike = doneLooksLike
        // Clamp to [1, cap] — a create can only tighten the bound, never lift it.
        self.maxSessions = max(1, min(maxSessions, Pursuit.maxMaxSessions))
        self.maxDays = max(1, min(maxDays, Pursuit.maxMaxDays))
        self.abandonCondition = abandonCondition
        self.privateName = privateName
        self.workSessionsToday = workSessionsToday
        self.lastWorkedAt = lastWorkedAt
        self.retiredSessionsByDay = retiredSessionsByDay
    }

    /// The required-field gate (structural). Trimmed-empty required strings are refused; evidence must pass the dossier gate. Returns a human reason or nil. Enforced at WRITE time only.
    public func validationError() -> String? {
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
            "workSessionsToday": .int(Int64(workSessionsToday)),
        ]
        if let privateName, !privateName.isEmpty { obj["privateName"] = .string(privateName) }
        if let lastWorkedAt, !lastWorkedAt.isEmpty { obj["lastWorkedAt"] = .string(lastWorkedAt) }
        if !retiredSessionsByDay.isEmpty {
            obj["retiredSessionsByDay"] = .object(retiredSessionsByDay.mapValues { .int(Int64($0)) })
        }
        return .object(obj)
    }

    /// Both feed and base inputs must carry lossless, representable accounting.
    public static func fromJSON(_ value: JSONValue) -> Pursuit? {
        guard case .object(let obj) = value else { return nil }
        var retiredSessionsByDay: [String: Int] = [:]
        var total = 0
        if let value = obj["retiredSessionsByDay"] {
            guard case .object(let days) = value else { return nil }
            for (day, value) in days {
                guard case .int(let raw) = value, raw > 0, let count = Int(exactly: raw) else { return nil }
                let addition = total.addingReportingOverflow(count)
                guard !addition.overflow else { return nil }
                total = addition.partialValue
                retiredSessionsByDay[day] = count
            }
        }
        return Pursuit(
            why: obj["why"]?.stringValue ?? "",
            evidence: obj["evidence"].map { PromotionDossier.fromJSON($0) } ?? PromotionDossier(citations: []),
            doneLooksLike: obj["doneLooksLike"]?.stringValue ?? "",
            maxSessions: jsonInt(obj, "maxSessions") ?? Pursuit.defaultMaxSessions,
            maxDays: jsonInt(obj, "maxDays") ?? Pursuit.defaultMaxDays,
            abandonCondition: obj["abandonCondition"]?.stringValue ?? "",
            privateName: obj["privateName"]?.stringValue,
            workSessionsToday: jsonInt(obj, "workSessionsToday") ?? 0,
            lastWorkedAt: obj["lastWorkedAt"]?.stringValue,
            retiredSessionsByDay: retiredSessionsByDay
        )
    }
}
