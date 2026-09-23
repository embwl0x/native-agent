import Foundation
import PersistenceCore
import StandingBots

/// A return address for a deliberately requested check, not a bot scheduler or
/// second conversation. The canonical queue and shelf remain execution truth.
enum BotRunConversation {
    typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    static func dispatch(input: [String: JSONValue], surface: String, scope: String,
                         dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let bot = try definitions.get(botReference(input, definitions: definitions))
        let store = AgentConversationStore(dataRoot: dataRoot)
        let agent = "bot-run:" + bot.id.uuidString
        if let old = try store.find(scopeSessionID: scope, agent: agent, label: "Requested check"),
           ["sending", "waiting"].contains(old.phase) || old.deliveryState == "delivering" {
            if old.automaticRead {
                return .object(["status": .string("waiting"), "with": .string(bot.name),
                    "detail": .string("That requested check is already being handled. Its result will return here; no second check was queued.")])
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
        guard case .object(var fields) = result, fields["status"] == .string("queued"),
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
            fields["detail"] = .string("The check is queued. Its result will return to this conversation; you can keep talking in the meantime.")
        } catch {
            fields["automatic_return"] = .bool(false)
            fields["detail"] = .string("The check was queued, but its return address could not be saved. Read the exact saved result later; do not queue the check again.")
        }
        return .object(fields)
    }
}
