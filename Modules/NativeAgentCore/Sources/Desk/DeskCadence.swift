import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskCadence.swift` | Carried steps, cadence and notification policy values |

/// Carried work's words, readiness, planned call and originating turn. An inferred step keeps its source sentence; every step keeps its peer steering.
public struct DeskStep: Sendable, Equatable {
    public var lifeID: String?
    public var status: String?
    public var reason: String?
    public var words: String
    /// `next_turn`, `own_turn`, `when_user_messages[ <door>]`, `after_card`, `at <ISO time>`.
    public var when: String
    public var card: String?
    public var action: String?
    public var source: String?
    public var peers: [String]
    public var elevated: [String]
    /// The originating conversation: a wake that works it carries that conversation's context.
    public var session: String?
    /// `person`, `agent:<name>` or `self`; nil on older steps.
    public var origin: String?
    /// When the current readiness condition was filed.
    public var filedAt: String?
    /// The originating turn's durable envelope, never a later message's door.
    public var replyRoute: JSONValue?

    public init(words: String, when: String, card: String? = nil, action: String? = nil, source: String? = nil,
                peers: [String] = [], elevated: [String] = [], session: String? = nil, origin: String? = nil, filedAt: String? = nil,
                replyRoute: JSONValue? = nil) {
        self.words = words; self.when = when; self.card = card; self.action = action; self.source = source
        self.peers = peers; self.elevated = elevated; self.session = session
        self.origin = origin
        self.filedAt = filedAt
        self.replyRoute = replyRoute
    }

    init?(fields obj: [String: JSONValue]) {
        guard let words = obj["words"]?.stringValue, let when = obj["when"]?.stringValue else { return nil }
        self.init(words: words, when: when, card: obj["card"]?.stringValue, action: obj["action"]?.stringValue,
                  source: obj["source"]?.stringValue, peers: (obj["peers"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                  elevated: (obj["elevated"]?.arrayValue?.compactMap(\.stringValue) ?? []), session: obj["session"]?.stringValue,
                  origin: obj["origin"]?.stringValue, filedAt: obj["filedAt"]?.stringValue, replyRoute: obj["replyRoute"])
        lifeID = obj["lifeID"]?.stringValue
        status = obj["status"]?.stringValue
        reason = obj["reason"]?.stringValue
    }

    var fields: [String: JSONValue] {
        var obj: [String: JSONValue] = ["words": .string(words), "when": .string(when)]
        for (key, value) in [("card", card), ("action", action), ("source", source), ("session", session), ("origin", origin), ("filedAt", filedAt), ("lifeID", lifeID), ("status", status), ("reason", reason)] {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        if !peers.isEmpty { obj["peers"] = .array(peers.map(JSONValue.string)) }
        if !elevated.isEmpty { obj["elevated"] = .array(elevated.map(JSONValue.string)) }
        if let replyRoute { obj["replyRoute"] = replyRoute }
        return obj
    }

    mutating func preserveOrigin(of previous: DeskStep) {
        peers = previous.peers + peers.filter { !previous.peers.contains($0) }
        elevated = previous.elevated + elevated.filter { !previous.elevated.contains($0) }
        session = previous.session
        origin = previous.origin
        filedAt = previous.filedAt
        replyRoute = previous.replyRoute
    }

    public func owedToPerson(dataRoot: URL) -> Bool {
        if let origin { return origin == "person" }
        // Older steps recorded only their conversation, or an inferred promise.
        let kind = SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)
        return source?.hasPrefix("Repeated work: ") != true
            && kind?.isPeerConversation != true && kind?.isOwnWork != true && (session != nil || source != nil)
    }
}

// MARK: - Cadence / NotifyPolicy / Note

public struct Cadence: Sendable, Equatable {
    public var mode: CadenceMode
    public var interval: String?
    public var nextRefreshAt: String?
    public var lastRefreshAt: String?
    public var staleAfter: String?
    public var refreshSources: [String]

    public init(
        mode: CadenceMode = .on_ask,
        interval: String? = nil,
        nextRefreshAt: String? = nil,
        lastRefreshAt: String? = nil,
        staleAfter: String? = nil,
        refreshSources: [String] = []
    ) {
        self.mode = mode
        self.interval = interval
        self.nextRefreshAt = nextRefreshAt
        self.lastRefreshAt = lastRefreshAt
        self.staleAfter = staleAfter
        self.refreshSources = refreshSources
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["mode": .string(mode.rawValue)]
        if let interval, !interval.isEmpty { obj["interval"] = .string(interval) }
        if let nextRefreshAt, !nextRefreshAt.isEmpty { obj["nextRefreshAt"] = .string(nextRefreshAt) }
        if let lastRefreshAt, !lastRefreshAt.isEmpty { obj["lastRefreshAt"] = .string(lastRefreshAt) }
        if let staleAfter, !staleAfter.isEmpty { obj["staleAfter"] = .string(staleAfter) }
        if !refreshSources.isEmpty { obj["refreshSources"] = .array(refreshSources.map { .string($0) }) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> Cadence {
        guard case .object(let obj) = value else { return Cadence() }
        let mode = obj["mode"]?.stringValue.flatMap { CadenceMode(rawValue: $0) } ?? .on_ask
        return Cadence(
            mode: mode,
            interval: obj["interval"]?.stringValue,
            nextRefreshAt: obj["nextRefreshAt"]?.stringValue,
            lastRefreshAt: obj["lastRefreshAt"]?.stringValue,
            staleAfter: obj["staleAfter"]?.stringValue,
            refreshSources: (obj["refreshSources"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        )
    }
}

public struct NotifyPolicy: Sendable, Equatable {
    public var level: NotifyLevel
    public var on: [String]               // state_change, blocked, done, explicit
    public var cooldown: String?
    public var lastNotifiedAt: String?
    public var notifyReason: String?

    public init(
        level: NotifyLevel = .quiet,
        on: [String] = [],
        cooldown: String? = nil,
        lastNotifiedAt: String? = nil,
        notifyReason: String? = nil
    ) {
        self.level = level
        self.on = on
        self.cooldown = cooldown
        self.lastNotifiedAt = lastNotifiedAt
        self.notifyReason = notifyReason
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["level": .string(level.rawValue)]
        if !on.isEmpty { obj["on"] = .array(on.map { .string($0) }) }
        if let cooldown, !cooldown.isEmpty { obj["cooldown"] = .string(cooldown) }
        if let lastNotifiedAt, !lastNotifiedAt.isEmpty { obj["lastNotifiedAt"] = .string(lastNotifiedAt) }
        if let notifyReason, !notifyReason.isEmpty { obj["notifyReason"] = .string(notifyReason) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> NotifyPolicy {
        guard case .object(let obj) = value else { return NotifyPolicy() }
        let level = obj["level"]?.stringValue.flatMap { NotifyLevel(rawValue: $0) } ?? .quiet
        return NotifyPolicy(
            level: level,
            on: (obj["on"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            cooldown: obj["cooldown"]?.stringValue,
            lastNotifiedAt: obj["lastNotifiedAt"]?.stringValue,
            notifyReason: obj["notifyReason"]?.stringValue
        )
    }
}
