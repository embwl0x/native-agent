import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustedRemoteEffectNodes.swift` | Reads operator-provisioned trusted node JSON and returns SSH execution receipts to the caller; unused provisioning APIs and unread receipt-file writes are retired |

public struct TrustedRemoteEffectNode: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var hostKeyAlgorithm: String
    public var hostKey: String
    public var allowedExecutables: [String]
    public var enabled: Bool
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        host: String,
        port: Int = 22,
        user: String,
        hostKeyAlgorithm: String,
        hostKey: String,
        allowedExecutables: [String],
        enabled: Bool = false,
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.hostKeyAlgorithm = hostKeyAlgorithm
        self.hostKey = hostKey
        self.allowedExecutables = allowedExecutables
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public var hostKeyFingerprint: String? {
        guard let bytes = Data(base64Encoded: hostKey) else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

public struct TrustedRemoteEffectReceipt: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let nodeId: String
    public let nodeName: String
    public let commandDigest: String
    public let executable: String
    public let startedAt: String
    public let finishedAt: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let hostKeyFingerprint: String
}

public enum TrustedRemoteEffectError: Error, LocalizedError, Equatable, Sendable {
    case corruptStore
    case invalidNode(String)
    case unknownNode(String)
    case disabledNode(String)
    case executableDenied(String)
    case invalidArgument(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .corruptStore: "remote_node_store_corrupt: Execution is disabled. Repair mac_control/trusted_remote_nodes.json under the app data root, preserving the original bytes; do not replace it with an empty list."
        case .invalidNode(let reason): "invalid_remote_node: \(reason). Correct this field in mac_control/trusted_remote_nodes.json before execution."
        case .unknownNode(let id): "remote_node_not_found: \(id). Use app {action:\"node.list\"} to select a configured node."
        case .disabledNode(let name): "remote_node_disabled: \(name). The owner must enable this node's enabled field in mac_control/trusted_remote_nodes.json before execution."
        case .executableDenied(let value): "remote_executable_denied: \(value). Choose an allowed executable from app {action:\"node.list\"}; only the owner may expand allowedExecutables in mac_control/trusted_remote_nodes.json."
        case .invalidArgument(let reason): "invalid_remote_argument: \(reason). Correct the reported argument in node.run before execution."
        case .transport(let reason): "remote_transport_failed: \(reason). Inspect the remote command's effects before another execution; correct the reported SSH connection or authentication cause in the node's host, port, user or pinned host key."
        }
    }
}

/// A narrow MacControl adapter. It owns no remote mind, memory, scheduler, or
/// tool catalog. SSH identity is pinned per invocation in a temporary
/// known_hosts file and the existing local SSH agent/keychain supplies auth.
/// Node JSON is operator-provisioned; execution returns its receipt without
/// writing a second, unread receipt store.
public final class TrustedRemoteEffectNodeStore: @unchecked Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var nodesPath: URL { root.appendingPathComponent("mac_control/trusted_remote_nodes.json") }

    public func list() async throws -> [TrustedRemoteEffectNode] {
        try loadStrict()
    }

    public func execute(
        nodeId: String,
        executable: String,
        arguments: [String],
        timeoutSeconds: Int = 60
    ) async throws -> TrustedRemoteEffectReceipt {
        let nodes = try loadStrict()
        guard let node = nodes.first(where: { $0.id == nodeId }) else {
            throw TrustedRemoteEffectError.unknownNode(nodeId)
        }
        guard node.enabled else { throw TrustedRemoteEffectError.disabledNode(node.name) }
        guard node.allowedExecutables.contains(executable) else {
            throw TrustedRemoteEffectError.executableDenied(executable)
        }
        guard arguments.count <= 64 else { throw TrustedRemoteEffectError.invalidArgument("too many arguments") }
        guard arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw TrustedRemoteEffectError.invalidArgument("arguments must be bounded single-line values")
        }
        guard arguments.reduce(into: 0, { $0 += $1.utf8.count }) <= 65_536 else {
            throw TrustedRemoteEffectError.invalidArgument("combined arguments exceed 64 KiB")
        }
        let command = ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
        let digest = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
        let started = Date()
        let result = try await Self.runSSH(
            node: node,
            command: command,
            timeoutSeconds: max(1, min(timeoutSeconds, 300))
        )
        return TrustedRemoteEffectReceipt(
            id: UUID().uuidString.lowercased(),
            nodeId: node.id,
            nodeName: node.name,
            commandDigest: digest,
            executable: executable,
            startedAt: ISO8601DateFormatter().string(from: started),
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            exitCode: result.exitCode,
            stdout: Self.bounded(result.stdout),
            stderr: Self.bounded(result.stderr + (result.timedOut
                ? (result.stderr.isEmpty ? "Timed out." : "\nTimed out.") : "")),
            hostKeyFingerprint: node.hostKeyFingerprint ?? "invalid"
        )
    }

    private func loadStrict() throws -> [TrustedRemoteEffectNode] {
        guard FileManager.default.fileExists(atPath: nodesPath.path) else { return [] }
        do {
            let data = try Data(contentsOf: nodesPath)
            return try JSONDecoder().decode([TrustedRemoteEffectNode].self, from: data)
                .map { try validate($0) }
        } catch {
            throw TrustedRemoteEffectError.corruptStore
        }
    }

    private func validate(_ node: TrustedRemoteEffectNode) throws -> TrustedRemoteEffectNode {
        let safeID = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeID.isEmpty, safeID.count <= 160 else { throw TrustedRemoteEffectError.invalidNode("id") }
        guard !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, node.name.count <= 120 else {
            throw TrustedRemoteEffectError.invalidNode("name")
        }
        let host = node.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = node.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: " \t\r\n@:/[]").union(.controlCharacters)
        guard !host.isEmpty, host.utf8.count <= 253, host.rangeOfCharacter(from: forbidden) == nil else {
            throw TrustedRemoteEffectError.invalidNode("host")
        }
        guard !user.isEmpty, user.utf8.count <= 128, user.rangeOfCharacter(from: forbidden) == nil else {
            throw TrustedRemoteEffectError.invalidNode("user")
        }
        guard (1...65_535).contains(node.port) else { throw TrustedRemoteEffectError.invalidNode("port") }
        guard ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"].contains(node.hostKeyAlgorithm),
              node.hostKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let key = Data(base64Encoded: node.hostKey), key.count >= 32 else {
            throw TrustedRemoteEffectError.invalidNode("host key")
        }
        let executables = Array(Set(node.allowedExecutables.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .sorted()
        guard !executables.isEmpty, executables.count <= 32,
              executables.allSatisfy({
                $0.hasPrefix("/")
                    && $0.utf8.count <= 1_024
                    && !$0.contains("\0")
                    && !$0.contains(where: { $0.isWhitespace })
              }) else { throw TrustedRemoteEffectError.invalidNode("allowlisted executables") }
        var copy = node
        copy.host = host
        copy.user = user
        copy.allowedExecutables = executables
        return copy
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func bounded(_ value: String) -> String {
        let bytes = Array(value.utf8.prefix(32_768))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func runSSH(
        node: TrustedRemoteEffectNode,
        command: String,
        timeoutSeconds: Int
    ) async throws -> ProcessRunResult {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(InstallPaths.current.name("nativeagent-known-hosts-\(UUID().uuidString)"))
            let hostToken = node.port == 22 ? node.host : "[\(node.host)]:\(node.port)"
            let line = "\(hostToken) \(node.hostKeyAlgorithm) \(node.hostKey)\n"
            try Data(line.utf8).write(to: temp, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: temp) }
            let arguments = [
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=no",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ControlPath=none",
                "-o", "VerifyHostKeyDNS=no",
                "-o", "KnownHostsCommand=none",
                "-o", "UserKnownHostsFile=\(temp.path)",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=\(min(timeoutSeconds, 30))",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=2",
                "-p", String(node.port),
                "\(node.user)@\(node.host)",
                command,
            ]
            try Task.checkCancellation()
            return try await SystemProcessAdapter().run(
                executable: "/usr/bin/ssh", arguments: arguments,
                currentDirectory: nil, environment: nil, standardInput: nil,
                timeoutSeconds: TimeInterval(timeoutSeconds), outputByteLimit: 32_768,
                launchFailure: { TrustedRemoteEffectError.transport($0.localizedDescription) }
            )
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }
}
