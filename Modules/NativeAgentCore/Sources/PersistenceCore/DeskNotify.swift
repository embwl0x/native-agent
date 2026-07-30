import Foundation

// MARK: - DeskNotifyEvaluator — pure "which desk items should ping User now"
//
// A PULL surface that can tap User on the shoulder: a desk item the user tagged
// direct/urgent pings him when its CONTENT changes (updatedAt advances past the
// last ping) and the cooldown has elapsed. Pure + deterministic (`now` injected);
// the loop that actually fires the push lives in the app
// (BackgroundLoopsAssembly+DeskNotify) and calls SwiftNativeDeskStore.markNotified
// after each successful push.
//
// DESK-LOCAL BY DESIGN: this reads desk state and decides who to ping. It NEVER
// touches the CognitiveSubstrate — the desk reaches out to User, it does NOT live
// in Agent's cognition (User's hard line, 2026-06-29).
//
// IDEMPOTENT (Agent's requirement — one state change can't fan out into duplicate
// pings): markNotified stamps notify.lastNotifiedAt WITHOUT bumping updatedAt, so
// after a push the `updatedAt > lastNotifiedAt` gate is closed until the NEXT real
// content change. The cooldown is a second floor against rapid re-fire.
//
// v1 scope: fires on ANY content change to a direct/urgent active item. The
// notify.on event filter (blocked/unblocked/due/explicit/…) is captured on the
// item but not yet enforced here — a documented refinement, not a silent gap.

public enum DeskNotifyEvaluator {

    /// Everything the loop needs to fire one notification.
    public struct Decision: Sendable, Equatable {
        public let handle: String
        public let title: String
        public let body: String
        public let level: NotifyLevel   // .direct or .urgent
        /// The item's updatedAt at evaluation time — the loop stamps against THIS
        /// version (CAS) so a content change landing during the tick isn't
        /// swallowed (it pings on the next tick instead).
        public let observedUpdatedAt: String

        public init(handle: String, title: String, body: String, level: NotifyLevel, observedUpdatedAt: String) {
            self.handle = handle
            self.title = title
            self.body = body
            self.level = level
            self.observedUpdatedAt = observedUpdatedAt
        }
    }

    /// Cooldown floor used when an item's notify.cooldown is unset/unparseable.
    public static let defaultCooldown: TimeInterval = 30 * 60

    /// The items that should ping User NOW, in desk (alias) order.
    public static func decisions(_ state: DeskState, now: Date) -> [Decision] {
        state.items.compactMap { decision(for: $0, now: now) }
    }

    /// Earliest future cooldown crossing for a changed direct/urgent item.
    /// Initial notifications and already-due rows are handled by the event or
    /// startup reconciliation pass; returning only a future date prevents an
    /// exact-deadline owner from spinning on corrupt/unchanged state.
    public static func nextMeaningfulDeadline(_ state: DeskState, after now: Date) -> Date? {
        state.items.compactMap { item -> Date? in
            guard item.notify.level == .direct || item.notify.level == .urgent,
                  !item.status.isTerminal,
                  let lastRaw = item.notify.lastNotifiedAt,
                  let last = DeskClock.parseISO(lastRaw),
                  let updated = DeskClock.parseISO(item.updatedAt),
                  updated > last
            else { return nil }
            let cooldown = item.notify.cooldown.flatMap(parseDuration) ?? defaultCooldown
            let due = last.addingTimeInterval(cooldown)
            return due > now ? due : nil
        }.min()
    }

    static func decision(for item: DeskItem, now: Date) -> Decision? {
        // Only items the user explicitly asked to be tapped on the shoulder for.
        guard item.notify.level == .direct || item.notify.level == .urgent else { return nil }
        // A finished item doesn't interrupt User.
        guard !item.status.isTerminal else { return nil }

        if let lastRaw = item.notify.lastNotifiedAt, let last = DeskClock.parseISO(lastRaw) {
            // Already pinged once: re-ping only on a REAL change since then
            // (markNotified doesn't bump updatedAt, so the stamp itself can't
            // re-trigger) …
            guard let updated = DeskClock.parseISO(item.updatedAt), updated > last else { return nil }
            // … and only past the cooldown floor.
            let cooldown = item.notify.cooldown.flatMap(parseDuration) ?? defaultCooldown
            guard now.timeIntervalSince(last) >= cooldown else { return nil }
        }
        // (lastNotifiedAt nil ⇒ never pinged ⇒ fire on this first eligible tick.)

        let reason = trimmedNonEmpty(item.notify.notifyReason)
            ?? "\(item.project) · \(item.title) — now \(item.status.rawValue)"
        return Decision(
            handle: item.handle,
            title: "Desk · \(item.project)",
            body: reason,
            level: item.notify.level,
            observedUpdatedAt: item.updatedAt
        )
    }

    // MARK: helpers

    static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Parse "30m" / "2h" / "1d" / "45s" into seconds (mirrors DeskProjection).
    static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()) else { return nil }
        switch unit {
        case "s": return TimeInterval(value)
        case "m": return TimeInterval(value * 60)
        case "h": return TimeInterval(value * 3600)
        case "d": return TimeInterval(value * 86_400)
        default: return nil
        }
    }
}
