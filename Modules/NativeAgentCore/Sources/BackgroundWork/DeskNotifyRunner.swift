import Foundation
import AttentionRouting
import BackgroundLoops
import ChatTurnRuntime
import Cognition
import NotificationInbox
import PersistenceCore
import Desk
// Blueprint: | `DeskNotifyRunner.swift` | `DeskNotifyRunner`: calls the desk-notify part through the scheduled owner's originating app door; revision-checked native commit before notification delivery, quiet hours, stamps and exact-deadline scheduling; already-committed held deliveries retain their native release path even when a new proposal fails |

// The part proposes; this native owner commits bookkeeping and delivers.
public struct DeskNotifyRunner: EventDeadlineLoopRunner {
    private let propose: @Sendable (JSONValue) async throws -> DeskNotificationProposal
    private let attention: AttentionRouter
    private let postNagNotification: @Sendable (String, String, String?) async -> Bool
    public init(interval: TimeInterval, dataRoot: URL,
                attention: AttentionRouter,
                propose: @escaping @Sendable (JSONValue) async throws -> DeskNotificationProposal,
                postMacNotification: @escaping @Sendable (String, String, [String: String], String?) async -> Bool,
                postNagNotification: @escaping @Sendable (String, String, String?) async -> Bool) {
        self.propose = propose
        self.interval = interval
        self.dataRoot = dataRoot
        self.attention = attention
        self.postMacNotification = postMacNotification
        self.postNagNotification = postNagNotification
    }

    public let interval: TimeInterval
    let dataRoot: URL
    let postMacNotification: @Sendable (String, String, [String: String], String?) async -> Bool

