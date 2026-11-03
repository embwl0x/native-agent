import Foundation
import Desk
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `HarnessQueue.swift` | `HarnessQueue` enum, `HarnessFinding` struct; `file`, `resolve`, `fold`: keyed findings refresh in place, preserving closure and person ownership; carried lines name their desk.N and the queue.done call; carry offers and direct intention speech share the wake ledger's retained material fingerprint, including IntentionClock occurrence identities (civil for migrated calendar work) and person transition times; prompt moments bypass free-time quiet, and system notes name experience/news/body-signal releases |

/// One finding, with one Desk identity and the person who can tend it.
public struct HarnessFinding: Sendable, Equatable {
    public enum Owner: String, Sendable { case agent, builder, owner }
    public enum Source: String, Sendable { case doctor, sweep, loop, bridge, agent }

    /// Stable across repeats: the Doctor check id or the sweep's finding id.
    public var key: String
    public var title: String
    public var summary: String
    public var owner: Owner
    /// The trace, approval, file or check it came from.
    public var refs: [DeskRef]
    public var source: Source

    public init(key: String, title: String, summary: String, owner: Owner, refs: [DeskRef], source: Source) {
        self.key = key; self.title = title; self.summary = summary
        self.owner = owner; self.refs = refs; self.source = source
    }
}

extension ResidentWake {
    package struct CarriedSettlement: Codable, Sendable, Equatable {
        package let id: String
        package let lifeID: String
        package let item: JSONValue
        package let fingerprint: String
        package let notes: [String]
        package let reason: String
    }

    package static func owedCarriedSettlements(dataRoot: URL) throws -> [CarriedSettlement] {
        let life = try DataRootLife.current(in: dataRoot)
        return try checkedRead(dataRoot).carriedSettlements?.filter { $0.lifeID == life } ?? []
    }

    package func settleCarried(_ debt: CarriedSettlement, dataRoot: URL) throws {
        guard kept(dataRoot, { ledger in
            ledger.carriedSettlements?.removeAll { $0.id == debt.id }
        })?.saved == true else {
            throw PersistenceCoreError.ioFailure("The intention's completed settlement could not be saved.")
        }
    }
    package static func carriedArrival(_ item: DeskItem, crossing: Date, dataRoot: URL) -> Item {
        let key = "carry." + item.handle
        let step = item.step
        let peers = (step?.peers ?? []).filter { !CapabilityLifecycle.ownerTrusts($0) }
        let provenance = peers.isEmpty ? "" : " Peer steering retained: " + peers.joined(separator: ", ")
            + ". The answer covers this turn and its carried steps, without permanently trusting the peer."
        // What released it since she last wrote on it (a condition, news or body signal).
        let released = MyQueue.entry(item).map { MyQueue.releaseNotes(for: $0).map { $0.text + " " }.joined() } ?? ""
        let words = item.summary ?? step?.words ?? item.title
        // Its name rides with it, so what she is shown she can finish.
        let name = "desk." + item.alias
        let done = "app {action:\"queue.done\", args:{id:\"\(name)\"}}"
        let wait = "desk.wait {handle:\"\(name)\", on: <the card, message or debt id it needs>}: you are woken when that settles, not before."
        var line: String
        if let step, step.rhythm != nil {
            // A rhythm is never done by one occurrence: it comes back at its next time.
            let next = IntentionClock.next(step, after: crossing).map { " It comes back " + Self.shown($0) + "." } ?? " This is its last time."
            line = "You meant to, now (" + Self.shown(IntentionClock.occurrence(step, at: crossing) ?? crossing) + "): \(words) (\(name))." + next
                + " Keep it open unless it is finished for good; then \(done)."
        } else if step != nil {
            line = "You meant to (\(name)): \(words). Do what you judge right. Once it is done, \(done); if it can't move yet, say what it waits on with \(wait)"
        } else {
            line = "Yours to carry, \(name): \(item.title) — \(words). Do what you judge right. Close it with desk.close {handle:\"\(name)\"} only once it is actually done. If it can't move yet, say what it waits on with \(wait)"
        }
        switch step.map({ MyQueue.Until($0.until) }) ?? .once {
        case .words(let until): line += " It is done when: \(until). Once it is, \(done)."
        case .time(let ends): line += " It ends by itself " + Self.shown(ends) + "."
        case .once, .standing: break
        }
        if let say = step?.say { line += " Say this as it is, nothing added: \"\(say)\"" }
        var arrival = Item(id: key + "." + String(crossing.timeIntervalSince1970),
            line: released + line + provenance,
            key: key, thread: key,
            at: crossing, session: step?.session,
            filedAt: step.map { $0.filedAt ?? item.openedAt }, materialFingerprint: carriedFingerprint(item, at: crossing, dataRoot: dataRoot))
        arrival.clock = step.flatMap { MyQueue.When($0.when, card: $0.card)?.isPrompt } ?? false
        return arrival
    }

    /// A time as she reads it on the Mac's clock ("Thu 16:00").
    package static func shown(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = Calendar.current.isDate(date, inSameDayAs: Date()) ? "'at' HH:mm" : "EEE MMM d 'at' HH:mm"
        return format.string(from: date)
    }

