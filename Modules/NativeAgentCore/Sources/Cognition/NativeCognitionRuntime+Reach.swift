// One initiative path shares worthwhile things at considerate times, without requiring a reply.
//
//   1. On device, from state she already has, a few CANDIDATES — each a thing,
//      with its source and why it might be worth his time: a plan of User's
//      coming due on the Desk, an open care of hers pressing to be said, an opinion she revised with its evidence, an
//      interest she came back to with a better question, what a trusted
//      builder shipped, a gentle dream association about him.
//   2. TIMING GATES, all on device: his quiet hours, not while he is talking
//      to her or working with Claude, one offer a day, eight hours apart, a
//      subject once a week, nothing he has been around for since, nothing she
//      rejected, and after a message he did not answer nothing more until he
//      is back.
//   3. One candidate that passes everything becomes one resident-wake turn of
//      hers (her voice, her tools, her choice): she writes the message, or
//      answers "pass". It goes to his conversation through the proactive
//      speech seam (`.reachOut`). When that conversation is his Telegram DM
//      it is sent there too and nothing knocks; otherwise one quiet knock to
//      his phone points at it.
//
// Counters are housekeeping facts in one bounded file: when he last
// took a turn, what she offered, sent or passed on, whether he took a turn
// within a day after (a fact, never a score), whether it knocked. They feed
// the timing above; no prompt ever reads them. Absence only ever makes a
// moment considerate; it never makes a candidate.
//
// How it landed is the care's, not the ledger's: once a care's offer to his
// own conversation is settled, the care that sent it gets one story entry by
// him, welcomed or unanswered, written on device. A welcome care grows; an
// unanswered one only keeps the fact (moved 0).

