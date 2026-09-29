import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

/// The inbox reader deliberately keeps cards with a bad optional source rather
/// than dropping the whole record. Preserve why the source is unavailable so
/// the visible provenance badge does not turn a bad wire value into silence.
public enum InboxSourceReadState: Hashable, Sendable {
    case present
    case missing
    case malformed
}

/// One card of the live notification inbox (`notifications/inbox.jsonl`), read
/// straight from its parsed row. The Mac's inbox surfaces render it; the
/// phone's inbox snapshot is its encoding.
public struct InboxItemRecord: Identifiable, Encodable, Hashable, Sendable {
    public let id: String
    public let created_at: String
    public let source: String
    public let sourceReadState: InboxSourceReadState
    public let severity: String      // info | important | actionable
    public let title: String
    public let summary: String
    public let detail: String?
    public let relatedWorkshopExecutionId: String?
    public let related_approval_id: String?
    public let related_paths: [String]?
    public let related_groups: [InboxRelatedGroup]?
    public let actions: [InboxActionRecord]
    // ui-honesty 2026-06-10: `var` so the UI can patch a row to "read" locally
    // after a successful read action, without waiting on a full reload.
    public var status: String        // unread | read | archived | dismissed
    public let read_at: String?

    enum CodingKeys: String, CodingKey {
        case id, created_at, source, severity, title, summary, detail
        case relatedWorkshopExecutionId = "related_mission_id" // compatibility wire ID
        case related_approval_id, related_paths, related_groups
        case actions, status, read_at
    }

    /// A row without a string `id` is not a card. Every other field keeps the
    /// card: a missing or mistyped value takes its default, and a list with
    /// one unreadable element is read as absent (actions as none).
    ///
    /// Wave 4 (phase A) read-both: the FUTURE `related_execution_id` spelling
    /// wins over the on-wire `related_mission_id`; `encode(to:)` still writes
    /// `related_mission_id`, so the inbox snapshot a 0.3.7 iOS install reads
    /// is byte-identical.
    public init?(row: JSONValue) {
        guard case .object(let o) = row, let id = Self.string(o["id"]) else { return nil }
        self.id = id
        created_at = Self.string(o["created_at"]) ?? ""
        if o["source"] == nil {
            source = ""
            sourceReadState = .missing
        } else if let decodedSource = Self.string(o["source"]) {
            source = decodedSource
            sourceReadState = .present
        } else {
            source = ""
            sourceReadState = .malformed
        }
        severity = Self.string(o["severity"]) ?? "info"
        title = Self.string(o["title"]) ?? ""
        summary = Self.string(o["summary"]) ?? ""
        detail = Self.string(o["detail"])
        relatedWorkshopExecutionId = Self.string(o[InboxExecutionLinkVocabulary.futureKey])
            ?? Self.string(o[InboxExecutionLinkVocabulary.wireKey])
        related_approval_id = Self.string(o["related_approval_id"])
        related_paths = Self.strings(o["related_paths"])
        related_groups = Self.all(o["related_groups"], Self.group)
        actions = Self.all(o["actions"], Self.action) ?? []
        status = Self.string(o["status"]) ?? "unread"
        read_at = Self.string(o["read_at"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(created_at, forKey: .created_at)
        try c.encode(source, forKey: .source)
        try c.encode(severity, forKey: .severity)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(relatedWorkshopExecutionId, forKey: .relatedWorkshopExecutionId)
        try c.encodeIfPresent(related_approval_id, forKey: .related_approval_id)
        try c.encodeIfPresent(related_paths, forKey: .related_paths)
        try c.encodeIfPresent(related_groups, forKey: .related_groups)
        try c.encode(actions, forKey: .actions)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(read_at, forKey: .read_at)
    }

    // MARK: - Row fields

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        all(value) { string($0) }
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let n)?: return Int(exactly: n)
        case .double(let d)?: return Int(exactly: d)
        default: return nil
        }
    }

    /// Every element read, or nil when the value is not an array or any
    /// element is unreadable.
    private static func all<T>(_ value: JSONValue?, _ read: (JSONValue) -> T?) -> [T]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [T] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard let item = read(element) else { return nil }
            out.append(item)
        }
        return out
    }

    /// An optional field: absent or null is nil; any other non-match fails
    /// the element.
    private static func nullable<T>(_ value: JSONValue?, _ read: (JSONValue?) -> T?) -> T?? {
        switch value {
        case nil, .null?: return .some(nil)
        default: return read(value).map { .some($0) }
        }
    }

    private static func group(_ value: JSONValue) -> InboxRelatedGroup? {
        guard case .object(let g) = value,
              let id = string(g["id"]), let title = string(g["title"]), let count = int(g["count"]),
              let itemIDs = nullable(g["item_ids"], strings),
              let source = nullable(g["source"], string) else { return nil }
        return InboxRelatedGroup(id: id, title: title, count: count, item_ids: itemIDs, source: source)
    }

    private static func action(_ value: JSONValue) -> InboxActionRecord? {
        guard case .object(let a) = value,
              let id = string(a["id"]), let label = string(a["label"]),
              let description = nullable(a["description"], string) else { return nil }
        return InboxActionRecord(id: id, label: label, description: description)
    }
}

/// The only route from a persisted digest card to its Review Groups controls.
/// New cards use the structured wire; prose remains compatibility for existing
/// JSONL cards only.
extension InboxItemRecord: InboxDigestItem {}
extension InboxRelatedGroup: InboxDigestGroup {}

extension InboxItemRecord {
    public var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Still asking for attention: the phone's inbox keeps these ahead of the
    /// resolved rows.
    public var isActivityPending: Bool {
        normalizedStatus == "unread" || normalizedStatus == "active"
    }
}
