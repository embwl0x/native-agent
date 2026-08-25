import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Connectors.statusMessageSection
@MainActor
@Suite("Connectors status message", .serialized)
struct ConnectorsStatusMessageBehaviorEvalTests {
    @Test("a connector mutation reports the verified value from the mounted registry")
    func connectorToggleUsesMountedRootAndReportsVerifiedState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConnector(id: "local_files", name: "File Workspaces", enabled: false, root: root)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let loaded = try await app.client.getConnectors()
        let connector = try #require(loaded.first { $0.id == "local_files" })
        let outcome = await app.updateConnector(connector, enabled: true)

        guard case let .verified(confirmed) = outcome else {
            Issue.record("the mounted connector registry did not confirm the toggle")
            return
        }
        #expect(confirmed.enabled)
        #expect(app.connectors.first { $0.id == "local_files" }?.enabled == true)
        // A background action can update this global line after the mutation.
        // The Connectors section must retain the receipt that came from the
        // verified mutation instead of relaying unrelated application activity.
        app.statusText = "Telegram status refreshed"
        #expect(ConnectorsStatusMessagePresentation.connectorUpdate(
            connectorName: connector.name,
            enabled: true,
            outcome: outcome
        ) == .init(text: "File Workspaces is enabled.", tone: .success))
    }

    @Test("failure and workspace outcomes name the actual operation instead of a shared status")
    func adverseAndWorkspaceMessagesStaySpecific() {
        let failure = ConnectorsStatusMessagePresentation.connectorUpdate(
            connectorName: "GitHub",
            enabled: false,
            outcome: .failed("registry is unavailable")
        )
        #expect(failure.text == "Could not disable GitHub: registry is unavailable")
        #expect(failure.tone == .failure)

        let missingDetail = ConnectorsStatusMessagePresentation.connectorUpdate(
            connectorName: "GitHub",
            enabled: true,
            outcome: .failed("   ")
        )
        #expect(missingDetail.text == "Could not enable GitHub: the connector registry did not confirm the change")
        #expect(missingDetail.tone == .failure)

        let workspace = ConnectorsStatusMessagePresentation.workspaceAdd(
            name: "Projects",
            writable: true,
            outcome: .failed("workspace registry is unavailable")
        )
        #expect(workspace.text == "Could not add Projects: workspace registry is unavailable")
        #expect(workspace.tone == .failure)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("connectors-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeConnector(id: String, name: String, enabled: Bool, root: URL) throws {
        let path = root.appendingPathComponent("connectors/registry.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "enabled": .bool(enabled),
            "authState": .string("not_required"),
            "healthStatus": .string("ready"),
        ]
        let data = try JSONValue.array([.object(row)]).serializedData(pretty: false)
        try data.write(to: path, options: .atomic)
    }
}
