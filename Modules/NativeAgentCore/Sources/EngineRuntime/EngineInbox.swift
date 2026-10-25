import Foundation
import BackgroundWork
import NativeAgentShared
import NativeAgentCore
import AuthoredCapabilities
import Observation
import NotificationInbox
import PersistenceCore
import TriggerScheduler
import Cognition
// Blueprint: | `EngineInbox.swift` | InboxFacade publishes checked items, triggers and read errors through LatestRead; each caller receives its own rows; markRead and committed trigger changes use write; owner-scoped observe/observeTriggers, including canonical ability invalidations for authored trigger defaults, loading and availability; InboxItemRecord action/proactive prominence and newest physical row per stable card id. |

extension InboxItemRecord {
    public var isUnread: Bool { normalizedStatus == "unread" }
}

/// `NativeAgentEngine.inbox` (S10): the live notification inbox for one data
/// root, as core `InboxItemRecord`s. Today's notes, the Inbox page, the chat
/// strip and the badges render `items`; LatestRead owns publication here.
/// Phone snapshots receive their own checked read. Card actions run through
/// the app's `InboxCardActions`.
@MainActor
@Observable
public final class InboxFacade {
    public nonisolated let dataRoot: URL
    /// The file's one owner for this root. The default root shares the
    /// process-wide actor, which keeps the parsed 1–2 MB feed until the file
    /// changes; another root gets its own.
    public nonisolated let store: LiveNotificationInbox

    /// Every card, newest first, as of the last published read.
    public private(set) var items: [InboxItemRecord] = [] {
        didSet { itemsDidChange?() }
    }
    public private(set) var loadError: String?
    public private(set) var hasLoadedSnapshot = false
    public var isLoading: Bool { pendingItemReads > 0 }
    private var pendingItemReads = 0
    public private(set) var triggerRows: [TriggerConfig] = []
    public private(set) var triggersRead = false
    public private(set) var triggerError: String?
    public var isLoadingTriggers: Bool { pendingTriggerReads > 0 }
    private var pendingTriggerReads = 0
    @ObservationIgnored private lazy var itemRead = LatestRead()
    @ObservationIgnored private lazy var triggerRead = LatestRead()

    public var refreshErrorText: String? {
        loadError.map { _ in
            items.isEmpty ? "Couldn't read your notes. Try Refresh."
                : "Couldn't refresh, so these notes may be out of date. Try Refresh."
        }
    }

    public enum ContentPresentation { case loading, unavailable, empty, content }

    public func contentPresentation(hasVisibleItems: Bool) -> ContentPresentation {
        if hasVisibleItems { return .content }
        if loadError != nil { return .unavailable }
        return hasLoadedSnapshot ? .empty : .loading
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
    public func list(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        pendingItemReads += 1
        defer { pendingItemReads -= 1 }
        let result: Result<[InboxItemRecord], Error> = await itemRead.read({
            do { return .success(try await self.read()) }
            catch { return .failure(error) }
        }) { result in
            switch result {
            case .success(let loaded):
                if items != loaded { items = loaded }
                hasLoadedSnapshot = true
                loadError = nil
            case .failure(let error):
                loadError = UserFacingError.message(error, action: "read your inbox")
            }
        }
        let loaded = try result.get()
        return unreadOnly ? loaded.filter(\.isUnread) : loaded
    }

    private nonisolated func read() async throws -> [InboxItemRecord] {
        let rows = try await store.rows()
        var items = InboxItemRecord.latest(in: rows)
        if !rows.isEmpty && items.isEmpty {
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

    public func refresh() async { _ = try? await list() }

    /// Mounted inbox surfaces observe the same source and publish to every reader.
    public func observe() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [LiveNotificationInbox.livePath(dataRoot: dataRoot)]) {
            await self.refresh()
        }
    }

    /// Marks the shown card read after a successful read action. Reading does
    /// not settle an owner obligation.
    public func markRead(_ id: String) {
        itemRead.write {
            if let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread {
                items[idx].status = "read"
            }
        }
    }
}

// MARK: - Proactive triggers

extension InboxFacade {
    public func observeTriggers() async {
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: [dataRoot.appendingPathComponent("triggers/trigger_config.json")],
            notifications: [AbilityStore.didChange]
        ) {
            do { _ = try await self.triggers() }
            catch { print("[inbox triggers] \(error.localizedDescription)") }
        }
    }

    /// The kinds of card she raises unasked (morning brief, idle check-in,
    /// file watch…), as TriggerScheduler keeps them for this root.
    public func triggers() async throws -> [TriggerConfig] {
        pendingTriggerReads += 1
        defer { pendingTriggerReads -= 1 }
        let result: Result<[TriggerConfig], Error> = await triggerRead.read({
            do { return .success(try await NativeAgentEngine.makeNativeTriggerScheduler(dataRoot: dataRoot).listInboxTriggers()) }
            catch { return .failure(error) }
        }) { result in
            triggersRead = true
            switch result {
            case .success(let loaded):
                triggerRows = loaded
                triggerError = nil
            case .failure(let error):
                triggerError = UserFacingError.message(error, action: "load triggers")
            }
        }
        return try result.get()
    }

