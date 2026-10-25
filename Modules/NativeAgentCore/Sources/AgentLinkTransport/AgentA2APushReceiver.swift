import Foundation
import PersistenceCore
// Blueprint: | `AgentA2APushReceiver.swift` | `AgentA2APushReceiver` actor; `receive`, `consume`; authenticated task pushes invalidate the continuation through its canonical record writer; an owned invalidator registers before reads, replays pending hints, and retires on resident stop. Continuation startup makes saved waiting A2A task reads due after registering the invalidator, reconciling deadlines whose process-local push proof was lost at restart. The bounded mailbox retains current-process proof of delivery for each peer/task after consumption: proven push suspends sampling only after a validated task read; unavailable, invalid or thrown reads retain their short deadlines, while absent proof or an ended stream without push keeps fallback reads; GetTask stays authoritative and the one-day boundary remains |

/// A bounded delivery mailbox, not task state: authenticated webhook evidence
/// is validated then reduced to a wake hint. GetTask remains authoritative.
public actor AgentA2APushReceiver {
    public static let shared = AgentA2APushReceiver()
    private var hints: [(peer: String, task: String, pending: Bool)] = []
    private var invalidator: (owner: UUID, wake: @Sendable (String, String) -> Void)?

    /// The continuation's existing store writer owns scheduling. Install before
    /// reading its rows and replay retained hints to close the registration race.
    public func installInvalidator(owner: UUID, wake: @escaping @Sendable (String, String) -> Void) {
        guard invalidator?.owner != owner, !Task.isCancelled else { return }
        invalidator = (owner, wake)
        for hint in hints where hint.pending { wake(hint.peer, hint.task) }
    }

    public func removeInvalidator(owner: UUID) {
        if invalidator?.owner == owner { invalidator = nil }
    }

    public func receive(value: JSONValue, peerID: String) throws {
        guard !peerID.isEmpty, case .object(let envelope) = value else { throw AgentA2AWire.WireError.invalid("push notification") }
        let keys = ["task", "message", "statusUpdate", "artifactUpdate"].filter { envelope[$0] != nil }
        guard keys.count == 1, case .object(let payload)? = envelope[keys[0]] else { throw AgentA2AWire.WireError.invalid("push StreamResponse") }
        let interface = AgentA2AWire.Interface(endpoint: URL(string: "http://127.0.0.1")!, version: "1.0", binding: "HTTP+JSON")
        let taskID: String?
        if keys[0] == "task" || keys[0] == "message" {
            taskID = try AgentA2AWire.normalizeResponse(value, interface: interface).taskID
        } else {
            guard case .string(let id)? = payload["taskId"], !id.isEmpty,
                  case .string(let context)? = payload["contextId"], !context.isEmpty else { throw AgentA2AWire.WireError.invalid("push task identity") }
            // A push delta need not be preceded by an initial task snapshot.
            // Supply only identity to the same streaming validator.
            let seed: JSONValue = .object(["task": .object(["id": .string(id), "contextId": .string(context),
                "status": .object(["state": .string("TASK_STATE_WORKING")])])])
            _ = try AgentA2AStream.normalize([seed, value], interface: interface, requestID: nil, expectedTaskID: id)
            taskID = id
        }
        guard let taskID else { return } // A direct message has no GetTask route.
        hints.removeAll { $0.peer == peerID && $0.task == taskID }
        hints.append((peerID, taskID, true))
        if hints.count > 128 { hints.removeFirst(hints.count - 128) }
        invalidator?.wake(peerID, taskID)
    }

    public func consume(peerID: String, taskID: String) -> Bool {
        guard let index = hints.firstIndex(where: { $0.peer == peerID && $0.task == taskID && $0.pending }) else { return false }
        hints[index].pending = false
        return true
    }

    /// A card's capability alone cannot prove its callback reaches this app.
    /// One authenticated delivery establishes push support for this exact task.
    public func hasReceived(peerID: String, taskID: String) -> Bool {
        hints.contains { $0.peer == peerID && $0.task == taskID }
    }
}
