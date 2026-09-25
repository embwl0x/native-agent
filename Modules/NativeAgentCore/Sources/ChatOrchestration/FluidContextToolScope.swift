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
                "message": .string("No context packet was prepared for this turn (context flow off, or its build failed), so there is nothing to expand; read the source directly instead (memory_search, read_file, or the tool that produced it)."),
            ])
        }
        // Blank means the one on offer; with several, name them (she sent {}
        // three times on 09-24 and got only a code back).
        let offered = prepared.packet.expandablePointers.map(\.atomID.rawValue)
        var given: String?
        if case .string(let text)? = input["atom_id"] {
            given = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[context_expand ", with: "")
                .split(separator: " ").first.map(String.init)
        }
        if given?.isEmpty != false, offered.count == 1 { given = offered[0] }
        guard let rawAtomID = given, !rawAtomID.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_atom_id"),
                "message": .string(offered.isEmpty
                    ? "Nothing in this turn's context is cut short, so there is nothing to expand."
                    : "Pass atom_id: one of offered_atom_ids (the id in a [context_expand atom:… ] marker)."),
                "offered_atom_ids": .array(offered.prefix(12).map(JSONValue.string)),
            ])
        }
        let atomID = ContextAtomID(rawValue: rawAtomID)
        guard let pointer = prepared.packet.expandablePointers.first(where: {
            $0.atomID == atomID
        }) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("pointer_not_offered_this_turn"),
                "message": .string("That atom id is not in this turn's context pointer list (ids from earlier turns expire); use an id listed this turn, or read the source directly."),
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
            maximumCharacters: requestedMaximum,
            // The expander does not infer which atoms were offered — this is
            // the packet the model was shown, so this is where the offer is
            // declared. Same list the pointer lookup above already searched.
            offeredTruncationAtomIDs: Set(
                prepared.packet.expandablePointers.map(\.atomID)
            )
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
