import Foundation
import NativeAgentShared
import Testing
import ToolRegistry
@testable import NativeAgentApp

/// Wave 4 closes Settings rows only through the values mounted by the real
/// SwiftUI controls, or through the production action writer followed by the
/// next reader.  No source inspection and no test-only rendering copies.
@Suite("app.settings · reports-only wave 4", .serialized)
struct SettingsReportsOnlyWave4EvalTests {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-wave4-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // ui.Capabilities.nativeActionRunButton
    @Test func missingNativeActionApprovalMetadataFailsClosedInTheMountedRunGate() {
        func action(_ approval: Bool?) -> NativeActionRecord {
            NativeActionRecord(id: "eval", name: "Eval", kind: "test", risk: "medium", requiresApproval: approval, dryRunAvailable: true)
        }
        #expect(CapabilitiesPresentation.runRequiresApproval(action(true)))
        #expect(!CapabilitiesPresentation.runRequiresApproval(action(false)))
        #expect(CapabilitiesPresentation.runRequiresApproval(action(nil)))
    }

    // ui.Tools.autoRunToggleButton
    @Test func autoRunControlTracksThePersistedWriterAndKeepsItsPriorLabelOnMalformedAuthority() async throws {
        let root = try tempRoot("auto-run")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("tools/registry.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [[
            "id": "tool-a", "name": "Tool A", "description": "test tool", "triggers": ["test"],
            "status": "active", "phase": "active", "createdAt": "2026-08-24T00:00:00Z",
            "updatedAt": "2026-08-24T00:00:00Z", "autoRun": false,
        ]]).write(to: path)

        let saved = try await NativeClient.updateTool(id: "tool-a", autoRun: true, dataRoot: root)
        #expect(saved.autoRun == true)
        #expect(AuthoredToolPresentation.autoRunTitle(saved) == "Disable Auto-run")

        let malformed = Data("{broken".utf8)
        try malformed.write(to: path, options: .atomic)
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.updateTool(id: "tool-a", autoRun: false, dataRoot: root)
        }
        #expect(try Data(contentsOf: path) == malformed)
        #expect(AuthoredToolPresentation.autoRunTitle(saved) == "Disable Auto-run")
    }

    // ui.Tools.quarantineButton
    @Test func quarantineActionRemovesTheActiveRegistryEntryAndPreservesItsQuarantinedArtifact() async throws {
        let root = try tempRoot("quarantine")
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("tools/active/tool-a", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("print(\"safe\")\n".utf8).write(to: active.appendingPathComponent("tool.swift"))
        try JSONSerialization.data(withJSONObject: [
            "id": "tool-a", "name": "Tool A", "description": "test tool", "triggers": ["test"],
            "entrypoint": "tool.swift", "permissions": ["app_data_read"],
            "status": "active", "phase": "active", "createdAt": "2026-08-24T00:00:00Z",
        ]).write(to: active.appendingPathComponent("manifest.json"))
        let registry = root.appendingPathComponent("tools/registry.json")
        try JSONSerialization.data(withJSONObject: [[
            "id": "tool-a", "name": "Tool A", "description": "test tool", "triggers": ["test"],
            "status": "active", "phase": "active", "createdAt": "2026-08-24T00:00:00Z",
            "updatedAt": "2026-08-24T00:00:00Z", "activePath": active.path,
        ]]).write(to: registry)

        let client = NativeClient(baseURL: "http://localhost", dataRootOverride: root)
        let quarantined = try await client.quarantineTool(id: "tool-a", reason: "operator requested")
        #expect(quarantined.status == "quarantined")
        let quarantinePath = try #require(quarantined.quarantinePath)
        #expect(quarantinePath == root.appendingPathComponent("tools/quarantine/tool-a").path)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: quarantinePath).appendingPathComponent("manifest.json").path
        ))
        #expect(FileManager.default.fileExists(atPath: active.path),
                "quarantine preserves the signed active artifact while taking its registry row out of active state")
        #expect(try await SwiftNativeToolRegistry(root: root).listTools(filter: .status("active")).isEmpty)
        #expect(!AuthoredToolPresentation.canQuarantine(quarantined))
    }

    // ui.Status.recentActivityPanel
    @Test func recentActivityProjectionShowsTheNewestEightInNewestFirstOrder() throws {
        let decoder = JSONDecoder()
        let events = try (0..<200).map { index in
            try decoder.decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: [
                "id": "event-\(index)", "kind": "eval", "title": "Event \(index)",
                "status": "ok", "createdAt": "2026-08-24T00:00:00Z",
            ]))
        }
        #expect(StatusActivityPresentation.recentEvents(from: events).map(\.id) == [
            "event-199", "event-198", "event-197", "event-196", "event-195", "event-194", "event-193", "event-192",
        ])
    }
}
