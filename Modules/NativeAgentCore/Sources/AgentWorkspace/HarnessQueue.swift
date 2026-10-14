import Foundation
import Desk

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
        return .init(id: key + "." + String(crossing.timeIntervalSince1970),
            line: "Yours to carry: \(item.title) — \(item.summary ?? step?.words ?? item.title). Do what you judge right. Close it with desk.close only once it is actually done; otherwise leave it open and note why it waits.",
            key: key, thread: key,
            at: crossing, session: step?.session,
            filedAt: step.map { $0.filedAt ?? item.openedAt })
    }

    /// The carry projection reads the wake owner's spacing and hop law here,
    /// without duplicating its ledger or importing its implementation details.
    package static func carriedOpportunities(dataRoot: URL, handles: [String], at now: Date) -> [String: Date] {
        let ledger = read(dataRoot)
        guard !ledger.pending.contains(where: { $0.key?.hasPrefix("carry.") == true && $0.routeWait == nil }) else { return [:] }
        return Dictionary(uniqueKeysWithValues: handles.filter { handle in
            !ledger.pending.contains { $0.key == "carry." + handle && $0.routeWait != nil }
        }.map { handle in
            let key = "carry." + handle
            var due = max(now, ledger.lastWake?.addingTimeInterval(spacing) ?? now)
            if let offered = ledger.recent.filter({ $0.key == key }).map(\.at).max() {
                due = max(due, offered.addingTimeInterval(spacing))
            }
            if let hop = ledger.hops[key], hop.count >= maxHops {
                let rested = hop.at.addingTimeInterval(rest)
                due = max(due, Date(timeIntervalSinceReferenceDate: rested.timeIntervalSinceReferenceDate.nextUp))
            }
            return (handle, due)
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
