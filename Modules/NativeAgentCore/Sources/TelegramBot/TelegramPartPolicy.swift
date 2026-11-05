import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPartPolicy.swift` | Parts draw checked choices; native code owns callback admission and routing writes |
// Use the originating door's canonical turn envelope; a separate origin would split authority.

public typealias TelegramPartCall = @Sendable (_ id: String, _ input: JSONValue, _ turn: Turn) async -> PartCallResult<JSONValue>

struct TelegramModelPickerDecision: Codable, Sendable {
    struct Selection: Codable, Sendable { let providerId: String?; let modelId: String }
    let selection: Selection?
    let reply: String?
    let text: String?
    let markup: JSONValue?
}

extension SwiftNativeTelegramBot {
    func callTelegramPart<Value: Decodable & Sendable>(_ id: String, input: JSONValue, turn: Turn,
        as type: Value.Type = Value.self) async throws -> Value {
        guard let partCall else {
            throw PartCallError(code: "unavailable", message: "The originating Telegram app door is not bound.")
        }
        switch await partCall(id, input, turn) {
        case .success(let value):
            return try JSONDecoder().decode(type, from: value.serializedData(pretty: false))
        case .failure(let error): throw error
        }
    }

    /// Callback identities are made here from checked routing choices. The part can arrange their buttons, but cannot introduce another callback action.
    func modelPicker(_ op: String, menu: TelegramModelMenu?, args: [String] = [],
        providerId: String? = nil, modelId: String? = nil, turn: Turn) async throws -> TelegramModelPickerDecision {
        let packet: JSONValue = menu.map { menu in .object([
            "surface": .string(menu.surface), "currentModel": .string(menu.currentModel),
            "currentProvider": .string(menu.currentProvider),
            "providers": .array(menu.providers.map { provider in .object([
                "id": .string(provider.id), "displayName": .string(provider.displayName),
                "isCurrent": .bool(provider.isCurrent),
                "callback": .string(TelegramModelSelectionCallback.providerData(id: provider.id)),
                "models": .array(provider.models.map { model in .object([
                    "id": .string(model.id), "name": .string(model.name), "isCurrent": .bool(model.isCurrent),
                    "callback": .string(TelegramModelSelectionCallback.modelData(providerId: provider.id, modelId: model.id))
                ]) })
            ]) })
        ]) } ?? .null
        let current = packet == .null ? menu : nil
        let decision: TelegramModelPickerDecision = try await callTelegramPart("telegram-model-picker", input: .object([
            "op": .string(op), "menu": packet,
            "menuStatus": .string(packet == .null ? "unavailable" : "available"),
            "args": .array(args.map(JSONValue.string)),
            "providerId": providerId.map(JSONValue.string) ?? .null,
            "modelId": modelId.map(JSONValue.string) ?? .null,
            "providersCallback": .string(TelegramModelSelectionCallback.providersData),
            "current": .object(["status": .string(current == nil ? "unavailable" : "available"),
                "model": current.map { .string($0.currentModel) } ?? .null,
                "provider": current.map { .string($0.currentProvider) } ?? .null])
        ]), turn: turn)
        if op == "command", decision.reply?.isEmpty != false {
            throw PartCallError(code: "bad_result", message: "The model picker returned no command reply.")
        }
        return decision
    }

    func modelPickerPresentation(_ op: String, menu: TelegramModelMenu,
        providerId: String? = nil, modelId: String? = nil, turn: Turn) async throws -> (text: String, markup: JSONValue) {
        let decision = try await modelPicker(op, menu: menu, providerId: providerId, modelId: modelId, turn: turn)
        guard let text = decision.text, !text.isEmpty, text.count <= 4_096,
              case .object(let markup)? = decision.markup,
              Set(markup.keys) == ["inline_keyboard"],
              case .array(let rows)? = markup["inline_keyboard"], rows.count <= 41 else {
            throw PartCallError(code: "bad_result", message: "The model picker returned an invalid Telegram menu.")
        }
        let allowed = Set(menu.providers.flatMap { provider in
            [TelegramModelSelectionCallback.providerData(id: provider.id)] + provider.models.map {
                TelegramModelSelectionCallback.modelData(providerId: provider.id, modelId: $0.id)
            }
        } + [TelegramModelSelectionCallback.providersData])
        for row in rows {
            guard case .array(let buttons) = row, buttons.count == 1,
                  case .object(let button) = buttons[0], Set(button.keys) == ["text", "callback_data"],
                  let title = button["text"]?.stringValue, !title.isEmpty,
                  let key = button["callback_data"]?.stringValue, allowed.contains(key) else {
                throw PartCallError(code: "bad_result", message: "The model picker returned a button outside the checked routing choices.")
            }
        }
        let issues = menu.catalogIssues
        let presented = issues.isEmpty ? text : text + "\n" + issues
        guard presented.count <= 4_096 else {
            throw PartCallError(code: "bad_result", message: "Telegram model catalog diagnostics exceed the menu limit. Read Providers to repair its catalogs.")
        }
        return (presented, .object(markup))
    }
}
