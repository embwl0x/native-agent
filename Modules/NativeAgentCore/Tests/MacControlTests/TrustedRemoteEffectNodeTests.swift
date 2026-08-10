import Foundation
import Testing
@testable import MacControl

private func remoteNodeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("trusted-remote-node-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func sampleNode(enabled: Bool = true) -> TrustedRemoteEffectNode {
    TrustedRemoteEffectNode(
        id: "node-1",
        name: "Build Mac",
        host: "build.example.test",
        port: 2222,
        user: "builder",
        hostKeyAlgorithm: "ssh-ed25519",
        hostKey: Data(repeating: 7, count: 32).base64EncodedString(),
        allowedExecutables: ["/usr/bin/git", "/usr/bin/swift"],
        enabled: enabled
    )
}

@Test func trustedRemoteNodeStoreRoundTripsPinnedAuthorityWithoutSecrets() async throws {
    let root = try remoteNodeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TrustedRemoteEffectNodeStore(root: root)
    let saved = try await store.upsert(sampleNode())
    let rows = try await store.list()
    #expect(rows == [saved])
    #expect(saved.hostKeyFingerprint?.hasPrefix("SHA256:") == true)
    let bytes = try Data(contentsOf: root.appendingPathComponent("mac_control/trusted_remote_nodes.json"))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.lowercased().contains("password"))
    #expect(!text.lowercased().contains("privatekey"))
}

@Test func trustedRemoteNodeStoreCorruptionFailsClosedAndPreservesBytes() async throws {
    let root = try remoteNodeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mac_control/trusted_remote_nodes.json")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("[{broken".utf8)
    try corrupt.write(to: path)
    let store = TrustedRemoteEffectNodeStore(root: root)
    await #expect(throws: TrustedRemoteEffectError.corruptStore) { try await store.list() }
    await #expect(throws: TrustedRemoteEffectError.corruptStore) { try await store.upsert(sampleNode()) }
    #expect(try Data(contentsOf: path) == corrupt)
}

@Test func trustedRemoteExecutionRejectsUnknownExecutableBeforeTransport() async throws {
    let root = try remoteNodeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TrustedRemoteEffectNodeStore(root: root)
    _ = try await store.upsert(sampleNode())
    await #expect(throws: TrustedRemoteEffectError.executableDenied("/bin/sh")) {
        try await store.execute(nodeId: "node-1", executable: "/bin/sh", arguments: ["-c", "true"])
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mac_control/remote_effect_receipts.jsonl").path))
}

@Test func trustedRemoteExecutionRejectsOversizedCombinedArgumentsBeforeTransport() async throws {
    let root = try remoteNodeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TrustedRemoteEffectNodeStore(root: root)
    _ = try await store.upsert(sampleNode())
    let oversized = Array(repeating: String(repeating: "x", count: 4_096), count: 17)
    await #expect(throws: TrustedRemoteEffectError.invalidArgument("combined arguments exceed 64 KiB")) {
        try await store.execute(nodeId: "node-1", executable: "/usr/bin/git", arguments: oversized)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mac_control/remote_effect_receipts.jsonl").path))
}

@Test func trustedRemoteNodeRejectsUnboundedIdentityBeforePersistence() async throws {
    let root = try remoteNodeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TrustedRemoteEffectNodeStore(root: root)
    var node = sampleNode()
    node.host = String(repeating: "h", count: 254)
    await #expect(throws: TrustedRemoteEffectError.invalidNode("host")) {
        try await store.upsert(node)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mac_control/trusted_remote_nodes.json").path))
}
