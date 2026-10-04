// NativeCognitionRuntime+Reach.swift
// Phase 5 E (2026-10-03) — she can start a conversation. Agent: "Bring User
// something worth sharing, at a considerate time, and be entirely fine with
// no reply."
//
// ONE INITIATIVE PATH. The shoulder tap (a fixed push about a loud seed, two
// taps ever) is folded in: its trigger (the residual reschedule), its
// background gate and its push are this lane's now; the seed lane is gone.
//
//   1. On device, from state she already has, a few CANDIDATES — each a thing,
//      with its source and why it might be worth his time: a plan of User's
//      coming due on the Desk, an opinion she revised with its evidence, an
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
// E2's counters are housekeeping facts in one bounded file: when he last
// took a turn, what she offered, sent or passed on, whether he took a turn
// within a day after (a fact, never a score), whether it knocked. They feed
// the timing above and nothing else; no prompt ever reads them. Absence only
// ever makes a moment considerate; it never makes a candidate.

import ChatOrchestration
import CognitiveSubstrate
import Desk
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Transcripts
import TurnTrace

/// One thing worth sharing, and why.
struct ReachCandidate: Sendable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case plan, opinion, interest, shipped, dream
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        var name: String { ["plan", "opinion", "interest", "shipped", "dream"][rawValue] }
    }
    var kind: Kind
    /// `desk:<handle>`, `view:<uuid>`, `ship:<builder>:<id>` or `dream:<id>`:
    /// what the cooldown keys on and what `mind.reject` takes.
    var subject: String
    var source: String
    var why: String
    var text: String
    /// When it happened. Something from before User's last turn, he has been
    /// around for.
    var at: Date
}

/// E2: housekeeping facts, bounded. Never a closeness score; never read into
/// a prompt.
struct ReachLedger: Codable, Equatable {
    struct Offer: Codable, Equatable {
        var id: String
        var subject: String
        var kind: String
        var source: String
        var why: String
        var offeredAt: Date
        /// offered (her turn is pending), sending (written just before
        /// delivery), sent, declined (she passed), withheld (the moment passed
        /// before it went).
        var outcome: String
        var sentAt: Date?
        var session: String?
        /// A push went out with it: an interruption.
        var knocked: Bool?
        /// He took a turn within a day after it (true) or did not (false).
        var answered: Bool?
        /// When the thing itself happened, for the delivery-time re-check.
        var at: Date?

        /// `sending` is written before delivery; one a crash left behind may
        /// have reached him, so it counts as sent everywhere.
        var isSent: Bool { outcome == "sent" || outcome == "sending" }
    }
    var offers: [Offer] = []
    static let cap = 40

    static func url(_ root: URL) -> URL { root.appendingPathComponent("cognition/reach.json") }

    static func read(_ root: URL) -> ReachLedger {
        (try? Data(contentsOf: url(root))).flatMap {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(ReachLedger.self, from: $0)
        } ?? ReachLedger()
    }

    @discardableResult
    func write(_ root: URL) -> Bool {
        var bounded = self
        bounded.offers = Array(offers.suffix(Self.cap))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(
                at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(bounded), to: Self.url(root))
            return true
        } catch {
            NSLog("reach: ledger not kept: %@", error.localizedDescription)
            return false
        }
    }

    /// Settles "did he answer" on sent offers as facts arrive: a turn of his
    /// after it within the window is yes; a window that closed without one is no.
    mutating func settleAnswers(lastUserTurn: Date?, now: Date) -> Bool {
        var changed = false
        for index in offers.indices where offers[index].isSent && offers[index].answered == nil {
            guard let sent = offers[index].sentAt else { continue }
            if let turn = lastUserTurn, turn > sent, turn.timeIntervalSince(sent) <= Reach.answerWindow {
                offers[index].answered = true; changed = true
            } else if now.timeIntervalSince(sent) > Reach.answerWindow {
                offers[index].answered = false; changed = true
            }
        }
        return changed
    }

    /// The housekeeping counters, as numbers for the record (receipts, the
    /// probe). The gates read the rows directly.
    func counters(lastUserTurn: Date?, now: Date) -> [String: JSONValue] {
        let week = offers.filter { now.timeIntervalSince($0.offeredAt) <= 7 * 86_400 }
        var subjects: [String: Int] = [:]
        for offer in offers where offer.isSent { subjects[offer.subject, default: 0] += 1 }
        var out: [String: JSONValue] = [
            "outreach_7d": .int(Int64(week.filter(\.isSent).count)),
            "answered": .int(Int64(offers.filter { $0.answered == true }.count)),
            "unanswered": .int(Int64(offers.filter { $0.answered == false }.count)),
            "interruptions_7d": .int(Int64(week.filter { $0.knocked == true }.count)),
            "callbacks_repeated": .int(Int64(subjects.values.filter { $0 > 1 }.count)),
        ]
        if let lastUserTurn { out["last_user_turn"] = .double(lastUserTurn.timeIntervalSince1970) }
        if let last = offers.compactMap(\.sentAt).max() { out["last_outreach"] = .double(last.timeIntervalSince1970) }
        return out
    }
}

