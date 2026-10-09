import Foundation
import PersistenceCore
import StandingBots

/// A return address for a deliberately requested check, not a bot scheduler or
/// second conversation. The canonical queue and shelf remain execution truth.
public enum BotRunConversation {
    typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    /// Run once from a Helper control uses the same durable return owner as a
    /// requested chat check. Scheduled occurrences never enter this boundary.
    public static func enqueueRequestedCheck(botID: UUID, dataRoot: URL) async throws -> UUID {
        let bot = try BotDefinitionStore(dataRoot: dataRoot).get(botID)
        let result = try await ChatToolSessionContext.withReplyRoute(.init(surface: "chat")) {
            try await dispatch(input: ["id": .string(botID.uuidString)], surface: "chat",
                               scope: bot.sessionID, dataRoot: dataRoot) { _, _ in
                let receipt = try BotRunQueue(dataRoot: dataRoot).enqueue(bot: botID)
                return .object(["status": .string(receipt.accepted ? "queued" : "joined"), "id": .string(botID.uuidString),
                                "requestId": .string(receipt.runID.uuidString)])
            }
        }
        guard case .object(let fields) = result, fields["automatic_return"] == .bool(true),
              case .string(let raw)? = fields["requestId"], let requestID = UUID(uuidString: raw) else {
            throw StandingBotsError.invalidValue("The requested check has no confirmed return address. Inspect its saved work before requesting it again.")
        }
        return requestID
    }

    static func dispatch(input: [String: JSONValue], surface: String, scope: String,
                         dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let bot = try definitions.get(botReference(input, definitions: definitions))
        guard !BotRunQueue.ancestry.contains(bot.id) else {
            throw StandingBotsError.invalidValue(BotRunQueue.alreadyExecutingWords)
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let agent = "bot-run:" + bot.id.uuidString
        if let old = try store.find(scopeSessionID: scope, agent: agent, label: "Requested check"),
           ["sending", "waiting"].contains(old.phase) || old.deliveryState == "delivering" {
            if old.automaticRead {
                guard case .string(let request)? = old.readInput?["message_id"], UUID(uuidString: request) != nil else {
                    throw StandingBotsError.invalidValue("The earlier check has no exact run reference. Inspect the helper's saved work; no second check was queued.")
                }
                return .object(["status": .string("joined"), "with": .string(bot.name),
                    "id": .string(bot.id.uuidString), "requestId": .string(request),
                    "automatic_return": .bool(true), "return_session": .string(old.scopeSessionID),
                    "read_with": .object(["action": .string("shelf.entry"), "args": .object([
                        "id": .string(request), "bot_id": .string(bot.id.uuidString)])]),
                    "detail": .string("Joined run \(request). Its result will return to conversation \(old.scopeSessionID) and be saved on the helper's shelf; no second check was queued.")])
            }
            _ = try store.update(id: old.id, operationID: old.operationID) {
                $0.phase = "attention"; $0.deliveryState = "interrupted"
                $0.receipt = .object(["status": .string("interrupted"),
                    "detail": .string("The earlier check's queue acknowledgement was interrupted. No run was repeated.")])
            }
            return .object(["status": .string("interrupted"), "with": .string(bot.name),
                "detail": .string("The earlier check's queue acknowledgement was interrupted. Its result is not confirmed, and no new run was queued. Check the bot's saved work before requesting another check.")])
        }
        let replyRoute = ChatToolSessionContext.replyRoute.map { route in
            ["surface": route.surface, "destinationId": route.destinationId,
             "threadId": route.threadId, "sourceKey": route.sourceKey,
             "replyTo": route.replyTo, "correlationId": route.correlationId].compactMapValues { $0 }
        }
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: bot.name,
            label: "Requested check", fresh: false, sourceSurface: surface, fingerprint: nil, replyRoute: replyRoute)
        let result: JSONValue
        do { result = try await perform("bot_run_once", input) }
        catch {
            _ = try? store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "attention"; $0.deliveryState = "interrupted"
                $0.receipt = .object(["status": .string("interrupted"),
                    "detail": .string("The check did not return a confirmed queue receipt. It was not retried.")])
            }
            throw error
        }
        guard case .object(var fields) = result, [JSONValue.string("queued"), .string("joined")].contains(fields["status"] ?? .null),
              case .string(let returnedBot)? = fields["id"], UUID(uuidString: returnedBot) == bot.id,
              case .string(let request)? = fields["requestId"], let requestID = UUID(uuidString: request) else {
            _ = try? store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "attention"; $0.deliveryState = "not_registered"; $0.receipt = AgentConversationStore.cacheReceipt(result)
            }
            return result
        }
        do {
            _ = try store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "waiting"; $0.automaticRead = true; $0.nextReadAt = Date()
                $0.name = bot.name
                $0.conversationID = "bot:" + bot.id.uuidString
                $0.readInput = ["agent": .string("bot:" + bot.id.uuidString), "message_id": .string(requestID.uuidString)]
                $0.receipt = AgentConversationStore.cacheReceipt(result)
            }
            fields["with"] = .string(bot.name)
            fields["automatic_return"] = .bool(true)
            fields["return_session"] = .string(scope)
            fields["detail"] = .string("\(fields["status"] == .string("joined") ? "Joined" : "Queued") run \(requestID.uuidString). Its result will return to conversation \(scope) and be saved on the helper's shelf; you can keep talking in the meantime.")
        } catch {
            fields["automatic_return"] = .bool(false)
            fields["detail"] = .string("The run was accepted, but its return address could not be saved. Read the exact saved result later; do not queue the check again.")
        }
        return .object(fields)
    }
}
