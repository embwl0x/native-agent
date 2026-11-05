import Foundation
import NativeAgentShared
import NativeAgentCore
import AuthoredCapabilities
import Observation
import NotificationInbox
import PersistenceCore
import TriggerScheduler
import Cognition
import BackgroundWork
import Experiences
// Blueprint: | `EngineInbox.swift` | Root-specific ForPerson inbox reading, face-change subscription lifetime and checked trigger publication |

extension InboxItemRecord {
    public var isUnread: Bool { normalizedStatus == "unread" }
}

/// Share one root’s checked inbox across surfaces through LatestRead; phone snapshots return their own read, and native owners execute card actions.
@MainActor
@Observable
public final class InboxFacade {
    public nonisolated let dataRoot: URL
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
    @ObservationIgnored var faceChanges: Task<Void, Never>?

    isolated deinit { faceChanges?.cancel() }

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
    }

    /// Failed owner reads retain proven rows with loadError; the phone receives the same checked reading.
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
        try await ForPerson.at(dataRoot).inbox()
    }

    public func refresh() async { _ = try? await list() }

    /// Mounted inbox surfaces must share one source and revision.
    public func observe() async {
        for await _ in await ForPerson.at(dataRoot).changes() {
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// The read action already committed; publish its owner's current reading, including any answer that landed meanwhile.
    public func markRead(_ id: String) {
        Task { await refresh() }
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

    /// Unknown trigger names must throw instead of silently ignoring the request.
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

extension InboxRelatedGroup {
    public func matches(_ item: InboxItemRecord) -> Bool {
        matches(itemID: item.id, title: item.title)
    }
}

/// Project card actions once at the Desk boundary so every offered button invokes its exact native operation.
public enum InboxVisibleActionsPresentation {
    private static let hiddenActionIDs: Set<String> = ["view", "read", "reply"]

    public static func actions(for item: InboxItemRecord) -> [InboxActionRecord] {
        guard !item.isHiddenFromDefaultInbox else { return [] }
        var seen: Set<String> = []
        var visible: [InboxActionRecord] = []

        for action in InboxActionVocabulary.actions(declared: item.actions, approvalLinked: item.hasLinkedApproval) {
            let canonicalID = InboxActionVocabulary.normalizedAction(action.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased())
            guard !hiddenActionIDs.contains(canonicalID),
                  InboxActionVocabulary.nativeActionIDs.contains(canonicalID)
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


/// Reading is not resolving: share OwnerAttentionPolicy with the overview and retain unresolved cards, including owner-restored cards, in the latest
/// checked revision.
public enum InboxNeedsYou {
    public struct Sections {
        public let needsYou: [InboxItemRecord]
        public let rest: [InboxItemRecord]

        public var isEmpty: Bool { needsYou.isEmpty && rest.isEmpty }
    }

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
