import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeApprovalInbox {
    /// Pre-owner restore merge for monotonic approval facts. This is invoked
    /// before the app constructs ApprovalInbox, so there is no live writer to
    /// coordinate with. Existing malformed destination bytes throw and remain
    /// untouched; they are never treated as an empty store.
    public nonisolated static func mergeRestoreFences(
        safetyRoot: URL,
        destinationRoot: URL
    ) throws {
        try mergeSpendStore(
            safetyPath: effectSpendPath(root: safetyRoot),
            destinationPath: effectSpendPath(root: destinationRoot),
            schema: effectSpendSchema,
            loader: loadEffectSpends
        )
        try mergeSpendStore(
            safetyPath: injectionSpendPath(root: safetyRoot),
            destinationPath: injectionSpendPath(root: destinationRoot),
            schema: injectionSpendSchema,
            loader: loadSpends
        )
        try mergeApprovalResolutionFacts(
            safetyPath: approvalsPath(root: safetyRoot),
            destinationPath: approvalsPath(root: destinationRoot)
        )
    }

    private nonisolated static func effectSpendPath(root: URL) -> URL {
        approvalsDirectory(root: root).appendingPathComponent("effect_spends.json")
    }

    private nonisolated static func injectionSpendPath(root: URL) -> URL {
        approvalsDirectory(root: root).appendingPathComponent("injection_spends.json")
    }

    private nonisolated static func approvalsPath(root: URL) -> URL {
        approvalsDirectory(root: root).appendingPathComponent("requests.json")
    }

    private nonisolated static func approvalsDirectory(root: URL) -> URL {
        root.appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
    }

    private nonisolated static func mergeSpendStore(
        safetyPath: URL,
        destinationPath: URL,
        schema: String,
        loader: (URL) throws -> [String: JSONValue]
    ) throws {
        guard FileManager.default.fileExists(atPath: safetyPath.path) else { return }
        let safety = try loader(safetyPath)
        var destination = try loader(destinationPath)
        for (id, marker) in safety { destination[id] = marker }
        try writeRestoreJSON(
            .object(["schema": .string(schema), "spends": .object(destination)]),
            to: destinationPath
        )
    }

    private nonisolated static func mergeApprovalResolutionFacts(
        safetyPath: URL,
        destinationPath: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: safetyPath.path) else { return }
        let safety = try loadApprovalRowsChecked(at: safetyPath)
        var destination = try loadApprovalRowsChecked(at: destinationPath)
        var destinationIndexes: [String: Int] = [:]
        for (index, value) in destination.enumerated() {
            if case .object(let object) = value,
               case .string(let id)? = object["id"] {
                destinationIndexes[id] = index
            }
        }

        let terminal: Set<String> = ["resolved", "denied", "canceled", "orphaned"]
        for value in safety {
            guard case .object(let safetyObject) = value,
                  case .string(let id)? = safetyObject["id"],
                  case .string(let status)? = safetyObject["status"],
                  terminal.contains(status) || safetyObject["executedAction"] != nil else {
                continue
            }
            guard let index = destinationIndexes[id],
                  case .object(var targetObject) = destination[index] else {
                destinationIndexes[id] = destination.count
                destination.append(value)
                continue
            }
            guard targetObject["action"] == safetyObject["action"],
                  targetObject["payload"] == safetyObject["payload"] else {
                throw ApprovalInboxError.malformedResponse(
                    "restore fence id \(id) refers to different approval payloads"
                )
            }
            // Resolution and execution facts only move forward. Descriptive
            // payload/title bytes still come from the selected backup.
            for key in [
                "status", "decision", "resolvedAt", "decidedBy",
                "resolutionProvenance", "executedAction", "detail",
            ] where safetyObject[key] != nil {
                targetObject[key] = safetyObject[key]
            }
            destination[index] = .object(targetObject)
        }
        try writeRestoreJSON(.array(destination), to: destinationPath)
    }

    private nonisolated static func writeRestoreJSON(_ value: JSONValue, to path: URL) throws {
        let bytes = try value.serializedData(pretty: true)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: path, options: .atomic)
    }
}