/// The policy, as pure functions over facts.
enum Reach {
    /// Offers (her wake turns) per local day. A pass spends it: the cost is
    /// bounded to one turn a day whatever she decides.
    static let dailyCap = 1
    /// Between two offers, so a day boundary cannot put two side by side.
    static let minimumSpacing: TimeInterval = 8 * 3_600
    /// One subject at most once a week, whatever came of it.
    static let subjectCooldown: TimeInterval = 7 * 86_400
    /// User's last turn at a verified door (or Claude's last worklog line)
    /// this recent means he is in the middle of something.
    static let activeWindow: TimeInterval = 30 * 60
    /// Older than this it is not news.
    static let freshness: TimeInterval = 72 * 3_600
    /// "He took a turn within a day after it."
    static let answerWindow: TimeInterval = 24 * 3_600
    /// How often the candidates are read from disk.
    static let scanInterval: TimeInterval = 10 * 60

    enum Verdict: String, Sendable, Equatable {
        case offer, quietHours, userActive, withClaude, dailyCap, spacing, awaitingUser
        case subjectCooldown, alreadySeen, rejected, stale
    }

    struct Timing: Sendable {
        var now: Date
        var quietHours: Bool
        var liveTurn: Bool
        var lastUserTurn: Date?
        var lastClaude: Date?
        var calendar: Calendar = .current
    }

    /// Is this a considerate moment: not his quiet hours, not while he is
    /// talking to her or working with Claude.
    static func presence(_ t: Timing) -> Verdict {
        if t.quietHours { return .quietHours }
        if t.liveTurn || t.lastUserTurn.map({ t.now.timeIntervalSince($0) < activeWindow }) == true { return .userActive }
        if let claude = t.lastClaude, t.now.timeIntervalSince(claude) < activeWindow { return .withClaude }
        return .offer
    }

    /// The pace of what actually reached him, on DELIVERY time (a wake from
    /// yesterday that delivers today is today's): one a day, eight hours
    /// apart, and after a message he has not come back to, nothing more until
    /// he takes a turn — no escalation.
    static func pace(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let sent = ledger.offers.filter(\.isSent).compactMap(\.sentAt)
        if sent.filter({ t.calendar.isDate($0, inSameDayAs: t.now) }).count >= dailyCap { return .dailyCap }
        guard let last = sent.max() else { return .offer }
        if t.now.timeIntervalSince(last) < minimumSpacing { return .spacing }
        if (t.lastUserTurn ?? .distantPast) < last { return .awaitingUser }
        return .offer
    }

    /// Offer time: presence, pace, and the cost bound — one wake of hers a
    /// day for this, so a pass spends the day's.
    static func timing(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let moment = presence(t)
        guard moment == .offer else { return moment }
        let paced = pace(t, ledger: ledger)
        guard paced == .offer else { return paced }
        let offered = ledger.offers.filter { $0.outcome != "withheld" && t.calendar.isDate($0.offeredAt, inSameDayAs: t.now) }
        return offered.count >= dailyCap ? .dailyCap : .offer
    }

