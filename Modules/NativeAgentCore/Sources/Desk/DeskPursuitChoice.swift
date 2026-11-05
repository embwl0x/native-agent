import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `DeskPursuitChoice.swift` | `PursuitChoiceScore`, `DeskPursuitChoice`: pure pursuit scoring and the Desk-day window key |

/// Normalized components keep any one signal from dominating the choice between pursuits.
public struct PursuitChoiceScore: Sendable, Equatable {
    public let handle: String
    public let alias: String
    public let evidenceStrength: Double   // dossier breadth × source diversity
    public let momentum: Double           // completed work over the pursuit's life
    public let closureProximity: Double   // how near its doneLooksLike budget
    public let noProgressPenalty: Double  // reserved-but-never-completed drag
    public let recentAttentionPenalty: Double // worked very recently → yield, spread
    public var total: Double {
        evidenceStrength + momentum + closureProximity - noProgressPenalty - recentAttentionPenalty
    }
}

public enum DeskPursuitChoice {
    /// Nil for an item that is not a pursuit.
    public static func score(for item: DeskItem, now: Date = Date()) -> PursuitChoiceScore? {
        guard item.isPursuit, let p = item.pursuit else { return nil }
        let reservations = item.workAttempts.filter { $0.lane == .pursuit }
        let completed = p.retiredSessions + reservations.filter { $0.completedAt != nil && $0.disposition != .unstarted }.count
        let openReservations = reservations.filter { $0.completedAt == nil }.count

        // Evidence breadth and diversity exclude friction, matching Desk’s dossier law.
        let nonFriction = p.evidence.citations.filter { !$0.isFriction }
        let nonFrictionKinds = Set(nonFriction.map { $0.token })
        let breadth = min(Double(nonFriction.count), 5) / 5.0
        let diversity = min(Double(nonFrictionKinds.count), 3) / 3.0
        let evidenceStrength = 0.6 * diversity + 0.4 * breadth

        // Completed work outranks reservations so active pursuits lead stalled ones.
        let momentum = min(Double(completed), 4) / 4.0

        // Proximity to closure; the denominator is clamped to one.
        let budget = max(p.maxSessions, 1)
        let closureProximity = min(Double(completed) / Double(budget), 1.0)

        // Uncompleted reservations weigh gently, so repeated nonprogress yields without punishing one open slot.
        let noProgressPenalty = min(Double(openReservations), 3) / 3.0 * 0.5

        // Recent attention decays over 24 hours to spread work; stronger evidence can still win.
        let recentAttentionPenalty: Double = {
            guard let raw = p.lastWorkedAt, let last = DeskClock.parseISO(raw) else { return 0 }
            let hours = now.timeIntervalSince(last) / 3600.0
            // A future timestamp is zero age, never absent, so the choice stays deterministic.
            guard hours < 24 else { return 0 }
            let clamped = max(0, hours)
            return (1.0 - clamped / 24.0) * 0.6
        }()

        return PursuitChoiceScore(
            handle: item.handle, alias: item.alias,
            evidenceStrength: evidenceStrength, momentum: momentum,
            closureProximity: closureProximity, noProgressPenalty: noProgressPenalty,
            recentAttentionPenalty: recentAttentionPenalty)
    }

    /// One Desk-day two-hour key: background work claims at most one slot per window.
    public static func windowKey(_ date: Date) -> String {
        "\(DeskClock.dayStamp(date))-b\(Int(date.timeIntervalSince(deskDayStart(date)) / 7200))"
    }

    /// The end of the two-hour window holding `date`, by the same day start and width as `windowKey`.
    public static func windowEnd(_ date: Date) -> Date {
        let start = deskDayStart(date)
        return start.addingTimeInterval(Double(Int(date.timeIntervalSince(start) / 7200) + 1) * 7200)
    }

    /// DeskClock's day and zone, so windows match canonical session counts.
    static func deskDayStart(_ date: Date) -> Date {
        DeskClock.parseDay(DeskClock.dayStamp(date)) ?? date
    }
}
