import CryptoKit
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore

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
        case .corruptStore: "Trusted remote node configuration is corrupt; execution is disabled until it is repaired."
        case .invalidNode(let reason): "Invalid trusted remote node: \(reason)"
        case .unknownNode(let id): "Unknown trusted remote node: \(id)"
        case .disabledNode(let name): "Trusted remote node is disabled: \(name)"
        case .executableDenied(let value): "Remote executable is not allowlisted: \(value)"
        case .invalidArgument(let reason): "Invalid remote argument: \(reason)"
        case .transport(let reason): "Remote execution failed: \(reason)"
        }
    }
}

/// A narrow MacControl adapter. It owns no remote mind, memory, scheduler, or
/// tool catalog. SSH identity is pinned per invocation in a temporary
/// known_hosts file and the existing local SSH agent/keychain supplies auth.
public final class TrustedRemoteEffectNodeStore: @unchecked Sendable {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore

    public init(root: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.root = root
        self.persistence = persistence
    }

    private var nodesPath: URL { root.appendingPathComponent("mac_control/trusted_remote_nodes.json") }
    private var receiptsPath: URL { root.appendingPathComponent("mac_control/remote_effect_receipts.jsonl") }

    public func list() async throws -> [TrustedRemoteEffectNode] {
        try loadStrict()
    }

    public func upsert(_ node: TrustedRemoteEffectNode) async throws -> TrustedRemoteEffectNode {
        var normalized = try validate(node)
        normalized.updatedAt = ISO8601DateFormatter().string(from: Date())
        let captured = normalized
        return try await persistence.withFileLock(nodesPath) {
            var rows = try self.loadStrict()
            if let index = rows.firstIndex(where: { $0.id == captured.id }) {
                rows[index] = captured
            } else {
                rows.append(captured)
            }
            try self.write(rows)
            return captured
        }
    }

    public func remove(id: String) async throws {
        try await persistence.withFileLock(nodesPath) {
            var rows = try self.loadStrict()
            rows.removeAll { $0.id == id }
            try self.write(rows)
        }
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
        let receipt = TrustedRemoteEffectReceipt(
            id: UUID().uuidString.lowercased(),
            nodeId: node.id,
            nodeName: node.name,
            commandDigest: digest,
            executable: executable,
            startedAt: ISO8601DateFormatter().string(from: started),
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            exitCode: result.status,
            stdout: Self.bounded(result.stdout),
            stderr: Self.bounded(result.stderr),
            hostKeyFingerprint: node.hostKeyFingerprint ?? "invalid"
        )
        let data = try JSONEncoder().encode(receipt)
        let value = try JSONValue.parse(data)
        try await appendJSONLCapped(
            value,
            to: receiptsPath,
            using: persistence,
            maxLines: 500,
            logLabel: "trusted-remote-effects",
            maxBytes: 2_000_000,
            trimToBytes: 1_500_000
        )
        return receipt
    }

    private func loadStrict() throws -> [TrustedRemoteEffectNode] {
        guard FileManager.default.fileExists(atPath: nodesPath.path) else { return [] }
        do {
            let data = try Data(contentsOf: nodesPath)
            return try JSONDecoder().decode([TrustedRemoteEffectNode].self, from: data)
        } catch {
            throw TrustedRemoteEffectError.corruptStore
        }
    }

    private func write(_ rows: [TrustedRemoteEffectNode]) throws {
        try FileManager.default.createDirectory(at: nodesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: nodesPath, options: .atomic)
    }

    private func validate(_ node: TrustedRemoteEffectNode) throws -> TrustedRemoteEffectNode {
        let safeID = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeID.isEmpty, safeID.count <= 160 else { throw TrustedRemoteEffectError.invalidNode("id") }
        guard !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, node.name.count <= 120 else {
            throw TrustedRemoteEffectError.invalidNode("name")
        }
        let host = node.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = node.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: " \t\r\n@:/[]")
        guard !host.isEmpty, host.utf8.count <= 253, host.rangeOfCharacter(from: forbidden) == nil else {
            throw TrustedRemoteEffectError.invalidNode("host")
        }
        guard !user.isEmpty, user.utf8.count <= 128, user.rangeOfCharacter(from: forbidden) == nil else {
            throw TrustedRemoteEffectError.invalidNode("user")
        }
        guard (1...65_535).contains(node.port) else { throw TrustedRemoteEffectError.invalidNode("port") }
        guard ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"].contains(node.hostKeyAlgorithm),
              let key = Data(base64Encoded: node.hostKey), key.count >= 32 else {
            throw TrustedRemoteEffectError.invalidNode("host key")
        }
        let executables = Array(Set(node.allowedExecutables.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter {
                $0.hasPrefix("/")
                    && $0.utf8.count <= 1_024
                    && !$0.contains("\0")
                    && !$0.contains(where: { $0.isWhitespace })
            }
            .sorted()
        guard !executables.isEmpty, executables.count <= 32 else { throw TrustedRemoteEffectError.invalidNode("allowlisted executables") }
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

    /// Drain the pipe completely so the child cannot block, while retaining at
    /// most `limit` bytes. Bounding after `readDataToEndOfFile()` is too late:
    /// an untrusted remote process could otherwise make this Mac allocate its
    /// entire output before the receipt truncation ran.
    private static func drain(_ handle: FileHandle, retaining limit: Int) -> Data {
        var retained = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 8_192),
                  !chunk.isEmpty else { break }
            let remaining = max(0, limit - retained.count)
            if remaining > 0 { retained.append(chunk.prefix(remaining)) }
        }
        return retained
    }

    private struct ProcessResult: Sendable { let status: Int32; let stdout: String; let stderr: String }

    private static func runSSH(
        node: TrustedRemoteEffectNode,
        command: String,
        timeoutSeconds: Int
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nativeagent-known-hosts-\(UUID().uuidString)")
            let hostToken = node.port == 22 ? node.host : "[\(node.host)]:\(node.port)"
            let line = "\(hostToken) \(node.hostKeyAlgorithm) \(node.hostKey)\n"
            try Data(line.utf8).write(to: temp, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: temp) }
            let out = Pipe()
            let err = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=no",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(temp.path)",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=\(min(timeoutSeconds, 30))",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=2",
                "-p", String(node.port),
                "\(node.user)@\(node.host)",
                command,
            ]
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { throw TrustedRemoteEffectError.transport(error.localizedDescription) }
            async let stdoutData = Task.detached(priority: .utility) {
                Self.drain(out.fileHandleForReading, retaining: 32_768)
            }.value
            async let stderrData = Task.detached(priority: .utility) {
                Self.drain(err.fileHandleForReading, retaining: 32_768)
            }.value
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
            while process.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate()
                let grace = clock.now.advanced(by: .seconds(2))
                while process.isRunning && clock.now < grace { try? await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let data = await (stdoutData, stderrData)
            let stdout = String(decoding: data.0, as: UTF8.self)
            var stderr = String(decoding: data.1, as: UTF8.self)
            if timedOut { stderr += stderr.isEmpty ? "Timed out." : "\nTimed out." }
            return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}