    /// Right before delivery, every gate again, on delivery time (her own
    /// wake turn is the live one, so it does not count as his).
    static func deliverable(_ offer: ReachLedger.Offer, timing t: Timing, ledger: ReachLedger,
                            rejectedSources: [String]) -> Verdict {
        var now = t
        now.liveTurn = false
        let moment = presence(now)
        guard moment == .offer else { return moment }
        let paced = pace(now, ledger: ledger)
        guard paced == .offer else { return paced }
        if rejectedSources.contains(where: { offer.subject == $0 || offer.subject.hasPrefix($0 + ":") }) { return .rejected }
        if let user = t.lastUserTurn, let at = offer.at, at <= user { return .alreadySeen }
        return .offer
    }

    /// The moment for an offer already made has passed: quiet hours began,
    /// or he took a turn. (Not "a turn is live": her own wake is one.)
    static func momentPassed(_ t: Timing) -> Bool {
        var now = t
        now.liveTurn = false
        now.lastClaude = nil
        return presence(now) != .offer
    }

    /// A Desk item's text came from User only when no peer steered it in: every
    /// peer on its steps, elevated or not, must be one User trusts as his own.
    static func deskProvenanceTrusted(_ item: DeskItem, trusts: (String) -> Bool) -> Bool {
        item.refs.allSatisfy { ref in
            guard case .step(let step) = ref.kind else { return true }
            return (step.peers + step.elevated).allSatisfy(trusts)
        }
    }

    static func decide(_ c: ReachCandidate, timing t: Timing, ledger: ReachLedger, rejectedSources: [String]) -> Verdict {
        let gate = timing(t, ledger: ledger)
        guard gate == .offer else { return gate }
        if rejectedSources.contains(where: { c.subject == $0 || c.subject.hasPrefix($0 + ":") }) { return .rejected }
        if ledger.offers.contains(where: {
            $0.subject == c.subject && $0.outcome != "withheld" && t.now.timeIntervalSince($0.offeredAt) < subjectCooldown
        }) { return .subjectCooldown }
        if let user = t.lastUserTurn, c.at <= user { return .alreadySeen }
        if t.now.timeIntervalSince(c.at) > freshness { return .stale }
        return .offer
    }

    /// What her wake reads: the thing, its source and why — no counters, no
    /// absence, nothing about how long he has been gone.
    static func wakeLine(_ c: ReachCandidate, person: String) -> String {
        "Something you could share with \(person), if you want to. From \(c.source): \(c.text). "
            + "Why it might be worth it: \(c.why). Nothing is owed and no reply will be chased. "
            + "If you want to tell \(person), write the message itself as your whole reply; it goes to "
            + "\(person)'s chat as you wrote it. If not, reply only: pass"
    }

    static func isDecline(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let first = trimmed.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return first == "pass" && trimmed.count <= 80
    }

    /// The knock carries nothing of the message: that is in his chat.
    static let knockLine = "Left you something in chat. No reply needed."