import ChatTurnRuntime
import AgentWorkspace
import AgentConversations
import CognitiveSubstrate
import Desk
import DreamREMCycle
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Transcripts
import TurnTrace
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+Reach.swift` | `NativeCognitionRuntime` outreach execution, durable offer settlement, care landing and exact delivery deadlines |

/// Runtime-owned single flight and source-read limits. Memory only: the facts that
/// must survive a restart are in the ledger.
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
        if changed { ledger.write(dataRoot) }
    }

    /// Rides `rescheduleResidualRepairDeadline`, where the shoulder tap rode:
    /// no timer, no loop, no budget of its own.
    func considerReach() {
        guard !isFlushedForTermination, sourceWakes.reachReady, reachEnabled, reachTask == nil else { return }
        if let due = sourceWakes.reachNextAt, due <= now() { sourceWakes.reachDirty = true }
        guard sourceWakes.reachDirty else { return }
        reachTask = Task {
            await self.runReachPass()
            await self.finishReachPass()
        }
    }

    private func finishReachPass() async {
        reachTask = nil
        await rescheduleResidualRepairDeadline()
    }

    /// Claude's worklog is read only when `withClaude` is asked for.
    private func reachTiming(at instant: Date, withClaude: Bool = false) async -> Reach.Timing {
        Reach.Timing(
            now: instant,
            quietHours: host.inQuietHours(at: instant, dataRoot: dataRoot),
            liveTurn: liveTurnInFlight,
            lastUserTurn: UserTurnStamp.last(dataRoot: dataRoot),
            lastClaude: withClaude && AgentConversationDelivery.lane(for: "claude", dataRoot: dataRoot) != nil
                ? Self.claudeLastActivity(Self.defaultClaudeWorklog()) : nil)
    }

    private func runReachPass() async {
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let instant = now()
        sourceWakes.reachDirty = false
        sourceWakes.reachNextAt = nil
        await reconcileReachDeliveries()
        do { try ReachAnswerSettlement.record(dataRoot: dataRoot, now: instant) }
        catch {
            nativeLog("reach: answer settlement not kept: %@", error.localizedDescription)
            return
        }
        var timing = await reachTiming(at: instant)
        // Each read-modify-write of the ledger below is one synchronous
        // segment on this actor: no await between the read and the write, so
        // a delivery's `sending` row can never be overwritten by a stale copy.
        guard var ledger = ReachLedger.read(dataRoot) else { return }
        projectReachDeadline(timing: timing, ledger: ledger, candidates: [])
        var changed = false
        // An offer still waiting for her wake whose moment has passed (he came
        // back, quiet hours began) is taken back before it costs a turn.
        if Reach.momentPassed(timing), let index = ledger.offers.lastIndex(where: { $0.outcome == "offered" }),
           ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "reach") {
            ledger.offers[index].outcome = "withheld"
            changed = true
        }
        if changed { ledger.write(dataRoot) }
        await landReachAnswers(ledger)
        guard Reach.timing(timing, ledger: ledger) == .offer else { return }
        if let last = sourceWakes.reachLastScanAt, instant.timeIntervalSince(last) < Reach.scanInterval {
            sourceWakes.reachNextAt = last.addingTimeInterval(Reach.scanInterval)
            return
        }
        sourceWakes.reachLastScanAt = instant
        timing = await reachTiming(at: instant, withClaude: true)
        let rejected = await substrate.associationSuppressionSnapshot().map(\.source)
        let candidates = await reachCandidates(at: instant)
        projectReachDeadline(timing: timing, ledger: ledger, candidates: candidates)
        guard candidates.contains(where: {
            Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected) == .offer
        }) else { return }
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        // Fresh read, decided and written in one segment.
        guard let fresh = ReachLedger.read(dataRoot) else { return }
        ledger = fresh
        guard let pick = candidates.first(where: {
            Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected) == .offer
        }) else { return }
        let offer = ReachLedger.Offer(
            id: "reach:" + UUID().uuidString.lowercased(), subject: pick.subject, kind: pick.kind.name,
            source: pick.source, why: pick.why, offeredAt: instant, outcome: "offered", at: pick.at)
        ledger.offers.append(offer)
        guard ledger.write(dataRoot) else { return }
        // Keyed "reach": a newer offer would replace a pending one.
        ResidentWake.shared.request(dataRoot: dataRoot, reason: "something worth sharing", items: [.init(
            id: offer.id, line: Reach.wakeLine(pick, person: Self.resolvedPerson(dataRoot: dataRoot)),
            key: "reach", thread: "reach", at: instant)])
        await substrate.recordReceipt(kind: "reach.offered", payload: .object([
            "id": .string(offer.id), "subject": .string(pick.subject), "kind": .string(pick.kind.name),
            "source": .string(pick.source), "why": .string(pick.why),
            "counters": .object(ledger.counters(lastUserTurn: timing.lastUserTurn, now: instant)),
        ]))
    }

    /// Reconcile uncertain offers without another attempt to speak.
    private func reconcileReachDeliveries() async {
        guard let snapshot = ReachLedger.read(dataRoot) else { return }
        for offer in snapshot.offers where offer.outcome == "sending" {
            guard let session = offer.session else { continue }
            do {
                // Positive evidence is safe even while a delivery is in flight.
                // Absence here cannot prove it will not append after this read.
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

    /// Each settled answer lands once in its care. A failed care save is
    /// retried from the offer's source identity, without another movement.
    private func landReachAnswers(_ ledger: ReachLedger) async {
        let person = Self.resolvedPerson(dataRoot: dataRoot)
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
        // One segment: these rows only, on a fresh read.
        guard !landed.isEmpty, var fresh = ReachLedger.read(dataRoot) else { return }
        for index in fresh.offers.indices where landed.contains(fresh.offers[index].id) {
            fresh.offers[index].landed = true
        }
        fresh.write(dataRoot)
    }

    private func projectReachDeadline(timing: Reach.Timing, ledger: ReachLedger, candidates: [ReachCandidate]) {
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
        let pending = ledger.offers.contains { $0.outcome == "offered" || ($0.outcome == "sent" && $0.sentAt.map { $0.addingTimeInterval(Reach.answerWindow) >= at } == true) }
        let current = relevant.contains { $0.at <= at } || plans.contains { $0 <= at }
        if pending || current {
            if let last = timing.lastUserTurn { boundaries.append(last.addingTimeInterval(Reach.activeWindow)) }
            if let last = timing.lastClaude { boundaries.append(last.addingTimeInterval(Reach.activeWindow)) }
            if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: at)) { boundaries.append(nextDay) }
            if let quiet = TurnQuietHoursWindow.read(dataRoot: dataRoot) {
                for hour in [quiet.startHour, quiet.endHour] {
                    if let next = Calendar.current.nextDate(after: at, matching: DateComponents(hour: hour, minute: 0, second: 0), matchingPolicy: .nextTime) { boundaries.append(next) }
                }
            }
        }
        // A timing gate can defer the candidate read itself. Its eligibility
        // boundary must survive even when no candidates have been read yet.
        let timingBoundary: Date? = switch Reach.timing(timing, ledger: ledger) {
        case .quietHours:
            TurnQuietHoursWindow.read(dataRoot: dataRoot)?.end(after: at)
        case .userActive:
            timing.lastUserTurn?.addingTimeInterval(Reach.activeWindow)
        case .withClaude:
            timing.lastClaude?.addingTimeInterval(Reach.activeWindow)
        case .dailyCap:
            timing.calendar.date(byAdding: .day, value: 1, to: timing.calendar.startOfDay(for: at))
        case .spacing:
            ledger.offers.filter(\.mayHaveReachedHim).compactMap(\.sentAt).max()?.addingTimeInterval(Reach.minimumSpacing)
        case .offer, .awaitingUser, .subjectCooldown, .alreadySeen, .rejected, .stale:
            nil
        }
        let sourceBoundary = (pending || !relevant.isEmpty || !plans.isEmpty)
            ? boundaries.filter { $0 > at }.min() : nil
        sourceWakes.reachNextAt = [sourceBoundary, timingBoundary].compactMap { $0 }.filter { $0 > at }.min()
    }

    /// Her wake answered. A pass, or a gate that no longer holds, sends
    /// nothing; otherwise her words go to his conversation, then one knock
    /// (or his Telegram DM, with no knock).
    public func deliverReach(
        reply: String, itemID: String, turnID: String, chat: SwiftNativeChatOrchestrationClient
    ) async {
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let instant = now()
        let timing = await reachTiming(at: instant, withClaude: true)
        let rejected = await substrate.associationSuppressionSnapshot().map(\.source)
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot)
        // One segment: every gate again on delivery time, then a durable
        // `sending` row BEFORE anything can reach him. A crash after delivery
        // leaves that row, which pacing holds back for, so the no-reply gate
        // can never reopen on a message he may have.
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
            var destination = anchor
            do {
                switch try await chat.speakProactively(
                    content: text, caller: .reachOut,
                    idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: itemID, content: text),
                    sessionId: anchor, initiative: .scheduled) {
                case .posted:
                    outcome = "sent"
                    // Her words are in his conversation; one phone knock opens it with Reply.
                    if reachEnabled {
                        knocked = (try? await host.deliverShoulderTap(
                            eventId: itemID, title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                            body: Reach.knockLine, reason: itemID,
                            userInfo: ["screen": "chat", "source": "reach_out", "sessionId": anchor], at: instant)) != nil
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
                // An older claim has no established destination. Neither a
                // duplicate claim nor its failed reconciliation proves absence.
                nativeLog("reach: claimed delivery still has no established destination")
            } catch {
                // The append has ended. Only the speech owner's clean scan can
                // establish non-delivery; an unreadable transcript stays open.
                nativeLog("reach: delivery needs reconciliation: %@", error.localizedDescription)
                do {
                    outcome = try await SwiftNativeChatOrchestrationClient.proactiveSpeechCommitted(
                        dataRoot: dataRoot, caller: .reachOut, idempotencyScope: itemID, sessionId: anchor)
                        ? "sent" : "withheld"
                } catch {
                    nativeLog("reach: delivery still uncertain: %@", error.localizedDescription)
                }
            }
            // One segment again: patch this row only, on a fresh read. An
            // unreadable ledger leaves the row `sending`: uncertain, not sent.
            if let fresh = ReachLedger.read(dataRoot), let row = fresh.offers.firstIndex(where: { $0.id == itemID }) {
                ledger = fresh
                if ledger.offers[row].isSent { outcome = "sent" }
                ledger.offers[row].outcome = outcome
                ledger.offers[row].session = destination
                ledger.offers[row].knocked = knocked
                if outcome == "withheld" { ledger.offers[row].sentAt = nil }
                ledger.write(dataRoot)
                offer = ledger.offers[row]
            }
        }
        // mind.why: why she reached out (or did not), on the turn that wrote it.
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnID, kind: "mind.why", sessionId: offer.session ?? ResidentWake.session, surface: "chat",
            payload: .object([
                "lane": .string("outreach"), "outcome": .string(offer.outcome),
                "subject": .string(offer.subject), "kind": .string(offer.kind),
                "source": .string(offer.source), "why": .string(offer.why),
                "detail": .string("mind.reject with this subject as source stops it."),
            ])))
        await substrate.recordReceipt(kind: "reach.\(offer.outcome)", payload: .object([
            "id": .string(offer.id), "subject": .string(offer.subject),
            "knocked": .bool(offer.knocked == true),
        ]))
    }

    nonisolated static func resolvedPerson(dataRoot: URL) -> String {
        let name = resolveUserName(dataRoot: dataRoot)
        return name.isEmpty ? "the person" : name
    }

    // MARK: - Candidates (on device, from state she already has)

    func reachCandidates(at instant: Date) async -> [ReachCandidate] {
        var out: [ReachCandidate] = []
        let person = Self.resolvedPerson(dataRoot: dataRoot)

        // The open care pressing hardest, held with him or hers alone: what
        // she would bring up if they were talking. It happened when it last moved.
        if let top = await substrate.caresPressing(for: CognitiveCare.ownerKey, at: instant)
            .first(where: { $0.care.open != nil }),
           top.pressure >= CognitiveSubstrate.careReleasePressure,
           let open = top.care.open, let newest = top.care.story.last {
            out.append(ReachCandidate(
                kind: .care, subject: "care:\(top.care.id.uuidString)", source: "something on your mind",
                why: newest.note,
                text: "\"\(Self.clipped(top.care.about, 120))\", still wondering: \(Self.clipped(open, 200))",
                at: newest.at))
        }

        // A plan of his on the Desk that just came due (parked until a day,
        // within the last day). Items he asked to be pinged about already are.
        if let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() {
            for item in state.items where item.origin == .owner && item.status != .done && item.status != .canceled
                && item.notify.level != .direct && item.notify.level != .urgent {
                // A peer-steered item's words are the peer's: skipped.
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

        // Outreach offers only what it read; an unreadable record offers nothing.
        let builders = Self.builderNews(dataRoot: dataRoot, unseenOnly: true).builders
        for builder in builders where PeerTrust.ownerTrusts(builder.lane, dataRoot: dataRoot) {
            guard let newest = builder.shipped.filter({ $0.1.count >= 6 }).max(by: { $0.0 < $1.0 }) else { continue }
            out.append(ReachCandidate(
                kind: .shipped, subject: "ship:\(builder.lane):\(Reach.digest(newest.1))", source: "\(builder.name)'s record of its work",
                why: AgentConversationDelivery.door(for: builder.lane, dataRoot: dataRoot)?.liveReader == true
                    ? "\(builder.name) shipped it during \(person)'s quiet hours, so he likely hasn't seen it; you could make it short and human"
                    : "\(builder.name) works on its own, so \(person) may not have seen it; you could make it short and human",
                text: "\(builder.name) shipped \"\(newest.1)\"", at: newest.0))
        }

        // A dream association, only about him and gentle, marked as a dream.
        if let diary = try? Self.livingDiary(dataRoot: dataRoot, now: instant),
           let markdown = try? String(contentsOf: diary.url, encoding: .utf8) {
            for claim in DreamClaim.read(in: markdown)
            where claim.gentle == true && claim.aboutOwner == true {
                out.append(ReachCandidate(
                    kind: .dream, subject: "dream:\(diary.name)#\(Reach.digest(claim.provenance.quote))", source: "last night's dream diary",
                    why: "it was about \(person), and gentle; a dream association, not something that happened",
                    text: "\"\(Self.clipped(claim.provenance.quote, 160))\"", at: diary.written))
            }
        }

        return out.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : $0.at > $1.at }
    }
}
