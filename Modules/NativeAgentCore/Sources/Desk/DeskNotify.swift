import Foundation
import PersistenceCore
// Blueprint: | `DeskNotify.swift` | `DeskNotificationRead`, `DeskNotificationProposal`: frozen native policy inputs and typed proposals; native consent/ceilings and defer truth; Desk/config revision checks and baseline/window commit under native locks; a nag's baseline and ledger settle only after channel acceptance or durable hold. No part execution under a lock. Notification, nag, drift wording and deadline policy live in Resources/abilities/desk-notify.js; the person's unmute and scheduled loop share it |

/// An editable decision, never a write to Desk or its notification ledger.
public struct DeskNotificationProposal: Codable, Sendable {
    public struct Notification: Codable, Sendable {
        public let handle: String
        public let title: String
        public let body: String
        public let level: String
        public let observedUpdatedAt: String
        public let oneTimeAnnouncement: Bool
    }
    public struct Nag: Codable, Sendable {
        public let handle: String
        public let title: String
        public let body: String
    }
    public let notifications: [Notification]
    public let nags: [Nag]
    public let digest: [String]
    public let digestTitle: String
    public let digestBody: String
    public let consume: [String]
    public let openWindow: Bool
    public let deadline: Double?
}

/// Frozen native facts for both the scheduled pass and the person's unmute.
/// Calling the part is the caller's job, through its originating app door.
public struct DeskNotificationRead: Sendable {
    public let state: DeskState
    public let config: DeskNagConfig
    public let now: Date
    public let unmute: Bool
    private let facts: [String: (parking: (parked: Bool, until: Date?), observed: DeskNagObservation)]

