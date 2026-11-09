import Foundation
import AttentionRouting
import BackgroundLoops
import ChatTurnRuntime
import Cognition
import Experiences
import PersistenceCore
import Desk
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `DeskNotifyRunner.swift` | Desk matters and nags; ForPerson changes arm the quiet-window end deadline, which releases owed doors |

// The part proposes; this native owner commits bookkeeping and delivers.
public struct DeskNotifyRunner: EventDeadlineLoopRunner {
    private let propose: @Sendable (JSONValue) async throws -> DeskNotificationProposal
    private let attention: AttentionRouter
    public init(dataRoot: URL,
                attention: AttentionRouter,
                propose: @escaping @Sendable (JSONValue) async throws -> DeskNotificationProposal) {
        self.propose = propose
        self.dataRoot = dataRoot
        self.attention = attention
    }

    public var wake: OrganWake { .onChange }
    let dataRoot: URL

    public var loopId: String { "desk_notify" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func physiologyEvents() -> AsyncStream<Void> {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let events = EventDeadlinePhysiology.storeAndFileEvents(
            paths: [store.opsPath, store.basePath, DeskNagConfigStore(dataRoot: dataRoot).configPath,
                    dataRoot.appendingPathComponent("abilities/desk-notify.js"),
                    dataRoot.appendingPathComponent("user_prefs.json")],
            stores: [.desk],
            notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange],
            loopId: loopId
        )
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let files = Task {
            for await _ in events { pair.continuation.yield(()) }
        }
        let matters = Task {
            for await _ in await ForPerson.at(dataRoot).changes() { pair.continuation.yield(()) }
        }
        pair.continuation.onTermination = { _ in files.cancel(); matters.cancel() }
        return pair.stream
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let held: Bool
        do { held = try await AttentionRouter.hasHeld(dataRoot: dataRoot) }
        catch {
            await recordDeadlineFailure(error, source: "held notification record")
            return nil
        }
        let quietEnd: Date?
        do {
            quietEnd = try AttentionRouter.quietHoursEnd(at: now, dataRoot: dataRoot)
        } catch {
            await recordDeadlineFailure(error, source: "quiet-hours preferences")
            return nil
        }
        do {
            let read = try await DeskNotificationRead.read(dataRoot: dataRoot, now: now)
            let proposal = try await propose(read.input)
            try read.validate(proposal)
            return [proposal.deadline.map { Date(timeIntervalSince1970: $0) }, held ? quietEnd : nil].compactMap { $0 }.min()
        } catch {
            nativeLog("desk_notify: deadline proposal failed: \(error)")
            await settle {
                await BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: loopId,
                    outcome: .failed(error: """
                        Desk notification deadline unavailable: \(error.localizedDescription). Repair the Desk or inbox source before retrying.
                        """))
            }
            return held ? quietEnd : nil
        }
    }

    private func recordDeadlineFailure(_ error: any Error, source: String) async {
        await settle {
            await BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: loopId,
                outcome: .failed(error: "Desk notification \(source) unavailable: \(error.localizedDescription). Repair the source to rearm delivery."))
        }
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let outcome = await notify()
        if Task.isCancelled {
            OrganJudge.beat(loopId, .stopped, note: "cancelled", cadence: wake.period)
        } else {
            OrganJudge.beat(loopId, tick: outcome, cadence: wake.period)
        }
        return outcome
    }

    private func notify() async -> LoopTickOutcome {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        var released = 0
        var failures: [String] = []
        if !Task.isCancelled {
            do { released = try await AttentionRouter.release(dataRoot: dataRoot, router: attention) }
            catch { failures.append("Held notification release: \(error.localizedDescription)") }
        }
        let prepared: Result<(DeskNotificationRead, DeskNotificationProposal), Error>
        do {
            try Task.checkCancellation()
            let read = try await DeskNotificationRead.read(dataRoot: dataRoot, now: Date())
            let proposal = try await propose(read.input)
            _ = try await read.commit(proposal, dataRoot: dataRoot)
            try Task.checkCancellation()
            prepared = .success((read, proposal))
        } catch {
            prepared = .failure(error)
        }
        let read: DeskNotificationRead
        let proposal: DeskNotificationProposal
        switch prepared {
        case .success(let value): (read, proposal) = value
        case .failure(let error):
            // The Desk moved under this pass; the change that moved it wakes the next one, so this is no failure.
            if error is DeskNotificationRead.ChangedRead, released == 0, failures.isEmpty { return .skipped(reason: "the Desk changed during this pass") }
            return .failed(error: "Desk notification proposal/commit: \(error)"
                + (released > 0 ? "; released \(released) held notification(s)" : "")
                + (failures.isEmpty ? "" : "; " + failures.joined(separator: "; ")))
        }
        let state = read.state
        let decisions = proposal.notifications
        var notified = 0
        var deferred = Set<String>()
        let nagCount = await publishNags(proposal, read: read, failures: &failures, deferred: &deferred)
        if decisions.isEmpty && nagCount == 0 && released == 0 && failures.isEmpty {
            return .skipped(reason: "no Desk notification due")
        }
        // Retain every due decision now; the router owns quiet-hours holding and its release.
        for decision in decisions {
            guard !Task.isCancelled else { break }
            // Preserve failed occurrences and derive identity from the evaluated immutable state, never a post-delivery reread.
            guard let item = state.items.first(where: { $0.handle == decision.handle }) else {
                failures.append("\(decision.handle) notification has no observed Desk item")
                continue
            }
            let revision = item.status.isTerminal
                ? (item.closedAt ?? decision.observedUpdatedAt)
                : decision.observedUpdatedAt
            // A normal router return retains intent; destination verdicts alone prove acceptance.
            var outcome: AttentionOutcome?
            if !Task.isCancelled {
                do { outcome = try await attention.tell(Matter(id: "desk_notify:\(decision.handle):\(revision)",
                    form: decision.level == "urgent" ? .wentWrong : item.status.isTerminal ? .done : .words,
                    from: "desk", title: decision.title, summary: decision.body,
                    open: "page:desk/" + decision.handle, evidence: [.init(source: "desk", id: decision.handle)]),
                    reach: .person(from: nil), turn: nil
                ) } catch { failures.append("\(decision.handle) notification route: \(error.localizedDescription)") }
            }
            if let outcome {
                for (destination, verdict) in outcome.destinationOutcomes {
                    if case .notDelivered(let reason) = verdict {
                        failures.append("\(decision.handle) \(destination): \(reason)")
                    }
                }
            }
            if let message = outcome?.deferredFields?["message"]?.stringValue { deferred.insert(message) }
            if outcome?.destinationOutcomes.values.contains(.delivered) == true { notified += 1 }
            // The matter keeps its owed doors, even while held or awaiting a receipt.
            guard outcome != nil else { continue }
            // CAS stamps only the notified version so concurrent edits keep their ping owed.
            // markNotified leaves updatedAt unchanged to prevent self-triggering.
            // One-time announcements stamp unconditionally to prevent repeat delivery.
            let stampError: String? = await settle {
                do {
                    if decision.oneTimeAnnouncement {
                        _ = try await store.markNotified(decision.handle)
                    } else {
                        _ = try await store.markNotifiedIfUnchanged(decision.handle, expectedUpdatedAt: decision.observedUpdatedAt)
                    }
                    return nil
                } catch { return "\(decision.handle) notification stamp: \(error)" }
            }
            if let stampError {
                nativeLog("desk_notify: %@ — may re-ping next tick", stampError)
                failures.append(stampError)
            }
        }
        let held = deferred.isEmpty ? "" : "; " + deferred.sorted().joined(separator: "; ")
        if !failures.isEmpty {
            return .failed(error: "Desk notification partial failure: "
                + failures.prefix(5).joined(separator: "; ") + held)
        }
        // Count channel acceptance, not proposed decisions.
        return .completed(result: "notified \(notified) of \(decisions.count) Desk decision(s)"
            + (nagCount > 0 ? " + \(nagCount) recorded nag(s)" : "") + held)
    }

    /// A digest never travels alone, except for the mute-expiry drift report.
    private func publishNags(_ proposal: DeskNotificationProposal, read: DeskNotificationRead,
                             failures: inout [String], deferred: inout Set<String>) async -> Int {
        guard !Task.isCancelled else { return 0 }
        if proposal.openWindow {
            if !proposal.digest.isEmpty {
                if await deliverNag(title: proposal.digestTitle, body: proposal.digestBody,
                    label: "unmute digest:\(read.config.windowId)", failures: &failures, deferred: &deferred) {
                    let error: String? = await settle {
                        do {
                            _ = try await read.commit(proposal, dataRoot: dataRoot, digestAccepted: true)
                            return nil
                        } catch { return "unmute digest stamp: \(error)" }
                    }
                    if let error { failures.append(error) }
                    return 1
                }
            }
            return 0
        }
        var delivered = 0
        for nag in proposal.nags {
            guard !Task.isCancelled else { break }
            if await deliverNag(title: nag.title, body: nag.body, label: "\(nag.handle):\(read.config.windowId)",
                deskHandle: nag.handle, failures: &failures, deferred: &deferred) {
                delivered += 1
                let error: String? = await settle {
                    do { try await read.recordNagDelivery(nag, dataRoot: dataRoot); return nil }
                    catch { return "\(nag.handle) nag stamp: \(error)" }
                }
                if let error { failures.append(error) }
            }
        }
        return delivered
    }

    /// Keep each selected destination's refusal visible without inventing an absent door.
    private func deliverNag(
        title: String,
        body: String,
        label: String,
        deskHandle: String? = nil,
        failures: inout [String],
        deferred: inout Set<String>
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        // Item handles route banner clicks to their item; the unmute digest has no single target.
        let outcome: AttentionOutcome?
        do { outcome = try await attention.tell(Matter(id: "desk_nag:\(label)", form: .words, from: "desk",
            title: title, summary: body, open: deskHandle.map { "page:desk/" + $0 } ?? "page:desk",
            evidence: deskHandle.map { [.init(source: "desk", id: $0)] } ?? []), reach: .person(from: nil), turn: nil
        ) } catch {
            outcome = nil
            failures.append("\(label) nag route: \(error.localizedDescription)")
        }
        if let outcome {
            for (destination, verdict) in outcome.destinationOutcomes {
                if case .notDelivered(let reason) = verdict { failures.append("\(label) nag \(destination): \(reason)") }
            }
        }
        if let message = outcome?.deferredFields?["message"]?.stringValue { deferred.insert(message) }
        return outcome != nil // The matter owns every destination from here.
    }
}
