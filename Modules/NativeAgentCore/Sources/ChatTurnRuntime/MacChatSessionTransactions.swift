import Foundation
import NativeAgentShared

/// Canonical transcript operations, implemented by the existing Core facade.
@MainActor
public protocol MacChatSessionStore: AnyObject {
    var sessions: [NativeAgentShared.ChatSession] { get set }
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
    func noteChatSessionUserChoice()
    func hasCachedChatTranscript(for sessionID: String) -> Bool
    func containsChatSession(_ sessionID: String) -> Bool
    func chatSessionLifecycle(for sessionID: String) -> MacChatTurnLifecycleState?
    func commitChatSessionSelection(_ requestedId: String, snapshot: ChatSessionLoadSnapshot?, persistSelection: Bool)
    func presentChatSessionStatus(_ text: String)
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
public final class MacChatSessionTransactions {
    private let chatRenameMutationGate = ChatRenameMutationGate()
    private var chatRenameIntentGeneration: [String: Int] = [:]

    public init() {}

    public func existingMainSession(in sessions: [NativeAgentShared.ChatSession]) -> NativeAgentShared.ChatSession? {
        sessions.first(where: { isMainAppSourceKey($0.sourceKey) && $0.archived != true })
    }

    public func create(store: any MacChatSessionStore) async throws -> NativeAgentShared.ChatSession {
        try await store.create(title: "New Chat", sourceKey: "app")
    }

    public func select<Port: MacChatSessionSelectionPort>(
        _ requestedId: String,
        persistSelection: Bool,
        port: Port,
        load: (String) async throws -> Port.ChatSessionLoadSnapshot
    ) async {
        guard !requestedId.isEmpty else { return }
        // The human has picked a session. From here on this launch the main
        // window stops defaulting to the conversation anchor — never yank
        // someone off a session they chose.
        port.noteChatSessionUserChoice()
        port.chatSelectionGeneration += 1
        let generation = port.chatSelectionGeneration
        let hasCachedTranscript = port.hasCachedChatTranscript(for: requestedId)
        let lifecycleAtLoadStart = port.chatSessionLifecycle(for: requestedId)

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
                  port.containsChatSession(requestedId) else { return }
            if hasCachedTranscript {
                guard port.activeChatSessionId == requestedId else { return }
            }
            // A turn can start AND settle during this load, leaving no active
            // stream for commitChatSessionSelection's guard to see. Its retained
            // lifecycle is the existing evidence that the local rows/receipt
            // advanced. Still honor selection, but do not roll those rows back.
            let currentLifecycle = port.chatSessionLifecycle(for: requestedId)
            let turnAdvanced = currentLifecycle != nil && currentLifecycle != lifecycleAtLoadStart
            port.commitChatSessionSelection(
                requestedId,
                snapshot: turnAdvanced ? nil : snapshot,
                persistSelection: persistSelection
            )
        } catch {
            if port.chatSelectionGeneration == generation {
                port.presentChatSessionStatus("Chat session load failed: \(error.localizedDescription)")
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
