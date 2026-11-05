// Share worthwhile source-backed things at considerate times without requiring a reply.
// Use local timing gates and one resident wake; absence may permit timing but cannot create a candidate.
// Keep pacing facts in the bounded ledger outside prompts; settled care outcomes belong to their care's story.

import ChatTurnRuntime
import AgentWorkspace
import AgentConversations
import CognitiveSubstrate
import Desk
import DreamREMCycle
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Transcripts
import TurnTrace
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+Reach.swift` | `NativeCognitionRuntime`. |

/// Keep only process-local flight state here; restart-surviving facts belong in the ledger.
extension NativeCognitionRuntime {

    func withdrawReachIfDisabled() {
        guard !reachEnabled else { return }
        _ = ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "reach")
        guard var ledger = ReachLedger.read(dataRoot) else { return }
        var changed = false
        for index in ledger.offers.indices where ledger.offers[index].outcome == "offered" {
            ledger.offers[index].outcome = "withheld"
            changed = true
        }
        guard changed else { return }
        let saved = ledger.write(dataRoot)
        if let off = clockOffReason(explicit: false) {
            OrganJudge.beatOff(MindClockVerb.reach.organ, because: off + (saved ? "; the pending offer was withdrawn"
                : "; the pending offer was withdrawn but the ledger was not saved"))
        }
    }

    /// Use the existing residual deadline rather than another timer or budget.
    func considerReach(runNow: Bool = false, reply: MindClockReply? = nil) {
        if !isFlushedForTermination, let off = clockOffReason(explicit: false) {
            if let reply { reply(.off(off)) } else { beat(.reach, .off(off)) }
            return
        }
        guard !isFlushedForTermination, sourceWakes.reachReady, reachEnabled, reachTask == nil else {
            reply?(.init("held", "Reach sources are not ready, a pass is running, or the runtime is stopping.")); return
        }
        if let due = sourceWakes.reachNextAt, due <= now() { sourceWakes.reachDirty = true }
        guard runNow || sourceWakes.reachDirty else { return }
        reachTask = Task {
            let result = await self.runReachPass(satisfyWait: runNow)
            if let reply { reply(result) } else { await self.beat(.reach, result) }
            await self.finishReachPass()
        }
    }

    private func finishReachPass() async {
        reachTask = nil
        await rescheduleResidualRepairDeadline()
    }

    private func reachTiming(at instant: Date) async throws -> Reach.Timing {
        Reach.Timing(
            now: instant,
            quietHours: host.inQuietHours(at: instant, dataRoot: dataRoot),
            liveTurn: liveTurnInFlight,
            lastUserTurn: UserTurnStamp.last(dataRoot: dataRoot))
    }

    private func runReachPass(satisfyWait: Bool = false) async -> MindClockResult {
        // Consume invalidation before awaiting reads so later edges survive even a failed pass.
        sourceWakes.reachDirty = false
        sourceWakes.reachNextAt = nil
        do { return try await runReachPassChecked(satisfyWait: satisfyWait) }
        catch {
            sourceWakes.reachNextAt = nil
            _ = Self.bodySourceFailure(error, source: "Reach source inventory", dataRoot: dataRoot)
            return .init("unavailable", "Reach sources are unavailable: " + error.localizedDescription
                + ". Repair the named source; no subject or audience was substituted.")
        }
    }

    private func runReachPassChecked(satisfyWait: Bool) async throws -> MindClockResult {
        guard !isFlushedForTermination, !Task.isCancelled else { return .init("stopped", "Reach stopped.") }
        if let off = clockOffReason(explicit: false) {
            withdrawReachIfDisabled()
            return .off(off)
        }
        let instant = now()
        let person = try Self.resolvedPerson(dataRoot: dataRoot)
        await reconcileReachDeliveries()
        do { try ReachAnswerSettlement.record(dataRoot: dataRoot, now: instant) }
        catch {
            nativeLog("reach: answer settlement not kept: %@", error.localizedDescription)
            return .init("unavailable", "Reach answer settlement was not kept: " + error.localizedDescription)
        }
        var timing = try await reachTiming(at: instant)
        // Keep ledger read-modify-write in one actor segment so stale state cannot overwrite a sending row.
        guard var ledger = ReachLedger.read(dataRoot) else { return .init("unavailable", "The Reach ledger could not be read.") }
        projectReachDeadline(timing: timing, ledger: ledger, candidates: [])
        var changed = false
        // Withdraw a pending offer when its considerate moment has passed, before spending a turn.
        if let passed = Reach.momentPassed(timing), let index = ledger.offers.lastIndex(where: { $0.outcome == "offered" }),
           ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "reach") {
            ledger.offers[index].outcome = "withheld"
            changed = true
            OrganJudge.beat(MindClockVerb.reach.organ, .held, note: "withdrew the pending offer: its moment passed (\(passed.rawValue))")
        }
        if changed, !ledger.write(dataRoot) { return .init("failed", "The withdrawn Reach offer was not saved.") }
        await landReachAnswers(ledger)
        let gate = Reach.timing(timing, ledger: ledger)
        guard gate == .offer else { return .waiting(gate.rawValue) }
        if !satisfyWait, let last = sourceWakes.reachLastScanAt, instant.timeIntervalSince(last) < Reach.scanInterval {
            sourceWakes.reachNextAt = last.addingTimeInterval(Reach.scanInterval)
            return .waiting("Reach candidate reads are cooling down.")
        }
        sourceWakes.reachLastScanAt = instant
        timing = try await reachTiming(at: instant)
        let rejected = await substrate.associationSuppressionSnapshot().map(\.source)
        let candidates = try await reachCandidates(at: instant)
        projectReachDeadline(timing: timing, ledger: ledger, candidates: candidates)
        guard candidates.contains(where: {
            Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected) == .offer
        }) else {
            return .init("nothing", candidates.isEmpty ? "No current Reach candidate was available; no offer was made."
                : "No candidate passed Reach policy.", fields: ["decisions": .array(candidates.map {
                    .object([
                        "subject": .string($0.subject),
                        "outcome": .string(Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected).rawValue)
                    ])
                })])
        }
        if let off = clockOffReason(explicit: false) {
            withdrawReachIfDisabled()
            return .off(off + " (switched off during its reads)")
        }
        guard !isFlushedForTermination, !Task.isCancelled else { return .init("stopped", "Reach stopped during its reads.") }
        timing = try await reachTiming(at: now())
        guard let fresh = ReachLedger.read(dataRoot) else { return .init("unavailable", "The fresh Reach ledger could not be read.") }
        ledger = fresh
        guard let pick = candidates.first(where: {
            Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected) == .offer
        }) else { return .init("nothing", "No candidate passed the fresh Reach policy read.") }
        let offer = ReachLedger.Offer(
            id: "reach:" + UUID().uuidString.lowercased(), subject: pick.subject, kind: pick.kind.name,
            source: pick.source, why: pick.why, offeredAt: instant, outcome: "offered", at: pick.at)
        ledger.offers.append(offer)
        guard ledger.write(dataRoot) else { return .init("failed", "The Reach offer was not saved.") }
        // A stable reach key lets a newer offer replace a pending one.
        let kept = ResidentWake.shared.request(dataRoot: dataRoot, reason: "something worth sharing", items: [.init(
            id: offer.id, line: Reach.wakeLine(pick, person: person),
            key: "reach", thread: "reach", at: instant)])
        await substrate.recordReceipt(kind: "reach.offered", payload: .object([
            "id": .string(offer.id), "subject": .string(pick.subject), "kind": .string(pick.kind.name),
            "source": .string(pick.source), "why": .string(pick.why),
            "counters": .object(ledger.counters(lastUserTurn: timing.lastUserTurn, now: instant)),
        ]))
        return .init(kept ? "offered" : "failed", kept ? pick.why : "The offer was saved but its ResidentWake was not kept.", fields: [
            "id": .string(offer.id), "subject": .string(pick.subject), "wake_kept": .bool(kept)
        ])
    }

    /// Reconcile uncertain offers without attempting speech again.
    private func reconcileReachDeliveries() async {
        guard let snapshot = ReachLedger.read(dataRoot) else { return }
        for offer in snapshot.offers where offer.outcome == "sending" {
            guard let session = offer.session else { continue }
            do {
                // Positive append evidence may settle an in-flight delivery; absence cannot prove a later append will not land.
                guard try await SwiftNativeChatOrchestrationClient.proactiveSpeechCommitted(
                    dataRoot: dataRoot, caller: .reachOut, idempotencyScope: offer.id, sessionId: session),
                      var fresh = ReachLedger.read(dataRoot),
                      let row = fresh.offers.firstIndex(where: { $0.id == offer.id && $0.outcome == "sending" }) else { continue }
                fresh.offers[row].outcome = "sent"
                fresh.write(dataRoot)
            } catch {
                nativeLog("reach: delivery still uncertain for %@: %@", offer.id, error.localizedDescription)
            }
        }
    }

    /// Retry failed care saves by source identity so a settled answer moves its care only once.
    private func landReachAnswers(_ ledger: ReachLedger) async {
        let person: String
        do { person = try Self.resolvedPerson(dataRoot: dataRoot) }
        catch { _ = Self.bodySourceFailure(error, source: "memory/profile.json", dataRoot: dataRoot); return }
        var landed: [String] = []
        for offer in ledger.offers where offer.landed == nil {
            guard let answered = offer.answered, let sent = offer.sentAt, let session = offer.session,
                  CognitiveSubstrate.peerIdentity(session: session, dataRoot: dataRoot) == nil, offer.subject.hasPrefix("care:"),
                  let care = UUID(uuidString: String(offer.subject.dropFirst(5))) else { continue }
            let closed = sent.addingTimeInterval(Reach.answerWindow)
            do {
                if try await substrate.noteReachLanded(
                    care: care, answered: answered, person: person, source: offer.id,
                    at: answered ? (offer.answeredAt ?? closed) : closed) {
                    landed.append(offer.id)
                }
            } catch {
                nativeLog("reach: how %@ landed is not in its care yet, the next pass tries again: %@",
                          offer.id, String(describing: error))
            }
        }
        // Patch only these rows against a fresh read in one segment.
        guard !landed.isEmpty, var fresh = ReachLedger.read(dataRoot) else { return }
        for index in fresh.offers.indices where landed.contains(fresh.offers[index].id) {
            fresh.offers[index].landed = true
        }
        fresh.write(dataRoot)
    }

    private func projectReachDeadline(timing: Reach.Timing, ledger: ReachLedger, candidates: [ReachCandidate]) {
        let quiet: TurnQuietHoursWindow?
        do { quiet = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot) }
        catch {
            // Unknown quiet-hour boundaries remain repair owed; preference invalidation projects the repaired window.
            sourceWakes.reachNextAt = nil
            return
        }
        let at = timing.now
        let relevant = candidates.filter { candidate in
            let life: TimeInterval = if case .plan = candidate.kind { 86_400 } else { Reach.freshness }
            return candidate.at.addingTimeInterval(life) >= at
        }
        let plans = pursuitCandidates.filter { !$0.status.isTerminal && $0.origin == .owner }
            .compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }.filter { $0 > at.addingTimeInterval(-86_400) }
        let deferred = plans.filter { $0 > at }
        var boundaries = deferred + relevant.flatMap { candidate -> [Date] in
            let life: TimeInterval = if case .plan = candidate.kind { 86_400 } else { Reach.freshness }
            return [candidate.at, Self.afterInclusiveBoundary(candidate.at.addingTimeInterval(life))]
        }
        boundaries += ledger.offers.flatMap { offer in
            [offer.offeredAt.addingTimeInterval(Reach.subjectCooldown)] + (offer.sentAt.map {
                [$0.addingTimeInterval(Reach.minimumSpacing), Self.afterInclusiveBoundary($0.addingTimeInterval(Reach.answerWindow))]
            } ?? [])
        }
        let pending = ledger.offers.contains {
            $0.outcome == "offered"
                || ($0.outcome == "sent" && $0.sentAt.map { $0.addingTimeInterval(Reach.answerWindow) >= at } == true)
        }
        let current = relevant.contains { $0.at <= at } || plans.contains { $0 <= at }
        if pending || current {
            if let last = timing.lastUserTurn { boundaries.append(last.addingTimeInterval(Reach.activeWindow)) }
            if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: at)) { boundaries.append(nextDay) }
            if let quiet {
                for hour in [quiet.startHour, quiet.endHour] {
                    if let next = Calendar.current.nextDate(after: at, matching: DateComponents(hour: hour, minute: 0, second: 0),
                        matchingPolicy: .nextTime) { boundaries.append(next) }
                }
            }
        }
        // Retain timing eligibility boundaries even when a gate defers candidate reads.
        let timingBoundary: Date? = switch Reach.timing(timing, ledger: ledger) {
        case .quietHours:
            quiet?.end(after: at)
        case .userActive:
            timing.lastUserTurn?.addingTimeInterval(Reach.activeWindow)
        case .dailyCap:
            timing.calendar.date(byAdding: .day, value: 1, to: timing.calendar.startOfDay(for: at))
        case .spacing:
            ledger.offers.filter(\.mayHaveReachedPerson).compactMap(\.sentAt).max()?.addingTimeInterval(Reach.minimumSpacing)
        case .offer, .awaitingUser, .subjectCooldown, .alreadySeen, .rejected, .stale:
            nil
        }
        let sourceBoundary = (pending || !relevant.isEmpty || !plans.isEmpty)
            ? boundaries.filter { $0 > at }.min() : nil
        sourceWakes.reachNextAt = [sourceBoundary, timingBoundary].compactMap { $0 }.filter { $0 > at }.min()
    }

    /// Recheck gates before speech; deliver to the person's conversation and route only the necessary notification.
    public func deliverReach(
        reply: String, itemID: String, turnID: String, chat: SwiftNativeChatOrchestrationClient, turn: Turn
    ) async {
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let instant = now()
        let timing: Reach.Timing
        do { timing = try await reachTiming(at: instant) }
        catch { _ = Self.bodySourceFailure(error, source: "Reach delivery timing", dataRoot: dataRoot); return }
        let rejected = await substrate.associationSuppressionSnapshot().map(\.source)
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot)
        // Recheck gates and persist sending in one segment before delivery; an uncertain send must keep no-reply pacing closed.
        guard var ledger = ReachLedger.read(dataRoot) else { return }
        guard let index = ledger.offers.firstIndex(where: { $0.id == itemID && $0.outcome == "offered" }) else { return }
        if Reach.isDecline(text) {
            ledger.offers[index].outcome = "declined"
        } else if let anchor,
                  Reach.deliverable(ledger.offers[index], timing: timing, ledger: ledger, rejectedSources: rejected) == .offer {
            ledger.offers[index].outcome = "sending"
            ledger.offers[index].sentAt = instant
            ledger.offers[index].session = anchor
        } else {
            ledger.offers[index].outcome = "withheld"
        }
        guard ledger.write(dataRoot) else { return }
        var offer = ledger.offers[index]
        if offer.outcome == "sending", let anchor {
            var outcome = "sending"
            var knocked = false
            var knockFailure: String?
            var destination = anchor
            do {
                switch try await chat.speakProactively(
                    content: text, caller: .reachOut,
                    idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: itemID, content: text),
                    sessionId: anchor, initiative: .scheduled, turn: turn) {
                case .posted:
                    outcome = "sent"
                    // The notification opens the already-written conversation rather than carrying another copy of the message.
                    if reachEnabled {
                        do {
                            knocked = try await host.deliverShoulderTap(
                                eventId: itemID, title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                                body: Reach.knockLine, reason: itemID,
                                userInfo: ["screen": "chat", "source": "reach_out", "sessionId": anchor], at: instant, turn: turn) != nil
                        } catch {
                            knockFailure = error.localizedDescription
                            await recordKnockFailure(error, eventID: itemID)
                        }
                    }
                case .duplicate(let originalSession):
                    destination = originalSession
                    if (try? await SwiftNativeChatOrchestrationClient.proactiveSpeechCommitted(
                        dataRoot: dataRoot, caller: .reachOut, idempotencyScope: itemID, sessionId: originalSession)) == true {
                        outcome = "sent"
                    }
                case .rateLimited:
                    outcome = "withheld"
                }
            } catch is ProactiveSpeechError {
                // An older claim without a destination cannot establish non-delivery through duplication or failed reconciliation.
                nativeLog("reach: claimed delivery still has no established destination")
            } catch {
                // Only the speech owner's clean scan after append termination can establish non-delivery; unreadable evidence stays open.
                nativeLog("reach: delivery needs reconciliation: %@", error.localizedDescription)
                do {
                    outcome = try await SwiftNativeChatOrchestrationClient.proactiveSpeechCommitted(
                        dataRoot: dataRoot, caller: .reachOut, idempotencyScope: itemID, sessionId: anchor)
                        ? "sent" : "withheld"
                } catch {
                    nativeLog("reach: delivery still uncertain: %@", error.localizedDescription)
                }
            }
            // Patch only this row from a fresh read; an unreadable ledger leaves sending uncertain.
            if let fresh = ReachLedger.read(dataRoot), let row = fresh.offers.firstIndex(where: { $0.id == itemID }) {
                ledger = fresh
                if ledger.offers[row].isSent { outcome = "sent" }
                ledger.offers[row].outcome = outcome
                ledger.offers[row].session = destination
                ledger.offers[row].knocked = knocked
                ledger.offers[row].knockFailure = knockFailure
                if outcome == "withheld" { ledger.offers[row].sentAt = nil }
                ledger.write(dataRoot)
                offer = ledger.offers[row]
            }
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnID, kind: "mind.why", sessionId: offer.session ?? ResidentWake.session, surface: "chat",
            payload: .object([
                "lane": .string("outreach"), "outcome": .string(offer.outcome),
                "subject": .string(offer.subject), "kind": .string(offer.kind),
                "source": .string(offer.source), "why": .string(offer.why),
                "detail": .string("mind.reject with this subject as source stops it."),
            ]), turn: turn))
        await substrate.recordReceipt(kind: "reach.\(offer.outcome)", payload: .object([
            "id": .string(offer.id), "subject": .string(offer.subject),
            "knocked": .bool(offer.knocked == true),
            "knockFailure": offer.knockFailure.map(JSONValue.string) ?? .null,
        ]))
    }

    func recordKnockFailure(_ error: Error, eventID: String) async {
        RepairOwed.owe(dataRoot, id: "notification:" + eventID, kind: .run,
            operation: "cognition.notification:" + eventID, owner: "AttentionRouter",
            words: "The words were posted, but their notification is unavailable: " + error.localizedDescription,
            tap: "Repair notification delivery in Settings → Doctor. Do not post the words again.")
        await substrate.recordReceipt(kind: "notification.unavailable", payload: .object([
            "eventId": .string(eventID), "speech": .string("posted"),
            "error": .string(error.localizedDescription),
        ]))
    }

    nonisolated static func resolvedPerson(dataRoot: URL) throws -> String {
        let name = try resolveUserName(dataRoot: dataRoot)
        return name.isEmpty ? "the person" : name
    }

    // MARK: - Candidates (on device, from state the agent already has)

    func reachCandidates(at instant: Date) async throws -> [ReachCandidate] {
        var out: [ReachCandidate] = []
        let person = try Self.resolvedPerson(dataRoot: dataRoot)

        // Only an open care gap can supply outreach; a root's charge alone is feeling rather than something to say.
        if let top = await substrate.caresPressing(for: CognitiveCare.ownerKey, at: instant)
            .first(where: { $0.care.open != nil }),
           top.pressure >= CognitiveSubstrate.careReleasePressure,
           let open = top.care.open, let newest = top.care.story.last(where: { $0.moved != 0 }) ?? top.care.story.last {
            out.append(ReachCandidate(
                kind: .care, subject: "care:\(top.care.id.uuidString)", source: "something on your mind",
                why: newest.note,
                text: "\"\(Self.clipped(top.care.about, 120))\", still wondering: \(Self.clipped(open, 200))",
                at: newest.at))
        }

        // Offer only newly due Desk plans without a requested ping, avoiding duplicate reminders.
        do {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            for item in state.items where item.origin == .owner && item.status != .done && item.status != .canceled
                && item.notify.level != .direct && item.notify.level != .urgent {
                // Skip peer-steered words because they do not carry the person's authority.
                guard Reach.deskProvenanceTrusted(item, trusts: { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) }),
                      let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let until = DeskSequencing.parseDeferStamp(raw),
                      instant.timeIntervalSince(until) <= 86_400 else { continue }
                out.append(ReachCandidate(
                    kind: .plan, subject: "desk:\(item.handle)", source: "\(person)'s Desk (item \(item.alias))",
                    why: "something \(person) said you might do, and it has come due",
                    text: "\"\(Self.clipped(item.title, 120))\", parked until \(raw.prefix(10))", at: until))
            }
        }

        // Keep dream associations gentle, person-related and explicitly labelled as dreams.
        if let diary = try Self.livingDiary(dataRoot: dataRoot, now: instant) {
            let markdown = try String(contentsOf: diary.url, encoding: .utf8)
            for section in DreamClaim.read(in: markdown) {
                if let gap = section.unavailable {
                    _ = Self.bodySourceFailure(PersistenceCoreError.ioFailure(gap),
                        source: "\(diary.url.path): dream claims", dataRoot: dataRoot)
                    continue
                }
                for claim in section.claims where claim.gentle == true && claim.aboutOwner == true {
                    out.append(ReachCandidate(
                        kind: .dream, subject: "dream:\(diary.name)#\(Reach.digest(claim.provenance.quote))", source: "last night's dream diary",
                        why: "it was about \(person), and gentle; a dream association, not something that happened",
                        text: "\"\(Self.clipped(claim.provenance.quote, 160))\"", at: diary.written))
                }
            }
        }

        return out.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : $0.at > $1.at }
    }
}
