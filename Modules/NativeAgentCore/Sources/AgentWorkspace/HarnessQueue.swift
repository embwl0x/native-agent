import Foundation
import Desk

/// One finding the app can neither repair itself nor ask the person about:
/// Doctor rows, the weekly sweep's code findings, loops, the bridge.
public struct HarnessFinding: Sendable, Equatable {
    /// Who fixes it: `agent` (Agent triages) or `builder` (needs a code change).
    public enum Owner: String, Sendable { case agent, builder }
    public enum Source: String, Sendable { case doctor, sweep, loop, bridge }

    /// Stable across repeats: "<check id>|<error signature>" or the sweep's finding id.
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

/// The app files its own work: one open Desk item per finding in project
/// `harness` (origin system), closed when the finding reads ok again, plus
/// the standing "Body" item that carries the daily body report.
public enum HarnessQueue {
    public static let project = "harness"
    static let standingKey = "body"

    /// The item's key note; its first line is the identity the store matches.
    static func keyNote(_ key: String) -> String { "harness-key:" + key }

    /// The open item for this finding, created once; repeats refresh its summary.
    /// A new item is one arrival for her (ResidentWake), held a minute
    /// so it never lands inside a live turn. A repeat within its first day asks
    /// again: the ledger keeps the id that long, so a request a crash or a
    /// failed write lost is made up, and a delivered one is not repeated.
    @discardableResult
    public static func file(_ finding: HarnessFinding, dataRoot: URL) async throws -> DeskItem {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let filed = try await store.fileSystemItem(
            kind: .plan, project: project, title: finding.title, summary: finding.summary,
            assignee: finding.owner.rawValue,
            note: keyNote(finding.key) + "\nfiled by " + finding.source.rawValue,
            refs: finding.refs
        )
        var item = filed.item
        if filed.reusedEquivalent, item.summary != finding.summary {
            _ = try await store.updateTitle(item.handle, summary: finding.summary)
            item.summary = finding.summary
        }
        if !filed.reusedEquivalent
            || DeskClock.parseISO(item.openedAt).map({ Date().timeIntervalSince($0) < 86_400 }) == true {
            ResidentWake.shared.request(dataRoot: dataRoot, reason: "the harness queue", items: [.init(
                id: wakeKey(item.handle), line: "Filed for the \(finding.owner.rawValue) on the harness lane: \"\(item.title.prefix(140))\" (\(item.handle))",
                key: wakeKey(item.handle), hold: 60)])
        }
        return item
    }

    static func wakeKey(_ handle: String) -> String { "harness." + handle }

    /// The finding reads ok again: its open item closes with `note`, and a
    /// wake for any item with this key that has not reached her is taken back
    /// (an item an interrupted resolve already closed included).
    public static func resolve(key: String, note: String, dataRoot: URL) async throws {
        let line = keyNote(key)
        try await settle(dataRoot: dataRoot) { $0 == line ? note : nil }
    }

    /// Every open finding whose key starts with one of these prefixes closes
    /// with that prefix's note, in one pass (Doctor: "<check id>|" per row
    /// that reads ok again, whatever failure signature it was filed under).
    public static func resolve(keyPrefixes notes: [String: String], dataRoot: URL) async throws {
        let lines = notes.map { (keyNote($0.key), $0.value) }
        try await settle(dataRoot: dataRoot) { line in lines.first { line.hasPrefix($0.0) }?.1 }
    }

    /// `noteFor` answers an item's key line with its closing note, or nil.
    private static func settle(dataRoot: URL, _ noteFor: @escaping @Sendable (Substring) -> String?) async throws {
        let answer: @Sendable (DeskItem) -> String? = { item in
            guard item.project == project else { return nil }
            return item.notes.lazy.compactMap { noteFor($0.text.prefix { $0 != "\n" }) }.first
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        try await store.settleWaits { item in answer(item).map { ($0, .done, nil) } }
        for item in try await store.liveState().items where answer(item) != nil {
            ResidentWake.shared.withdraw(dataRoot: dataRoot, key: wakeKey(item.handle))
        }
    }

    /// Open findings, newest first; the standing Body item is not one.
    public static func open(_ state: DeskState) -> [DeskItem] {
        state.items.filter { $0.project == project && $0.kind != .standing && !$0.status.isTerminal }
            .sorted { $0.openedAt > $1.openedAt }
    }

    /// The one standing "Body" item, created on first ask; a closed one is reopened.
    public static func standing(dataRoot: URL) async throws -> DeskItem {
        try await SwiftNativeDeskStore(dataRoot: dataRoot).fileSystemItem(
            kind: .standing, project: project, title: "Body", summary: "The daily body report.",
            assignee: nil, note: keyNote(standingKey), refs: [], reopen: true
        ).item
    }
}
