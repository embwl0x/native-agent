import Foundation
import Observation
import Transcripts
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `MacChatSessionTransactions.swift` | `LatestRead`; `write`; Transactional selection and rename |

@MainActor
public protocol MacChatSessionStore: AnyObject {
    var sessions: [NativeAgentShared.ChatSession] { get set }
    /// Called only inside the index owner's LatestRead publication closure.
    func publishSessionIndexRead(_ sessions: [NativeAgentShared.ChatSession])
    func hasCachedTranscript(for sessionID: String) -> Bool
    func list() async throws -> [NativeAgentShared.ChatSession]
    func create(title: String, sourceKey: String?) async throws -> NativeAgentShared.ChatSession
    func update(id: String, title: String?, archived: Bool?) async throws -> NativeAgentShared.ChatSession
}

/// Selection is admitted in Core; committing bubbles, receipts, defaults and
/// window identity remains one synchronous MainActor presentation operation.
@MainActor
public protocol MacChatSessionSelectionPort: AnyObject {
    var chatSelectionGeneration: Int { get set }
    var activeChatSessionId: String { get }
    func commitChatSessionSelection(_ requestedId: String)
}

/// Serialize durable writes without holding actor state across awaits; queued stale renames may yield, but a started write completes first.
actor ChatRenameMutationGate {
    private var held = false
    private var waiters: [ScopedWaiter] = []

    func acquire() async {
        guard held else { held = true; return }
        let done = ScopedWaiter()
        waiters.append(done)
        await Task { await done.park() }.value
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
public final class MacChatSessionTransactions {
    @ObservationIgnored public let indexRead = LatestRead()

    private let chatRenameMutationGate = ChatRenameMutationGate()
    private var chatRenameIntentGeneration: [String: Int] = [:]

    public private(set) var loadInFlight = false
    @ObservationIgnored private var loadCompleted = false
    @ObservationIgnored private var loadDone = ScopedWaiter()

    public init() {}

    public func load(_ operation: () async -> Void) async {
        if loadInFlight {
            await waitForLoadCompletion()
            return
        }
        loadInFlight = true
        await operation()
        loadInFlight = false
        loadCompleted = true
        loadDone.resume()
        loadDone = ScopedWaiter()
    }

    public func waitForLoadCompletion() async {
        guard loadInFlight || !loadCompleted else { return }
        let done = loadDone
        await Task { await done.park() }.value
    }

    public func existingMainSession(in sessions: [NativeAgentShared.ChatSession], anchorSessionId: String? = nil,
                                    currentSelection: String? = nil) -> NativeAgentShared.ChatSession? {
        let direct = sessions.filter { $0.archived != true && SessionConversation.kind($0).isPersonConversation }
        return direct.first(where: { $0.id == anchorSessionId })
            ?? direct.first(where: { $0.id == currentSelection })
            ?? direct.first(where: { isMainAppSourceKey($0.sourceKey) })
            ?? direct.first
    }

    public func create(store: any MacChatSessionStore, title: String = "New Chat") async throws -> NativeAgentShared.ChatSession {
        let session = try await store.create(title: title, sourceKey: "app")
        publishOpenedSession(session, store: store)
        return session
    }

    public func publishOpenedSession(_ session: NativeAgentShared.ChatSession, store: any MacChatSessionStore) {
        indexRead.write {
            if let index = store.sessions.firstIndex(where: { $0.id == session.id }) {
                store.sessions[index] = session
            } else {
                store.sessions.insert(session, at: 0)
            }
        }
    }

    public func reconcileStartupSession(
        store: any MacChatSessionStore, anchorSessionId: String? = nil, currentSelection: String? = nil
    ) async throws -> (session: NativeAgentShared.ChatSession, created: Bool) {
        if let session = existingMainSession(in: store.sessions, anchorSessionId: anchorSessionId,
                                             currentSelection: currentSelection) { return (session, false) }
        let session = try await create(store: store)
        return (session, true)
    }

    public func select<Port: MacChatSessionSelectionPort>(
        _ requestedId: String,
        userInitiated: Bool = true,
        port: Port,
        store: any MacChatSessionStore,
        presentStatus: (String) -> Void,
        load: (String) async throws -> Void
    ) async {
        guard !requestedId.isEmpty else { return }
        // A user-selected session outranks the conversation anchor for the rest of this launch.
        if userInitiated { MacChatSelectionIntent.noteUserChoice() }
        port.chatSelectionGeneration += 1
        let generation = port.chatSelectionGeneration
        let hasCachedTranscript = store.hasCachedTranscript(for: requestedId)

        if hasCachedTranscript {
            port.commitChatSessionSelection(requestedId)
        }

        do {
            try await load(requestedId)
            guard port.chatSelectionGeneration == generation,
                  store.sessions.contains(where: { $0.id == requestedId }) else { return }
            if hasCachedTranscript {
                guard port.activeChatSessionId == requestedId else { return }
            }
            port.commitChatSessionSelection(requestedId)
        } catch {
            if port.chatSelectionGeneration == generation {
                presentStatus("Chat session load failed: \(error.localizedDescription)")
            }
        }
    }

    public func rename(
        id sessionId: String,
        title: String,
        store: any MacChatSessionStore,
        present: @MainActor (String, Bool) -> Void
    ) async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !cleanTitle.isEmpty else { return }
        let intent = (chatRenameIntentGeneration[sessionId] ?? 0) &+ 1
        chatRenameIntentGeneration[sessionId] = intent
        await chatRenameMutationGate.acquire()
        defer { Task { await chatRenameMutationGate.release() } }
        // Skip obsolete queued titles so the newest rename intent owns the final durable value.
        guard chatRenameIntentGeneration[sessionId] == intent else { return }
        // Enforce unchanged-title no-op at the durable owner so recycled editors cannot rewrite or republish the index.
        if store.sessions.first(where: { $0.id == sessionId })?.title == cleanTitle {
            return
        }
        do {
            let updated = try await store.update(id: sessionId, title: cleanTitle, archived: nil)
            indexRead.write {
                if let index = store.sessions.firstIndex(where: { $0.id == sessionId }) { store.sessions[index] = updated }
            }
            _ = await indexRead.read({ try? await store.list() }, publish: { refreshed in
                if let refreshed { store.publishSessionIndexRead(refreshed) }
            })
            present("Renamed chat session", true)
        } catch {
            present("Rename failed: \(error.localizedDescription)", false)
        }
    }
}

private func isMainAppSourceKey(_ sourceKey: String?) -> Bool {
    guard let raw = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
        return false
    }
    if raw == "app" { return true }
    return raw.hasSuffix("_app")
}

