import Foundation
import PersistenceCore
import Testing
import TrustCenter
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / client.improvementsCapabilityPacks

@Suite("Native client capability-pack receipts")
struct NativeClientImprovementsCapabilityPacksEvalTests {
    @Test("capability pack receipts are durable, ordered, and never silently emptied when their authority is damaged")
    func receiptsRemainHonestAcrossBootstrapReloadAndMalformedAuthority() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let installsPath = root.appendingPathComponent("catalog/installs.json")

        // No file is the one valid empty state, and reading it must not
        // fabricate an authority file.
        let bootstrap = try await client.getCapabilityPackInstalls()
        #expect(bootstrap.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installsPath.path))

        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root,
            persistence: SwiftNativePersistenceCore()
        )
        let first = try await client.installCapabilityPack(
            try await signer.sign(pack(id: "capability-pack-first", name: "First Pack"))
        )
        let second = try await client.installCapabilityPack(
            try await signer.sign(pack(id: "capability-pack-second", name: "Second Pack"))
        )
        #expect(first.status == "installed")
        #expect(second.status == "installed")

        let reloaded = NativeClient(baseURL: "", dataRootOverride: root)
        let durable = try await reloaded.getCapabilityPackInstalls()
        #expect(Set(durable.map(\.id)) == Set([first.id, second.id]))
        #expect(durable.allSatisfy { $0.status == "installed" && !$0.packId.isEmpty })

        let rolledBack = try await reloaded.rollbackCapabilityPack(id: first.id)
        #expect(rolledBack.status == "rolled_back")
        let postRollbackClient = NativeClient(baseURL: "", dataRootOverride: root)
        let afterRollback = try await postRollbackClient.getCapabilityPackInstalls()
        #expect(afterRollback.first(where: { $0.id == first.id })?.status == "rolled_back")

        try Data("{not json".utf8).write(to: installsPath, options: .atomic)
        do {
            _ = try await NativeClient(baseURL: "", dataRootOverride: root).getCapabilityPackInstalls()
            Issue.record("A malformed capability-pack receipt store must not become an empty installs list.")
        } catch {
            #expect(error.localizedDescription.contains("capability catalog store malformed"))
        }
        #expect(try Data(contentsOf: installsPath) == Data("{not json".utf8))

        try Data("{\"not\":\"an install array\"}".utf8).write(to: installsPath, options: .atomic)
        do {
            _ = try await NativeClient(baseURL: "", dataRootOverride: root).getCapabilityPackInstalls()
            Issue.record("A non-array capability-pack receipt store must be unavailable, not empty.")
        } catch {
            #expect(error.localizedDescription.contains("expected a JSON array"))
        }

        // Replace the malformed bytes with an incomplete receipt and prove it
        // is also refused at the read boundary rather than decoded as an install.
        try Data("[{\"id\":\"install:broken\",\"status\":\"installed\"}]".utf8)
            .write(to: installsPath, options: .atomic)
        do {
            _ = try await NativeClient(baseURL: "", dataRootOverride: root).getCapabilityPackInstalls()
            Issue.record("A receipt without packId must not be presented as a capability pack.")
        } catch {
            #expect(error.localizedDescription.contains("no non-empty string packId"))
        }
        #expect(try Data(contentsOf: installsPath) == Data("[{\"id\":\"install:broken\",\"status\":\"installed\"}]".utf8))
    }

    private func pack(id: String, name: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string(name),
            "version": .string("1.0.0"),
            "items": .object([
                "catalog": .array([]),
                "workflows": .array([]),
                "skills": .array([]),
            ]),
        ]
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-pack-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