    /// Turn one trigger on or off. A name the scheduler does not know throws.
    public func setTrigger(_ name: String, enabled: Bool) async throws {
        let scheduler = NativeAgentEngine.makeNativeTriggerScheduler(dataRoot: dataRoot)
        let status = try await enabled
            ? scheduler.enableInboxTrigger(name: name)
            : scheduler.disableInboxTrigger(name: name)
        try Self.requireTrigger(status, name: name)
        triggerRead.write {
            if let enabled = status.enabled, let index = triggerRows.firstIndex(where: { $0.name == status.name }) {
                triggerRows[index].enabled = enabled
            }
        }
        do { _ = try await triggers() }
        catch { print("[inbox triggers] \(error.localizedDescription)") }
    }

    private nonisolated static func requireTrigger(_ status: TriggerStatus, name: String) throws {
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
    }
}

extension InboxItemRecord {
    public var isHiddenFromDefaultInbox: Bool {
        normalizedStatus == "archived" || normalizedStatus == "dismissed"
    }
    public var hasLinkedApproval: Bool { !(related_approval_id ?? "").isEmpty }
    public var isProactiveCard: Bool { source.lowercased().hasPrefix("proactive_autonomy:") }
    public var isApprovalBacklogCard: Bool {
        let lowerSource = source.lowercased()
        let lowerDetail = (detail ?? "").lowercased()
        return hasLinkedApproval
            || lowerSource.hasPrefix("proactive_autonomy:approval_backlog:")
            || lowerDetail.contains("suggested action: approvals.triage")
    }

    public var fallbackPrimaryAction: InboxActionRecord? {
        if isApprovalBacklogCard {
            return InboxActionRecord(
                id: "open_approvals",
                label: "Open Approvals",
                description: "Review pending approvals"
            )
        }
        if isProactiveCard {
            return nil
        }
        if severity.lowercased() == "actionable" || relatedWorkshopExecutionId != nil {
            return InboxActionRecord(id: "act", label: "Act", description: "Take primary action")
        }
        return nil
    }

    public var effectiveActions: [InboxActionRecord] {
        if !actions.isEmpty { return actions }
        var fallback = [InboxActionRecord(id: "view", label: "View", description: "See full detail")]
        if let primary = fallbackPrimaryAction {
            fallback.append(primary)
        }
        fallback.append(contentsOf: [
            InboxActionRecord(id: "archive", label: "Archive", description: "Archive this item"),
            InboxActionRecord(id: "dismiss", label: "Dismiss", description: "Dismiss this item"),
        ])
        return fallback
    }

    public var actionIDs: Set<String> {
        Set(effectiveActions.map(\.id))
    }

    public var isForYouLane: Bool { !isSystemLane }
}

extension InboxRelatedGroup {
    public func matches(_ item: InboxItemRecord) -> Bool {
        matches(itemID: item.id, title: item.title)
    }
}

/// The persisted inbox action list includes control verbs which the Desk owns
/// itself: opening a card marks it read, and viewing/replying are not direct
/// button operations. Project once at the presentation boundary so every Desk
/// surface offers exactly the native action that its button will invoke.
public enum InboxVisibleActionsPresentation {
    private static let hiddenActionIDs: Set<String> = ["view", "read", "reply"]
    private static let executableActionIDs: Set<String> = Set([
        "act", "approve", "reject",
    ]).union(HeartbeatCardAction.ids)

    public static func actions(for item: InboxItemRecord) -> [InboxActionRecord] {
        guard !item.isHiddenFromDefaultInbox else { return [] }
        var seen: Set<String> = []
        var visible: [InboxActionRecord] = []

        for action in item.effectiveActions {
            let normalizedID = action.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let canonicalID = normalizedID == "deny" ? "reject" : normalizedID
            guard !hiddenActionIDs.contains(canonicalID),
                  executableActionIDs.contains(canonicalID)
            else { continue }

            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(canonicalID).inserted else { continue }
            visible.append(InboxActionRecord(
                id: canonicalID,
                label: label,
                description: action.description
            ))
        }
        return visible
    }
}


/// WHAT STILL NEEDS THE PERSON, as opposed to what she has already told him.
///
/// The inbox was one flat list per lane in arrival order, and opening a card
/// marked it read — so an approval he opened, thought about and did not act on
/// sank under the next hour of notices and was gone. Reading is not resolving;
/// the same OwnerAttentionPolicy as the overview owns this section.
///
/// Resolution is what removes it. Every surface renders the latest checked
/// InboxFacade revision, including a card restored by its durable owner.
public enum InboxNeedsYou {
    public struct Sections {
        public let needsYou: [InboxItemRecord]
        public let rest: [InboxItemRecord]

        public var isEmpty: Bool { needsYou.isEmpty && rest.isEmpty }
    }

    /// - Parameter everywhere: the visible population across every lane.
    /// - Parameter lane: the lane's own visible population, which keeps its
    ///   arrival order below.
    public static func sections(
        everywhere: [InboxItemRecord],
        lane: [InboxItemRecord]
    ) -> Sections {
        let needsYou = everywhere
            .filter(\.requiresOwnerInput)
            .sorted { $0.created_at > $1.created_at }
        let claimed = Set(needsYou.map(\.id))
        return Sections(needsYou: needsYou, rest: lane.filter { !claimed.contains($0.id) })
    }
}
