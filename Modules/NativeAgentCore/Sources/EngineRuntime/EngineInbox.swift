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
import ApprovalTransactions
import Privacy
// Blueprint: | `EngineInbox.swift` | Root-specific ForPerson inbox reading, face-change subscription lifetime and checked trigger publication |

extension InboxItemRecord {
    public var isUnread: Bool { normalizedStatus == "unread" }
}

/// Share one root’s checked inbox across surfaces through LatestRead; phone snapshots return their own read, and native owners execute card actions.
@MainActor
@Observable
public final class InboxFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let reading: InboxReadings
    public private(set) var triggerRows: [TriggerConfig] = []
    public private(set) var triggersRead = false
    public private(set) var triggerError: String?
    public var isLoadingTriggers: Bool { pendingTriggerReads > 0 }
    private var pendingTriggerReads = 0
    @ObservationIgnored private lazy var triggerRead = LatestRead()
    @ObservationIgnored var faceChanges: Task<Void, Never>?

    isolated deinit { faceChanges?.cancel() }

    public nonisolated init(dataRoot: URL, counts: CountsFeedProjection) {
        self.dataRoot = dataRoot
        self.reading = InboxReadings(dataRoot: dataRoot, counts: counts)
    }

    /// Failed owner reads retain proven rows with loadError; the phone receives the same checked reading.
    public nonisolated func list(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        try await reading.list(unreadOnly: unreadOnly)
    }

    public nonisolated func changes() async -> AsyncStream<Void> {
        await reading.changes()
    }

    public nonisolated func refresh() async {
        do { _ = try await list() }
        catch { /* The checked reading retains the source's cause in its face. */ }
    }

    /// Mounted inbox surfaces must share one source and revision.
    public nonisolated func observe() async {
        for await _ in await ForPerson.at(dataRoot).changes() {
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// The read action already committed; publish its owner's current reading, including any answer that landed meanwhile.
    public nonisolated func markRead(_ id: String) {
        Task { await refresh() }
    }
}

/// The inbox owns its admitted rows; every caller returns its own read and every face receives this owner's finished value.
private actor InboxReadings {
    private let dataRoot: URL
    private let counts: CountsFeedProjection
    private let latest = LatestRead()
    private var face = InboxCountsFace()
    private var reads: Set<UUID> = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(dataRoot: URL, counts: CountsFeedProjection) {
        self.dataRoot = dataRoot
        self.counts = counts
    }

    deinit { for observer in observers.values { observer.finish() } }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func list(unreadOnly: Bool) async throws -> [InboxItemRecord] {
        let id = UUID()
        reads.insert(id)
        face.isReading = true
        await counts.updateInbox(face)
        let result: Result<[InboxItemRecord], Error> = await latest.read({
            do { return .success(try await ForPerson.at(dataRoot).inbox()) }
            catch { return .failure(error) }
        }) { result in
            let previous = face
            switch result {
            case .success(let rows):
                face.rows = rows.map(Self.disclosed)
                face.noteIDs = rows.filter {
                    $0.isUnread && $0.source != InlineInteractionDelivery.source && !$0.hasLinkedApproval
                }.map(\.id)
                face.unread = .init(value: rows.filter(\.isUnread).count)
            case .failure(let error):
                face.unread.issue = NativeAppSecretRedactor.redactText(UserFacingError.message(error, action: "read your inbox"))
            }
            if face != previous { for continuation in observers.values { continuation.yield() } }
        }
        reads.remove(id)
        face.isReading = !reads.isEmpty
        await counts.updateInbox(face)
        let rows = try result.get()
        return unreadOnly ? rows.filter(\.isUnread) : rows
    }

    private static func disclosed(_ row: InboxItemRecord) -> InboxItemRecord {
        let redact = NativeAppSecretRedactor.redactText
        var result = InboxItemRecord(
            id: row.id, created_at: row.created_at, source: row.source, severity: row.severity,
            title: redact(row.title), summary: redact(row.summary), detail: row.detail.map(redact),
            relatedWorkshopExecutionId: row.relatedWorkshopExecutionId, related_approval_id: row.related_approval_id,
            related_paths: row.related_paths, related_groups: row.related_groups?.map {
                .init(id: $0.id, title: redact($0.title), count: $0.count, item_ids: $0.item_ids, source: $0.source)
            }, actions: row.actions.map { .init(id: $0.id, label: redact($0.label), description: $0.description.map(redact)) },
            status: row.status, read_at: row.read_at, chat_session_id: row.chat_session_id,
            presentation: row.presentation.map {
                .init(icon: $0.icon, badge: redact($0.badge), words: redact($0.words), actLabel: $0.actLabel.map(redact))
            }, interaction_session_id: row.interaction_session_id, interaction_id: row.interaction_id)
        result.relatedDelegationID = row.relatedDelegationID
        return result
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
