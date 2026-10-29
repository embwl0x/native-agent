import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ApprovalInbox+RestoreFences.swift` | `SwiftNativeApprovalInbox.mergeRestoreFences`: pre-owner restore merge of monotonic spends, resolutions and continuation facts, with unreadable-piece receipts |

extension SwiftNativeApprovalInbox {
    /// Pre-owner restore merge for monotonic approval facts. This is invoked
    /// before the app constructs ApprovalInbox, so there is no live writer to
    /// coordinate with. An unreadable piece is omitted with a receipt; it never
    /// prevents installing the backup or suppresses another readable piece.
    public nonisolated static func mergeRestoreFences(
        safetyRoot: URL,
        destinationRoot: URL
    ) throws -> [String] {
        var notes: [String] = []
        func carry(_ piece: String, _ merge: () throws -> String?) throws {
            if let cause = try merge() {
                notes.append("workflows/approvals/\(piece): \(cause); current consumption or resolution facts from this piece were not kept.")
            }
        }
        try carry("effect_spends.json") { try mergeSpendStore(
            safetyPath: effectSpendPath(root: safetyRoot),
            destinationPath: effectSpendPath(root: destinationRoot),
            schema: effectSpendSchema,
            actionField: "action"
        ) }
        try carry("injection_spends.json") { try mergeSpendStore(
            safetyPath: injectionSpendPath(root: safetyRoot),
            destinationPath: injectionSpendPath(root: destinationRoot),
            schema: injectionSpendSchema,
            actionField: "tool"
        ) }
        try carry("requests.json") { try mergeApprovalResolutionFacts(
            safetyPath: approvalsPath(root: safetyRoot),
            destinationPath: approvalsPath(root: destinationRoot)
        ) }
        return notes
    }

    nonisolated static func effectSpendPath(root: URL) -> URL {
        approvalsDirectory(root: root).appendingPathComponent("effect_spends.json")
    }

    nonisolated static func injectionSpendPath(root: URL) -> URL {
        approvalsDirectory(root: root).appendingPathComponent("injection_spends.json")
    }

    nonisolated static func approvalsPath(root: URL) -> URL {
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
        actionField: String
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: safetyPath.path) else { return nil }
        let safety: [String: JSONValue]
        do { safety = try loadSpends(at: safetyPath, schema: schema, actionField: actionField) }
        catch { return error.localizedDescription }
        var destination = try loadSpends(at: destinationPath, schema: schema, actionField: actionField)
        for (id, marker) in safety { destination[id] = marker }
        try writeRestoreJSON(
            .object(["schema": .string(schema), "spends": .object(destination)]),
            to: destinationPath
        )
        return nil
    }

    private nonisolated static func mergeApprovalResolutionFacts(
        safetyPath: URL,
        destinationPath: URL
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: safetyPath.path) else { return nil }
        let safety: [JSONValue]
        do { safety = try loadApprovalRowsChecked(at: safetyPath) }
        catch { return error.localizedDescription }
        var destination = try loadApprovalRowsChecked(at: destinationPath)
        var destinationIndexes: [String: Int] = [:]
        for (index, value) in destination.enumerated() {
            if case .object(let object) = value,
               case .string(let id)? = object["id"] {
                destinationIndexes[id] = index
            }
        }

        for value in safety {
            guard case .object(let safetyObject) = value,
                  case .string(let id)? = safetyObject["id"],
                  case .string(let status)? = safetyObject["status"],
                  terminalApprovalStatuses.contains(status) || safetyObject["executedAction"] != nil else {
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
                return "restore fence id \(id) refers to different approval payloads"
            }
            // Resolution, execution and continuation facts only move forward.
            // Descriptive payload/title bytes still come from the selected backup.
            for key in [
                "status", "decision", "resolvedAt", "decidedBy",
                "resolutionProvenance", "executedAction", "detail",
                "chatContinuation",
            ] where safetyObject[key] != nil {
                targetObject[key] = safetyObject[key]
            }
            destination[index] = .object(targetObject)
        }
        try writeRestoreJSON(.array(destination), to: destinationPath)
        return nil
    }

    private nonisolated static func writeRestoreJSON(_ value: JSONValue, to path: URL) throws {
        let bytes = try value.serializedData(pretty: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
    }
}
