import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Connector registry mutation")
struct ConnectorRegistryMutationTests {
    @Test func unsupportedConnectorCannotBeEnabledOrMutateRegistryTruth() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try writeRegistry([
            "id": .string("linear"),
            "enabled": .bool(false),
            "authState": .string("needs_auth"),
            "healthStatus": .string("needs_auth"),
        ], root: root)
        let before = try Data(contentsOf: path)

        await #expect(throws: Error.self) {
            _ = try await NativeClient(baseURL: "").updateConnector(id: "linear", enabled: true, root: root)
        }

        #expect(try Data(contentsOf: path) == before)
    }

    @Test func configuredNotionConnectorRetainsItsRegistryToggle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeRegistry([
            "id": .string("notion"),
            "enabled": .bool(true),
            "authState": .string("connected"),
            "healthStatus": .string("ok"),
        ], root: root)

        let updated = try await NativeClient(baseURL: "").updateConnector(
            id: "notion",
            enabled: false,
            root: root
        )

        #expect(!updated.enabled)
        let saved = try await #require(
            NativeClient.readConnectorRegistryEntry(root: root, provider: "notion")
        )
        #expect(saved["enabled"] == .bool(false))
    }

    @Test func unconfiguredOAuthConnectorCannotBeEnabled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try writeRegistry([
            "id": .string("gmail"),
            "enabled": .bool(false),
            "authState": .string("needs_auth"),
            "healthStatus": .string("needs_auth"),
        ], root: root)
        let before = try Data(contentsOf: path)
        let saved = ProcessInfo.processInfo.environment["NATIVE_AGENT_GMAIL_CLIENT_ID"]
        unsetenv("NATIVE_AGENT_GMAIL_CLIENT_ID")
        defer { if let saved { setenv("NATIVE_AGENT_GMAIL_CLIENT_ID", saved, 1) } }

        await #expect(throws: Error.self) {
            _ = try await NativeClient(baseURL: "").updateConnector(id: "gmail", enabled: true, root: root)
        }

        #expect(try Data(contentsOf: path) == before)
    }

    @Test func localWorkspaceConnectorRetainsItsRealEnableControl() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeRegistry([
            "id": .string("local_files"),
            "name": .string("Local File Workspaces"),
            "enabled": .bool(false),
            "authState": .string("not_required"),
            "healthStatus": .string("ready"),
        ], root: root)

        let updated = try await NativeClient(baseURL: "").updateConnector(
            id: "local_files",
            enabled: true,
            root: root
        )

        #expect(updated.enabled)
        let saved = try await #require(
            NativeClient.readConnectorRegistryEntry(root: root, provider: "local_files")
        )
        #expect(saved["enabled"] == .bool(true))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectorRegistryMutationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeRegistry(
        _ row: [String: JSONValue],
        root: URL
    ) throws -> URL {
        let path = root.appendingPathComponent("connectors/registry.json")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONValue.array([.object(row)]).serializedData(pretty: true)
            .write(to: path, options: .atomic)
        return path
    }
}
