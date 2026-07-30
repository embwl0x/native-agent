import Context
import Foundation
import NativeAgentCore
import PersistenceCore

enum FluidContextToolScope {
    @TaskLocal static var current: ContextPreparedTurn?
}

extension SwiftToolDispatcher {
    func impl_context_expand(input: [String: JSONValue], surface: String) throws -> JSONValue {
        guard let prepared = FluidContextToolScope.current else {
            return .object([
                "status": .string("failed"),
                "reason": .string("context_generation_unavailable"),
            ])
        }
        guard case .string(let rawAtomID)? = input["atom_id"] else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_atom_id"),
            ])
        }
        let atomID = ContextAtomID(rawValue: rawAtomID)
        guard let pointer = prepared.packet.expandablePointers.first(where: {
            $0.atomID == atomID
        }) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("pointer_not_offered_this_turn"),
                "atom_id": .string(rawAtomID),
            ])
        }
        let requestedMaximum: Int? = {
            guard case .int(let value)? = input["max_characters"] else { return nil }
            return Int(clamping: value)
        }()
        let result = try ContextExpander().expand(
            pointer,
            for: prepared.need,
            from: prepared.generation,
            pinnedTo: prepared.lease.snapshot,
            maximumCharacters: requestedMaximum
        )
        Task {
            await prepared.recordExpansion(
                atomID: result.receipt.atomID,
                receiptID: result.receipt.id
            )
        }
        return .object([
            "status": .string("ok"),
            "generation_id": .int(result.receipt.generationID),
            "atom_id": .string(result.receipt.atomID.rawValue),
            "source_id": .string(result.receipt.sourceID.rawValue),
            "text": .string(result.text),
            "truncated": .bool(result.truncated),
            "receipt_id": .string(result.receipt.id),
        ])
    }
}
