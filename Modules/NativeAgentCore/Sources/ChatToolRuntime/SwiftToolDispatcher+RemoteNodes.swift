import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore

extension SwiftToolDispatcher {
    func impl_remote_node_list() async throws -> JSONValue {
        let rows = try await TrustedRemoteEffectNodeStore(root: dataRoot).list()
        return .object([
            "status": .string("ok"),
            "authority": .string("MacControl trusted remote effect nodes; no remote mind, memory, or scheduler"),
            "nodes": .array(rows.map { node in
                .object([
                    "id": .string(node.id),
                    "name": .string(node.name),
                    "host": .string(node.host),
                    "port": .int(Int64(node.port)),
                    "user": .string(node.user),
                    "enabled": .bool(node.enabled),
                    "host_key_fingerprint": node.hostKeyFingerprint.map(JSONValue.string) ?? .null,
                    "allowed_executables": .array(node.allowedExecutables.map(JSONValue.string)),
                ])
            }),
        ])
    }

    func impl_remote_node_execute(input: [String: JSONValue]) async throws -> JSONValue {
        guard case .string(let nodeId)? = input["node_id"], !nodeId.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "remote_node_execute requires node_id")
        }
        guard case .string(let executable)? = input["executable"], !executable.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "remote_node_execute requires an absolute executable")
        }
        let arguments: [String]
        if case .array(let raw)? = input["arguments"] {
            arguments = try raw.map {
                guard case .string(let value) = $0 else {
                    throw AutonomyGateError.toolDenied(reason: "remote_node_execute arguments must be strings")
                }
                return value
            }
        } else {
            arguments = []
        }
        let timeout: Int
        if case .int(let value)? = input["timeout_seconds"] { timeout = Int(value) } else { timeout = 60 }
        do {
            let receipt = try await TrustedRemoteEffectNodeStore(root: dataRoot).execute(
                nodeId: nodeId,
                executable: executable,
                arguments: arguments,
                timeoutSeconds: timeout
            )
            return .object([
                "status": .string(receipt.exitCode == 0 ? "completed" : "failed"),
                "receipt_id": .string(receipt.id),
                "node_id": .string(receipt.nodeId),
                "node_name": .string(receipt.nodeName),
                "command_digest": .string(receipt.commandDigest),
                "executable": .string(receipt.executable),
                "exit_code": .int(Int64(receipt.exitCode)),
                "stdout": .string(receipt.stdout),
                "stderr": .string(receipt.stderr),
                "host_key_fingerprint": .string(receipt.hostKeyFingerprint),
                "started_at": .string(receipt.startedAt),
                "finished_at": .string(receipt.finishedAt),
            ])
        } catch {
            throw AutonomyGateError.toolDenied(reason: error.localizedDescription)
        }
    }
}
