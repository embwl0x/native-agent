import Foundation
import NativeAgentShared
import NativeAgentCore
import Observation
import NotificationInbox
import PersistenceCore
import Cognition
import BackgroundWork
import Experiences
import ApprovalTransactions
import Privacy
// Blueprint: | `EngineInbox.swift` | Root-specific ForPerson inbox reading and face-change subscription lifetime |

extension InboxItemRecord {
    public var isUnread: Bool { normalizedStatus == "unread" }
}

/// Share one root’s checked inbox across surfaces through LatestRead; phone snapshots return their own read, and native owners execute card actions.
@MainActor
@Observable
public final class InboxFacade {
    public nonisolated let dataRoot: URL
    private nonisolated let reading: InboxReadings
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
