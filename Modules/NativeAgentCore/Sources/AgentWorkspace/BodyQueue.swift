import Foundation
import Desk
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BodyQueue.swift` | `BodyQueue`, `BodyFinding`, `file`, `resolve`, `fold`: stable finding identities |

/// Each finding keeps its Desk identity and the person who can tend it.
public struct BodyFinding: Sendable, Equatable {
    public enum Owner: String, Sendable { case agent, builder, owner }
    public enum Source: String, Sendable { case doctor, loop, bridge, agent }

    /// Use the producer's stable finding identity so repeats update one item.
    public var key: String
    public var title: String
    public var summary: String
    public var owner: Owner
    public var refs: [DeskRef]
    public var source: Source

    public init(key: String, title: String, summary: String, owner: Owner, refs: [DeskRef], source: Source) {
        self.key = key; self.title = title; self.summary = summary
        self.owner = owner; self.refs = refs; self.source = source
    }
}

/// File one Desk item per system finding; close it only when the finding reads ok.
public enum BodyQueue {
    public static let project = "body"

    /// Preserve Doctor closure and person ownership across repeat findings.
    @discardableResult
    public static func file(_ finding: BodyFinding, dataRoot: URL, refreshRefs: Bool = false) async throws -> DeskItem {
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
              !(filed.reusedEquivalent && (item.assignee == "owner" || item.waitingOn == "owner")) else { return item }
        for ref in finding.refs where !refreshRefs && ref.kind.token != "step" && !item.refs.contains(where: { $0.kind == ref.kind }) {
            try await store.addRef(item.handle, ref: ref)
            item.refs.append(ref)
        }
        return item
    }

    /// Resolution closes the finding's item, also when an interrupted resolve already closed it.
    @discardableResult
    public static func resolve(key: String, note: String, dataRoot: URL, observedAt: Date? = nil) async throws -> Bool {
        return try await settle(dataRoot: dataRoot, observedAt: observedAt) { $0 == key ? note : nil }
    }

    /// Close matching finding-key prefixes in one pass, retaining each prefix's note.
    public static func resolve(keyPrefixes notes: [String: String], dataRoot: URL) async throws {
        try await settle(dataRoot: dataRoot) { key in notes.first { key.hasPrefix($0.key) }?.value }
    }

    /// Settle per-record findings only after their rollup is filed.
    public static func fold(keyPrefixes: [String], into title: String, dataRoot: URL) async throws {
        try await settle(dataRoot: dataRoot) { key in
            keyPrefixes.contains(where: { key.hasPrefix($0) }) ? "folded into " + title : nil
        }
    }

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
        return !items.contains { !$0.status.isTerminal && answer($0) != nil }
    }

    /// Keep the standing Body item out of the open-finding list.
    public static func open(_ state: DeskState) -> [DeskItem] {
        state.items.filter { $0.project == project && $0.kind != .standing && !$0.status.isTerminal }
            .sorted { $0.openedAt > $1.openedAt }
    }

}
