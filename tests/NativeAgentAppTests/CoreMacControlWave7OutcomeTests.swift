import Foundation
import MacControl
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("core.maccontrol · remote node configuration outcomes", .serialized)
struct CoreMacControlWave7OutcomeTests {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-nodes-wave7-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func saveDisableAndDeleteMutateTheExecutorStore() async throws {
        let root = try tempRoot("crud")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let store = TrustedRemoteEffectNodeStore(root: root)
        let validKey = Data(repeating: 0x42, count: 32).base64EncodedString()
        let draft = RemoteNodeDraft(
            name: "Build Mac",
            host: "example.invalid",
            user: "builder",
            hostKey: validKey,
            allowedExecutables: "/usr/bin/swift",
            enabled: true
        )
        let initialSave = await RemoteNodeConfigurationAction.save(
            draft: draft,
            selectedID: nil,
            client: client
        )
        let enabled = try #require({
            if case let .saved(node) = initialSave { return node }
            return nil
        }())
        #expect(enabled.hostKey == validKey)
        #expect(Data(base64Encoded: enabled.hostKey)?.count == 32)

        var disabledDraft = RemoteNodeDraft(enabled)
        disabledDraft.enabled = false
        let disableSave = await RemoteNodeConfigurationAction.save(
            draft: disabledDraft,
            selectedID: enabled.id,
            client: client
        )
        let disabled = try #require({
            if case let .saved(node) = disableSave { return node }
            return nil
        }())
        #expect(disabled.id == enabled.id)
        #expect(RemoteNodeConfigurationAction.nodeStateText(enabled: disabled.enabled) == "Disabled")
        let rowsAfterDisable = try await store.list()
        #expect(rowsAfterDisable == [disabled])
        await #expect(throws: TrustedRemoteEffectError.self) {
            _ = try await store.execute(
                nodeId: disabled.id,
                executable: "/usr/bin/swift",
                arguments: []
            )
        }

        let delete = await RemoteNodeConfigurationAction.delete(selectedID: disabled.id, client: client)
        #expect(delete == .deleted)
        let rowsAfterDelete = try await store.list()
        #expect(rowsAfterDelete.isEmpty)
    }

    @Test func saveSurfacesInvalidHostKeyWithoutWritingARecord() async throws {
        let root = try tempRoot("invalid-key")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let store = TrustedRemoteEffectNodeStore(root: root)
        let invalidDraft = RemoteNodeDraft(
            name: "Invalid Mac",
            host: "example.invalid",
            user: "builder",
            hostKey: Data("ten-byte-key".utf8).base64EncodedString(),
            allowedExecutables: "/usr/bin/swift",
            enabled: true
        )
        let outcome = await RemoteNodeConfigurationAction.save(
            draft: invalidDraft,
            selectedID: nil,
            client: client
        )
        let storedNodes = try await store.list()
        #expect(storedNodes.isEmpty)
        #expect(outcome.errorMessage?.contains("host key") == true)
    }
}
