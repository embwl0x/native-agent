import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramCommandPolicy.swift` | telegram-commands.js projects menu/help over native command identities through L0 PartFaces and prepares memory reply words before the native write; reserved Stop/approval controls, canonical memory provenance, storage and awaited reply settlement remain native; menu synchronization keys on the selected part version |

extension SwiftNativeTelegramBot {
    /// The native registry supplies executable names/usage; the face authors
    /// their words. Reserved controls cannot be removed or replaced by a part.
    func commandProjection() async throws -> (commands: [TelegramBotCommand], help: String, version: String) {
        let owner: Task<PartFaces, Never>
        if let commandFaces { owner = commandFaces }
        else {
            guard let call = partFace else {
                throw PartCallError(code: "unavailable", message: "The originating Telegram app door is not bound.")
            }
            let dataRoot = self.dataRoot
            owner = Task { @MainActor in PartFaces(dataRoot: dataRoot, call: call) }
            commandFaces = owner
        }
        let names = TelegramCommandRegistry.menuCommandNames
        let input: JSONValue = .object(["commands": .array(TelegramCommandRegistry.definitions.filter(\.showInMenu).map {
            .object(["name": .string($0.name), "usage": .string($0.usage)])
        })])
        let snapshot = await owner.value.sourceChanged(id: "telegram-commands", epoch: 1, input: input)
        guard snapshot.status == .ready, let version = snapshot.version, let face = snapshot.face else {
            throw snapshot.error ?? PartCallError(code: "unavailable", message: "The Telegram commands face is unavailable.")
        }
        guard let rows = face.sections.first(where: { $0.id == "menu" })?.rows,
              Set(rows.map(\.id)) == Set(names), rows.count == names.count,
              rows.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 256 }),
              let help = face.sections.first(where: { $0.id == "help" })?.rows.first(where: { $0.id == "body" })?.title,
              !help.isEmpty, help.count <= 3_500 else {
            throw PartCallError(code: "bad_result", message: "The commands face must retain every native menu control and bounded help text.")
        }
        return (rows.map { TelegramBotCommand(command: $0.id, description: $0.title) }, help,
            TelegramCommandRegistry.version + ":" + version)
    }

    private struct MemoryCommandWords: Decodable, Sendable {
        let requiresText: String; let unavailable: String; let success: String; let failure: String
    }

    func closeCommandFaces() async {
        let owner = commandFaces
        commandFaces = nil
        if let owner { await settle { await owner.value.close() } }
    }

    func memoryCommandReply(command: String, args: [String]) async -> String {
        let words: MemoryCommandWords
        do {
            words = try await callTelegramPart("telegram-commands", input: .object([
                "op": .string("memory"), "command": .string(command)
            ]))
        } catch { return "Telegram commands part unavailable: \(error.localizedDescription)" }
        let text = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return words.requiresText }
        guard let memory = completenessDeps?.memory else { return words.unavailable }
        // All authored wording is prepared before the canonical write. A part
        // failure cannot turn a committed memory into another write attempt.
        do {
            try Task.checkCancellation()
            let id = command == "remember"
                ? try await memory.remember(text: text, source: "telegram:/remember")
                : try await memory.note(text: text, kind: "telegram_note", source: "telegram:/note")
            return words.success + id
        } catch { return words.failure + error.localizedDescription }
    }

}
