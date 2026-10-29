import Foundation
import Cognition
import OSLog
import PersistenceCore
import StandingBots
import NativeAgentShared
import Desk
import TriggerScheduler
import WorkshopExecution
// Blueprint: | `DeskItemPresentation.swift` | Desk tones, item freshness and shared relative-time wording with exact next-change boundaries |
public enum DeskPresentationTone: Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}

/// Desk timestamps use the caller's frozen clock and exact freshness boundaries.
public enum DeskRelativeTimePresentation {
    public static func text(forISO raw: String, now: Date) -> String {
        guard let date = UserDisplayFormatters.parseISOTimestamp(raw) else {
            return "unknown"
        }
        return text(for: date, now: now)
    }

    public static func text(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite,
              let days = Int(exactly: seconds < 0 ? ceil(-seconds / 86_400) : floor(seconds / 86_400))
        else { return "unknown" }
        if seconds < 0 {
            let remaining = -seconds
            switch remaining {
            case ..<60: return "in less than a minute"
            case ..<3_600: return "in \(Int(ceil(remaining / 60)))m"
            case ..<86_400: return "in \(Int(ceil(remaining / 3_600)))h"
            default: return "in \(days)d"
            }
        }
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(days)d ago"
        }
    }

    /// The next change in this vocabulary, rather than a periodic clock tick.
    public static func nextRefreshAt(for date: Date, now: Date) -> Date {
        let remaining = date.timeIntervalSince(now)
        if remaining > 0 {
            let unit: TimeInterval
            switch remaining {
            case ..<60: return date
            case ..<3_600: unit = 60
            case ..<86_400: unit = 3_600
            default: unit = 86_400
            }
            let boundary = max(unit, (ceil(remaining / unit) - 1) * unit)
            return date.addingTimeInterval(-boundary + 0.001)
        }
        let seconds = max(0, now.timeIntervalSince(date))
        let boundary: TimeInterval
        switch seconds {
        case ..<90: boundary = 90
        case ..<3_600: boundary = (floor(seconds / 60) + 1) * 60
        case ..<86_400: boundary = (floor(seconds / 3_600) + 1) * 3_600
        default: boundary = (floor(seconds / 86_400) + 1) * 86_400
        }
        return date.addingTimeInterval(boundary)
    }
}

public enum DeskItemPresentation {
    public struct BlockedPill: Sendable, Equatable {
        public let text: String
        public let targetHandle: String
    }

    public static func blockedPill(
        plan: DeskSequencing.ItemPlan,
        aliases: [String: String],
        cap: Int = 3
    ) -> BlockedPill? {
        let resolved = plan.effectiveBlockers.compactMap { handle in
            aliases[handle].map { (handle: handle, alias: $0) }
        }
        guard let first = resolved.first else { return nil }
        let shown = resolved.prefix(max(cap, 1)).map(\.alias).joined(separator: ", ")
        let overflow = resolved.count - min(resolved.count, max(cap, 1))
        return BlockedPill(
            text: "waiting on \(shown)" + (overflow > 0 ? " +\(overflow)" : ""),
            targetHandle: first.handle)
    }

    public static func nagBellSymbol(config: DeskNagConfig, now: Date) -> String {
        if config.isMuted(now: now) { return "bell.slash" }
        return config.enabled ? "bell.fill" : "bell"
    }

    /// The whole-board store failure is rendered next to lane failures, so it
    /// shares their precise bounded-error contract instead of creating a second
    /// arbitrary limit at the top of the Desk.
    public struct Freshness: Sendable, Equatable {
        public let text: String
        public let isStale: Bool
        public let isKnown: Bool
    }

    /// The row's timestamp claim. A malformed timestamp is unknown, never
    /// fresh; blocked and flagged rows retain a plain age because their status
    /// already carries the urgent signal.
    public static func freshness(for item: DeskItem, now: Date) -> Freshness {
        let facts = DeskPage.freshness(item, now: now)
        guard let date = facts.date else {
            return Freshness(text: "unknown", isStale: false, isKnown: false)
        }
        let plain = DeskRelativeTimePresentation.text(for: date, now: now)
        return Freshness(text: facts.isStale ? "\(facts.days)d stale" : plain, isStale: facts.isStale, isKnown: true)
    }
}
