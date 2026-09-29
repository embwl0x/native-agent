import Foundation
import PersistenceCore
import Skills
import MemoryV2

public enum SkillMutationRecallReconciliationError: Error, LocalizedError {
    case canonicalMutationCommitted

    public var errorDescription: String? {
        "The skill change was saved, but its recall pointers could not be refreshed. Recall may still reflect the earlier skill state; the saved change was not rolled back."
    }
}

public enum NativeSkillRegistryActions {
    public static func updateSkill(
        id: String, status: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> JSONValue {
        // wave 32 W15: gate to SwiftNativeSkillsClient.updateSkill when .skills
        // is ON. The Swift impl wraps the registry R-M-W in withFileLock and
        // fires the record_activity emission. Decode the returned skill object
        // with the shared native decoder.
        let impl = makeSkillsClient(root: dataRoot)
        let result = try await impl.updateSkill(body: .object(["id": .string(id), "status": .string(status)]))
        try await reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
        return result
    }

    public static func deleteSkill(
        id: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws {
        // wave 32 W15: gate to SwiftNativeSkillsClient.deleteSkill (registry
        // delete + body-file cleanup + manifest fallback + record_activity, all
        // flocked). The daemon route returns `{id, deleted:true[, source]}`;
        // the Mac caller discards the body (EmptyResponse), so we just run the
        // mutation and ignore the returned object.
        let impl = makeSkillsClient(root: dataRoot)
        _ = try await impl.deleteSkill(id: id)
        try await reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
    }

    public static func archiveSkill(
        id: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> JSONValue {
        let impl = makeSkillsClient(root: dataRoot)
        let result = try await impl.archiveSkill(id: id)
        try await reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
        return result
    }

    public static func restoreSkill(
        id: String, versionId: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> JSONValue {
        let impl = makeSkillsClient(root: dataRoot)
        let result = try await impl.restoreSkill(id: id, versionId: versionId)
        try await reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
        return result
    }

    public static func reconcileSkillEvolutionRecall(
        memory: SwiftNativeMemoryV2, dataRoot: URL, personaRoot: URL
    ) async throws {
        do {
            // Reuse the same serialized pointer owner and receipt as launch
            // and save_skill. A successful mutation return includes this
            // derived reconciliation, not merely a refreshed Skills screen.
            _ = try await memory.syncSkillPointersRecordingReceipt(
                bodiesDirs: [
                    dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
                    personaRoot.appendingPathComponent("skills/bodies", isDirectory: true),
                ],
                runtimeRegistryURL: dataRoot.appendingPathComponent("skills/registry.json"),
                receiptURL: dataRoot.appendingPathComponent("skills/.pointer_sync_receipt.json")
            )
        } catch {
            // The canonical mutation already committed. Never label this as
            // a failed archive/restore or silently claim recall is current.
            throw SkillMutationRecallReconciliationError.canonicalMutationCommitted
        }
    }
}