/// Resolve live routes through the current index, then one canonical refresh; transactional selection stays with AppModel.
public enum MacChatRunningSessionNavigation {
    @MainActor
    public static func navigate(
        sessionId: String,
        sessions: () -> [NativeAgentShared.ChatSession],
        refresh: () async -> Void,
        select: (NativeAgentShared.ChatSession) async -> Bool,
        isCurrentIntent: () -> Bool = { true }
    ) async -> Bool {
        guard isCurrentIntent() else { return false }
        if let current = sessions().first(where: { $0.id == sessionId }) {
            let selected = await select(current)
            return isCurrentIntent() && selected
        }
        await refresh()
        guard isCurrentIntent(),
              let refreshed = sessions().first(where: { $0.id == sessionId }) else {
            return false
        }
        let selected = await select(refreshed)
        return isCurrentIntent() && selected
    }
}

/// The conversation anchor may choose the launch default but cannot override a session the user explicitly picked.
/// Keep this process-scoped so an old launch's choice cannot outrank the user's current conversation.
@MainActor
public enum MacChatSelectionIntent {
    public private(set) static var userChoseThisLaunch = false

    /// Follow only anchors newer than the one Simple last followed or the user explicitly left.
    public static var lastSeenAnchorSessionId: String?

    /// Record explicit user selection, including sidebar picks and newly created sessions.
    public static func noteUserChoice() {
        userChoseThisLaunch = true
        lastSeenAnchorSessionId = ConversationAnchor.currentSessionId()
    }
}