    /// What an offer of carried work is measured from: the item's material state
    /// and the step it queues (refiling it is a change), never notes or stamps.
    /// A rhythm's occurrence or a person's transition is material: each one is a new offer.
    package static func carriedFingerprint(_ item: DeskItem, at now: Date, dataRoot: URL) -> String {
        let step = item.step.map { step -> [String] in
            var fields: [String] = [step.words, step.when, step.card ?? "", step.actionText ?? "", step.session ?? "", step.filedAt ?? ""]
                + (step.rhythm == nil ? [] : [IntentionClock.occurrenceID(step, at: now) ?? ""])
            switch MyQueue.When(step.when, card: step.card) {
            case .userHere?, .userAway?:
                fields.append(PersonPresence.read(dataRoot: dataRoot, now: now).transition.map { String($0.since.timeIntervalSince1970) } ?? "")
            case .news?, .signal?:
                // Each release is its own occurrence: a second release must run its habit again.
                fields.append(MyQueue.entry(item).flatMap { MyQueue.releaseNotes(for: $0).map(\.ts).max() } ?? "")
            default: break
            }
            return fields
        } ?? []
        return ([DeskObservationEvaluator.materialFingerprint(item)] + step).joined(separator: "\u{1F}")
    }

    /// Her habit finished or fixed words reached the transcript without a wake. Retain the
    /// same accepted carry record a delivered turn leaves, without spending a
    /// wake or a thread hop. Notes alone do not consume a clock occurrence.
    package func recordCarriedDelivery(_ item: DeskItem, dataRoot: URL, at now: Date,
                                      reason: String = "said", notes: [String]) throws -> CarriedSettlement {
        var delivered = Self.carriedArrival(item, crossing: now, dataRoot: dataRoot)
        let life = try DataRootLife.current(in: dataRoot)
        delivered.lifeID = life
        delivered.acceptedAt = now
        delivered.reason = reason
        let debt = CarriedSettlement(id: UUID().uuidString, lifeID: life, item: item.toJSON(),
            fingerprint: Self.carriedFingerprint(item, at: now, dataRoot: dataRoot), notes: notes, reason: reason)
        guard let saved = kept(dataRoot, { ledger -> CarriedSettlement in
            if let existing = ledger.carriedSettlements?.first(where: {
                $0.lifeID == debt.lifeID && $0.item.objectValue?["handle"] == debt.item.objectValue?["handle"]
                    && $0.fingerprint == debt.fingerprint
            }) { return existing }
            ledger.pending.removeAll { $0.key == delivered.key && $0.materialFingerprint == delivered.materialFingerprint }
            ledger.recent.removeAll { $0.key == delivered.key && $0.acceptedAt != nil && $0.at <= now }
            ledger.recent.append(delivered)
            ledger.carriedSettlements = (ledger.carriedSettlements ?? []) + [debt]
            return debt
        }), saved.saved else {
            throw PersistenceCoreError.ioFailure("The intention's delivered occurrence could not be saved.")
        }
        return saved.result
    }

    package static func carriedRunReceipt(_ item: DeskItem, dataRoot: URL, at now: Date) throws -> JSONValue? {
        let life = try DataRootLife.current(in: dataRoot)
        return try checkedRead(dataRoot).carriedRuns?.first {
            $0.key == "carry." + item.handle && $0.materialFingerprint == carriedFingerprint(item, at: now, dataRoot: dataRoot)
                && DataRootLife.life(of: $0.lifeID) == life
        }?.habitReceipt
    }

    package func recordCarriedRun(_ item: DeskItem, receipt: JSONValue, dataRoot: URL, at now: Date) throws {
        var run = Self.carriedArrival(item, crossing: now, dataRoot: dataRoot)
        run.lifeID = try DataRootLife.current(in: dataRoot)
        run.habitReceipt = receipt
        guard kept(dataRoot, { ledger in
            var runs = ledger.carriedRuns ?? []
            runs.removeAll { $0.key == run.key }
            runs.append(run)
            ledger.carriedRuns = Array(runs.suffix(256))
        })?.saved == true else {
            throw PersistenceCoreError.ioFailure("The habit's attempted occurrence could not be saved; reconcile it before another run.")
        }
    }

