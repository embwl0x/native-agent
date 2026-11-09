import NativeAgentShared
import Foundation
import PersistenceCore
// Blueprint: | `DeskCadence.swift` | Checked step provenance and cadence; malformed saved values cannot become defaults |

/// Inferred work keeps its source sentence; every step preserves peer steering.
public struct DeskStep: Sendable, Equatable {
    public var lifeID: String?
    public var status: String?
    public var reason: String?
    public var words: String
    public var when: String
    public var rhythm: JSONValue?
    /// The carried clock anchor and job identity make interrupted imports idempotent.
    public var clockStart: String?
    public var scheduledJobID: String?
    public var until: String?
    public var say: String?
    public var card: String?
    public var action: JSONValue?
    public var source: String?
    /// Original moment/candidate identities survive refiling and closure so replay cannot recreate landed promises.
    public var promiseCaptures: [String]
    public var peers: [String]
    public var elevated: [String]
    /// Resume with the originating conversation's context, never a later message's door.
    public var session: String?
    public var origin: String?
    public var filedAt: String?
    /// Keep the originating turn's durable route so later messages cannot redirect carried work.
    public var replyRoute: JSONValue?

    public init(words: String, when: String, card: String? = nil, action: JSONValue? = nil, source: String? = nil,
                peers: [String] = [], elevated: [String] = [], session: String? = nil, origin: String? = nil, filedAt: String? = nil,
                replyRoute: JSONValue? = nil, rhythm: JSONValue? = nil, until: String? = nil, say: String? = nil,
                clockStart: String? = nil, scheduledJobID: String? = nil, promiseCaptures: [String] = []) {
        self.words = words; self.when = when; self.card = card
        self.action = action.flatMap { $0 == .null ? nil : Self.plannedAction($0) ?? $0 }
        self.source = source
        self.promiseCaptures = promiseCaptures
        self.rhythm = rhythm; self.until = until; self.say = say
        self.clockStart = clockStart; self.scheduledJobID = scheduledJobID
        self.peers = peers; self.elevated = elevated; self.session = session
        self.origin = origin
        self.filedAt = filedAt
        self.replyRoute = replyRoute
    }

    init?(fields obj: [String: JSONValue]) {
        guard let words = obj["words"]?.stringValue, let when = obj["when"]?.stringValue,
              !when.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MyQueue.When(when, card: obj["card"]?.stringValue) != nil,
              DeskJSON.optionalStringsAreValid(obj, keys: ["card", "source", "session", "origin", "filedAt", "lifeID", "status", "reason", "until", "say",
                  "clockStart", "scheduledJobID"]),
              let peers = DeskJSON.strings(obj["peers"]),
              let promiseCaptures = DeskJSON.strings(obj["promiseCaptures"]),
              let elevated = DeskJSON.strings(obj["elevated"]) else { return nil }
        if let value = obj["replyRoute"] {
            guard case .object(let route) = value,
                  let surface = route["surface"]?.stringValue, !surface.isEmpty,
                  // The route is TurnEnvelope.persistedMetadata(): text fields plus one Boolean, declaredRemote.
                  route.allSatisfy({ $0.key == "declaredRemote" ? $0.value.boolValue != nil : $0.value.stringValue != nil }) else { return nil }
        }
        if let filed = obj["filedAt"]?.stringValue, DeskClock.parseISO(filed) == nil { return nil }
        if let value = obj["rhythm"], value.objectValue == nil { return nil }
        if let value = obj["action"] {
            guard value.objectValue != nil, Self.plannedAction(value) == value else { return nil }
        }
        self.init(words: words, when: when, card: obj["card"]?.stringValue, action: obj["action"],
                  source: obj["source"]?.stringValue, peers: peers,
                  elevated: elevated, session: obj["session"]?.stringValue,
                  origin: obj["origin"]?.stringValue, filedAt: obj["filedAt"]?.stringValue, replyRoute: obj["replyRoute"],
                  rhythm: obj["rhythm"], until: obj["until"]?.stringValue, say: obj["say"]?.stringValue,
                  clockStart: obj["clockStart"]?.stringValue, scheduledJobID: obj["scheduledJobID"]?.stringValue,
                  promiseCaptures: promiseCaptures)
        lifeID = obj["lifeID"]?.stringValue
        status = obj["status"]?.stringValue
        reason = obj["reason"]?.stringValue
    }

