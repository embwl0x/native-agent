import Foundation
import PersistenceCore

/// A bounded delivery mailbox, not task state: authenticated webhook evidence
/// is validated then reduced to a wake hint. GetTask remains authoritative.
public actor AgentA2APushReceiver {
    public static let shared = AgentA2APushReceiver()
    private var hints: [(peer: String, task: String)] = []

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
        hints.append((peerID, taskID))
        if hints.count > 128 { hints.removeFirst(hints.count - 128) }
    }

    public func consume(peerID: String, taskID: String) -> Bool {
        guard let index = hints.firstIndex(where: { $0.peer == peerID && $0.task == taskID }) else { return false }
        hints.remove(at: index)
        return true
    }
}