    public static func read(dataRoot: URL, now: Date, unmute: Bool = false) async throws -> Self {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state = try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let feed = try await store.readFeedUnlocked()
            guard feed.integrity.isClean else { throw UnavailableRead() }
            return SwiftNativeDeskStore.compact(base: feed.base, feed.ops)
        }
        let config = try await DeskNagConfigStore(dataRoot: dataRoot).loadChecked()
        let plan = DeskSequencing.compute(state, now: now)
        let facts = Dictionary(uniqueKeysWithValues: state.items.map { item in
            let parked = Self.parking(item, in: state, now: now)
            return (item.handle, (parking: parked, observed: DeskNagObservation(updatedAt: item.updatedAt,
                effectiveBlockerCount: plan.byHandle[item.handle]?.effectiveBlockers.count ?? 0,
                deferElapsed: !parked.parked)))
        })
        return Self(state: state, config: config, now: now, unmute: unmute, facts: facts)
    }

    /// Only policy facts cross this boundary, never notes, refs or work receipts.
    public var input: JSONValue {
        func seconds(_ date: Date?) -> JSONValue { date.map { .double($0.timeIntervalSince1970) } ?? .null }
        var facts: [String: JSONValue] = [:]
        let items = state.items.map { item -> JSONValue in
            let parked = self.facts[item.handle]?.parking
            facts[item.handle] = .object([
                "updated": seconds(DeskClock.parseISO(item.updatedAt)),
                "closed": seconds(item.closedAt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(DeskClock.parseISO)),
                "last": seconds(item.notify.lastNotifiedAt.flatMap(DeskClock.parseISO)),
                "lastSet": .bool(item.notify.lastNotifiedAt != nil),
                "cooldown": item.notify.cooldown.flatMap(DeskPage.parseDuration).map(JSONValue.double) ?? .null,
                "staleAfter": item.cadence.staleAfter.flatMap(DeskPage.parseDuration).map(JSONValue.double) ?? .null,
                "deferred": .bool(DeskSequencing.isDeferred(item, now: now)),
                "parked": .bool(parked?.parked == true), "until": seconds(parked?.until),
                "blockers": .int(Int64(self.facts[item.handle]?.observed.effectiveBlockerCount ?? 0)),
                "scoped": .bool(config.scopeEnabled(for: item)),
            ])
            return .object([
                "handle": .string(item.handle), "alias": .string(item.alias),
                "title": .string(item.title), "project": .string(item.project),
                "status": .string(item.status.rawValue), "updatedAt": .string(item.updatedAt),
                "parent": item.parent.map(JSONValue.string) ?? .null,
                "waitingOn": item.waitingOn.map(JSONValue.string) ?? .null,
                "notify": item.notify.toJSON(),
            ])
        }
        return .object([
            "availability": .string("ready"), "mode": .string(unmute ? "unmute" : "tick"),
            "now": .double(now.timeIntervalSince1970), "items": .array(items),
            "facts": .object(facts), "config": config.toJSON(),
            "graphDepth": .int(Int64(deskMaxGraphDepth)), "myQueue": .string(MyQueue.project),
            "muteSet": .bool(config.mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            "muteEnd": seconds(config.mutedUntil.flatMap(DeskSequencing.parseDeferStamp)),
        ])
    }

    /// Native consent and ceilings cannot be rewritten by a part's answer.
    public func validate(_ proposal: DeskNotificationProposal) throws {
        func unique(_ handles: [String]) -> Bool { Set(handles).count == handles.count }
        guard unique(proposal.notifications.map(\.handle)), unique(proposal.nags.map(\.handle)),
              unique(proposal.consume), proposal.deadline.map({ $0.isFinite && $0 > now.timeIntervalSince1970 }) ?? true,
              (!unmute || proposal.openWindow),
              !proposal.openWindow || unmute || (config.enabled && config.muteHasElapsed(now: now)) else { throw InvalidProposal() }
        for notification in proposal.notifications {
            guard let item = state.items.first(where: { $0.handle == notification.handle }),
                  notification.observedUpdatedAt == item.updatedAt,
                  facts[item.handle]?.parking.parked == false,
                  let level = NotifyLevel(rawValue: notification.level), [.direct, .urgent].contains(level),
                  let ceiling = notificationConsent(item), level != .urgent || ceiling == .urgent,
                  notification.oneTimeAnnouncement == Self.explicit(item) else { throw InvalidProposal() }
            // A part cannot republish an occurrence the native stamp settled.
            if let last = item.notify.lastNotifiedAt.flatMap(DeskClock.parseISO) {
                let revision = item.status.isTerminal
                    ? item.closedAt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(DeskClock.parseISO) : DeskClock.parseISO(item.updatedAt)
                guard !Self.explicit(item), let revision, revision > last else { throw InvalidProposal() }
            }
        }
        for nag in proposal.nags {
            guard config.enabled, !config.isMuted(now: now), !proposal.openWindow,
                  let item = state.items.first(where: { $0.handle == nag.handle }),
                  facts[item.handle]?.parking.parked == false,
                  !item.status.isTerminal, item.project != MyQueue.project, config.scopeEnabled(for: item),
                  config.ledger[item.handle] != config.windowId,
                  proposal.consume.contains(item.handle) else { throw InvalidProposal() }
        }
        for handle in proposal.consume {
            guard let item = state.items.first(where: { $0.handle == handle }), !item.status.isTerminal,
                  config.scopeEnabled(for: item),
                  unmute || config.enabled && (!config.isMuted(now: now) || proposal.openWindow) else { throw InvalidProposal() }
        }
    }

    /// Compare BOTH sources under their native locks before publication.
    /// A scheduled mute-expiry digest consumes its window only after delivery.
    /// No JavaScript executes here. A changed read fails visibly, without replay.
    public func commit(_ proposal: DeskNotificationProposal, dataRoot: URL, quietHours: Bool = false,
                       digestAccepted: Bool = false) async throws -> DeskNagConfig {
        try validate(proposal)
        try Task.checkCancellation()
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            try Task.checkCancellation()
            let feed = try await store.readFeedUnlocked()
            let currentState = SwiftNativeDeskStore.compact(base: feed.base, feed.ops)
            guard feed.integrity.isClean, currentState.items == state.items else { throw ChangedRead() }
            // No config write while disabled, quiet, or awaiting digest delivery.
            // Direct pings are separate.
            if !unmute && (quietHours || !config.enabled
                || proposal.openWindow && !proposal.digest.isEmpty && !digestAccepted) {
                guard try await DeskNagConfigStore(dataRoot: dataRoot).loadChecked() == config else { throw ChangedRead() }
                return config
            }
            return try await DeskNagConfigStore(dataRoot: dataRoot).updating { current in
                try Task.checkCancellation()
                guard current == config else { throw ChangedRead() }
                var next = current
                let awaitingDelivery = Set(proposal.nags.map(\.handle))
                for handle in proposal.consume where !awaitingDelivery.contains(handle) {
                    next.observed[handle] = facts[handle]?.observed
                }
                next.observed = next.observed.filter { facts[$0.key] != nil }
                next.ledger = next.ledger.filter { facts[$0.key] != nil }
                if proposal.openWindow { next = next.unmuted() }
                return (next, ())
            }.config
        }
    }

    /// A failed delivery leaves both the movement baseline and window unconsumed.
    public func recordNagDelivery(_ nag: DeskNotificationProposal.Nag, dataRoot: URL) async throws {
        guard let observed = facts[nag.handle]?.observed else { throw InvalidProposal() }
        _ = try await DeskNagConfigStore(dataRoot: dataRoot).updating { current in
            guard current.windowId == config.windowId,
                  current.observed[nag.handle] == config.observed[nag.handle] else { throw ChangedRead() }
            var next = current
            next.observed[nag.handle] = observed
            next.ledger[nag.handle] = config.windowId
            return (next, ())
        }
    }

    public struct ChangedRead: LocalizedError {
        public var errorDescription: String? { "Desk notification sources changed before commit; this proposal was not published." }
    }
    private struct UnavailableRead: LocalizedError {
        var errorDescription: String? { "The Desk feed is incomplete or unreadable; no notification proposal was made." }
    }
    private struct InvalidProposal: LocalizedError {
        var errorDescription: String? { "The Desk notification proposal exceeds its native consent or source bounds; this proposal was not published." }
    }

    private static func explicit(_ item: DeskItem) -> Bool {
        Set(item.notify.on.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }) == ["explicit"]
    }

    private func notificationConsent(_ item: DeskItem) -> NotifyLevel? {
        if [.direct, .urgent].contains(item.notify.level) { return item.notify.level }
        guard item.notify.level == .quiet, item.notify.on.isEmpty,
              item.notify.cooldown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
        var parent = item.parent
        var seen: Set<String> = [item.handle]
        while let handle = parent, seen.count <= deskMaxGraphDepth, seen.insert(handle).inserted {
            guard let ancestor = state.items.first(where: { $0.handle == handle }) else { return nil }
            if [.direct, .urgent].contains(ancestor.notify.level) {
                return Self.explicit(ancestor) ? nil : ancestor.notify.level
            }
            parent = ancestor.parent
        }
        return nil
    }

    /// Dependency/defer truth stays native, including malformed parent chains.
    static func parking(_ item: DeskItem, in state: DeskState, now: Date) -> (parked: Bool, until: Date?) {
        var current: DeskItem? = item
        var seen: Set<String> = []
        var until: Date?
        while let row = current, seen.count < deskMaxGraphDepth, seen.insert(row.handle).inserted {
            if DeskSequencing.isDeferred(row, now: now) {
                guard let raw = row.deferUntil, let end = DeskSequencing.parseDeferStamp(raw), end > now else { return (true, nil) }
                until = max(until ?? end, end)
            }
            current = row.parent.flatMap { parent in state.items.first { $0.handle == parent } }
        }
        if current != nil { return (true, nil) }
        return (until != nil, until)
    }
}