    var fields: [String: JSONValue] {
        var obj: [String: JSONValue] = ["words": .string(words), "when": .string(when)]
        for (key, value) in [("card", card), ("source", source), ("session", session), ("origin", origin), ("filedAt",
            filedAt), ("lifeID", lifeID), ("status", status), ("reason", reason), ("until", until), ("say",
            say), ("clockStart", clockStart), ("scheduledJobID", scheduledJobID)] {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        if !peers.isEmpty { obj["peers"] = .array(peers.map(JSONValue.string)) }
        if !promiseCaptures.isEmpty { obj["promiseCaptures"] = .array(promiseCaptures.map(JSONValue.string)) }
        if !elevated.isEmpty { obj["elevated"] = .array(elevated.map(JSONValue.string)) }
        if let replyRoute { obj["replyRoute"] = replyRoute }
        if let rhythm { obj["rhythm"] = rhythm }
        if let action { obj["action"] = action }
        return obj
    }

    public static func plannedAction(_ value: JSONValue?) -> JSONValue? {
        guard let value, value != .null else { return nil }
        let fields = value.stringValue.map { ["action": JSONValue.string($0)] } ?? value.objectValue
        guard let fields, Set(fields.keys).isSubset(of: ["action", "args"]),
              let id = fields["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              fields["args"] == nil || fields["args"]?.objectValue != nil else { return nil }
        var call: [String: JSONValue] = ["action": .string(id)]
        if let args = fields["args"] { call["args"] = args }
        return .object(call)
    }

    public var actionText: String? { action.flatMap { try? $0.serialize(pretty: false) } }

    /// Filing, attachment and approval resumption use the same visible words and peer provenance.
    public var title: String {
        peers.isEmpty && elevated.isEmpty
            ? String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            : "A step from \((peers + elevated).joined(separator: ", "))'s turn"
    }

    mutating func preserveOrigin(of previous: DeskStep) {
        promiseCaptures = previous.promiseCaptures + promiseCaptures.filter { !previous.promiseCaptures.contains($0) }
        peers = previous.peers + peers.filter { !previous.peers.contains($0) }
        elevated = previous.elevated + elevated.filter { !previous.elevated.contains($0) }
        session = previous.session
        origin = previous.origin
        filedAt = previous.filedAt
        replyRoute = previous.replyRoute
        scheduledJobID = previous.scheduledJobID
    }

    /// Every writer records who the step came from; the person's steps are the ones owed to them.
    public var owedToPerson: Bool { origin == "person" }
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

    public static func fromJSON(_ value: JSONValue) -> Cadence? {
        guard case .object(let obj) = value,
              let raw = obj["mode"]?.stringValue, let mode = CadenceMode(rawValue: raw),
              DeskJSON.optionalStringsAreValid(obj, keys: ["interval", "nextRefreshAt", "lastRefreshAt", "staleAfter"]),
              let sources = DeskJSON.strings(obj["refreshSources"]) else { return nil }
        for key in ["interval", "staleAfter"] {
            if let text = obj[key]?.stringValue, DeskPage.parseDuration(text) == nil { return nil }
        }
        for key in ["nextRefreshAt", "lastRefreshAt"] {
            if let text = obj[key]?.stringValue, DeskClock.parseISO(text) == nil { return nil }
        }
        return Cadence(
            mode: mode,
            interval: obj["interval"]?.stringValue,
            nextRefreshAt: obj["nextRefreshAt"]?.stringValue,
            lastRefreshAt: obj["lastRefreshAt"]?.stringValue,
            staleAfter: obj["staleAfter"]?.stringValue,
            refreshSources: sources
        )
    }
}

public struct NotifyPolicy: Sendable, Equatable {
    public var level: NotifyLevel
    public var on: [String]
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

    public static func fromJSON(_ value: JSONValue) -> NotifyPolicy? {
        guard case .object(let obj) = value,
              let raw = obj["level"]?.stringValue, let level = NotifyLevel(rawValue: raw),
              DeskJSON.optionalStringsAreValid(obj, keys: ["cooldown", "lastNotifiedAt", "notifyReason"]),
              let on = DeskJSON.strings(obj["on"]),
              on.allSatisfy({ ["state_change", "blocked", "done", "explicit"].contains($0) }) else { return nil }
        if let cooldown = obj["cooldown"]?.stringValue, DeskPage.parseDuration(cooldown) == nil { return nil }
        if let last = obj["lastNotifiedAt"]?.stringValue, DeskClock.parseISO(last) == nil { return nil }
        return NotifyPolicy(
            level: level,
            on: on,
            cooldown: obj["cooldown"]?.stringValue,
            lastNotifiedAt: obj["lastNotifiedAt"]?.stringValue,
            notifyReason: obj["notifyReason"]?.stringValue
        )
    }
}