    /// The carry projection reads the wake owner's spacing and hop law here,
    /// without duplicating its ledger or importing its implementation details.
    package static func carriedOpportunities(dataRoot: URL, items: [DeskItem], at now: Date) -> [String: Date]? {
        // An older offer had no fingerprint. Establish its baseline without
        // inventing a change; subsequent material changes compare against it.
        guard let saved = shared.kept(dataRoot, { ledger -> Ledger in
            for index in ledger.recent.indices where ledger.recent[index].materialFingerprint == nil {
                if let item = items.first(where: { "carry." + $0.handle == ledger.recent[index].key }) {
                    ledger.recent[index].materialFingerprint = carriedFingerprint(item, at: now, dataRoot: dataRoot)
                }
            }
            return ledger
        }), saved.saved else { return nil }
        let ledger = saved.result
        guard !ledger.pending.contains(where: { $0.key?.hasPrefix("carry.") == true && $0.routeWait == nil }) else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, Date)? in
            let key = "carry." + item.handle
            guard !ledger.pending.contains(where: { $0.key == key && $0.routeWait != nil }) else { return nil }
            var changed = DeskClock.parseISO(item.openedAt) ?? .distantPast
            for note in item.notes where note.author != "agent" {
                if let at = DeskClock.parseISO(note.ts) { changed = max(changed, at) }
            }
            if let offered = ledger.recent.filter({ $0.key == key }).max(by: { $0.at < $1.at }) {
                let materialChanged = offered.materialFingerprint != carriedFingerprint(item, at: now, dataRoot: dataRoot)
                guard materialChanged || changed > offered.at else { return nil }
                if materialChanged { changed = max(changed, now) }
            }
            // A clock moment comes at its time: the spacing between wakes holds only the rest.
            let clock = item.step.flatMap { MyQueue.When($0.when, card: $0.card) }.map { if case .at = $0 { return true }; if case .every = $0 { return true }; return false } ?? false
            var due = clock ? changed : max(changed, ledger.lastWake?.addingTimeInterval(spacing) ?? .distantPast)
            if let hop = ledger.hops[key], hop.count >= maxHops {
                let rested = hop.at.addingTimeInterval(rest)
                due = max(due, Date(timeIntervalSinceReferenceDate: rested.timeIntervalSinceReferenceDate.nextUp))
            }
            return (item.handle, due)
        })
    }
}

/// The app files its own work: one Desk item per finding in project
/// `harness` (origin system), closed when the finding reads ok again.
public enum HarnessQueue {
    public static let project = "harness"

    /// The original item; Doctor closure and person ownership survive repeats.
    @discardableResult
    public static func file(_ finding: HarnessFinding, dataRoot: URL, refreshRefs: Bool = false) async throws -> DeskItem {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let filed = try await store.fileSystemItem(
            kind: .plan, project: project, title: finding.title, summary: finding.summary,
            assignee: finding.owner.rawValue, waitingOn: finding.owner == .owner ? "owner" : nil,
            findingKey: finding.key,
            note: "filed by " + finding.source.rawValue,
            refs: finding.refs, reopen: finding.source != .doctor, refreshRefs: refreshRefs
        )
        var item = filed.item
        guard !item.status.isTerminal,
              !(filed.reusedEquivalent && (item.assignee == "owner" || item.waitingOn == "owner")) else {
            ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "harness." + item.handle)
            return item
        }
        for ref in finding.refs where !refreshRefs && ref.kind.token != "step" && !item.refs.contains(where: { $0.kind == ref.kind }) {
            try await store.addRef(item.handle, ref: ref)
            item.refs.append(ref)
        }
        ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "harness." + item.handle)
        return item
    }

    /// The finding reads ok again: its open item closes with `note`, and a
    /// wake for any item with this key that has not reached her is taken back
    /// (an item an interrupted resolve already closed included).
    @discardableResult
    public static func resolve(key: String, note: String, dataRoot: URL, observedAt: Date? = nil) async throws -> Bool {
        return try await settle(dataRoot: dataRoot, observedAt: observedAt) { $0 == key ? note : nil }
    }

    /// Every open finding whose key starts with one of these prefixes closes
    /// with that prefix's note, in one pass (including legacy Doctor signatures).
    public static func resolve(keyPrefixes notes: [String: String], dataRoot: URL) async throws {
        try await settle(dataRoot: dataRoot) { key in notes.first { key.hasPrefix($0.key) }?.value }
    }

    /// Retire per-record findings after their rollup is filed, in one settlement pass.
    public static func fold(keyPrefixes: [String], into title: String, dataRoot: URL) async throws {
        try await settle(dataRoot: dataRoot) { key in
            keyPrefixes.contains(where: { key.hasPrefix($0) }) ? "folded into " + title : nil
        }
    }

    /// `noteFor` answers an item's finding key with its closing note, or nil.
    @discardableResult
    private static func settle(dataRoot: URL, observedAt: Date? = nil,
                               _ noteFor: @escaping @Sendable (String) -> String?) async throws -> Bool {
        let answer: @Sendable (DeskItem) -> String? = { item in
            guard item.project == project, let key = item.findingKey else { return nil }
            return noteFor(key)
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        try await store.settleWaits { item in
            guard let note = answer(item) else { return nil }
            if let observedAt {
                guard let updated = DeskClock.parseISO(item.updatedAt), updated <= observedAt else { return nil }
            }
            return (note, .done, nil)
        }
        let items = try await store.liveState().items
        for item in items where item.status.isTerminal && answer(item) != nil {
            ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "carry." + item.handle)
            ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "harness." + item.handle)
        }
        return !items.contains { !$0.status.isTerminal && answer($0) != nil }
    }

    /// Open findings, newest first; the standing Body item is not one.
    public static func open(_ state: DeskState) -> [DeskItem] {
        state.items.filter { $0.project == project && $0.kind != .standing && !$0.status.isTerminal }
            .sorted { $0.openedAt > $1.openedAt }
    }

}
