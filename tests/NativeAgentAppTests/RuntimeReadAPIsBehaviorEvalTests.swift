import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("app.runtimes · NativeClient runtime read APIs", .serialized)
struct RuntimeReadAPIsBehaviorEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-read-apis-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workflow(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string("Seeded runtime read workflow"),
            "status": .string("active"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object([
                    "id": .string("trace"),
                    "kind": .string("trace"),
                ]),
            ]),
        ])
    }

    @Test("runtime reads use their injected root and retain empty versus unreadable feed truth")
    func readsSeededRowsAndRejectsUnreadableFeeds() async throws {
        let root = try root("seeded")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let health = try await client.getHealth()
        #expect(health.dataDir == root.path)

        _ = try await client.createWorkflow(workflow(id: "runtime-read-workflow"))
        let capabilities = try await client.getCapabilities()
        #expect(capabilities.records.contains(where: { $0.id == "workflow:runtime-read-workflow" }),
                "capability aggregation must read the workflow seeded beneath this client root")

        let profile = root
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("profile.json")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"Seeded Runtime Persona"}"#.utf8).write(to: profile)
        let personalOS = try await client.getPersonalOS()
        #expect(personalOS.spaces == [
            PersonalOSSpace(id: "persona", name: "Seeded Runtime Persona", count: 1, kind: "persona"),
        ])

        let tracePath = CapabilityTraceFeed.path(in: root)
        try FileManager.default.createDirectory(at: tracePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tracePath)
        let emptyTraces = try await client.getTraces()
        #expect(emptyTraces.isEmpty,
                "an existing empty trace feed is a successful empty read")

        let seededTrace = RuntimeTrace(
            id: "runtime-read-trace",
            kind: "workflow.run",
            title: "Seeded runtime trace",
            status: "ok",
            createdAt: "2026-08-24T00:00:00Z"
        )
        try JSONEncoder().encode(seededTrace).write(to: tracePath)
        let traces = try await client.getTraces()
        #expect(traces.map(\.id) == ["runtime-read-trace"])

        let corruptTrace = Data("{not-json}\\n".utf8)
        try corruptTrace.write(to: tracePath)
        await #expect(throws: (any Error).self) {
            _ = try await client.getTraces()
        }
        #expect(try Data(contentsOf: tracePath) == corruptTrace,
                "a failed read must not replace the authoritative feed with an empty one")

        let corruptProfile = Data("{not-json}".utf8)
        try corruptProfile.write(to: profile)
        await #expect(throws: (any Error).self) {
            _ = try await client.getPersonalOS()
        }
        #expect(try Data(contentsOf: profile) == corruptProfile)
    }
}
