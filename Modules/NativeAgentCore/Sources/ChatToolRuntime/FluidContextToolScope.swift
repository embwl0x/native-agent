import Context
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

package enum FluidContextToolScope {
    @TaskLocal package static var current: ContextPreparedTurn?
}

extension SwiftToolDispatcher {
    func impl_context_expand(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let locator = (jsonString(input["atom_id"]) ?? "")
            .replacingOccurrences(of: "[context_expand ", with: "")
            .replacingOccurrences(of: "[context.expand ", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "]")))
        if locator.hasPrefix("history:") {
            guard let sessionID = ChatToolSessionContext.verifiedSessionId ?? LLMCallContext.sessionId,
                  !sessionID.isEmpty else {
                throw AutonomyGateError.toolDenied(reason: "History expansion requires the current conversation.")
            }
            if let offset = input["offset"], offset != .null {
                guard case .int(let value) = offset, value >= 0 else {
                    throw ContextExpansionError.invalidCharacterOffset
                }
            }
            let maximum = max(1, min(optionalInt(input, "max_characters") ?? 8_000, 12_000))
            let result = try await impl_read_chat_message(input: [
                "session_id": .string(sessionID),
                "message_id": .string(String(locator.dropFirst("history:".count))),
                "offset": input["offset"] ?? .int(0),
                "limit": .int(Int64(maximum)),
            ], invokedAs: "context_expand")
            guard case .object(var fields) = result else { return result }
            fields["atom_id"] = .string(locator)
            if fields["has_more"] == .bool(true),
               case .int(let start)? = fields["offset"],
               case .int(let count)? = fields["returned_characters"] {
                fields["next_offset"] = .int(start + count)
            } else {
                fields["next_offset"] = .null
            }
            return .object(fields)
        }
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
        var given = locator.split(separator: " ").first.map(String.init)
        if given?.isEmpty != false, offered.count == 1 { given = offered[0] }
        guard let rawAtomID = given, !rawAtomID.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_atom_id"),
                "message": .string(offered.isEmpty
                    ? "Nothing in this turn's context is cut short, so there is nothing to expand."
                    : "Pass atom_id: one of offered_atom_ids (the id in a [context.expand atom:… ] marker)."),
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
        let offset: Int
        switch input["offset"] {
        case nil, .null?:
            offset = 0
        case .int(let value)?:
            offset = Int(clamping: value)
        default:
            throw ContextExpansionError.invalidCharacterOffset
        }
        let result = try ContextExpander().expand(
            pointer,
            for: prepared.need,
            from: prepared.generation,
            pinnedTo: prepared.lease.snapshot,
            maximumCharacters: requestedMaximum,
            offset: offset,
            offeredSelectedItems: prepared.packet.selectedItems.filter { item in
                prepared.packet.expandablePointers.contains(item.pointer)
            }
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
            "offset": .int(Int64(result.receipt.characterOffset)),
            "next_offset": result.nextOffset.map { .int(Int64($0)) } ?? .null,
            "full_character_count": .int(Int64(result.receipt.fullCharacterCount)),
            "truncated": .bool(result.truncated),
            "receipt_id": .string(result.receipt.id),
        ])
    }
}
