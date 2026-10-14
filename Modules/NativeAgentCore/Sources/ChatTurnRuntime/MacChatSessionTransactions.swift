import Foundation
import Observation
import Transcripts
import NativeAgentShared

/// Canonical transcript operations, implemented by the existing Core facade.
@MainActor
public protocol MacChatSessionStore: AnyObject {
    var sessions: [NativeAgentShared.ChatSession] { get set }
    func hasCachedTranscript(for sessionID: String) -> Bool
    func list() async throws -> [NativeAgentShared.ChatSession]
    func create(title: String, sourceKey: String?) async throws -> NativeAgentShared.ChatSession
    func update(id: String, title: String?, archived: Bool?) async throws -> NativeAgentShared.ChatSession
}

/// Selection is admitted in Core; committing bubbles, receipts, defaults and
/// window identity remains one synchronous MainActor presentation operation.
@MainActor
public protocol MacChatSessionSelectionPort: AnyObject {
    associatedtype ChatSessionLoadSnapshot
    var chatSelectionGeneration: Int { get set }
    var activeChatSessionId: String { get }
    func commitChatSessionSelection(_ requestedId: String, snapshot: ChatSessionLoadSnapshot?, persistSelection: Bool)
}

/// Serializes durable session-index mutations without holding an actor across
/// a re-entrant await. A newer rename intent can supersede a queued older one;
/// once a write has started, the next intent waits and writes last.
actor ChatRenameMutationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
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
    private let chatRenameMutationGate = ChatRenameMutationGate()
    private var chatRenameIntentGeneration: [String: Int] = [:]

    public private(set) var loadInFlight = false
    @ObservationIgnored private var loadCompleted = false
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []

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
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func waitForLoadCompletion() async {
        guard loadInFlight || !loadCompleted else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    public func existingMainSession(in sessions: [NativeAgentShared.ChatSession]) -> NativeAgentShared.ChatSession? {
        sessions.first(where: { isMainAppSourceKey($0.sourceKey) && $0.archived != true })
    }

    public func create(store: any MacChatSessionStore, title: String = "New Chat") async throws -> NativeAgentShared.ChatSession {
        try await store.create(title: title, sourceKey: "app")
    }

    public func reconcileStartupSession(
        store: any MacChatSessionStore
    ) async throws -> (session: NativeAgentShared.ChatSession, created: Bool) {
        if let session = existingMainSession(in: store.sessions) { return (session, false) }
        let session = try await create(store: store)
        store.sessions = [session]
        return (session, true)
    }

    public func restoreLiveRows<Message: MacChatRetryMessage>(
        messages: () -> [Message], streaming: Bool, userTurnId: String?, bubbleId: String?,
        makeUser: (String) -> Message, makeAssistant: (String) -> Message, append: (Message) -> Void
    ) {
        guard streaming else { return }
        if let userTurnId, !messages().contains(where: { $0.id == userTurnId }) {
            append(makeUser(userTurnId))
        }
        if let bubbleId, !messages().contains(where: { $0.id == bubbleId }) {
            append(makeAssistant(bubbleId))
        }
    }

    public func select<Port: MacChatSessionSelectionPort>(
        _ requestedId: String,
        persistSelection: Bool,
        port: Port,
        store: any MacChatSessionStore,
        runtime: MacChatTurnRuntime,
        presentStatus: (String) -> Void,
        load: (String) async throws -> Port.ChatSessionLoadSnapshot
    ) async {
        guard !requestedId.isEmpty else { return }
        // The human has picked a session. From here on this launch the main
        // window stops defaulting to the conversation anchor — never yank
        // someone off a session they chose.
        MacChatSelectionIntent.noteUserChoice()
        port.chatSelectionGeneration += 1
        let generation = port.chatSelectionGeneration
        let hasCachedTranscript = store.hasCachedTranscript(for: requestedId)
        let lifecycleAtLoadStart = runtime.lifecycle(for: requestedId)

        if hasCachedTranscript {
            port.commitChatSessionSelection(
                requestedId,
                snapshot: nil,
                persistSelection: persistSelection
            )
        }

        do {
            let snapshot = try await load(requestedId)
            guard port.chatSelectionGeneration == generation,
                  store.sessions.contains(where: { $0.id == requestedId }) else { return }
            if hasCachedTranscript {
                guard port.activeChatSessionId == requestedId else { return }
            }
            // A turn can start AND settle during this load, leaving no active
            // stream for commitChatSessionSelection's guard to see. Its retained
            // lifecycle is the existing evidence that the local rows/receipt
            // advanced. Still honor selection, but do not roll those rows back.
            let currentLifecycle = runtime.lifecycle(for: requestedId)
            let turnAdvanced = currentLifecycle != nil && currentLifecycle != lifecycleAtLoadStart
            port.commitChatSessionSelection(
                requestedId,
                snapshot: turnAdvanced ? nil : snapshot,
                persistSelection: persistSelection
            )
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
        // A newer request arrived while this one was waiting. Do not write an
        // obsolete title; the newest queued intent owns the durable index.
        guard chatRenameIntentGeneration[sessionId] == intent else { return }
        // Both visible rename controls already prevent an unchanged commit, but
        // keep that no-write guarantee at their shared durable owner too. A
        // recycled/focus-lost editor must not needlessly touch the session
        // index or publish a snapshot.
        if store.sessions.first(where: { $0.id == sessionId })?.title == cleanTitle {
            return
        }
        do {
            let updated = try await store.update(id: sessionId, title: cleanTitle, archived: nil)
            if let refreshed = try? await store.list() {
                store.sessions = refreshed
            } else if let index = store.sessions.firstIndex(where: { $0.id == sessionId }) {
                store.sessions[index] = updated
            }
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

/// Testable action seam for stale session-index races. A route rendered from
/// live `streamingSessions` first resolves the current index, then performs one
/// canonical refresh before admitting defeat. Selection itself remains owned
/// by AppModel's transactional selector.
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


/// Whether the human has explicitly picked a chat session since this launch.
///
/// THE RULE: the main window defaults to the conversation anchor — the remote
/// conversation User is currently in, on whichever surface — but it must NEVER
/// take him off a session he chose himself. Same protection iOS already gives
/// itself in `shouldReturnToMainSession`: a snapshot arriving mid-thought does
/// not get to move the screen.
///
/// Process-scoped rather than persisted, and that is the point. "This launch"
/// is the window in which his choice is still current; a choice from last week
/// should not outrank the conversation he is having right now.
@MainActor
public enum MacChatSelectionIntent {
    public private(set) static var userChoseThisLaunch = false

    /// The anchor Simple last followed or was taken off by a choice. Simple
    /// moves only when the anchor moves past this.
    public static var lastSeenAnchorSessionId: String?

    /// Called wherever the human's own intent selects a session — picking one
    /// in the sidebar, or creating a new one.
    public static func noteUserChoice() {
        userChoseThisLaunch = true
        lastSeenAnchorSessionId = ConversationAnchor.currentSessionId()
    }
}
