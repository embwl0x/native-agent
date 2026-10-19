import Foundation
import Desk
import NativeAgentCore

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
    package static func carriedArrival(_ item: DeskItem, crossing: Date) -> Item {
        let key = "carry." + item.handle
        let step = item.step
        let peers = (step?.peers ?? []).filter { !CapabilityLifecycle.ownerTrusts($0) }
        let provenance = peers.isEmpty ? "" : " Peer steering retained: " + peers.joined(separator: ", ")
            + ". A one-call approval does not elevate a peer."
        // What released it since she last wrote on it (MyQueueReady.release's note).
        let mine = item.notes.filter { $0.author == "agent" }.compactMap { DeskClock.parseISO($0.ts) }.max() ?? .distantPast
        let released = item.notes.filter {
            $0.author == "system" && $0.text.hasPrefix("Released: ") && (DeskClock.parseISO($0.ts) ?? .distantPast) > mine
        }.map { $0.text + " " }.joined()
        return .init(id: key + "." + String(crossing.timeIntervalSince1970),
            line: released + "Yours to carry: \(item.title) — \(item.summary ?? step?.words ?? item.title). Do what you judge right. Close it with desk.close only once it is actually done. If it can't move yet, say what it waits on with desk.wait {handle, on: <the card, message or debt id it needs>}: you are woken when that settles, not before." + provenance,
            key: key, thread: key,
            at: crossing, session: step?.session,
            filedAt: step.map { $0.filedAt ?? item.openedAt }, materialFingerprint: carriedFingerprint(item))
    }

    /// What an offer of carried work is measured from: the item's material state
    /// and the step it queues (refiling it is a change), never notes or stamps.
    static func carriedFingerprint(_ item: DeskItem) -> String {
        let step = item.step.map { [$0.words, $0.when, $0.card ?? "", $0.action ?? "", $0.session ?? "", $0.filedAt ?? ""] } ?? []
        return ([DeskObservationEvaluator.materialFingerprint(item)] + step).joined(separator: "\u{1F}")
    }

    /// The carry projection reads the wake owner's spacing and hop law here,
    /// without duplicating its ledger or importing its implementation details.
    package static func carriedOpportunities(dataRoot: URL, items: [DeskItem], at now: Date) -> [String: Date] {
        // An older offer had no fingerprint. Establish its baseline without
        // inventing a change; subsequent material changes compare against it.
        guard let saved = shared.kept(dataRoot, { ledger -> Ledger in
            for index in ledger.recent.indices where ledger.recent[index].materialFingerprint == nil {
                if let item = items.first(where: { "carry." + $0.handle == ledger.recent[index].key }) {
                    ledger.recent[index].materialFingerprint = carriedFingerprint(item)
                }
            }
            return ledger
        }), saved.saved else { return [:] }
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
                let materialChanged = offered.materialFingerprint != carriedFingerprint(item)
                guard materialChanged || changed > offered.at else { return nil }
                if materialChanged { changed = max(changed, now) }
            }
            var due = max(changed, ledger.lastWake?.addingTimeInterval(spacing) ?? .distantPast)
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

    /// The item's historical key note; findingKey owns its identity.
    /// A space after the label, not a colon: "harness-key:<key>" read as a
    /// credential pair and the display redactor blanked every key on the Desk.
    static func keyNote(_ key: String) -> String { "harness-key " + key }

    /// The original item; Doctor closure and person ownership survive repeats.
    @discardableResult
    public static func file(_ finding: HarnessFinding, dataRoot: URL, refreshRefs: Bool = false) async throws -> DeskItem {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let filed = try await store.fileSystemItem(
            kind: .plan, project: project, title: finding.title, summary: finding.summary,
            assignee: finding.owner.rawValue, findingKey: finding.key,
            note: keyNote(finding.key) + "\nfiled by " + finding.source.rawValue,
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
        let waitingOn = finding.owner == .owner ? "owner" : nil
        if !filed.reusedEquivalent && item.waitingOn != waitingOn {
            _ = try await store.setStatus(item.handle, status: item.status,
                blockedReason: item.blockedReason, waitingOn: waitingOn,
                progress: item.progress, assignee: finding.owner.rawValue, laneOf: item.laneOf)
            item.assignee = finding.owner.rawValue
            item.waitingOn = waitingOn
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

    /// Retire per-record findings after their rollup is filed, one item transaction at a time.
    public static func fold(keyPrefixes: [String], into title: String, dataRoot: URL) async throws {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        for item in try await store.liveState().items where item.project == project {
            guard let key = item.findingKey, keyPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            try await settle(dataRoot: dataRoot) { $0 == key ? "folded into " + title : nil }
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
