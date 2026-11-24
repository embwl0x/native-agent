import Foundation
import MacNerves
import NativeAgentCore
import PersistenceCore
// Blueprint: | `FileActions+RemoteNodes.swift` | `SwiftToolDispatcher`; SSH admission; unknown effects on Stop |

struct RemoteNodeExecuteArgs: DoorArgs {
    static let nodeIDField = DoorFieldDescriptor.string("node_id", "Required node id from node.list.", required: true)
    static let executableField = DoorFieldDescriptor.string("executable", "Required absolute executable path; must exactly match the node allowlist.", required: true)
    static let argumentsField = DoorFieldDescriptor.strings("arguments", """
        Optional argv values. Values are individually shell-quoted; multiline/NUL arguments are rejected.
        """)
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 60, clamped 1...300.")
    static let doorFields = [nodeIDField, executableField, argumentsField, timeoutSecondsField]
    let nodeID: String
    let executable: String
    let arguments: [String]?
    let timeoutSeconds: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        nodeID = try door.requiredString(Self.nodeIDField)
        executable = try door.requiredString(Self.executableField)
        arguments = try door.strings(Self.argumentsField)
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
    }
}

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

    func impl_remote_node_execute(input: RemoteNodeExecuteArgs) async throws -> JSONValue {
        let nodeId = input.nodeID
        guard !nodeId.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "remote_node_execute requires node_id")
        }
        let executable = input.executable
        guard !executable.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "remote_node_execute requires an absolute executable")
        }
        let arguments = input.arguments ?? []
        let timeout = input.timeoutSeconds ?? 60
        do {
            let receipt = try await TrustedRemoteEffectNodeStore(root: dataRoot).execute(
                nodeId: nodeId,
                executable: executable,
                arguments: arguments,
                timeoutSeconds: timeout
            )
            var output: [String: JSONValue] = [
                "status": .string(receipt.cancelled ? "cancelled" : receipt.exitCode == 0 ? "completed" : "failed"),
                "receipt_id": .string(receipt.id),
                "node_id": .string(receipt.nodeId),
                "node_name": .string(receipt.nodeName),
                "command_digest": .string(receipt.commandDigest),
                "executable": .string(receipt.executable),
                "exit_code": .int(Int64(receipt.exitCode)),
                "stdout": .string(receipt.stdout),
                "stderr": .string(receipt.stderr),
                "stdout_truncated": .bool(receipt.stdoutTruncated),
                "stderr_truncated": .bool(receipt.stderrTruncated),
                "timed_out": .bool(receipt.timedOut),
                "host_key_fingerprint": .string(receipt.hostKeyFingerprint),
                "started_at": .string(receipt.startedAt),
                "finished_at": .string(receipt.finishedAt),
            ]
            if receipt.cancelled {
                output["effects"] = .string("unknown")
                output["detail"] = .string("""
                    Local SSH was stopped. The remote command may still have taken effect; inspect the retained output and remote state before \
                    another execution.
                    """)
            }
            return .object(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TrustedRemoteEffectError {
            switch error {
            case .transport:
                throw ToolFailureError(error.localizedDescription, effects: .unknown)
            default:
                throw AutonomyGateError.toolDenied(reason: error.localizedDescription)
            }
        }
    }
}
