import Foundation
import PersistenceCore
// Blueprint: | `TurnFirstRenderRegistry.swift` | Bounded single-claim first-render correlation and publication |

/// Correlates the Mac UI's first visible assistant bubble with the turn trace
/// without putting UI concerns into the provider loop. Entries are bounded and
/// single-claim: an old bubble or a later delta cannot emit a duplicate render.
public actor TurnFirstRenderRegistry {
    public static let shared = TurnFirstRenderRegistry()

    private struct Pending: Sendable {
        let turnId: String
        let surface: String
        let registeredAtUptimeNs: UInt64
    }

    private let maximumEntries: Int
    private var pendingBySession: [String: Pending] = [:]
    private var insertionOrder: [String] = []

    public init(maximumEntries: Int = 256) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func register(turnId: String, sessionId: String, surface: String) {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turnId.isEmpty, !session.isEmpty else { return }
        if pendingBySession[session] == nil { insertionOrder.append(session) }
        pendingBySession[session] = Pending(
            turnId: turnId,
            surface: surface,
            registeredAtUptimeNs: DispatchTime.now().uptimeNanoseconds
        )
        while insertionOrder.count > maximumEntries {
            pendingBySession.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    /// The mounted surface reports visibility; correlation and publication
    /// remain with the registry that owns the turn's single render claim.
    public func observeFirstRender(
        role: String,
        content: String,
        isLastAssistant: Bool,
        messageSessionID: String?,
        messageTurnID: String?,
        activeSessionID: String,
        observedBy: String
    ) {
        guard role == "assistant", isLastAssistant,
              content.contains(where: { !$0.isWhitespace }) else { return }
        // A present-but-blank message session must not claim the active tab.
        let sessionID = (messageSessionID ?? activeSessionID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, let turnID = messageTurnID, !turnID.isEmpty,
              let event = claimFirstRenderEvent(
                sessionId: sessionID, turnId: turnID, observedBy: observedBy
              ) else { return }
        TurnTraceBus.fire(event)
    }

    public func claimFirstRenderEvent(
        sessionId: String,
        turnId: String,
        observedBy: String
    ) -> TurnTraceEvent? {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, let pending = pendingBySession[session], pending.turnId == turnId else {
            return nil
        }
        pendingBySession.removeValue(forKey: session)
        insertionOrder.removeAll { $0 == session }
        let elapsedMs = Int64(
            (DispatchTime.now().uptimeNanoseconds &- pending.registeredAtUptimeNs) / 1_000_000
        )
        return TurnTraceEvent(
            turnId: pending.turnId,
            kind: "surface.firstRender",
            sessionId: session,
            surface: pending.surface,
            payload: .object([
                "schema": .string("turn.lifecycle.v1"),
                "milestone": .string("surface.firstRender"),
                "observedBy": .string(observedBy),
                "elapsedMs": .int(elapsedMs),
            ])
        )
    }
}
