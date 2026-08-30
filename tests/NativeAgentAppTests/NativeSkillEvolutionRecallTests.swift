import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Skills
import Testing
@testable import NativeAgentApp

@Suite("Native skill evolution recall continuity")
struct NativeSkillEvolutionRecallTests {
    private let firstBody = "# Orchard Notes\n\nUse when recording FIRST observations of the orchard."
    private let secondBody = "# Orchard Notes\n\nUse when recording SECOND observations of the orchard."

    private func string(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = value, case .string(let text)? = object[key] else { return nil }
        return text
    }

    private func fixture() async throws -> (URL, MemoryStorage, SwiftNativeMemoryV2, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-evolution-recall-\(UUID())")
        let store = try MemoryStorage(dataRoot: root)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 8), storage: MemoryStorageBridge(storage: store)
        )
        let client = makeSkillsClient(root: root)
        _ = try await client.createSkill(body: .object([
            "name": .string("Orchard Notes"), "content": .string(firstBody),
        ]))
        let versions = try await client.listSkillVersions(id: "orchard-notes")
        let firstVersion = try #require(versions.first)
        let firstVersionID = try #require(string(firstVersion, "versionId"))
        _ = try await client.createSkill(body: .object([
            "name": .string("Orchard Notes"), "content": .string(secondBody),
        ]))
        _ = try await memory.syncSkillPointers(
            bodiesDirs: [root.appendingPathComponent("skills/bodies"), root.appendingPathComponent("persona/skills/bodies")],
            runtimeRegistryURL: root.appendingPathComponent("skills/registry.json")
        )
        return (root, store, memory, firstVersionID)
    }

    @Test func archiveAndRestoreReturnOnlyAfterPointerMatchesCanonicalVersion() async throws {
        let (root, store, memory, firstVersionID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pointerID = "skill-pointer:orchard-notes"
        let bodyPath = root.appendingPathComponent("skills/bodies/orchard-notes.md")
        let before = try #require(try await store.memory(id: pointerID))
        #expect(before.content.contains("SECOND"))
        let archived = try await NativeClient.archiveSkill(
            id: "orchard-notes", dataRoot: root, memory: memory, personaRoot: root.appendingPathComponent("persona")
        )
        #expect(archived.status == "archived")
        let retired = try #require(try await store.memory(id: pointerID))
        #expect(retired.status == "deleted")
        #expect(try String(contentsOf: bodyPath, encoding: .utf8) == secondBody)
        let client = makeSkillsClient(root: root)
        let archivedVersions = try await client.listSkillVersions(id: "orchard-notes")
        let archivedVersion = try #require(archivedVersions.first)
        let archivedVersionID = try #require(string(archivedVersion, "versionId"))

        let restored = try await NativeClient.restoreSkill(
            id: "orchard-notes", versionId: firstVersionID, dataRoot: root,
            memory: memory, personaRoot: root.appendingPathComponent("persona")
        )
        #expect(restored.status == "active")
        let revived = try #require(try await store.memory(id: pointerID))
        #expect(revived.status == "active")
        #expect(revived.content.contains("FIRST"))
        #expect(!revived.content.contains("SECOND"))
        #expect(try String(contentsOf: bodyPath, encoding: .utf8) == firstBody)
        #expect(try await store.isTombstoned(content: retired.content) == false)

        // Restoring an archived version restores that status, not an implicit
        // activation. Its body remains available to explicit skill reads.
        let restoredArchive = try await NativeClient.restoreSkill(
            id: "orchard-notes", versionId: archivedVersionID, dataRoot: root,
            memory: memory, personaRoot: root.appendingPathComponent("persona")
        )
        #expect(restoredArchive.status == "archived")
        let stillRetired = try #require(try await store.memory(id: pointerID))
        #expect(stillRetired.status == "deleted")
        #expect(try String(contentsOf: bodyPath, encoding: .utf8) == secondBody)
        let receipt = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/.pointer_sync_receipt.json")))
        #expect(string(receipt, "status") == "ok")
    }

    @Test(arguments: [false, true])
    func reconcileFailureReportsCommittedMutationWithoutRollback(restoring: Bool) async throws {
        let (root, store, memory, firstVersionID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        if restoring {
            _ = try await NativeClient.archiveSkill(
                id: "orchard-notes", dataRoot: root, memory: memory, personaRoot: root.appendingPathComponent("persona")
            )
        }
        do {
            if restoring {
                _ = try await NativeClient.restoreSkill(
                    id: "orchard-notes", versionId: firstVersionID, dataRoot: root,
                    memory: SwiftNativeMemoryV2(), personaRoot: root.appendingPathComponent("persona")
                )
            } else {
                _ = try await NativeClient.archiveSkill(
                    id: "orchard-notes", dataRoot: root, memory: SwiftNativeMemoryV2(), personaRoot: root.appendingPathComponent("persona")
                )
            }
            Issue.record("unavailable pointer owner reported complete success")
        } catch let error as SkillMutationRecallReconciliationError {
            #expect(error.localizedDescription.contains("change was saved"))
            #expect(error.localizedDescription.contains("not rolled back"))
        }
        let registry = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/registry.json")))
        guard case .array(let rows) = registry, let row = rows.first else { Issue.record("missing saved skill"); return }
        #expect(string(row, "status") == (restoring ? "active" : "archived"))
        let body = try String(contentsOf: root.appendingPathComponent("skills/bodies/orchard-notes.md"), encoding: .utf8)
        #expect(body == (restoring ? firstBody : secondBody))
        let pointer = try #require(try await store.memory(id: "skill-pointer:orchard-notes"))
        #expect(pointer.status == (restoring ? "deleted" : "active"))
        let receipt = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/.pointer_sync_receipt.json")))
        #expect(string(receipt, "status") == "failed")
    }

    @Test func statusAndDeleteCompleteWithMatchingRecallPointer() async throws {
        let (root, store, memory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona")
        let pointerID = "skill-pointer:orchard-notes"
        let disabled = try await NativeClient.updateSkill(
            id: "orchard-notes", status: "disabled", dataRoot: root, memory: memory, personaRoot: personaRoot
        )
        #expect(disabled.status == "disabled")
        let retired = try #require(try await store.memory(id: pointerID))
        #expect(retired.status == "deleted")
        let active = try await NativeClient.updateSkill(
            id: "orchard-notes", status: "active", dataRoot: root, memory: memory, personaRoot: personaRoot
        )
        #expect(active.status == "active")
        let revived = try #require(try await store.memory(id: pointerID))
        #expect(revived.status == "active")
        #expect(revived.content.contains("SECOND"))
        _ = try await NativeClient.deleteSkill(id: "orchard-notes", dataRoot: root, memory: memory, personaRoot: personaRoot)
        let removed = try #require(try await store.memory(id: pointerID))
        #expect(removed.status == "deleted")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/bodies/orchard-notes.md").path))
        #expect(try await store.isTombstoned(content: removed.content) == false)
        let registry = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/registry.json")))
        #expect(registry == .array([]))
        let versions = try await makeSkillsClient(root: root).listSkillVersions(id: "orchard-notes")
        #expect(versions.contains { string($0, "reason") == "before-delete" })
    }

    @Test(arguments: [false, true])
    func statusAndDeletePartialFailureKeepCommittedCanonicalState(deleting: Bool) async throws {
        let (root, store, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            if deleting {
                _ = try await NativeClient.deleteSkill(
                    id: "orchard-notes", dataRoot: root, memory: SwiftNativeMemoryV2(), personaRoot: root.appendingPathComponent("persona")
                )
            } else {
                _ = try await NativeClient.updateSkill(
                    id: "orchard-notes", status: "disabled", dataRoot: root,
                    memory: SwiftNativeMemoryV2(), personaRoot: root.appendingPathComponent("persona")
                )
            }
            Issue.record("unavailable pointer owner reported complete success")
        } catch let error as SkillMutationRecallReconciliationError {
            #expect(error.localizedDescription.contains("change was saved"))
        }
        let registry = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/registry.json")))
        guard case .array(let rows) = registry else { Issue.record("invalid registry"); return }
        if deleting {
            #expect(rows.isEmpty)
        } else {
            let row = try #require(rows.first)
            #expect(string(row, "status") == "disabled")
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/bodies/orchard-notes.md").path) == !deleting)
        let stale = try #require(try await store.memory(id: "skill-pointer:orchard-notes"))
        #expect(stale.status == "active")
        let receipt = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/.pointer_sync_receipt.json")))
        #expect(string(receipt, "status") == "failed")
    }

    @Test(arguments: [false, true])
    func runtimeEnableAwaitsRecallOrReportsCommittedPartialFailure(unavailable: Bool) async throws {
        let (root, store, memory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona")
        _ = try await NativeClient.updateSkill(
            id: "orchard-notes", status: "draft", dataRoot: root, memory: memory, personaRoot: personaRoot
        )
        let client = makeSkillsClient(root: root)
        let priorVersions = try await client.listSkillVersions(id: "orchard-notes")
        do {
            try await NativeClient.enableSkill(
                name: "orchard-notes", dataRoot: root,
                memory: unavailable ? SwiftNativeMemoryV2() : memory, personaRoot: personaRoot
            )
            #expect(!unavailable)
        } catch is SkillMutationRecallReconciliationError {
            #expect(unavailable)
        }
        let registry = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/registry.json")))
        guard case .array(let rows) = registry, let row = rows.first else { Issue.record("missing skill"); return }
        #expect(string(row, "status") == "active")
        let pointer = try #require(try await store.memory(id: "skill-pointer:orchard-notes"))
        #expect(pointer.status == (unavailable ? "deleted" : "active"))
        let receipt = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("skills/.pointer_sync_receipt.json")))
        #expect(string(receipt, "status") == (unavailable ? "failed" : "ok"))
        let versions = try await client.listSkillVersions(id: "orchard-notes")
        #expect(versions.count == priorVersions.count + 2) // one mutation, not enable then update
    }

    @Test func manifestOnlyEnableRegistersWithoutCreatingARecallOwnerOrBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-enable-only-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registryPath = root.appendingPathComponent("skills/manifest_registry.json")
        try FileManager.default.createDirectory(at: registryPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONValue.object(["skills": .object([
            "manifest-only": .object(["state": .string("drafted")]),
        ])]).serializedData(pretty: false).write(to: registryPath)
        try await NativeClient.enableSkill(
            name: "manifest-only", dataRoot: root, memory: nil, personaRoot: root.appendingPathComponent("persona")
        )
        let registry = try JSONValue.parse(Data(contentsOf: registryPath))
        guard case .object(let object) = registry, case .object(let skills)? = object["skills"],
              let row = skills["manifest-only"] else { Issue.record("missing manifest row"); return }
        #expect(string(row, "state") == "installed")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("memory").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/bodies").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/.pointer_sync_receipt.json").path))
    }
}
