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
// notify.on event filter (blocked/unblocked/due/…) is captured on the item but
// not yet fully enforced here — a documented refinement, not a silent gap —
// with ONE enforced exception (2026-08-08, the "opened a self-pursuit" storm):
// an item whose `on` is exactly ["explicit"] is a one-time announcement. It
// pings once and never again from bare updatedAt churn — the Workshop pump's
// own work-session ops advance updatedAt every couple of hours, and before
// this rule each advance replayed the frozen open-time notifyReason at the
// user (28 pushes for 2 pursuits in 4 days). Re-pings on OTHER filters also
// stop replaying the open-time reason: a re-ping describes the change.

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
        /// True for `on == ["explicit"]` one-time announcements. The loop
        /// stamps these UNCONDITIONALLY (no updatedAt CAS): fired is fired,
        /// and a content change landing mid-tick must not resurrect the
        /// announcement as a fresh "first ping" (gpt-5.5 review 2026-08-08).
        public let oneTimeAnnouncement: Bool

        public init(
            handle: String,
            title: String,
            body: String,
            level: NotifyLevel,
            observedUpdatedAt: String,
            oneTimeAnnouncement: Bool = false
        ) {
            self.handle = handle
            self.title = title
            self.body = body
            self.level = level
            self.observedUpdatedAt = observedUpdatedAt
            self.oneTimeAnnouncement = oneTimeAnnouncement
        }
    }

    /// Cooldown floor used when an item's notify.cooldown is unset/unparseable.
    public static let defaultCooldown: TimeInterval = 30 * 60

    /// The items that should ping User NOW, in desk (alias) order.
    public static func decisions(_ state: DeskState, now: Date) -> [Decision] {
        state.items.compactMap { decision(for: $0, now: now) }
    }

    /// Earliest future moment this lane could fire, per item:
    ///   • a PARKED item's own defer expiry — parking silences the shoulder-tap
    ///     (see `decision`), so the park ending is itself a wake-worthy moment:
    ///     an item that accumulated changes while parked must ping when it
    ///     un-parks, not whenever the next unrelated event happens to wake the
    ///     loop. Reported whether or not a cooldown is also outstanding, since
    ///     the defer gate outranks it.
    ///   • otherwise the cooldown crossing for an already-changed item.
    /// Initial notifications and already-due rows are handled by the event or
    /// startup reconciliation pass; returning only a future date prevents an
    /// exact-deadline owner from spinning on corrupt/unchanged state.
    public static func nextMeaningfulDeadline(_ state: DeskState, after now: Date) -> Date? {
        state.items.compactMap { item -> Date? in
            guard item.notify.level == .direct || item.notify.level == .urgent,
                  !item.status.isTerminal
            else { return nil }
            // A one-time announcement that already fired can never ping again,
            // so it must not generate wake deadlines either (a deadline for a
            // ping `decision` will refuse would spin the loop).
            if item.notify.lastNotifiedAt != nil, isExplicitOnly(item) { return nil }
            // Parked: the only thing that can unblock this item is the park
            // ending — but wake for it ONLY if a ping actually follows, so the
            // park end is a deadline for items with something to say, not for
            // every parked row on the desk.
            if DeskSequencing.isDeferred(item, now: now) {
                guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let until = DeskSequencing.parseDeferStamp(raw), until > now
                else { return nil }
                guard let lastRaw = item.notify.lastNotifiedAt,
                      let last = DeskClock.parseISO(lastRaw)
                else { return until }   // never pinged ⇒ eligible the moment the park lifts
                guard let updated = DeskClock.parseISO(item.updatedAt), updated > last
                else { return nil }     // nothing pending ⇒ the park end is not news
                let cooldown = item.notify.cooldown.flatMap(parseDuration) ?? defaultCooldown
                // Both gates must clear; the later one is the real moment.
                return max(until, last.addingTimeInterval(cooldown))
            }
            guard let lastRaw = item.notify.lastNotifiedAt,
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
        // PARKING SILENCES THE SHOULDER-TAP TOO (audit 2026-08-02, finding 4).
        // Both other desk lanes already honour the park — DeskSequencing drops a
        // deferred item out of `nextUp`, DeskNagEvaluator refuses to call it
        // stale — and this one didn't, so an item parked until September that
        // picked up a ref today fired a direct push. "Not now" has to mean the
        // same thing on every lane, and the loudest lane is the one where it
        // matters most. The change is NOT lost: `updatedAt` still sits past
        // `lastNotifiedAt`, so it fires on the first tick after the park ends —
        // which `nextMeaningfulDeadline` above now schedules exactly.
        guard !DeskSequencing.isDeferred(item, now: now) else { return nil }

        var isRePing = false
        if let lastRaw = item.notify.lastNotifiedAt, let last = DeskClock.parseISO(lastRaw) {
            // One-time announcements never re-ping: `on == ["explicit"]` means
            // the opener asked for exactly one shoulder-tap, and routine
            // machine churn (work logs, session receipts) advancing updatedAt
            // must not replay it.
            guard !isExplicitOnly(item) else { return nil }
            // Already pinged once: re-ping only on a REAL change since then
            // (markNotified doesn't bump updatedAt, so the stamp itself can't
            // re-trigger) …
            guard let updated = DeskClock.parseISO(item.updatedAt), updated > last else { return nil }
            // … and only past the cooldown floor.
            let cooldown = item.notify.cooldown.flatMap(parseDuration) ?? defaultCooldown
            guard now.timeIntervalSince(last) >= cooldown else { return nil }
            isRePing = true
        }
        // (lastNotifiedAt nil ⇒ never pinged ⇒ fire on this first eligible tick.)

        // notifyReason describes the moment the policy was SET (e.g. "opened a
        // self-pursuit"). It is first-ping copy only; a re-ping describes the
        // current state instead of replaying the stale announcement.
        let reason = isRePing
            ? "\(item.project) · \(item.title) — now \(item.status.rawValue)"
            : (trimmedNonEmpty(item.notify.notifyReason)
                ?? "\(item.project) · \(item.title) — now \(item.status.rawValue)")
        return Decision(
            handle: item.handle,
            title: "Desk · \(item.project)",
            body: reason,
            level: item.notify.level,
            observedUpdatedAt: item.updatedAt,
            oneTimeAnnouncement: isExplicitOnly(item)
        )
    }

    // MARK: helpers

    /// True when the item's `on` filter is exactly the one-time announcement:
    /// ping once, then stay silent regardless of content churn.
    static func isExplicitOnly(_ item: DeskItem) -> Bool {
        let filters = Set(item.notify.on.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).subtracting([""])
        return filters == ["explicit"]
    }

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
