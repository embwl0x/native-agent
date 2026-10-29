import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
// Blueprint: | `AgentContactTaskWire.swift` | A2A wire projection of retained task and stream facts |
extension NativeAgentA2AWire {
    static func project(_ task: AgentContactTask, version: String) throws -> [String: Any] {
        try project(Self.task(task), version: version)
    }
    static func project(_ object: [String: Any], version: String) throws -> [String: Any] {
        guard version == "1.0" else {
            var object = object
            if let parts = object["parts"] as? [[String: Any]] {
                object["parts"] = try parts.map { part in
                    guard part["kind"] as? String == "data" else { return part }
                    var canonical = part; canonical.removeValue(forKey: "kind")
                    return try AgentA2AWire.wirePart(JSONValue(fromFoundation: canonical), version: "0.3").foundationObject as! [String: Any]
                }
            }
            if let artifacts = object["artifacts"] as? [[String: Any]] { object["artifacts"] = try artifacts.map { try project($0, version: version) } }
            if let artifact = object["artifact"] as? [String: Any] { object["artifact"] = try project(artifact, version: version) }
            return object
        }
        return try AgentA2AWire.canonicalObject(JSONValue(fromFoundation: object)).foundationObject as! [String: Any]
    }
    static func task(_ task: AgentContactTask) -> [String: Any] {
        var result: [String: Any] = ["kind": "task", "id": task.id, "contextId": task.context, "status": status(task)]
        let parts = task.parts.isEmpty ? (task.text.isEmpty ? [] : [AgentContactPart.text(task.text)]) : task.parts
        var artifacts: [[String: Any]] = parts.isEmpty ? [] : [["artifactId": task.id + "-reply", "parts": parts.map(\.wire03)]]
        artifacts += (task.delegatedCompletions ?? [:]).sorted { $0.key < $1.key }.map {
            ["artifactId": $0.key, "parts": [$0.value.wire03]]
        }
        if !artifacts.isEmpty { result["artifacts"] = artifacts }
        return result
    }
    private static func status(_ task: AgentContactTask) -> [String: Any] {
        var status: [String: Any] = ["state": task.state == .stopped ? "canceled" : task.state.rawValue,
            "timestamp": NativeTimestampFormat.plainZulu(task.updated)]
        if let detail = task.detail {
            status["message"] = ["kind": "message", "role": "agent", "messageId": task.id + "-status",
                "taskId": task.id, "contextId": task.context, "parts": [["kind": "text", "text": detail]]]
        }
        if let failure = task.failure,
           let data = try? JSONEncoder().encode(failure),
           let value = try? JSONSerialization.jsonObject(with: data) {
            var message = status["message"] as? [String: Any] ?? [:]
            message["metadata"] = ["provider_failure": value]
            status["message"] = message
        }
        return status
    }
    public static func event(_ event: AgentContactEvent, id: Any, version: String = "0.3") -> [String: Any] {
        if version == "1.0" {
            let legacy = Self.event(event, id: id)
            let key: String
            switch event {
            case .snapshot: key = "task"
            case .status: key = "statusUpdate"
            case .artifact: key = "artifactUpdate"
            }
            do { return result(id, [key: try project(legacy["result"] as! [String: Any], version: version)]) }
            catch { return Self.error(id, -32603, "The task update could not be encoded") }
        }
        switch event {
        case .snapshot(let task): return result(id, Self.task(task))
        case .status(let task, let final):
            return result(id, ["kind": "status-update", "taskId": task.id, "contextId": task.context, "status": status(task), "final": final])
        case .artifact(let task, let artifactID, let parts, let append, let last):
            let object: [String: Any] = ["kind": "artifact-update", "taskId": task.id, "contextId": task.context,
                "artifact": ["artifactId": artifactID, "parts": parts.map(\.wire03)], "append": append, "lastChunk": last]
            return result(id, object)
        }
    }
}