    public var loopId: String { "desk_notify" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func physiologyEvents() -> AsyncStream<Void> {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        // The inbox too: a knock held for quiet hours books their end.
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [store.opsPath, store.basePath, DeskNagConfigStore(dataRoot: dataRoot).configPath,
                    dataRoot.appendingPathComponent("abilities/desk-notify.js"),
                    LiveNotificationInbox.livePath(dataRoot: dataRoot), dataRoot.appendingPathComponent("user_prefs.json")],
            stores: [.desk],
            notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange],
            loopId: loopId
        )
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let held = await AttentionRouter.hasHeld(dataRoot: dataRoot)
        let quietEnd = AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: dataRoot, at: now)
            ? TurnQuietHoursWindow.read(dataRoot: dataRoot)?.end(after: now) : nil
        do {
            let read = try await DeskNotificationRead.read(dataRoot: dataRoot, now: now)
            let proposal = try await propose(read.input)
            try read.validate(proposal)
            let needsQuietEnd = held || read.config.enabled || proposal.notifications.contains(where: { $0.level != "urgent" })
            return [proposal.deadline.map { Date(timeIntervalSince1970: $0) }, needsQuietEnd ? quietEnd : nil].compactMap { $0 }.min()
        } catch {
            nativeLog("desk_notify: deadline proposal failed: \(error)")
            return held ? quietEnd : nil
        }
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        var quietHours = AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: dataRoot)
        let prepared: Result<(DeskNotificationRead, DeskNotificationProposal), Error>
        do {
            try Task.checkCancellation()
            let read = try await DeskNotificationRead.read(dataRoot: dataRoot, now: Date())
            let proposal = try await propose(read.input)
            quietHours = AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: dataRoot)
            _ = try await read.commit(proposal, dataRoot: dataRoot, quietHours: quietHours)
            try Task.checkCancellation()
            prepared = .success((read, proposal))
        } catch {
            quietHours = AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: dataRoot)
            prepared = .failure(error)
        }
        // Already-committed inbox deliveries retain their native release path
        // when a new Desk proposal fails. Stop still prevents new delivery.
        let released = quietHours || Task.isCancelled ? 0 : await AttentionRouter.releaseHeld(
            dataRoot: dataRoot, router: attention, banner: postMacNotification)
        let read: DeskNotificationRead
        let proposal: DeskNotificationProposal
        switch prepared {
        case .success(let value): (read, proposal) = value
        case .failure(let error):
            return .failed(error: "Desk notification proposal/commit: \(error)"
                + (released > 0 ? "; released \(released) held notification(s)" : ""))
        }
        let state = read.state
        let decisions = proposal.notifications
        var failures: [String] = []
        var notified = 0
        let nagCount = quietHours ? 0 : await publishNags(proposal, failures: &failures)
        if decisions.isEmpty && nagCount == 0 && released == 0 && failures.isEmpty {
            return .skipped(reason: "no Desk notification due")
        }
        // Quiet hours hold a direct ping's Mac banner exactly as they hold its
        // push. Nothing is stamped, so it still lands on the first tick after
        // the window. An urgent item is never held: it posts and routes now.
        for decision in decisions where !quietHours || decision.level == "urgent" {
            // Dual delivery: Mac banner + paired-device push (the same backends
            // mac_notify / mobile_notify use). Best-effort; outcomes logged so a
            // failure isn't silent. v1 marks after attempting; success-gated retry
            // with backoff is a noted refinement (failures here are near-always a
            // permanent notification-setup issue, where retry only spams).
            let macOK = await postMacNotification(decision.title, decision.body, [:], nil)
            // Derive identity from the same immutable state evaluated
            // above, never from prose or a second read after delivery.
            let item = state.items.first { $0.handle == decision.handle }
            let revision = item?.status.isTerminal == true
                ? (item?.closedAt ?? decision.observedUpdatedAt)
                : decision.observedUpdatedAt
            // A non-throwing return is not a delivery: the router can
            // return normally having chosen no channel at all. Read its own
            // projection instead.
            let outcome = try? await attention.route(
                eventId: "desk_notify:\(decision.handle):\(revision)",
                importance: decision.level == "urgent" ? .adverse : .ownerWaiting,
                title: decision.title,
                body: decision.body,
                userInfo: ["screen": "inbox", "source": "desk"]
            )
            let projection = outcome?.deliveryProjection ?? .failed
            let mobileOK = projection != .failed
            let mobileReached = projection.reachedAChannel
            // Log BOTH channel outcomes so no failure is silent (Agent review).
            if !macOK {
                nativeLog("desk_notify: Mac banner failed for \(decision.handle)")
                failures.append("\(decision.handle) Mac banner")
            }
            if !mobileOK {
                nativeLog("desk_notify: paired-device push failed for \(decision.handle)")
                failures.append("\(decision.handle) paired-device push")
            }
            if macOK || mobileReached { notified += 1 }
            // Stamp lastNotifiedAt via CAS on the NOTIFIED version: if a content
            // change landed during this tick, skip the stamp so the next tick
            // pings the newer state (no lost ping). markNotified does NOT bump
            // updatedAt, so it can never re-trigger itself.
            // EXCEPT one-time announcements: those stamp unconditionally —
            // the announcement fired, and a mid-tick content change must not
            // leave lastNotifiedAt nil and resurrect it as a fresh first ping
            // (gpt-5.5 review 2026-08-08, the self-pursuit push storm).
            do {
                if decision.oneTimeAnnouncement {
                    _ = try await store.markNotified(decision.handle)
                } else {
                    _ = try await store.markNotifiedIfUnchanged(decision.handle, expectedUpdatedAt: decision.observedUpdatedAt)
                }
            } catch {
                nativeLog("desk_notify: stamp failed for \(decision.handle): \(error) — may re-ping next tick")
                failures.append("\(decision.handle) notification stamp: \(error)")
            }
        }
        if !failures.isEmpty {
            return .failed(error: "Desk notification partial failure: "
                + failures.prefix(5).joined(separator: "; "))
        }
        // The count is what a channel actually took, not how many decisions
        // this pass considered.
        return .completed(result: "notified \(notified) of \(decisions.count) Desk decision(s)"
            + (nagCount > 0 ? " + \(nagCount) nag(s)" : ""))
    }

    /// Ledger and baseline transitions have committed before publication.
    /// A digest never travels alone, except for the mute-expiry drift report.
    private func publishNags(_ proposal: DeskNotificationProposal, failures: inout [String]) async -> Int {
        if proposal.openWindow {
            if !proposal.digest.isEmpty {
                await deliverNag(title: proposal.digestTitle, body: proposal.digestBody,
                    label: "unmute digest", failures: &failures)
            }
            return 0
        }
        for nag in proposal.nags {
            await deliverNag(title: nag.title, body: nag.body, label: nag.handle,
                deskHandle: nag.handle, failures: &failures)
        }
        return proposal.nags.count
    }

    /// Same dual delivery as the notify pass (Mac banner + paired-device push),
    /// with both channel outcomes logged so no failure is silent.
    private func deliverNag(
        title: String,
        body: String,
        label: String,
        deskHandle: String? = nil,
        failures: inout [String]
    ) async {
        // The banner carries the handle it is about, so a click lands on that
        // item instead of on the app's front page. The unmute digest is about
        // no single item and carries nothing.
        let mobileOutcome = try? await attention.route(
            eventId: "desk_nag:\(label)",
            importance: .ownerWaiting,
            title: title,
            body: body,
            userInfo: ["screen": "inbox", "source": "desk"]
        )
        let mobileOK = mobileOutcome.map { $0.deliveryProjection != .failed } ?? false
        // The banner obeys the router's quiet hours, like the push.
        let macPosted = await AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: dataRoot)
            ? true
            : postNagNotification(title, body, deskHandle)
        if !macPosted {
            nativeLog("desk_notify: nag Mac banner failed for \(label)")
            failures.append("\(label) nag Mac banner")
        }
        if !mobileOK {
            nativeLog("desk_notify: nag paired-device push failed for \(label)")
            failures.append("\(label) nag paired-device push")
        }
    }
}
