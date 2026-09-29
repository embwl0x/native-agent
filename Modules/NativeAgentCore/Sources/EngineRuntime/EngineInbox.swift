import Foundation
import Observation
import NotificationInbox
import PersistenceCore

extension InboxItemRecord {
    public var isUnread: Bool { normalizedStatus == "unread" }
}

/// `NativeAgentEngine.inbox` (S10): the live notification inbox for one data
/// root, as core `InboxItemRecord`s. Today's notes, the Inbox page, the chat
/// strip and the badges render `items`; the read is nonisolated so the phone
/// snapshot uses the same owner. Card actions still run through
/// `NativeClient.inboxAction`.
@MainActor
@Observable
public final class InboxFacade {
    public nonisolated let dataRoot: URL
    /// The file's one owner for this root. The default root shares the
    /// process-wide actor, which keeps the parsed 1–2 MB feed until the file
    /// changes; another root gets its own.
    public nonisolated let store: LiveNotificationInbox

    /// Every card, newest first, as of the last read.
    public var items: [InboxItemRecord] = [] {
        didSet { itemsDidChange?() }
    }
    @ObservationIgnored public var itemsDidChange: (@MainActor () -> Void)?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        let path = LiveNotificationInbox.livePath(dataRoot: dataRoot)
        self.store = path == LiveNotificationInbox.livePath(dataRoot: PersistenceCore.defaultDataRoot())
            ? .shared
            : LiveNotificationInbox(path: path)
    }

    /// Cards newest first by `created_at` (blank last, then id). A row that
    /// is not a card is skipped, but a feed where no row reads is corruption,
    /// never an empty inbox, and throws.
    ///
    /// 2026-06-06: newest first — the file is append-only, so without the
    /// sort the just-fired card lands at the bottom. The phone's inbox
    /// snapshot inherits this order.
    public nonisolated func list(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        let rows = try await store.rows()
        var items: [InboxItemRecord] = []
        var unreadable = 0
        for row in rows {
            guard let item = InboxItemRecord(row: row) else {
                unreadable += 1
                continue
            }
            if unreadOnly && !item.isUnread { continue }
            items.append(item)
        }
        if !rows.isEmpty && unreadable == rows.count {
            throw NSError(domain: "NativeAgent", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "getInboxItems: all \(rows.count) inbox row(s) failed to decode — "
                    + "refusing to render a corrupt inbox as empty"
            ])
        }
        items.sort { lhs, rhs in
            if lhs.created_at.isEmpty { return false }
            if rhs.created_at.isEmpty { return true }
            if lhs.created_at != rhs.created_at { return lhs.created_at > rhs.created_at }
            return lhs.id > rhs.id
        }
        return items
    }

    /// Marks the shown card read after a successful read action, so badges
    /// agree before the next reload.
    public func markRead(_ id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread {
            items[idx].status = "read"
        }
    }
}