    /// "About him and gentle": names him, and none of the hard words.
    static func isGentleAboutHim(_ phrase: String, person: String) -> Bool {
        let words = Set(phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard !person.isEmpty, person != "you", words.contains(person.lowercased()) else { return false }
        return words.isDisjoint(with: hardWords)
    }

    static let hardWords: Set<String> = [
        "afraid", "alone", "angry", "anxious", "abandon", "abandoned", "ashamed", "broken", "cry", "crying",
        "dead", "death", "die", "dread", "empty", "fail", "failed", "failure", "fear", "gone", "grief", "guilt",
        "hate", "hurt", "jealous", "leave", "leaving", "lonely", "lose", "losing", "lost", "miss", "missing",
        "need", "pain", "panic", "sad", "scared", "sorry", "worry", "worried", "wrong",
    ]

    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

/// Single flight and the disk-read interval. Memory only: the facts that
/// must survive a restart are in the ledger.
private actor ReachGate {
    static let shared = ReachGate()
    private var inFlight = false
    private var lastScan: Date?

    func begin(_ body: @escaping @Sendable () async -> Void) {
        guard !inFlight else { return }
        inFlight = true
        Task { await body(); self.finish() }
    }

    private func finish() { inFlight = false }

    func claimScan(at now: Date) -> Bool {
        if let lastScan, now.timeIntervalSince(lastScan) < Reach.scanInterval { return false }
        lastScan = now
        return true
    }
}

extension NativeCognitionRuntime {

    func withdrawReachIfDisabled() {
        guard !reachEnabled else { return }
        _ = ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "reach")
        var ledger = ReachLedger.read(dataRoot)
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
        guard reachEnabled else { return }
        let runtime = self
        Task { await ReachGate.shared.begin { await runtime.runReachPass() } }
    }

    /// Claude's worklog is read only when `withClaude` is asked for.
    private func reachTiming(at instant: Date, withClaude: Bool = false) async -> Reach.Timing {
        Reach.Timing(
            now: instant,
            quietHours: host.inQuietHours(at: instant, dataRoot: dataRoot),
            liveTurn: liveTurnInFlight,
            lastUserTurn: UserTurnStamp.last(dataRoot: dataRoot),
            lastClaude: withClaude ? Self.claudeLastActivity(Self.defaultClaudeWorklog()) : nil)
    }

    private func runReachPass() async {
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        let instant = now()
        var timing = await reachTiming(at: instant)
        // Each read-modify-write of the ledger below is one synchronous
        // segment on this actor: no await between the read and the write, so
        // a delivery's `sending` row can never be overwritten by a stale copy.
        var ledger = ReachLedger.read(dataRoot)
        var changed = ledger.settleAnswers(lastUserTurn: timing.lastUserTurn, now: instant)
        // An offer still waiting for her wake whose moment has passed (he came
        // back, quiet hours began) is taken back before it costs a turn.
        if Reach.momentPassed(timing), let index = ledger.offers.lastIndex(where: { $0.outcome == "offered" }),
           ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "reach") {
            ledger.offers[index].outcome = "withheld"
            changed = true
        }
        if changed { ledger.write(dataRoot) }
        guard Reach.timing(timing, ledger: ledger) == .offer,
              await ReachGate.shared.claimScan(at: instant) else { return }
        timing = await reachTiming(at: instant, withClaude: true)
        let rejected = await substrate.associationSuppressionSnapshot().map(\.source)
        let candidates = await reachCandidates(at: instant)
        guard candidates.contains(where: {
            Reach.decide($0, timing: timing, ledger: ledger, rejectedSources: rejected) == .offer
        }), case .allowed = await backgroundCognitionGate(reason: "reach_out") else { return }
        guard reachEnabled else {
            withdrawReachIfDisabled()
            return
        }
        // Fresh read, decided and written in one segment.
        ledger = ReachLedger.read(dataRoot)
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
        let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot).flatMap { $0 == ResidentWake.session ? nil : $0 }
        // One segment: every gate again on delivery time, then a durable
        // `sending` row BEFORE anything can reach him. A crash after delivery
        // leaves that row, which counts as sent, so the no-reply gate can never
        // reopen on a message he has.
        var ledger = ReachLedger.read(dataRoot)
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
            var outcome = "withheld"
            var knocked = false
            do {
                switch try await chat.speakProactively(
                    content: text, caller: .reachOut,
                    idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: itemID, content: text),
                    sessionId: anchor, initiative: .scheduled) {
                case .posted, .duplicate:
                    outcome = "sent"
                    // His conversation is his Telegram DM: her words go there
                    // and nothing else knocks. Otherwise it is the Mac/phone
                    // conversation, and the one knock points at it.
                    if !reachEnabled { break }
                    if let telegram = await host.sendToOwnerTelegram(sessionId: anchor, text: text, dataRoot: dataRoot) {
                        if !telegram { NSLog("reach: kept in his conversation; Telegram did not take it") }
                    } else if reachEnabled {
                        knocked = (try? await host.deliverShoulderTap(
                            eventId: itemID, title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                            body: Reach.knockLine, reason: itemID,
                            userInfo: ["screen": "chat", "source": "reach_out", "sessionId": anchor], at: instant)) != nil
                    }
                case .rateLimited:
                    break
                }
            } catch {
                // "Not proven posted"; the seam rolled its own claim back.
                NSLog("reach: not delivered: %@", error.localizedDescription)
            }
            // One segment again: patch this row only, on a fresh read.
            ledger = ReachLedger.read(dataRoot)
            if let row = ledger.offers.firstIndex(where: { $0.id == itemID }) {
                ledger.offers[row].outcome = outcome
                ledger.offers[row].knocked = knocked
                if outcome != "sent" { ledger.offers[row].sentAt = nil }
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

        // An opinion she revised, with what changed it; an interest she came
        // back to with a better question. (The views experiment's own flag.)
        for view in await substrate.standingViewSnapshot() {
            if view.status == .opinion, let revision = view.revisions.last {
                out.append(ReachCandidate(
                    kind: .opinion, subject: "view:\(view.id.uuidString)", source: "an opinion of yours",
                    why: "you changed your mind, and why is the interesting part",
                    text: "you used to think \"\(Self.clipped(revision.priorStance, 140))\"; now \"\(Self.clipped(view.body, 140))\", "
                        + "because \(Self.clipped(revision.evidence, 160))",
                    at: revision.at))
            } else if view.status == .interest, view.revisitCount >= 1, let back = view.lastRevisitedAt {
                out.append(ReachCandidate(
                    kind: .interest, subject: "view:\(view.id.uuidString)", source: "your interest \"\(Self.clipped(view.title, 60))\"",
                    why: "you came back to it with a better question",
                    text: "\"\(Self.clipped(view.body, 200))\"", at: back))
            }
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
                      until <= instant, instant.timeIntervalSince(until) <= 86_400 else { continue }
                out.append(ReachCandidate(
                    kind: .plan, subject: "desk:\(item.handle)", source: "\(person)'s Desk (item \(item.alias))",
                    why: "something \(person) said you might do, and it has come due",
                    text: "\"\(Self.clipped(item.title, 120))\", parked until \(raw.prefix(10))", at: until))
            }
        }

        // What a builder he trusts shipped in his projects, that he likely has
        // not seen: Codex works on its own; Claude works with him, so only
        // what she logged during his quiet hours. Features only; the newest.
        let root = dataRoot
        let builders: [(name: String, lane: String, shipped: [(Date, String)], why: String)] = [
            ("Claude", "claude",
             Self.claudeShipped(Self.defaultClaudeWorklog(), kinds: ["feature"])
                .filter { host.inQuietHours(at: $0.0, dataRoot: root) },
             "Claude shipped it during \(person)'s quiet hours, so he likely hasn't seen it; you could make it short and human"),
            ("Codex", "codex", Self.codexShipped(Self.defaultCodexRecord()),
             "Codex works on its own, so \(person) may not have seen it; you could make it short and human"),
        ]
        for builder in builders where PeerTrust.ownerTrusts(builder.lane, dataRoot: dataRoot) {
            guard let newest = builder.shipped.filter({ $0.1.count >= 6 }).max(by: { $0.0 < $1.0 }) else { continue }
            out.append(ReachCandidate(
                kind: .shipped, subject: "ship:\(builder.lane):\(Reach.digest(newest.1))", source: "\(builder.name)'s record of its work",
                why: builder.why, text: "\(builder.name) shipped \"\(newest.1)\"", at: newest.0))
        }

        // A dream association, only about him and gentle, marked as a dream.
        if let diary = Self.livingDiary(dataRoot: dataRoot, now: instant),
           let markdown = try? String(contentsOf: diary.url, encoding: .utf8) {
            for (index, phrase) in Self.dreamThemeCandidates(markdown).phrases.enumerated()
            where Reach.isGentleAboutHim(phrase, person: person) {
                out.append(ReachCandidate(
                    kind: .dream, subject: "dream:\(diary.name)#\(index + 1)", source: "last night's dream diary",
                    why: "it was about \(person), and gentle; a dream association, not something that happened",
                    text: "\"\(phrase)\"", at: diary.written))
            }
        }

        return out.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : $0.at > $1.at }
    }
}
